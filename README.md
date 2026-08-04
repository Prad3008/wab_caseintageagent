# Azure Function App — CLI Workflow

This README documents the end-to-end workflow for working with an existing Azure Function App using **Azure CLI (`az`)** and **Azure Functions Core Tools (`func`)** instead of the VS Code Azure extension. Anyone on the team can follow this to get set up and verify their own environment.

---

## Prerequisites

- **Azure CLI** installed
  - Windows: `winget install Microsoft.AzureCLI`
  - Mac: `brew install azure-cli`
- **Azure Functions Core Tools** installed (`func` command) — needed for scaffolding/running functions locally, since `az` does not do this
- **Python** (version matching the Function App's runtime — see Step 3)
- **Git**
- Access to the correct Azure subscription/tenant for this project

---

## 1. Install & Sign In

```bash
az login
```

If your account has access to multiple tenants or subscriptions, list them and set the right one explicitly:

```bash
az account list --all --output table
az account set --subscription "<subscription-id>"
```

> ⚠️ **Common gotcha:** `az account show --output table` does **not** show a `SubscriptionId` column by default — it can look like the Tenant ID is the Subscription ID. Always confirm explicitly:
>
> ```bash
> az account show --query "{Name:name, SubscriptionId:id, TenantId:tenantId}" --output table
> ```
>
> Use the value under **SubscriptionId** (not TenantId) in `az account set --subscription`.

---

## 2. Find Your Function App

```bash
az functionapp list --output table
```

### If you see `Table output unavailable. Use the --query option...`

This is **not necessarily an error** — the default table formatter can fail even when data exists, or when the list is empty. Diagnose it like this:

```bash
# Step 1: check raw JSON output
az functionapp list --output json
```

- **Returns `[]`** → there are genuinely no Function Apps in this subscription. You're likely logged into the wrong subscription or tenant. Re-check with:
  ```bash
  az account list --all --output table
  ```
- **Returns actual data** → the table formatter choked on a missing/null field. Use an explicit `--query` to project only the fields you need:
  ```bash
  az functionapp list --query "[].{Name:name, ResourceGroup:resourceGroup, State:state, Location:location}" --output table
  ```

If you know the resource group already, you can skip the discovery step entirely:

```bash
az functionapp list --resource-group <your-rg> --output table
```

**✅ Note the exact Function App name and resource group** — both are required for every command below.

---

## 3. Check the Runtime/Version (to match locally)

```bash
az functionapp show \
  --name <your-function-app-name> \
  --resource-group <your-rg> \
  --query "{sku:properties.sku, runtimeName:properties.functionAppConfig.runtime.name, runtimeVersion:properties.functionAppConfig.runtime.version}" \
  --output table
```

> ⚠️ **Flex Consumption apps (`"sku": "FlexConsumption"`)** report runtime info under `functionAppConfig.runtime`, **not** under the classic `siteConfig.linuxFxVersion` / `siteConfig.pythonVersion` fields — those come back `null`/empty on Flex Consumption plans. If your query returns nothing, first check the SKU:
>
> ```bash
> az functionapp show --name <app> --resource-group <rg> --query "properties.sku" --output tsv
> ```
>
> - `FlexConsumption` → use the `functionAppConfig.runtime` query above
> - `Dynamic` / `ElasticPremium` / App Service Plan → use the original `siteConfig` query:
>   ```bash
>   az functionapp show \
>     --name <app> --resource-group <rg> \
>     --query "{runtime:siteConfig.linuxFxVersion, pythonVersion:siteConfig.pythonVersion}" \
>     --output table
>   ```

Install the matching Python version locally before proceeding.

---

## 4. Get the Code & Set Up Locally

```bash
git clone <your-ado-repo-url>
cd YourFunctionApp

python -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate

pip install -r requirements.txt
```

Open in VS Code (`code .`) purely for editing/debugging — no Azure sign-in is needed inside VS Code itself, since the CLI already handles auth.

---

## 5. Pull App Settings from Azure into Local Config

List current app settings:

```bash
az functionapp config appsettings list \
  --name <your-function-app-name> \
  --resource-group <your-rg> \
  --output table
```

There is **no direct `az` command** to auto-merge settings into `local.settings.json` (that's a VS Code extension convenience feature). Export to JSON and copy manually, or script it:

```bash
az functionapp config appsettings list \
  --name <your-function-app-name> \
  --resource-group <your-rg> \
  --output json > appsettings.json
```

Then hand-copy the **non-secret** values (Service Bus name, SQL server name, etc.) into `local.settings.json`.

**Do not** copy Key Vault–referenced values directly — pull those from Key Vault instead:

```bash
az keyvault secret show \
  --vault-name <your-keyvault-name> \
  --name <secret-name> \
  --query value -o tsv
```

---

## 6. Create a New Function (via Core Tools, not `az`)

Azure CLI doesn't scaffold function code — use `func`:

```bash
# Service Bus Queue trigger
func new --name b1_intake_handler --template "Azure Service Bus Queue trigger" --authlevel function

# HTTP trigger
func new --name b1_intake_handler --template "HTTP trigger" --authlevel function
```

This scaffolds into `function_app.py` (v2 model) or a new folder (v1 model), matching whatever model your existing project already uses.

---

## 7. Run & Test Locally

```bash
func start
```

Test an HTTP-triggered function:

```bash
curl -X POST http://localhost:7071/api/b1_intake_handler -d '{"test":"data"}'
```

Test a Service Bus–triggered function by sending a test message:

```bash
az servicebus queue message send \
  --resource-group <your-rg> \
  --namespace-name <your-sb-namespace> \
  --queue-name <your-queue-name> \
  --body '{"test":"payload"}'
```

> **Note:** `az servicebus queue message send` isn't available in all CLI extension versions. If it errors, use **Service Bus Explorer** in the Portal, or a small Python script with the `azure-servicebus` SDK to send a test message.

---

## 8. Deploy to Confirm (Dev Only)

```bash
func azure functionapp publish <your-function-app-name>
```

> ⚠️ Dev testing only — QA and Production deployments go through the CI/CD pipeline, not this command.

---

## Troubleshooting Quick Reference

| Symptom | Likely Cause | Fix |
|---|---|---|
| `Table output unavailable` on `az functionapp list` | Empty result set, or missing field breaks table formatter | Run with `--output json` first, then use explicit `--query` projection |
| `az account set --subscription` says subscription doesn't exist | You used the Tenant ID instead of Subscription ID | Run `az account show --query "{Name:name, SubscriptionId:id, TenantId:tenantId}"` and use the correct field |
| Function App not appearing anywhere | Wrong subscription/tenant active | `az login --allow-no-subscriptions` then `az account list --all --output table` |
| `az servicebus queue message send` not found | CLI extension version doesn't support it | Use Service Bus Explorer (Portal) or `azure-servicebus` Python SDK |
| `siteConfig.linuxFxVersion` / `pythonVersion` query returns empty | App is on a **Flex Consumption** plan (`"sku": "FlexConsumption"`), which stores runtime info elsewhere | Query `properties.functionAppConfig.runtime.name` / `.version` instead |

---

## Quick Command Cheat Sheet

```bash
az login
az account list --all --output table
az account set --subscription "<subscription-id>"
az functionapp list --query "[].{Name:name, ResourceGroup:resourceGroup, State:state, Location:location}" --output table
az functionapp show --name <app> --resource-group <rg> --query "{runtime:siteConfig.linuxFxVersion, pythonVersion:siteConfig.pythonVersion}" --output table
az functionapp config appsettings list --name <app> --resource-group <rg> --output table
az keyvault secret show --vault-name <vault> --name <secret> --query value -o tsv
func new --name <function-name> --template "<template>" --authlevel function
func start
func azure functionapp publish <app>
```
