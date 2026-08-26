# How logs flow from Python code to Application Insights / Log Analytics

## The short answer

Logs from any function in this app (including `func_case_intake_recovery`) reach Application Insights and Log Analytics automatically, with **zero application code and zero configuration beyond the `APPLICATIONINSIGHTS_CONNECTION_STRING` app setting** (already configured on `func-zenon-wab-eus2`). This has never depended on OpenTelemetry or `azure-monitor-opentelemetry` — it's separate, platform-level infrastructure that predates and is unaffected by anything in `recovery/telemetry.py`, including its removal of `configure_azure_monitor()` (see `recovery/TELEMETRY.md`'s "History" section for that removal).

## Step by step

**1. Your code calls `logger.info(...)` / `logger.exception(...)`.**
Anywhere in `recovery/service.py`, `recovery/dead_letters.py`, `recovery/stuck_emails.py`, etc. This builds a `LogRecord` object — which, thanks to `recovery/telemetry.py`'s record factory, already has `record.correlation_id` stamped on it at this point, independent of everything below.

**2. The Azure Functions Python Worker's built-in logging handler picks it up.**
The moment the Function App cold-starts, the Python worker (the process that actually runs your code, separate from the Functions host) attaches its own handler to the root logger automatically — this happens during platform startup, before any function code runs, and requires zero application code. This is a built-in part of the `azure-functions` runtime, nothing to do with OpenTelemetry.

**3. The record is forwarded to the Functions host over gRPC.**
The Python worker and the actual Functions host (a separate, language-agnostic process that manages the whole Function App — triggers, bindings, scaling) communicate over gRPC. Every log record gets sent across this channel — the same channel that powers the Portal's live log-streaming view.

*What gRPC is, briefly:* a framework (originally from Google) that lets one process call into a different process — possibly a different language, always a separate process here — almost like a local function call, over HTTP/2, using a compact binary format (Protocol Buffers) instead of text-based JSON. Azure Functions uses it specifically for this host ↔ language-worker boundary: "here's an incoming trigger, run this," "here's the log line your code just wrote," "here's the result to return."

**4. The host's own Application Insights integration converts it to telemetry.**
The Functions host itself (not your Python code, not OpenTelemetry) has Application Insights support built directly into the runtime. It reads `APPLICATIONINSIGHTS_CONNECTION_STRING` from the app settings, converts your log record into a `TraceTelemetry` item (or `ExceptionTelemetry` for `logger.exception`), and — critically — tags it with the real `operation_Id`/`operation_ParentId` for *that specific invocation*. This is the mechanism that gives correct invocation grouping natively, regardless of anything in `telemetry.py`.

**5. The host batches and ships telemetry to the ingestion endpoint.**
Sent over HTTPS to the `IngestionEndpoint` URL embedded in the connection string — Microsoft's Application Insights ingestion service.

**6. It lands in storage, split across tables by type.**
- `traces` — ordinary log lines. This is where nearly everything from this codebase lands.
- `exceptions` — `logger.exception()` calls.
- `requests` — one per invocation (the `"Executing 'Functions...'"` / `"Executed 'Functions...'"` rows).

Any custom attributes on the record — including `correlation_id`, stamped by `telemetry.py`'s factory — get serialized into `customDimensions`, queryable as `customDimensions.correlation_id`.

**7. Application Insights and Log Analytics are the same underlying store.**
In the modern "workspace-based" mode (which this resource uses), the Application Insights resource is a curated view over an underlying Log Analytics workspace — the same data, queryable from either the App Insights "Logs" blade or the Log Analytics workspace directly, with identical KQL.

## What actually depends on `configure_azure_monitor()` (now removed)

Nothing in the flow above. The only thing `configure_azure_monitor()` ever added on top of this native path was:
- A **second, duplicate** export of the same log lines through OpenTelemetry's own logging pipeline — which, since nothing wrapped the Timer invocation in an OpenTelemetry span, produced rows with an invalid, all-zero `operation_Id` instead of a real one. This was an active bug, not a benefit — removing it made the `traces` table *more* correct, not less.
- A separate `dependencies` table entry for each Service Bus SDK call (`ServiceBus.receive`, `ServiceBus.abandon`, etc.), giving the exact duration of each call. This is the one thing genuinely lost by removing `configure_azure_monitor()` — the *outcome* of each call (success/failure, and why) is still fully covered by this codebase's own `logger.info`/`logger.exception` calls, which reach `traces` via the native path above regardless.
