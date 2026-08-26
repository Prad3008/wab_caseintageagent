"""Dead-letter handling for Function D.

case-intake-ingestion's dead-letter sub-queue holds messages Service Bus
gave up retrying (MaxDeliveryCount exhausted) before a cia_email_instance
row was ever written for them — a class of failure recovery/stuck_emails.py
has zero visibility into, since it only reads SQL and there's nothing there
to find for a message that never got that far.

IMPORTANT: this queue is shared with the live, currently-running
func_orchestrate (the Dataverse-based pipeline) — it is func_orchestrate's
own Service Bus trigger queue, not something dedicated to this SQL-based
pipeline. Its dead-letter sub-queue can therefore contain messages meant for
either pipeline. process_dead_letters() only ever acts on a message whose
body matches one of two recognized shapes (see _extract_activity_id) — this
pipeline's own flat {"activity_id": ...} envelope, or a Dataverse queueitem
"Create" webhook event — and leaves everything else untouched in the
dead-letter sub-queue, exactly as it found it.

Two entry points:
    scan_dead_letters()   — read-only peek, never mutates the queue. Safe to
                             call anytime, purely for visibility.
    process_dead_letters() — receives matching messages. An activity_id with
                             no existing cia_email_instance row is written
                             through the real B.1 stored procedure (the same
                             write path B.1 always owns); one that already
                             has a row is never written to again, but if
                             cia_queue_item is still missing for it, that
                             piece alone is backfilled. Either way, the
                             message is only completed — permanently removed
                             from the dead-letter sub-queue — once that SQL
                             state is confirmed correct. A message that
                             doesn't match, or whose write fails, is
                             abandoned (left in the dead-letter sub-queue,
                             untouched) rather than completed.

Kept independent of service.py/stuck_emails.py/publisher.py on purpose —
this file may import config.py read-only (for the SQL connection string)
but never the other way around, so the running SQL scan never depends on
Service Bus being reachable.

Auth: uses the same "CaseIntakeServiceBus" connection app settings already
configured on func-zenon-wab-eus2 for func_orchestrate's Service Bus trigger
(CaseIntakeServiceBus__fullyQualifiedNamespace / __clientId,
CASE_INTAKE_SB_QUEUE) — no new app settings needed. The function app's
managed identity already holds "Azure Service Bus Data Receiver" on
sb-case-intake-dev (verified 2026-08-10), which covers peek, receive,
complete, and abandon.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field
from typing import Any

import pyodbc

from . import telemetry

logger = logging.getLogger(__name__)

# Local/manual-run fallback only — matches sb-case-intake-dev exactly, so
# local_run.py-style manual invocation doesn't need these app settings set.
_DEFAULT_NAMESPACE = "sb-case-intake-dev.servicebus.windows.net"
_DEFAULT_QUEUE = "case-intake-ingestion"

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

# queue_id is NOT NULL on dbo.cia_queue_item, but a dead-letter-revived
# message (this pipeline's own {"activity_id": ...} shape, not a Dataverse
# queueitem event) carries no real Dataverse queue reference. The all-zero
# GUID is a documented sentinel meaning "no queue reference available" —
# it is not a real queue_id and should never collide with one.
_UNKNOWN_QUEUE_ID = "00000000-0000-0000-0000-000000000000"
_QUEUE_ITEM_INSERT_SQL = """
INSERT INTO dbo.cia_queue_item (queue_item_id, activity_id, queue_id, queue_name, received_date_time)
VALUES (NEWID(), ?, ?, 'dead-letter-recovery', SYSUTCDATETIME())
"""


@dataclass
class DeadLetterOutcome:
    """What a dead-letter scan found and (for process_dead_letters) did.

    scan_dead_letters() only ever populates found/messages.
    process_dead_letters() populates all fields.
    """

    found: int = 0
    processed: int = 0
    skipped: int = 0
    failed: int = 0
    messages: list[dict[str, Any]] = field(default_factory=list)


# Dataverse queueitem "Create" events link the queue item to the email
# activity via objectid.LogicalName. Both spellings seen in practice are
# accepted: "activity_id" (the newer convention) and "email" (what the
# real dead-lettered smoke-test messages from 2026-06-29 actually use).
_DATAVERSE_OBJECT_LOGICAL_NAMES = {"activity_id", "email"}


def _extract_activity_id(parsed: dict[str, Any]) -> str | None:
    """Recognizes two message shapes and returns the activity_id, if any.

    1. This pipeline's own flat shape: {"activity_id": "<guid>", ...}
       (what a real ServiceBusRecoveryPublisher-sent ResumeMessage looks like).
    2. A Dataverse queueitem "Create" webhook event: InputParameters ->
       Target -> Attributes -> objectid, where the linked object's
       LogicalName is one of _DATAVERSE_OBJECT_LOGICAL_NAMES and its Id is
       the GUID to use.
    """
    flat = parsed.get("activity_id")
    if isinstance(flat, str):
        return flat

    for param in parsed.get("InputParameters") or []:
        if not isinstance(param, dict) or param.get("key") != "Target":
            continue
        target = param.get("value")
        if not isinstance(target, dict):
            continue
        for attr in target.get("Attributes") or []:
            if not isinstance(attr, dict) or attr.get("key") != "objectid":
                continue
            obj = attr.get("value")
            if isinstance(obj, dict) and obj.get("LogicalName") in _DATAVERSE_OBJECT_LOGICAL_NAMES:
                obj_id = obj.get("Id")
                if isinstance(obj_id, str):
                    return obj_id
    return None


def _summarize(message: Any) -> dict[str, Any]:
    """Pulls out the fields worth logging, plus activity_id if the body parses as JSON."""
    body_bytes = b"".join(message.body) if hasattr(message.body, "__iter__") else bytes(message.body)
    body_text = body_bytes.decode("utf-8", errors="replace")

    activity_id = None
    try:
        parsed = json.loads(body_text)
        if isinstance(parsed, dict):
            activity_id = _extract_activity_id(parsed)
    except (ValueError, TypeError):
        pass

    return {
        "message_id": message.message_id,
        "activity_id": activity_id,
        "delivery_count": message.delivery_count,
        "enqueued_time_utc": str(message.enqueued_time_utc),
        "dead_letter_reason": message.dead_letter_reason,
        "dead_letter_error_description": message.dead_letter_error_description,
        "body_preview": body_text[:500],
    }


def _service_bus_settings() -> tuple[str, str, str | None]:
    namespace = os.environ.get("CaseIntakeServiceBus__fullyQualifiedNamespace") or _DEFAULT_NAMESPACE
    queue_name = os.environ.get("CASE_INTAKE_SB_QUEUE") or _DEFAULT_QUEUE
    client_id = os.environ.get("CaseIntakeServiceBus__clientId") or None
    return namespace, queue_name, client_id


def scan_dead_letters(max_messages: int = 50) -> DeadLetterOutcome:
    """Peeks up to max_messages from the ingestion queue's dead-letter sub-queue.

    Read-only: peek_messages takes no lock and removes nothing — unlike
    receive, a peeked message stays in the dead-letter sub-queue exactly as
    it was, safe to call anytime without risk of losing a message.
    """
    from azure.identity import DefaultAzureCredential
    from azure.servicebus import ServiceBusClient, ServiceBusSubQueue

    namespace, queue_name, client_id = _service_bus_settings()
    credential = DefaultAzureCredential(managed_identity_client_id=client_id)
    client = ServiceBusClient(fully_qualified_namespace=namespace, credential=credential)

    try:
        with client.get_queue_receiver(queue_name=queue_name, sub_queue=ServiceBusSubQueue.DEAD_LETTER) as receiver:
            messages = receiver.peek_messages(max_message_count=max_messages)
    finally:
        client.close()

    summaries = [_summarize(m) for m in messages]
    logger.info("dead-letter scan: %s message(s) in %s", len(summaries), queue_name)

    for message, summary in zip(messages, summaries):
        with telemetry.message_scope(message):
            # Full detail (body_preview etc.) is in the returned messages
            # list for the caller to inspect/print — DEBUG here so a
            # routine peek doesn't flood INFO-level logs, but the id is
            # still traceable if needed.
            logger.debug("dead-letter: message_id=%s activity_id=%s", summary["message_id"], summary["activity_id"])

    return DeadLetterOutcome(found=len(summaries), messages=summaries)


_EMAIL_INSTANCE_EXISTS_SQL = "SELECT TOP 1 1 FROM dbo.cia_email_instance WHERE activity_id = ?"
_QUEUE_ITEM_EXISTS_SQL = "SELECT TOP 1 1 FROM dbo.cia_queue_item WHERE activity_id = ?"


def _email_instance_exists(sql_connection_string: str, activity_id: str) -> bool:
    """True if any attempt already exists for this activity_id.

    Dead-letter revival is only for activity_ids B.1 has never run for at
    all — not a retry mechanism (that's stuck_emails.py's job, which
    resumes from the correct stage using resume_processing_stage). A
    second dead-lettered message for an activity_id that already has a row
    is a duplicate delivery, not a new email to process.
    """
    with pyodbc.connect(sql_connection_string) as conn:
        row = conn.execute(_EMAIL_INSTANCE_EXISTS_SQL, activity_id).fetchone()
    return row is not None


def _queue_item_exists(sql_connection_string: str, activity_id: str) -> bool:
    """True if a cia_queue_item row already exists for this activity_id."""
    with pyodbc.connect(sql_connection_string) as conn:
        row = conn.execute(_QUEUE_ITEM_EXISTS_SQL, activity_id).fetchone()
    return row is not None


def _run_b1_write(sql_connection_string: str, activity_id: str) -> tuple[str, bool]:
    """Calls the real B.1 stored proc — the same write path B.1 always owns.

    No subject is available from a dead-letter-revived message (this
    pipeline's own shape carries only activity_id), so @subject is NULL —
    the proc already supports that.
    """
    with pyodbc.connect(sql_connection_string) as conn:
        row = conn.execute(_B1_WRITE_SQL, (activity_id, None)).fetchone()
    return str(row.new_email_instance_id), bool(row.skip_queueitem_write)


def _write_queue_item(sql_connection_string: str, activity_id: str) -> None:
    """B.2's write. Called either when B.1 reports skip_queueitem_write=False,
    or as a standalone backfill when cia_email_instance already exists for
    this activity_id but cia_queue_item doesn't."""
    with pyodbc.connect(sql_connection_string) as conn:
        conn.execute(_QUEUE_ITEM_INSERT_SQL, (activity_id, _UNKNOWN_QUEUE_ID))


def process_dead_letters(sql_connection_string: str | None = None, max_messages: int = 50) -> DeadLetterOutcome:
    """Revives dead-lettered messages that match this pipeline's own shape.

    For each dead-lettered message:
      - no activity_id found in the body (e.g. an unparseable test message,
        or a Dataverse event whose LogicalName isn't recognized): abandoned
        — left in the dead-letter sub-queue exactly as found, counted in
        `skipped`.
      - has an activity_id, and both cia_email_instance and cia_queue_item
        already have a row for it: abandoned, nothing written — counted in
        `skipped` (action "skipped_already_exists"). Dead-letter revival is
        only for activity_ids B.1 has never run for at all; a second
        dead-lettered message for one that's already fully recorded is a
        duplicate delivery, not a retry request (that's stuck_emails.py's
        job, via resume_processing_stage).
      - has an activity_id, cia_email_instance already has a row but
        cia_queue_item doesn't: only the missing cia_queue_item row is
        backfilled (no second B.1 write) — counted in `processed` (action
        "queue_item_backfilled").
      - has an activity_id, no existing cia_email_instance row at all:
        written through dbo.usp_cia_email_instance_b1_write (and
        cia_queue_item, if B.1 reports skip_queueitem_write=False) —
        counted in `processed` (action "processed").
      - any of the above whose existence checks or writes raise: abandoned
        — left in the dead-letter sub-queue so the next run retries it —
        counted in `failed`.

    In every case, the message is only completed — permanently removed
    from the dead-letter sub-queue — once the corresponding SQL write (if
    any) has succeeded, never the reverse: a message is never lost, it's
    either still in the dead-letter sub-queue, or it's durably recorded in
    cia_email_instance / cia_queue_item.
    """
    from azure.identity import DefaultAzureCredential
    from azure.servicebus import ServiceBusClient, ServiceBusSubQueue

    if sql_connection_string is None:
        from .config import RecoveryConfig

        sql_connection_string = RecoveryConfig.from_env().sql_connection_string

    namespace, queue_name, client_id = _service_bus_settings()
    credential = DefaultAzureCredential(managed_identity_client_id=client_id)
    client = ServiceBusClient(fully_qualified_namespace=namespace, credential=credential)

    outcome = DeadLetterOutcome()
    try:
        with client.get_queue_receiver(queue_name=queue_name, sub_queue=ServiceBusSubQueue.DEAD_LETTER) as receiver:
            messages = receiver.receive_messages(max_message_count=max_messages, max_wait_time=5)
            outcome.found = len(messages)

            for message in messages:
                with telemetry.message_scope(message):
                    summary = _summarize(message)
                    activity_id = summary["activity_id"]

                    if not activity_id:
                        receiver.abandon_message(message)
                        summary["action"] = "skipped_no_activity_id"
                        outcome.skipped += 1
                        outcome.messages.append(summary)
                        logger.debug("dead-letter skipped, no activity_id: message_id=%s", summary["message_id"])
                        continue

                    try:
                        if _email_instance_exists(sql_connection_string, activity_id):
                            # Don't re-run B.1 for an activity_id that already has a
                            # row — but if cia_queue_item is still missing for it
                            # (e.g. an earlier revival wrote email_instance but died
                            # before B.2), backfill just that piece.
                            if _queue_item_exists(sql_connection_string, activity_id):
                                receiver.abandon_message(message)
                                summary["action"] = "skipped_already_exists"
                                outcome.skipped += 1
                                logger.debug("dead-letter skipped, already exists: activity_id=%s", activity_id)
                            else:
                                _write_queue_item(sql_connection_string, activity_id)
                                receiver.complete_message(message)
                                summary["action"] = "queue_item_backfilled"
                                outcome.processed += 1
                                logger.info("dead-letter queue_item backfilled: activity_id=%s", activity_id)
                        else:
                            new_email_instance_id, skip_queueitem_write = _run_b1_write(sql_connection_string, activity_id)
                            if not skip_queueitem_write:
                                _write_queue_item(sql_connection_string, activity_id)
                            receiver.complete_message(message)
                            summary["action"] = "processed"
                            summary["email_instance_id"] = new_email_instance_id
                            outcome.processed += 1
                            logger.info(
                                "dead-letter processed: activity_id=%s -> email_instance_id=%s",
                                activity_id, new_email_instance_id,
                            )
                    except Exception as exc:
                        receiver.abandon_message(message)
                        summary["action"] = "failed"
                        summary["error"] = str(exc)
                        outcome.failed += 1
                        logger.exception("dead-letter revival failed for activity_id=%s", activity_id)

                    outcome.messages.append(summary)
    finally:
        client.close()

    logger.info(
        "dead-letter processing done: found=%s processed=%s skipped=%s failed=%s",
        outcome.found, outcome.processed, outcome.skipped, outcome.failed,
    )

    return outcome
