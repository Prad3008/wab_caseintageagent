# Correlating traces across orchestrate → APIM → Foundry

## Scope and status

This is a planning/implementation guide, not something implemented in this repo. `func_orchestrate` — the live function that actually calls Foundry — is **not** part of this repo's source. `deploy.sh` documents this explicitly: this repo's `Functions/` folder only contains `func_case_intake_recovery/`, `recovery/`, and `orchestrator/` (a dummy B.1–B.9 stand-in for the case-intake pipeline's design); `func_orchestrate`, `func_recovery`, `func_feedback`, and Foundry's own configuration were never committed here and have not been touched by any of this work.

Everything below is a design plan for whoever owns `func_orchestrate`'s actual source, written from what was verified while building `recovery/telemetry.py` for the unrelated `func_case_intake_recovery` function (see `recovery/TELEMETRY.md`) plus general, well-established OpenTelemetry/Application Insights behavior. Where something is uncertain rather than verified, it's flagged as such below.

## The chain

```
func_orchestrate  --HTTP-->  APIM  --HTTP-->  Foundry
```

For a single `correlation_id`/`operation_id`/trace_id to tie all three together, every hop needs to both **extract** the incoming trace context and **propagate** it onward. Any single hop that doesn't do this breaks the chain from that point forward — the parts before it stay linked to each other, but nothing downstream of the break links back.

## 1. In `func_orchestrate`'s code

- Call `configure_azure_monitor()` once at startup. Note: `recovery/telemetry.py` (built for the unrelated `func_case_intake_recovery`) used to do exactly this, but that call has since been removed there entirely, per a client preference to move away from OpenTelemetry given its maturity/churn concerns — see `recovery/TELEMETRY.md`'s "History" section for the full reasoning, including a duplicate-logging bug that required an `OTEL_LOGS_EXPORTER=none` workaround while it was still in use. Whether the same OpenTelemetry-skepticism applies to `func_orchestrate` is a separate call for whoever owns that function — this guide assumes it's still in scope there since propagating `traceparent` to Foundry has no non-OpenTelemetry equivalent (unlike `func_case_intake_recovery`'s correlation_id, which had a good non-OpenTelemetry alternative — the Service Bus message's own native `.correlation_id` property).
- **The key difference from `func_case_intake_recovery`:** explicitly wrap the whole invocation body in a span *before* calling APIM/Foundry:
  ```python
  from opentelemetry import trace
  from opentelemetry.propagate import extract

  def main(msg: func.ServiceBusMessage):
      # func_orchestrate is triggered by a Service Bus message. If whatever
      # published it was itself OpenTelemetry-instrumented, the message
      # carries a traceparent in its application properties -- this must be
      # explicitly extracted and passed as the parent context; simply
      # wrapping in a span does NOT pick this up automatically. Confirm the
      # publisher (MuleSoft, or whatever enqueues onto this queue) actually
      # sets this property before relying on it -- if it doesn't, the
      # extract() call below is a safe no-op and a fresh root trace starts
      # instead, same as if this section didn't exist.
      props = msg.application_properties or {}
      traceparent = props.get(b"traceparent") or props.get("traceparent")
      if isinstance(traceparent, bytes):
          traceparent = traceparent.decode("utf-8")

      carrier = {"traceparent": traceparent} if traceparent else {}
      parent_context = extract(carrier)  # empty carrier -> current (empty) context, safe fallback

      tracer = trace.get_tracer(__name__)
      with tracer.start_as_current_span("func_orchestrate", context=parent_context):
          response = requests.post(apim_url, json=payload, ...)
  ```
  This matters because of exactly what `recovery/telemetry.py`'s `TELEMETRY.md` documents for `func_case_intake_recovery`: if nothing wraps the invocation in a span, `trace.get_current_span().get_span_context().is_valid` is `False` at the moment any outbound call happens, and each auto-instrumented outbound call (e.g. an HTTP request) starts as its *own* disconnected root trace rather than a child of "this invocation." Without the explicit wrap *and* the extraction step above, you'd get a fresh, unrelated trace_id for every single Foundry call, disconnected from whatever published the triggering message — no better than not having tracing at all for the purpose of tying the whole chain back together.
- Use `requests` or `httpx` to make the call (both are in `azure-monitor-opentelemetry`'s supported auto-instrumentation list). Once wrapped in a real span, the `traceparent` header is injected into the outbound request automatically — no manual header code needed for the outbound half.

## 2. In APIM

- Confirm no inbound policy strips `traceparent`/`tracestate` headers. APIM passes through unrecognized headers by default, but this is worth auditing directly rather than assuming.
- Enable Application Insights integration on the API (Portal → API → Settings → Application Insights) — and **point it at the exact same App Insights resource** `func_orchestrate` uses. This is the step most likely to get missed: even if the `traceparent` header technically passes through untouched, APIM's own gateway-level telemetry (latency, response codes, throttling) lands in a *separate* place unless explicitly configured to land in the same resource.

## 3. Foundry — the genuinely uncertain piece

- Check whether the specific Foundry/Azure OpenAI resource in use exports its own telemetry via Diagnostic Settings, and if so, route it to the **same Log Analytics workspace** as the Function App and APIM. Without a shared destination workspace, there is no single place to query across all three regardless of whether the trace_id itself propagates correctly.
- Whether Foundry's managed endpoint actually **extracts** an incoming `traceparent` and uses it as the parent for its own internal step-level spans is specific to that service's implementation. This has not been verified in this session — it should be tested empirically (send one request with a known trace_id, then check whether Foundry's own monitoring surface shows a matching trace_id) rather than assumed either way.

## 4. A more robust fallback, given #3's uncertainty

Relying on infrastructure-level `traceparent` propagation across a PaaS boundary you don't fully control (Foundry's internals) is inherently less certain than something under direct application control. An alternative that doesn't depend on Foundry's internal tracing behavior: pass a business-level identifier — `activity_id` or `email_instance_id`, already logged everywhere in this system — explicitly in the request payload or a custom header to Foundry, and have Foundry's own logging (if the agent/prompt pipeline supports custom tags or metadata per call) echo it back. That gives a guaranteed, application-controlled correlation key independent of whether OpenTelemetry's trace context actually survives the APIM hop.

## 5. Querying across all three, once wired up

Assuming all three routes into one shared Log Analytics workspace:

```kql
union (traces | where operation_Id == "<trace_id>"),
      (dependencies | where operation_Id == "<trace_id>"),
      (<FoundryTelemetryTable> | where operation_Id == "<trace_id>")
| order by timestamp asc
```

The exact table name for Foundry's own exported telemetry depends on how its Diagnostic Settings are configured — this would need to be confirmed against whatever's actually set up for that resource.

## Summary of what's confirmed vs. assumed

| Claim | Status |
|---|---|
| `requests`/`httpx` auto-instrumentation injects `traceparent` automatically once wrapped in a real span | Confirmed at the time — same underlying mechanism verified for Service Bus calls via `configure_azure_monitor()` while `recovery/telemetry.py` still used it (`ServiceBus.receive`/`ServiceBus.abandon` showing up as dependencies). That call has since been removed from `telemetry.py` entirely, so this is no longer something `func_case_intake_recovery` demonstrates live — the underlying OpenTelemetry mechanism itself is unaffected and still applies to whatever `func_orchestrate` implements |
| Without an explicit span wrap, each outbound call becomes its own disconnected root trace | Confirmed at the time — this was exactly the `is_valid=False` behavior documented in `recovery/TELEMETRY.md`'s "History" section. Note: `recovery/telemetry.py` no longer contains any span-checking logic at all (that whole code path was removed, not just documented as unreachable) — that section is now purely a historical writeup of the general principle, which still applies to whatever `func_orchestrate` implements, not a description of current `telemetry.py` behavior |
| `func_orchestrate` is Service-Bus-triggered | Confirmed |
| The triggering Service Bus message carries a `traceparent` in its application properties | Confirmed by whoever owns `func_orchestrate` — but this only helps if the code explicitly extracts it (section 1's `extract(carrier)` call) and passes it as the parent context; wrapping in a span alone does not read it automatically |
| APIM passes through `traceparent` by default | Standard APIM behavior, not independently verified against this specific APIM instance's policies |
| Foundry extracts incoming `traceparent` for its own spans | **Not verified** — flagged as uncertain, needs empirical testing |
| Foundry telemetry lands in the same Log Analytics workspace as the Function App by default | **Not true by default** — requires explicit Diagnostic Settings configuration, not confirmed to exist currently |
