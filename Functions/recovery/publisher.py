"""Re-enqueue step for Function D.

Each stuck row found resolves to the same action: hand a ResumeMessage
envelope to whatever runs the B.1-B.9 case-intake spine. Today that's a
direct in-process call into the orchestrator/ stand-in
(OrchestratorRecoveryPublisher, the default — see service.py:
build_publisher) since case-intake-ingestion has no live Service Bus
consumer yet. ServiceBusRecoveryPublisher is left in place, ready to flip on
once a real queue consumer exists (set SERVICE_BUS_NAMESPACE +
SERVICE_BUS_QUEUE_NAME). NullRecoveryPublisher (log-only, no orchestrator
call at all) stays available for tests/offline runs.
"""

from __future__ import annotations

import json
import logging
from dataclasses import asdict, dataclass
from typing import Protocol

from .config import RecoveryConfig

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ResumeMessage:
    """Envelope describing one activity_id that needs (re)processing.

    resume_from_stage is the computed resume_processing_stage off the latest
    attempt row (B1/B4/B7/B8/B9).

    skip_queueitem_write is True when a cia_queue_item already exists for
    this activity_id — a stuck-write retry past B.1 — so the orchestrator's
    B.2 step should be skipped rather than writing a duplicate.
    """

    activity_id: str
    resume_from_stage: str
    is_recovery: bool = True
    case_payload: str | None = None
    skip_queueitem_write: bool = False

    def to_message_body(self) -> str:
        body = {key: value for key, value in asdict(self).items() if value is not None}
        return json.dumps(body)


class RecoveryPublisher(Protocol):
    """Shared interface so service.py doesn't care which impl runs."""

    def publish(self, message: ResumeMessage) -> None: ...

    def close(self) -> None: ...


class NullRecoveryPublisher:
    """Log-only publisher — no orchestrator call, no Service Bus.

    Not the default (see service.build_publisher); kept for tests/offline
    runs where even the dummy orchestrator call is unwanted.
    """

    def publish(self, message: ResumeMessage) -> None:
        logger.info("recovery (log-only mode) would publish: %s", message.to_message_body())

    def close(self) -> None:
        pass


class OrchestratorRecoveryPublisher:
    """Default publisher: calls the orchestrator/ spine directly, in-process.

    Stands in for "publish to the ingestion queue" until case-intake-ingestion
    has a real consumer — orchestrator.run_from_stage() is a dummy today
    (every B.1-B.9 step just logs and returns a fake result; see
    orchestrator/spine.py), written by a teammate. Calling it directly here
    means recovery's wiring (which activity_id, which stage to resume from,
    whether to skip B.2) is already correct and won't need to change once
    the real implementation replaces the dummy step bodies.
    """

    def publish(self, message: ResumeMessage) -> None:
        from orchestrator import run_from_stage

        result = run_from_stage(
            activity_id=message.activity_id,
            resume_from_stage=message.resume_from_stage,
            skip_queueitem_write=message.skip_queueitem_write,
            case_payload=message.case_payload,
        )
        # One concise line per activity_id — the individual B.1-B.9 step
        # detail is already in orchestrator/spine.py at DEBUG, so dumping
        # the full nested `result` here again would just duplicate it.
        if "stopped_at" in result:
            logger.info(
                "recovery -> orchestrator: activity_id=%s stopped_at=%s (%d step(s) ran)",
                result["activity_id"], result["stopped_at"], len(result["steps"]),
            )
        else:
            logger.info(
                "recovery -> orchestrator: activity_id=%s started_at=%s (%d step(s) ran)",
                result["activity_id"], result["started_at"], len(result["steps"]),
            )

    def close(self) -> None:
        pass


class ServiceBusRecoveryPublisher:
    """Publishes ResumeMessage envelopes to the pipeline's ingestion queue.

    Only constructed when config.service_bus_namespace and config.queue_name
    are both set — see service.build_publisher(). Imports azure.servicebus
    lazily so NullRecoveryPublisher's (default) path never requires the
    package to be installed.
    """

    def __init__(self, config: RecoveryConfig) -> None:
        from azure.identity import DefaultAzureCredential
        from azure.servicebus import ServiceBusClient

        self._config = config
        # Managed identity only — consistent with the pipeline's secretless
        # auth model; no connection-string secret is used here.
        self._client = ServiceBusClient(
            fully_qualified_namespace=config.service_bus_namespace,
            credential=DefaultAzureCredential(),
        )

    def publish(self, message: ResumeMessage) -> None:
        from azure.servicebus import ServiceBusMessage

        with self._client.get_queue_sender(self._config.queue_name) as sender:
            sender.send_messages(ServiceBusMessage(message.to_message_body()))

    def close(self) -> None:
        self._client.close()
