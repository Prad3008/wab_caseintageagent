"""Manual entry point for peeking the dead-letter queue from a workstation.

Usage:
    python local_run_dead_letters.py

Uses DefaultAzureCredential, which falls back to your `az login` session
locally (no browser popup, unlike local_run.py's SQL path) — you need the
"Azure Service Bus Data Receiver" role on the sb-case-intake-dev namespace
for this to work. Read-only: peek_messages takes no lock and removes
nothing from the dead-letter sub-queue.
"""

from __future__ import annotations

import json
import logging
import sys

from recovery.dead_letters import scan_dead_letters

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
# The Service Bus SDK's own AMQP protocol logging (connection/link/session
# state changes) is extremely chatty at INFO — quiet it so only our own
# recovery.* log lines (and real Azure SDK warnings/errors) show up.
for _noisy in ("azure.servicebus", "azure.identity", "azure.core.pipeline.policies.http_logging_policy"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)


def main() -> int:
    outcome = scan_dead_letters()

    print("\n=== Dead letters ===")
    print(json.dumps({"found": outcome.found, "messages": outcome.messages}, indent=2, default=str))

    return 0


if __name__ == "__main__":
    sys.exit(main())
