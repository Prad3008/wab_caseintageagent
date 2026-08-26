# telemetry.py — explained simply

## The problem it solves

Every time `func_case_intake_recovery` runs (or someone runs one of the `local_run*.py` scripts by hand), it prints/logs many lines — one for the run summary, one per stuck email it retries, one per dead letter it processes, warnings, errors, and so on.

If something goes wrong, you want to answer: **"show me every log line that belongs to this one specific thing, and only that thing."** Azure already answers this at the *invocation* level for free — every log line from one Timer tick automatically gets tagged with a real `operation_Id`, no code required (see `Functions/LOG_FLOW.md`). What Azure *can't* do on its own: tell two different dead-letter messages apart when both get handled inside the same invocation — they'd share the same `operation_Id`. `telemetry.py` exists to fill exactly that one gap, and nothing more.

## What it does

Python's `logging` module builds a small object (a `LogRecord`) every time you call `logger.info(...)`, `logger.warning(...)`, etc. `telemetry.py` swaps out the function that builds these objects (`logging.setLogRecordFactory`) for its own version that adds one extra field — `record.correlation_id` — onto every single one, automatically, no matter which file or function is doing the logging.

That field defaults to `"-"` and stays `"-"` for the entire invocation — deliberately. There's no "start of invocation" step generating an id, because `operation_Id` already covers that. The *only* place `correlation_id` ever becomes something other than `"-"` is inside a `message_scope(message)` block, in `recovery/dead_letters.py`, while one specific dead-letter message is being handled — and the moment that block ends, it goes right back to `"-"`.

**No OpenTelemetry/`azure-monitor-opentelemetry` dependency of any kind.** Two earlier, more elaborate versions of this file existed and were both removed — see "History" below.

## The two functions — that's the whole file

| Function | What it does |
|---|---|
| `message_scope(message)` | A `with`-block context manager. For the duration of the block, `correlation_id` becomes that message's own native `.correlation_id` property (a standard Service Bus/AMQP field a publisher can set explicitly) if present, otherwise a freshly generated `uuid4`. The instant the block ends — normal completion, `continue`, or an exception, doesn't matter which — `correlation_id` automatically goes back to whatever it was before. No manual "remember to switch it back" step exists anywhere; it structurally can't be forgotten or skipped. |
| `_record_factory(...)` | Private, internal plumbing — the thing that actually reads the current value and stamps `record.correlation_id` onto every log line. Not something any caller ever calls directly; installed automatically the moment this file is imported. |

That's it. No "start the invocation" function, no separate getter, no manual save/restore calls anywhere in this codebase.

## How it's actually used

