"""Shared telemetry bootstrap for func_case_intake_recovery/__init__.py's
Timer trigger, local_run.py's manual runs, and recovery/dead_letters.py.

Gives every log line a correlation_id automatically, without threading it
through every logger.info() call by hand — but only where correlation_id
actually adds information beyond what Azure already gives you for free:

  - At the invocation level, correlation_id is deliberately NOT generated.
    Azure Functions already tags every invocation's logs with a real
    operation_Id natively (see Functions/LOG_FLOW.md) — generating our own
    id on top of that would just be a second name for the same thing.
    correlation_id sits at its default, "-", for any log line outside a
    message_scope() block, which correctly signals "not message-specific,
    use operation_Id for this one."

  - Inside message_scope(message), correlation_id becomes genuinely useful:
    operation_Id can't tell two different dead-letter messages handled in
    the same invocation apart (they'd share the same operation_Id), but a
    message's own correlation_id can. message_scope() is a `with`-block
    context manager — it activates that message's own native Service
    Bus/AMQP .correlation_id property (a standard field a publisher can
    set explicitly) if present, otherwise a freshly generated uuid4 — then
    automatically restores whatever was active before the instant the
    `with` block ends, on success or on an exception, so there's no manual
    "remember to switch it back" step to forget.

No OpenTelemetry/Azure Monitor dependency of any kind.
"""

from __future__ import annotations

import contextlib
import logging
import uuid
from contextvars import ContextVar
from typing import Any, Generator

_correlation_id_var: ContextVar[str] = ContextVar("correlation_id", default="-")

# Installed at import time (below), via the LogRecord factory rather than a
# logging.Filter, so record.correlation_id exists on every record from the
# very first line ever logged, regardless of which/how many handlers exist
# at that point. A Filter would only apply to records that happen to reach
# a handler that already has it attached, which is order-dependent; the
# factory runs for every record, everywhere, unconditionally.
_original_factory = logging.getLogRecordFactory()


def _record_factory(*args, **kwargs):
    record = _original_factory(*args, **kwargs)
    record.correlation_id = _correlation_id_var.get()
    return record


logging.setLogRecordFactory(_record_factory)


@contextlib.contextmanager
def message_scope(message: Any) -> Generator[str, None, None]:
    """Wrap the processing of one Service Bus message in its own
    correlation_id scope, then automatically restore whatever was active
    before the moment the `with` block ends — on success OR on an
    exception, it doesn't matter, the restore always happens, so there's
    no manual "remember to put it back" step that could be forgotten or
    skipped by an early return.

    Uses the message's own native .correlation_id property — a standard
    Service Bus/AMQP field a publisher can set explicitly for exactly this
    purpose — if present, otherwise a freshly generated uuid4.

    Usage (see recovery/dead_letters.py):

        for message in messages:
            with telemetry.message_scope(message):
                ...                 # this message's own logs carry its own id
        # back out here, correlation_id is back to "-" (or an outer scope)
    """
    outer_correlation_id = _correlation_id_var.get()
    correlation_id = getattr(message, "correlation_id", None) or uuid.uuid4().hex
    _correlation_id_var.set(correlation_id)
    try:
        yield correlation_id
    finally:
        _correlation_id_var.set(outer_correlation_id)
