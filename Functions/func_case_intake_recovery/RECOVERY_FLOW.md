# func_case_intake_recovery — How It Works

A Timer-triggered Azure Function that runs two independent scans every 2 minutes: (1) the case-intake SQL database, for emails that got stuck mid-processing, and (2) the ingestion queue's dead-letter sub-queue, for messages Service Bus itself gave up delivering. Each scan can fail without affecting the other.

## One-sentence summary

Every 2 minutes, it checks for emails that got stuck or lost — both in the SQL state (stuck mid-pipeline) and at the Service Bus delivery level (dead-lettered before they ever reached SQL) — and for the SQL case, hands them back to the processing pipeline to pick up from that exact point.

## What "stuck" means

A row in `dbo.cia_email_instance` qualifies for recovery if **either**:
- it's sitting at a non-terminal `status_code` and hasn't been touched in over 10 minutes (the normal in-flight window has been exceeded), **or**
- its `failed_stage` column is not null — a specific B.x stage explicitly recorded a failure. This case is picked up immediately regardless of status or age, since a recorded failure isn't going to resolve itself by waiting.

Only the **latest attempt** per `activity_id` is considered (via `ROW_NUMBER()` over `attempt_number`), so a superseded retry row is never re-processed.

**Retrying a stuck row is a real write**, capped: for each stuck row found, `StuckEmailFinder.retry()` calls the real `dbo.usp_cia_email_instance_b1_write` stored proc's retry-path branch — same `activity_id`, a genuinely new `email_instance_id`, `attempt_number + 1`, carrying forward whatever's valid based on the prior attempt's `resume_processing_stage`. This only happens if the row's current `attempt_number` is below `RecoveryConfig.max_retry_attempts` (default **5**, `RECOVERY_MAX_RETRY_ATTEMPTS` env override) — a row already at the cap is left alone (counted as `failed`, reason `"max_retry_attempts_exceeded"`), so a persistently-failing `activity_id` can't generate new attempt rows forever.

## What "dead-lettered" means, and why it's a separate scan

A row in `dbo.cia_email_instance` only exists once B.1 has actually run. But a message can fail *before* that — never reaching Service Bus at all, or reaching it and failing every delivery attempt (`MaxDeliveryCount`, 10 for `case-intake-ingestion`) before B.1 ever committed. Service Bus moves those to the queue's dead-letter sub-queue and stops retrying. `stuck_emails.py` has **zero visibility** into this — there's nothing in SQL to find. `recovery/dead_letters.py` closes that gap.

**Important**: `case-intake-ingestion` is shared with the live, currently-running `func_orchestrate` (the Dataverse-based pipeline) — it's `func_orchestrate`'s own Service Bus trigger queue, not something dedicated to this SQL pipeline. Its dead-letter sub-queue can contain messages meant for *either* pipeline. `process_dead_letters()` only ever acts on a message whose body matches one of two recognized shapes (`_extract_activity_id`):
1. This pipeline's own flat shape — `{"activity_id": "<guid>", ...}`.
2. A Dataverse `queueitem` "Create" webhook event — `InputParameters[].value.Attributes[].value` where `LogicalName` is `"activity_id"` or `"email"` and `Id` is the GUID to use.

Anything else is **abandoned** — left in the dead-letter sub-queue exactly as found, never touched.

For a matching message, there are two existence checks before deciding what to write — B.1 (`cia_email_instance`) and B.2 (`cia_queue_item`) are checked independently, since dead-letter revival is only for activity_ids B.1 has never run for at all, never a retry mechanism (that's `stuck_emails.py`'s job, via `resume_processing_stage`):

| `cia_email_instance` exists? | `cia_queue_item` exists? | What happens | Message outcome |
|---|---|---|---|
| No | (either) | Full B.1 write via `usp_cia_email_instance_b1_write`, then `cia_queue_item` too if B.1 reports a fresh attempt (`skip_queueitem_write=False`) | Completed (`action: "processed"`) |
| Yes | No | **Only** `cia_queue_item` is backfilled — no second B.1 write, no new attempt row | Completed (`action: "queue_item_backfilled"`) |
| Yes | Yes | Nothing written — this is a duplicate delivery (e.g. the same Dataverse event dead-lettering twice) | Abandoned (`action: "skipped_already_exists"`) |

