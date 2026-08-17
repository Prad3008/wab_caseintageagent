"""Manual entry point for actively processing the dead-letter queue.

Usage:
    python local_run_process_dead_letters.py

UNLIKE local_run_dead_letters.py, this is NOT read-only: it receives
messages from case-intake-ingestion's dead-letter sub-queue, and for any
message whose body has an "activity_id" field, writes it through the real
B.1 stored procedure (and B.2's queue_item insert, if needed) and then
COMPLETES the message — permanently removing it from the dead-letter
sub-queue. Messages without an activity_id (e.g. Dataverse queueitem events
meant for func_orchestrate) are abandoned — left untouched.

Uses DefaultAzureCredential (falls back to your `az login` session locally)
for Service Bus, and RecoveryConfig.from_env() for the SQL connection —
same ActiveDirectoryInteractive browser-login behavior as local_run.py the
first time pyodbc needs a token.

Run local_run_dead_letters.py first if you just want to see what's there
without risking completing anything.
"""

from __future__ import annotations

import json
import logging
import sys

from recovery.dead_letters import process_dead_letters

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
# The Service Bus SDK's own AMQP protocol logging (connection/link/session
# state changes) is extremely chatty at INFO — quiet it so only our own
# recovery.* log lines (and real Azure SDK warnings/errors) show up.
for _noisy in ("azure.servicebus", "azure.identity", "azure.core.pipeline.policies.http_logging_policy"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)


def main() -> int:
    outcome = process_dead_letters()

    print("\n=== Dead letter processing ===")
    print(json.dumps(
        {
            "found": outcome.found,
            "processed": outcome.processed,
            "skipped": outcome.skipped,
            "failed": outcome.failed,
            "messages": outcome.messages,
        },
        indent=2,
        default=str,
    ))

    return 0


if __name__ == "__main__":
    sys.exit(main())
