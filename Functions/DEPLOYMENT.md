# Deploying to func-zenon-wab-eus2 via Azure CLI

`func-zenon-wab-eus2` runs on the **Flex Consumption** plan, which breaks the
"normal" Azure Functions CLI deployment commands. This doc is the actual
working procedure, and why the obvious commands fail.

## Why the standard commands don't work here

```bash
az functionapp deployment source config-zip ...   # Fails: "not supported for Flex Consumption"
az functionapp deploy ...                          # Fails: 415 / connection errors on this plan
az functionapp deployment list-publishing-credentials ...  # Fails: Basic Auth isn't supported on this plan
```

Flex Consumption doesn't run the traditional Kudu file system
(`/api/vfs/...`, `/api/zipdeploy`) that these commands rely on. It deploys by
handing a source package to Kudu's build pipeline, which compiles it with
Oryx and drops the final artifact into a storage account blob the app
actually runs from (`stzenonwabeus2/stzenonwabeus2/released-package.zip`, in
this app's case).

## The actual working procedure

### 1. Build a source-only zip

No vendored dependencies — Oryx builds them remotely. Zip up `host.json`,
`requirements.txt`, and every `func_*/` and shared package folder
(`recovery/`, `orchestrator/`, etc.) at the app root. Keep this small (a few
hundred KB); do **not** include a pre-built `.python_packages` folder.

```bash
cd Functions
python -c "
import zipfile, os
with zipfile.ZipFile('deploy-package.zip', 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk('.'):
        for f in files:
            full = os.path.join(root, f)
            zf.write(full, os.path.relpath(full, '.'))
"
```

### 2. Get an AAD token scoped for Kudu

Not `https://management.azure.com/` — that audience 404s against this app's
SCM host. The working audience is `https://management.core.windows.net/`.

```bash
CORE_TOKEN=$(az account get-access-token --resource https://management.core.windows.net/ --query accessToken -o tsv)
```

### 3. POST the zip to Kudu's `/api/publish` endpoint with `RemoteBuild=true`

```bash
SCM_HOST="func-zenon-wab-eus2-fde7dybtdkaqf3cr.scm.eastus2-01.azurewebsites.net"
curl -X POST "https://${SCM_HOST}/api/publish?RemoteBuild=true" \
  -H "Authorization: Bearer ${CORE_TOKEN}" \
  -H "Content-Type: application/zip" \
  --data-binary @deploy-package.zip
```

Returns `202 Accepted` with a deployment ID (e.g. `"a1cf30a3-..."`) almost
immediately. The actual build (Oryx installing `requirements.txt`) happens
asynchronously and takes roughly 2 minutes.

### 4. Poll the deployment status until it completes

```bash
curl "https://${SCM_HOST}/api/deployments/<deployment-id>" \
  -H "Authorization: Bearer ${CORE_TOKEN}"
```

Watch the `status` field:

| status | meaning |
|---|---|
| `1` | Building |
| `2` | Deploying |
| `4` | Success (`complete: true` at this point) |
| anything else | Failed — check the `log_url` in the response |

### 5. Verify

```bash
az functionapp function list --name func-zenon-wab-eus2 --resource-group rg-zenon-wab-foundry-eus2
```

Confirm the function shows up, then check Application Insights for the
first few invocations to confirm it's actually running correctly — a
successful deploy doesn't guarantee the code runs without error (cold-start
SQL/Service Bus auth blips have shown up on the very first tick after a
deploy in this app before, then succeeded on the next one).

```bash
az monitor app-insights query --app appi-zenon-wab-eus2 -g rg-zenon-wab-foundry-eus2 \
  --analytics-query "traces | where timestamp > ago(5m) | where message has '<your-function-name>' | order by timestamp asc | project timestamp, message"
```

## Notes specific to this app

- **App settings persist across deploys** — deploying new code does not
  reset `local.settings.json`-equivalent app settings. If a function shows
  as disabled (`AzureWebJobs.<name>.Disabled = 1`), check that separately;
  it isn't caused by (or fixed by) redeploying.
- **A disabled-looking function right after deploy may just be worker
  recycle lag** — Flex Consumption can show a function as briefly disabled
  for a few minutes while workers converge on the new package, then settle
  back to its real enabled/disabled setting on its own.
- **Deploying only touches what's in the zip** — this app hosts multiple
  functions (`func_recovery`, `func_orchestrate`, `func_feedback`,
  `func_case_intake_recovery`). Always package the *whole* app root, not
  just the function you're changing, or you'll silently drop the others
  from the deployed package.