No `subject` is available from either recognized message shape, so B.1's write always passes `@subject = NULL` — the proc supports that. Completion never happens before the corresponding write succeeds, so a message is never lost: it's either still in the dead-letter sub-queue, or durably recorded in `cia_email_instance` / `cia_queue_item`. `cia_queue_item.queue_id` is `NOT NULL` but a dead-letter-revived message carries no real Dataverse queue reference, so it's written as the documented sentinel `00000000-0000-0000-0000-000000000000` with `queue_name = 'dead-letter-recovery'`.

Two entry points, two very different risk levels:
- `scan_dead_letters()` — read-only `peek_messages`, never mutates anything. Safe to call anytime.
- `process_dead_letters()` — what the deployed timer actually calls. Receives, writes to SQL, and **permanently deletes** matching messages via `complete_message()`. Non-matching or failed-write messages are `abandon_message()`'d back to the dead-letter sub-queue, not lost.

## Files and what each one does

| Order | File | Role |
|---|---|---|
| 1 | `func_case_intake_recovery/function.json` | Declares the trigger — runs every 2 minutes (NCRONTAB `0 */2 * * * *`) |
| 2 | `func_case_intake_recovery/__init__.py` | Entry point Azure actually calls. Runs both scans, each in its own try/except so one failing never blocks the other |
| 3 | `recovery/config.py` | Reads settings: SQL connection string (with a .NET→ODBC connection-string translator), write window, terminal status codes, `max_retry_attempts` |
| 4 | `recovery/service.py` | The conductor for the SQL scan — pulls all stuck rows in one SQL call, retries each (subject to the cap), then loops the publisher over each result. Also owns `RecoveryOutcome`/`RecoverySummary`, the outcome types it returns |
| 5 | `recovery/stuck_emails.py` | Runs the one SQL query against `dbo.cia_email_instance` — pulls *all* stuck rows in a single round trip. Also owns the real retry write (`StuckEmailFinder.retry()`, via `usp_cia_email_instance_b1_write`) and `StuckInstance`, the row shape the query returns |
| 6 | `recovery/publisher.py` | Per row: decides how to hand it off (today: call the orchestrator directly), builds the `ResumeMessage` envelope |
| 7 | `orchestrator/__init__.py` | Exposes `run_from_stage` — the package's public entry point |
| 8 | `orchestrator/spine.py` | The actual B.1–B.9 steps (currently a dummy stand-in — see below), run once per stuck row |
| 9 | `recovery/dead_letters.py` | The dead-letter scan and revival logic — entirely independent of files 3–8, deliberately kept in its own file so it can be reviewed/changed/removed without touching the running SQL scan. May import `config.py` read-only (for the SQL connection string); never the reverse |
| 10 | `recovery/telemetry.py` | `message_scope(message)` — a `with`-block used only in `recovery/dead_letters.py`, giving one dead-letter message's logs their own `correlation_id` (distinguishing it from other messages in the same invocation, which `operation_Id` alone can't do). Every entry point imports this module purely for its side effect (installing the `correlation_id` `LogRecord` factory); ordinary invocation-level logs stay at `correlation_id=-`, relying on Azure's own `operation_Id` for invocation-level grouping. No OpenTelemetry/Azure Monitor dependency of any kind |



## Full call sequence, one timer tick