Every one of the four entry points (`func_case_intake_recovery/__init__.py`'s Timer trigger, and the three `local_run*.py` scripts) imports `recovery.telemetry` purely for its side effect — to guarantee the record factory above is installed before any log line is written:

```python
import recovery.telemetry  # noqa: F401 — installs the correlation_id LogRecord factory
```

Nothing else about those entry points changes; ordinary `logger.info(...)` calls anywhere just work, showing `correlation_id=-`.

`recovery/dead_letters.py` is the one place that actually uses `message_scope()`, inside both `scan_dead_letters()` and `process_dead_letters()`'s message loops:

```python
for message in messages:
    with telemetry.message_scope(message):
        ...                              # this message's own logs use its own id
    # back out here, correlation_id is already "-" again — automatically
logger.info("dead-letter processing done: ...")   # correctly shows "-", not a stray message id
```

## What happens locally vs. in Azure

Identical behavior either way: `correlation_id` is `"-"` outside a `message_scope()` block, and a real id (native or generated) inside one. The only difference is whether it's exported anywhere — deployed on `func-zenon-wab-eus2`, it lands in Application Insights as `customDimensions.correlation_id`; running `local_run*.py` on a laptop, it's just visible in the console output.

## Sequence: what happens on every invocation

1. **Cold start (once per process, not per invocation).** The Python worker imports `func_case_intake_recovery/__init__.py`, which imports `recovery.telemetry` purely for its side effect. Just importing it runs its top-level code immediately: `_correlation_id_var` is created (defaulting to `"-"`), and `logging.setLogRecordFactory(_record_factory)` swaps Python's global "build a LogRecord" function for every logger in the whole process, for the rest of its lifetime.

2. **The Timer fires (every 2 minutes).** Azure's host runtime generates its own invocation with a genuine `operation_Id`/`operation_ParentId` and logs `"Executing 'Functions.func_case_intake_recovery' (Reason='Timer fired...')"` tagged with it. This happens inside the host, before any of our Python code runs.

3. **`main(timer)` runs.** `logging.info("func_case_intake_recovery invoked")` — this line, and every other line logged so far, carries `correlation_id="-"` plus the real host `operation_Id` (via the Functions host's native export, unrelated to anything in this file).

4. **`run_recovery()` executes.** Every log call inside `recovery/service.py`/`recovery/stuck_emails.py` still shows `correlation_id="-"` — correct, since nothing message-specific is happening yet, and `operation_Id` already ties these lines back to this invocation.

5. **`process_dead_letters()` executes.** For each message received, `with telemetry.message_scope(message):` switches `correlation_id` to that message's own native id (or a generated one) for exactly the lines logged inside that block. The instant the block ends, `correlation_id` reverts to `"-"` — before the next message's block opens, and before the final summary line logs.

6. **The Functions host carries logs to Application Insights.** The host natively forwards every `logging.*` call, tagged with the real `operation_Id`, and `customDimensions` carries whatever `correlation_id` was active at that moment — `"-"` for most lines, a real id for the handful of lines inside a `message_scope()` block.

7. **Querying it.** To find one invocation's worth of logs: `traces | where operation_Id == "<id>"`. To find every log line about one specific dead-letter message, possibly across *different* invocations if it was retried: `traces | where customDimensions.correlation_id == "<id>"`. Each query answers a different question — that's the whole reason both exist.

## History: what used to be here, and why it's gone

Three iterations existed at different points; all were simplified away. Kept here so the reasoning isn't lost.

**1. Sourcing correlation_id from OpenTelemetry's trace_id.** An early version tried `trace.get_current_span().get_span_context().trace_id`, falling back to a generated `uuid4` only when no trace was active. In practice, that check was **always** `False` — never once returned a real trace_id — because Azure Monitor's auto-instrumentation only wraps a specific library list that doesn't include Azure Functions Timer triggers, and because the check ran before anything that *would* create a span had executed. Dead code in practice.

**2. Keeping `configure_azure_monitor()` just for Service Bus dependency tracing.** Kept around for one genuinely working feature — `ServiceBus.receive`/`ServiceBus.abandon` showing up as "dependency" records in Application Insights. Required its own workaround (`OTEL_LOGS_EXPORTER=none`, since the documented `disable_logging=True` kwarg was silently broken in the installed SDK version) to stop it from also duplicating every log line through a second, invalid-`operation_Id` export path. Removed outright given a client preference to move away from OpenTelemetry entirely, reinforced by needing that non-obvious workaround in the first place. What's lost: the exact *duration* of each Service Bus call as its own record. What's unaffected: whether each message succeeded or failed and why — that's this codebase's own `logger.info`/`logger.exception` calls, unaffected by any of this.

**3. Generating a whole-invocation correlation_id via `start_invocation()`.** After removing OpenTelemetry, this file still generated its own `uuid4` once per invocation, called explicitly from every entry point. Recognized as pure duplication: Azure's `operation_Id` already ties one invocation's logs together, for free, with zero code — generating a second id for the exact same purpose added a function call to every entry point and an extra field to log lines without adding any *new* information. Removed, leaving only `message_scope()` — the one case where a correlation id genuinely answers a question `operation_Id` can't.

## A worked example

```
INFO root [correlation_id=-]: func_case_intake_recovery invoked
INFO recovery.service [correlation_id=-]: activity_id=ABC123 retried: attempt 1 -> 2
INFO recovery.dead_letters [correlation_id=publisher-set-id-abc]: dead-letter processed: activity_id=XYZ -> email_instance_id=...
INFO recovery.dead_letters [correlation_id=9f3a1c2e...]: dead-letter processed: activity_id=DEF -> email_instance_id=...
INFO recovery.dead_letters [correlation_id=-]: dead-letter processing done: found=2 processed=2 skipped=0 failed=0
```

The first two lines, and the last one, are plain invocation-level activity — `"-"`, exactly as expected, since `operation_Id` already covers grouping these by invocation. The two `"dead-letter processed"` lines are each inside their own `message_scope()` block: the first message's publisher set a native `correlation_id` (`publisher-set-id-abc`), so that's used directly; the second message's publisher didn't, so a fresh `uuid4` (`9f3a1c2e...`) was generated for it. The final summary line correctly shows `"-"` again, not either message's id.
