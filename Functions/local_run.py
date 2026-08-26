"""Manual entry point for running the recovery scan from a workstation.

Usage:
    python local_run.py

Uses RecoveryConfig.from_env() defaults (the ActiveDirectoryInteractive
connection string baked into recovery/config.py) unless SQL_CONNECTION_STRING
is set in the environment. Running this pops a browser AAD login the first
time pyodbc needs a token — that's expected and is why this script, not the
deployed Timer Function, is the place to use ActiveDirectoryInteractive.

Prints a human-readable report of what the stuck-writes scan found, and
what it would publish, without requiring Service Bus to be configured (see
recovery/publisher.py).
"""

from __future__ import annotations

import json
import logging
import sys

from recovery import run_recovery
import recovery.telemetry  # noqa: F401 — side effect only: installs the correlation_id LogRecord factory used by recovery.dead_letters.message_scope()

logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s %(name)s [correlation_id=%(correlation_id)s]: %(message)s",
)


def main() -> int:
    logging.info("local_run invoked")

    summary = run_recovery()

    print("\n=== Stuck writes ===")
    print(json.dumps(summary.stuck_writes.__dict__, indent=2, default=str))

    print("\n=== Summary ===")
    print(json.dumps(summary.as_log_dict(), indent=2))

    return 0


if __name__ == "__main__":
    sys.exit(main())
