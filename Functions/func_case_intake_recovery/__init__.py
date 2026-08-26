"""func_case_intake_recovery — Timer-triggered entry point for the Function D recovery scan.

Fires every 2 minutes (NCRONTAB "0 */2 * * * *"). Stays a thin adapter
running two independent scans, each free to fail without affecting the
other:
  - recovery.service.run_recovery() — the SQL-backed stuck-writes scan.
  - recovery.dead_letters.process_dead_letters() — revives dead-lettered
    messages in case-intake-ingestion that match this pipeline's own shape
    (writes each through the real B.1 stored proc, then completes it);
    everything else (e.g. Dataverse queueitem events meant for the separate
    func_orchestrate pipeline sharing this queue) is left untouched. See
    recovery/dead_letters.py for the full contract.

All branching lives in those two modules, each unit-testable without any
live Azure Function context. This file should never grow logic of its own —
if it needs a new import beyond logging and azure.functions, that logic
belongs in the recovery package instead.

This is the SQL-backed case-intake recovery scan (dbo.cia_email_instance /
dbo.cia_queue_item on sqldb-case-intake-dev) — a distinct, separately named
function from the existing Dataverse-backed func_recovery, which this
deployment leaves untouched.
"""

from __future__ import annotations

import logging
import os
import sys

import azure.functions as func

_func_app_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _func_app_root not in sys.path:
    sys.path.insert(0, _func_app_root)

from recovery import run_recovery  # noqa: E402
from recovery.dead_letters import process_dead_letters  # noqa: E402
import recovery.telemetry  # noqa: E402,F401 — side effect only: installs the correlation_id LogRecord factory used by recovery.dead_letters.message_scope()

# The Service Bus SDK's own AMQP protocol logging (connection/link/session
# state changes) is extremely chatty at INFO — quiet it so Application
# Insights isn't flooded with SDK internals on every 2-minute tick, leaving
# only our own recovery.* log lines and real Azure SDK warnings/errors.
for _noisy in ("azure.servicebus", "azure.identity", "azure.core.pipeline.policies.http_logging_policy"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)


def main(timer: func.TimerRequest) -> None:
    logging.info("func_case_intake_recovery invoked")

    if timer.past_due:
        logging.warning("func_case_intake_recovery: timer is past due")

    try:
        summary = run_recovery()
        logging.info("func_case_intake_recovery summary: %s", summary.as_log_dict())
    except Exception:
        logging.exception("func_case_intake_recovery: run_recovery failed")

    try:
        dead_letters = process_dead_letters()
        if dead_letters.found:
            logging.warning(
                "func_case_intake_recovery: dead letters found=%s processed=%s skipped=%s failed=%s",
                dead_letters.found, dead_letters.processed, dead_letters.skipped, dead_letters.failed,
            )
    except Exception:
        logging.exception("func_case_intake_recovery: process_dead_letters failed")
