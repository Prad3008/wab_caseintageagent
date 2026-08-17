"""Pure orchestration for Function D — no azure.functions imports here.

run_recovery() is the single entry point the Timer trigger calls. Keeping
it free of Function-binding imports means it can be unit-tested with fake
StuckEmailFinder/publisher instances, offline, with no live Azure
resources.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from .config import RecoveryConfig
from .publisher import OrchestratorRecoveryPublisher, RecoveryPublisher, ResumeMessage, ServiceBusRecoveryPublisher
from .stuck_emails import StuckEmailFinder

logger = logging.getLogger(__name__)


@dataclass
class RecoveryOutcome:
    """Counters for one run of the stuck-writes scan."""

    scanned: int = 0
    replayed: int = 0
    failed: int = 0
    failures: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class RecoverySummary:
    """Full result of a single run_recovery() invocation."""

    stuck_writes: RecoveryOutcome

    def as_log_dict(self) -> dict[str, int]:
        """Flat dict for a single structured log line."""
        return {
            "stuck_writes_scanned": self.stuck_writes.scanned,
            "stuck_writes_replayed": self.stuck_writes.replayed,
            "stuck_writes_failed": self.stuck_writes.failed,
        }


def build_publisher(config: RecoveryConfig) -> RecoveryPublisher:
    """Picks Service Bus if it's configured; otherwise calls the orchestrator directly.

    case-intake-ingestion has no consumer yet, so the default path is an
    in-process call into orchestrator.run_from_stage() (dummy today — see
    orchestrator/spine.py) rather than publishing to a queue nobody reads.
    Set SERVICE_BUS_NAMESPACE + SERVICE_BUS_QUEUE_NAME once a real consumer
    exists to switch back to queue-based delivery.
    """
    if config.service_bus_namespace and config.queue_name:
        return ServiceBusRecoveryPublisher(config)
    logger.info("Service Bus not configured — recovery calling the orchestrator directly")
    return OrchestratorRecoveryPublisher()


def run_recovery(
    finder: StuckEmailFinder | None = None,
    publisher: RecoveryPublisher | None = None,
    config: RecoveryConfig | None = None,
) -> RecoverySummary:
    """Runs the stuck-writes scan and returns its outcome.

    Args:
        finder, publisher, config: injected for tests. When omitted, built
            from live Azure resources via RecoveryConfig.from_env().
    """
    config = config or RecoveryConfig.from_env()
    finder = finder or StuckEmailFinder(config)
    publisher = publisher or build_publisher(config)

    try:
        stuck_writes = _replay_stuck_writes(finder, publisher, config.max_retry_attempts)
    finally:
        publisher.close()

    return RecoverySummary(stuck_writes=stuck_writes)


def _replay_stuck_writes(
    finder: StuckEmailFinder, publisher: RecoveryPublisher, max_retry_attempts: int
) -> RecoveryOutcome:
    """Retries rows stalled past the write window, up to max_retry_attempts.

    Each retry creates a genuinely new attempt row — same activity_id, new
    email_instance_id, attempt_number + 1 — via the real B.1 stored proc
    (StuckEmailFinder.retry), the same write path B.1 always owns. A row
    already at max_retry_attempts is never retried again, so a persistently
    failing activity_id can't generate new attempts forever.

    Never re-calls the Foundry model — resume_processing_stage already
    tells the pipeline exactly where to pick back up, and case_payload
    carries whatever was already built for this attempt.
    """
    outcome = RecoveryOutcome()
    stuck_rows = finder.find_stuck_instances()
    outcome.scanned = len(stuck_rows)

    for row in stuck_rows:
        if row.attempt_number >= max_retry_attempts:
            logger.warning(
                "activity_id=%s has reached %d attempt(s) (max %d) — not retrying again",
                row.activity_id, row.attempt_number, max_retry_attempts,
            )
            outcome.failed += 1
            outcome.failures.append({"activity_id": row.activity_id, "error": "max_retry_attempts_exceeded"})
            continue

        try:
            new_email_instance_id, skip_queueitem_write = finder.retry(row.activity_id)
        except Exception as exc:
            logger.exception("Retry write failed for activity_id=%s", row.activity_id)
            outcome.failed += 1
            outcome.failures.append({"activity_id": row.activity_id, "error": str(exc)})
            continue

        logger.info(
            "activity_id=%s retried: attempt %d -> %d (email_instance_id=%s)",
            row.activity_id, row.attempt_number, row.attempt_number + 1, new_email_instance_id,
        )

        message = ResumeMessage(
            activity_id=row.activity_id,
            resume_from_stage=row.resume_processing_stage,
            case_payload=row.case_payload,
            skip_queueitem_write=skip_queueitem_write,
        )
        _publish_and_count(publisher, message, row.activity_id, outcome)

    return outcome


def _publish_and_count(
    publisher: RecoveryPublisher,
    message: ResumeMessage,
    activity_id: str,
    outcome: RecoveryOutcome,
) -> None:
    """Shared publish-and-tally step so callers don't duplicate error handling."""
    try:
        publisher.publish(message)
        outcome.replayed += 1
    except Exception as exc:
        logger.exception("Recovery publish failed for activity_id=%s", activity_id)
        outcome.failed += 1
        outcome.failures.append({"activity_id": activity_id, "error": str(exc)})