```
1. func_case_intake_recovery/function.json
   → declares: run every 2 minutes

2. func_case_intake_recovery/__init__.py → main(timer)
   → calls run_recovery()

3. recovery/service.py → run_recovery()
   3a. RecoveryConfig.from_env()                [recovery/config.py]
   3b. StuckEmailFinder(config)                  [recovery/stuck_emails.py]  — just creates the object, no DB call yet
   3c. build_publisher(config)                   [recovery/service.py]
        → OrchestratorRecoveryPublisher()        [recovery/publisher.py]  — no Service Bus configured, so this is picked

4. recovery/service.py → _replay_stuck_writes(finder, publisher, max_retry_attempts)
   4a. finder.find_stuck_instances()              [recovery/stuck_emails.py]   ← ONE SQL call
        → runs _FIND_STUCK_INSTANCES_SQL_TEMPLATE against dbo.cia_email_instance
          (matches: non-terminal status past the write window, OR failed_stage IS NOT NULL)
        → builds a list of StuckInstance objects    [recovery/stuck_emails.py]

   4b. for EACH StuckInstance in that list, one at a time:
        → attempt_number >= max_retry_attempts?
             → outcome.failed += 1 (reason "max_retry_attempts_exceeded") — no write, next row
        → finder.retry(activity_id)                 [recovery/stuck_emails.py]   ← REAL SQL write
             → EXEC dbo.usp_cia_email_instance_b1_write (retry-path branch, @subject=NULL)
             → returns (new_email_instance_id, skip_queueitem_write) — a genuinely new row now exists
        → write raised? → outcome.failed += 1, next row (no message published)
        → builds a ResumeMessage                    [recovery/publisher.py]
        → _publish_and_count(publisher, message, ...)   [recovery/service.py]
             → publisher.publish(message)
                  = OrchestratorRecoveryPublisher.publish()   [recovery/publisher.py]
                       → from orchestrator import run_from_stage
                       → orchestrator.spine.run_from_stage(activity_id, resume_from_stage, skip_queueitem_write, case_payload)   [orchestrator/spine.py]
                            → runs whichever of these apply, based on resume stage:
                                 _b1_write_activity_id()
                                 _b2_write_queue_item()
                                 _b3_check_write_success()
                                 _b4_pull_dataverse_data()
                                 _b5_process_email()
                                 _b6_invoke_agent_workflow()
                                 _b7_decision_actionable_confident()
                                 _b8_make_payload()
                                 _b9_post_payload()
                            ← returns a result dict
                       ← logs "recovery -> orchestrator.run_from_stage: {...}"
        ← outcome.replayed += 1  (or outcome.failed += 1 if this one row's publish threw —
                                    doesn't stop the loop, the next row is still attempted)

5. recovery/service.py → run_recovery()
   → publisher.close()
   → returns RecoverySummary(stuck_writes)        [recovery/service.py]

6. func_case_intake_recovery/__init__.py → main(timer)
   → logging.info("func_case_intake_recovery summary: %s", summary.as_log_dict())

7. func_case_intake_recovery/__init__.py → main(timer)   ← SECOND, INDEPENDENT scan
   → process_dead_letters()                       [recovery/dead_letters.py]
        → ServiceBusClient + DefaultAzureCredential (managed identity, same
          "CaseIntakeServiceBus" connection func_orchestrate already uses)
        → receiver.receive_messages() against case-intake-ingestion/$DeadLetterQueue
             (PeekLock — takes a lock, unlike scan_dead_letters()'s peek)
        → for EACH message received, one at a time:
             → _summarize(message)                 [recovery/dead_letters.py]
                  → tries to parse the body as JSON, via _extract_activity_id():
                       flat {"activity_id": ...} shape, OR a Dataverse queueitem
                       "Create" event's InputParameters[].value.Attributes[].value
             → no activity_id extracted (e.g. unrecognized Dataverse LogicalName,
               or an unparseable body)?
                  → receiver.abandon_message(message)   — left untouched, counted in `skipped`
             → activity_id found:
                  → _email_instance_exists(sql_connection_string, activity_id)   [recovery/dead_letters.py]
                  → EXISTS:
                       → _queue_item_exists(sql_connection_string, activity_id)   [recovery/dead_letters.py]
                       → EXISTS too → receiver.abandon_message(message)   — duplicate, counted in `skipped`
                       → MISSING    → _write_queue_item(...) then receiver.complete_message(message)
                                       — counted in `processed` (action "queue_item_backfilled")
                  → DOES NOT EXIST:
                       → _run_b1_write(sql_connection_string, activity_id)   [recovery/dead_letters.py]
                            → EXEC dbo.usp_cia_email_instance_b1_write (@subject=NULL)
                            → returns (new_email_instance_id, skip_queueitem_write)
                       → skip_queueitem_write is False? → _write_queue_item(...)
                            → INSERT dbo.cia_queue_item (queue_id = documented sentinel GUID)
                       → receiver.complete_message(message)   — counted in `processed` (action "processed")
                  → any existence check or write raised → receiver.abandon_message(message)
                       — left in DLQ, counted in `failed`
   → returns a DeadLetterOutcome(found, processed, skipped, failed, messages)
   → if any found, logs "dead letters found=N processed=N skipped=N failed=N"
   → this scan's own try/except means a Service Bus/SQL failure here never
     prevents step 3-6's SQL scan from running, or vice versa
```

## FAQ

