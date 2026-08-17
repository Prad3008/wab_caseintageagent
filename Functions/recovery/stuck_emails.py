"""SQL access for Function D — the stuck-writes scan, and its retry write.

find_stuck_instances() only *finds* which rows are stalled; retry() is the
one write this module owns — creating a new attempt row for a stuck
activity_id through the real dbo.usp_cia_email_instance_b1_write stored
proc, the same write path B.1 always uses (retry-path branch: carries
forward whatever's valid based on the prior attempt's resume_processing_stage).
Callers must check attempt_number against RecoveryConfig.max_retry_attempts
themselves before calling retry() — seeing find_stuck_instances()'s own
result is cheaper than this module re-querying the same thing.

Only looks at dbo.cia_email_instance — no dbo.cia_queue_item comparison.
A queue_item can't exist without an email_instance row (B.1 always writes
cia_email_instance before B.2 ever touches cia_queue_item), so there is no
"orphan queue item" case to scan for here.

Table/column names verified directly against sqldb-case-intake-dev on
2026-08-07 (INFORMATION_SCHEMA + sys.columns): dbo.cia_email_instance, not
the email_instance/vw_email_instance_latest names an earlier draft of this
module assumed — there is no such view, and there is no correlation_id
column.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import pyodbc

from .config import RecoveryConfig

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class StuckInstance:
    """One dbo.cia_email_instance row that either stalled before reaching a
    terminal status, or has an explicitly recorded stage failure.

    Sourced from the latest attempt (highest attempt_number) per activity_id
    — never a superseded retry row. Field names mirror the real
    dbo.cia_email_instance columns (verified against sqldb-case-intake-dev on
    2026-08-07) rather than the email_instance/correlation_id names an
    earlier draft of this package assumed — there is no correlation_id
    column; activity_id is the only identity carried across attempts.
    """

    email_instance_id: str
    activity_id: str
    attempt_number: int
    status_code: int
    last_completed_stage: str
    resume_processing_stage: str  # computed column; where the orchestrator should resume
    case_payload: str | None  # dbo.cia_email_instance.crm_case_payload, replayed as-is
    skip_queueitem_write: bool  # computed column; True once past B.1 — a queue_item already exists
    failed_stage: str | None  # computed column (JSON_VALUE of status_details); which stage recorded a failure, if any

# "Latest attempt per activity_id" replaces the nonexistent
# vw_email_instance_latest view: cia_email_instance has one row per attempt
# (uq_email_instance_activity_attempt on activity_id+attempt_number), so the
# current attempt is the max attempt_number per activity_id.
#
# A row qualifies either way:
#   - status_code NOT IN (?) AND modified_date_time older than the write
#     window: stopped making progress mid-pipeline without ever reaching a
#     recorded terminal outcome (see RecoveryConfig.terminal_status_codes).
#   - failed_stage IS NOT NULL: a specific B.x stage explicitly recorded a
#     failure (JSON_VALUE of status_details) — that's not going to resolve
#     itself by waiting, so it's picked up immediately regardless of
#     status_code or age.
# modified_date_time is assumed UTC, matching created_date_time's use
# elsewhere in this schema.
_FIND_STUCK_INSTANCES_SQL_TEMPLATE = """
WITH latest_attempt AS (
    SELECT
        email_instance_id, activity_id, attempt_number, status_code,
        last_completed_stage, resume_processing_stage, crm_case_payload,
        skip_queueitem_write, failed_stage, modified_date_time,
        ROW_NUMBER() OVER (PARTITION BY activity_id ORDER BY attempt_number DESC) AS rn
    FROM dbo.cia_email_instance
)
SELECT email_instance_id, activity_id, attempt_number, status_code,
       last_completed_stage, resume_processing_stage, crm_case_payload,
       skip_queueitem_write, failed_stage
FROM latest_attempt
WHERE rn = 1
  AND (
        (status_code NOT IN ({terminal_placeholders})
         AND modified_date_time < DATEADD(MINUTE, -?, SYSUTCDATETIME()))
        OR failed_stage IS NOT NULL
      )
"""

# T-SQL OUTPUT parameters aren't directly readable through pyodbc's execute()
# return value, so the proc call is wrapped in a batch that captures them
# into local variables and SELECTs them back as an ordinary result set —
# the standard pattern for calling a proc with OUTPUT params via pyodbc.
_B1_WRITE_SQL = """
DECLARE @new_email_instance_id UNIQUEIDENTIFIER, @skip_queueitem_write BIT;
EXEC dbo.usp_cia_email_instance_b1_write
    @activity_id = ?,
    @subject = ?,
    @new_email_instance_id = @new_email_instance_id OUTPUT,
    @skip_queueitem_write = @skip_queueitem_write OUTPUT;
SELECT @new_email_instance_id AS new_email_instance_id, @skip_queueitem_write AS skip_queueitem_write;
"""


class StuckEmailFinder:
    """Thin wrapper around pyodbc for the stuck-writes scan query."""

    def __init__(self, config: RecoveryConfig) -> None:
        self._config = config

    def _connect(self) -> pyodbc.Connection:
        # Authentication=ActiveDirectoryMsi (deployed) or
        # ActiveDirectoryInteractive (local) in the connection string means
        # the driver handles the token itself — no password or secret is
        # ever handled in this code.
        return pyodbc.connect(self._config.sql_connection_string)

    def find_stuck_instances(self) -> list[StuckInstance]:
        """Latest-attempt rows stalled past the write window, or with a recorded stage failure."""
        terminal_codes = self._config.terminal_status_codes
        placeholders = ",".join("?" for _ in terminal_codes)
        sql = _FIND_STUCK_INSTANCES_SQL_TEMPLATE.format(terminal_placeholders=placeholders)
        params = (*terminal_codes, self._config.write_window_minutes)

        with self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()

        return [
            StuckInstance(
                email_instance_id=str(row.email_instance_id),
                activity_id=str(row.activity_id),
                attempt_number=row.attempt_number,
                status_code=row.status_code,
                last_completed_stage=row.last_completed_stage,
                resume_processing_stage=row.resume_processing_stage,
                case_payload=row.crm_case_payload,
                skip_queueitem_write=bool(row.skip_queueitem_write),
                failed_stage=row.failed_stage,
            )
            for row in rows
        ]

    def retry(self, activity_id: str, subject: str | None = None) -> tuple[str, bool]:
        """Creates a new attempt row for activity_id via the real B.1 stored
        proc — the retry-path branch, which carries forward whatever's
        valid from the prior attempt based on its resume_processing_stage.

        Callers must check the row's attempt_number against
        RecoveryConfig.max_retry_attempts themselves before calling this —
        this method does not enforce the cap, since the caller already has
        the answer from find_stuck_instances() and re-querying it here
        would just be an extra round trip.

        No subject is available from a stuck-row retry (StuckInstance
        carries no subject field), so @subject is NULL by default — the
        proc already supports that.

        Returns (new_email_instance_id, skip_queueitem_write).
        """
        with self._connect() as conn:
            row = conn.execute(_B1_WRITE_SQL, (activity_id, subject)).fetchone()
        return str(row.new_email_instance_id), bool(row.skip_queueitem_write)