**Does `stuck_emails.py` pull all instances and call the publisher one by one?**

Yes. One SQL query pulls every matching row in a single round trip:

```python
# recovery/stuck_emails.py — find_stuck_instances()
with self._connect() as conn:
    rows = conn.execute(sql, params).fetchall()   # ONE query, ALL matching rows at once
return [StuckInstance(...) for row in rows]
```

Then `service.py` loops over that list and calls the publisher once per row, sequentially — not in parallel, not batched into a single call:

```python
# recovery/service.py — _replay_stuck_writes()
stuck_rows = finder.find_stuck_instances()   # the whole list, one round trip to SQL
for row in stuck_rows:                        # THEN loop, one row at a time
    message = ResumeMessage(...)
    _publish_and_count(publisher, message, row.activity_id, outcome)
```

If the query returns 5 stuck rows, each one gets retried (subject to the cap) and the orchestrator gets called up to 5 times, one after another. If any single row's retry write or publish call fails, it's caught, counted in `outcome.failed`, and the loop continues to the next row rather than aborting the whole run.

## Current status of the orchestrator

`orchestrator/spine.py` is a **placeholder**, not the real B.1–B.9 implementation. Every step (`_b1_write_activity_id` through `_b9_post_payload`) just logs what it would do and returns a fake-but-correctly-shaped result. The real implementation — being built by a teammate, per `Case_Intake_Design_Diagram.png` — will replace the bodies of those functions; `run_from_stage`'s sequencing logic (which steps to run or skip based on where a recovered attempt left off, and whether to skip B.2 when a queue item already exists) is already correct and won't need to change.

## Manual entry points (run from the `Functions/` folder)

| Script | Does it mutate anything? |
|---|---|
| `local_run.py` | **Yes** — runs the SQL stuck-writes scan, which now really retries every stuck row found (subject to `max_retry_attempts`) via `StuckEmailFinder.retry()` (pops a browser login the first time) |
| `local_run_dead_letters.py` | No — `scan_dead_letters()`, pure peek |
| `local_run_process_dead_letters.py` | **Yes** — `process_dead_letters()`, the same active revive-and-complete logic the deployed timer runs |

## Telemetry / correlation_id

`correlation_id` is deliberately **not** generated at the invocation level — Azure Functions already tags every invocation's logs with a real `operation_Id` natively, for free (see `Functions/LOG_FLOW.md`), so a second, self-generated id for the same purpose would be pure duplication. All four entry points above import `recovery.telemetry` purely for its side effect (installing the `correlation_id` `LogRecord` factory); ordinary logs from `run_recovery()`, `recovery.service`, `recovery.stuck_emails`, etc. all show `correlation_id=-`, relying on `operation_Id` for invocation-level grouping.

The one place `correlation_id` becomes genuinely useful: `recovery/dead_letters.py` opens a nested scope per message while processing dead letters, via `with telemetry.message_scope(message):` — using that message's own native Service Bus `.correlation_id` property if the publisher set one, otherwise a freshly generated `uuid4`. This is the one thing `operation_Id` can't do on its own: distinguish two different dead-letter messages handled within the *same* invocation, which would otherwise share the same `operation_Id`. The moment the `with` block ends (normal completion, `continue`, or an exception — doesn't matter which), `correlation_id` automatically goes back to `-`, with no manual restore step to forget.

**No OpenTelemetry/Azure Monitor dependency exists anywhere in this codebase.** Three iterations existed at different points and were all simplified away — sourcing correlation_id from OpenTelemetry's trace_id (never once worked in practice), then keeping `configure_azure_monitor()` just for Service Bus dependency tracing (dropped per a client preference to move away from OpenTelemetry entirely), then finally dropping the self-generated whole-invocation id itself once it was recognized as pure duplication of `operation_Id`. See `recovery/TELEMETRY.md`'s "History" section for the full reasoning behind each.

## Not yet wired up

Service Bus (`case-intake-ingestion`) has no live consumer for this pipeline yet, so `OrchestratorRecoveryPublisher` calls the orchestrator directly, in-process, instead of publishing to a queue. `ServiceBusRecoveryPublisher` already exists in `recovery/publisher.py`, ready to switch on once a real consumer exists — set `SERVICE_BUS_NAMESPACE` and `SERVICE_BUS_QUEUE_NAME` and `build_publisher()` in `recovery/service.py` picks it automatically.
