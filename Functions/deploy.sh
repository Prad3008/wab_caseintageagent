#!/usr/bin/env bash
# Deploys this Functions/ folder's changes to func-zenon-wab-eus2 (Flex
# Consumption) in one shot. Run from anywhere; it cd's to its own directory.
#
# IMPORTANT: this repo's Functions/ folder only contains func_case_intake_recovery/,
# recovery/, and orchestrator/ -- it does NOT contain func_recovery/,
# func_orchestrate/, func_feedback/, src/, or foundry/, which also live in
# the deployed app but were never committed to this repo. Naively zipping
# just this folder and deploying it would silently DROP those from the live
# app. So this script downloads the current live package first and overlays
# this repo's func_case_intake_recovery/recovery/orchestrator on top of it,
# rather than deploying this folder in isolation.
#
# See DEPLOYMENT.md for why this bypasses the standard `az functionapp
# deploy` / `config-zip` commands (they don't work on Flex Consumption) and
# talks to Kudu's own HTTP API directly instead.
#
# Usage:
#   ./deploy.sh
#
# Requires: az cli logged in (az login) with Contributor on the storage
# account (to read the live package) and the function app, python3, curl.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-zenon-wab-foundry-eus2}"
FUNCTION_APP="${FUNCTION_APP:-func-zenon-wab-eus2}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-stzenonwabeus2}"
STORAGE_CONTAINER="${STORAGE_CONTAINER:-stzenonwabeus2}"
SCM_HOST="${FUNCTION_APP}-fde7dybtdkaqf3cr.scm.eastus2-01.azurewebsites.net"
OVERLAY_DIRS=(func_case_intake_recovery recovery orchestrator)
NEW_DEPENDENCIES=(pyodbc azure-servicebus)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WORK_DIR="$(mktemp -d)"
# python here is a native Windows build, not MSYS-aware -- it can't resolve
# the /tmp/... paths bash hands out, so every path passed to python is
# converted to a Windows path first.
WORK_DIR_WIN="$(cygpath -w "$WORK_DIR" 2>/dev/null || echo "$WORK_DIR")"
trap 'rm -rf "$WORK_DIR"' EXIT

LIVE_ZIP="${WORK_DIR}/live-package.zip"
LIVE_ZIP_WIN="$(cygpath -w "$LIVE_ZIP" 2>/dev/null || echo "$LIVE_ZIP")"
MERGED_DIR="${WORK_DIR}/merged"
MERGED_DIR_WIN="$(cygpath -w "$MERGED_DIR" 2>/dev/null || echo "$MERGED_DIR")"
ZIP_PATH="${WORK_DIR}/deploy-package.zip"
ZIP_PATH_WIN="$(cygpath -w "$ZIP_PATH" 2>/dev/null || echo "$ZIP_PATH")"

echo "==> [1/6] Downloading the current live package (so func_recovery/func_orchestrate/func_feedback aren't dropped)"
az storage blob download \
  --account-name "$STORAGE_ACCOUNT" --container-name "$STORAGE_CONTAINER" \
  --name released-package.zip --file "$LIVE_ZIP" --auth-mode key -o none

echo "==> [2/6] Extracting live source (excluding the vendored .python_packages build output)"
mkdir -p "$MERGED_DIR"
python -c "
import zipfile

exclude_prefixes = ('.python_packages/', 'oryx-manifest.toml', '.ostype')
with zipfile.ZipFile(r'${LIVE_ZIP_WIN}') as zf:
    count = 0
    for name in zf.namelist():
        if any(name == p or name.startswith(p) for p in exclude_prefixes):
            continue
        zf.extract(name, r'${MERGED_DIR_WIN}')
        count += 1
    print(f'  extracted {count} files from the live package')
"

echo "==> [3/6] Overlaying this repo's current ${OVERLAY_DIRS[*]}"
for d in "${OVERLAY_DIRS[@]}"; do
  rm -rf "${MERGED_DIR:?}/${d}"
  cp -r "$d" "${MERGED_DIR}/${d}"
  # Local testing leaves __pycache__/*.pyc behind -- never ship those.
  find "${MERGED_DIR}/${d}" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
  echo "  overlaid ${d}/"
done

echo "==> [4/6] Ensuring requirements.txt has this function's dependencies"
REQ="${MERGED_DIR}/requirements.txt"
for pkg in "${NEW_DEPENDENCIES[@]}"; do
  if ! grep -qi "^${pkg}" "$REQ"; then
    printf '\n%s\n' "$pkg" >> "$REQ"
    echo "  added missing dependency: $pkg"
  fi
done

echo "==> [5/6] Building the merged source-only zip"
python -c "
import os, zipfile

base = r'${MERGED_DIR_WIN}'
with zipfile.ZipFile(r'${ZIP_PATH_WIN}', 'w', zipfile.ZIP_DEFLATED) as zf:
    count = 0
    for root, dirs, files in os.walk(base):
        for f in files:
            full = os.path.join(root, f)
            zf.write(full, os.path.relpath(full, base))
            count += 1
    print(f'  zipped {count} files')
"
echo "  size: $(du -h "$ZIP_PATH" | cut -f1)"

echo "==> [6/6] Deploying via Kudu (RemoteBuild=true)"
CORE_TOKEN=$(az account get-access-token --resource https://management.core.windows.net/ --query accessToken -o tsv)
RESPONSE=$(curl -sS -X POST "https://${SCM_HOST}/api/publish?RemoteBuild=true" \
  -H "Authorization: Bearer ${CORE_TOKEN}" \
  -H "Content-Type: application/zip" \
  --data-binary @"$ZIP_PATH" \
  -w "\nHTTP_STATUS:%{http_code}\n")

HTTP_STATUS=$(echo "$RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
DEPLOYMENT_ID=$(echo "$RESPONSE" | head -1 | tr -d '"')

if [[ "$HTTP_STATUS" != "202" ]]; then
  echo "  FAILED: HTTP $HTTP_STATUS"
  echo "$RESPONSE"
  exit 1
fi
echo "  accepted, deployment id: $DEPLOYMENT_ID"

echo "==> Polling deployment status (up to ~4 minutes)"
for i in $(seq 1 24); do
  DEPLOY_RESP=$(curl -sS "https://${SCM_HOST}/api/deployments/${DEPLOYMENT_ID}" \
    -H "Authorization: Bearer ${CORE_TOKEN}" --max-time 20)
  STATUS=$(echo "$DEPLOY_RESP" | python -c "import json,sys; d=json.load(sys.stdin); print(d['status'], d['complete'])")
  echo "  poll $i: status=$STATUS"
  if [[ "$STATUS" == *"True"* ]]; then
    CODE=$(echo "$STATUS" | cut -d' ' -f1)
    if [[ "$CODE" != "4" ]]; then
      echo "  FAILED: deployment finished with status $CODE (4 = success). Full response:"
      echo "$DEPLOY_RESP" | python -m json.tool
      exit 1
    fi
    break
  fi
  sleep 10
done

echo "==> Verifying functions are present"
az functionapp function list --name "$FUNCTION_APP" --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv

echo ""
echo "Done. Check Application Insights for the first few invocations to confirm it's actually running:"
echo "  az monitor app-insights query --app appi-zenon-wab-eus2 -g $RESOURCE_GROUP \\"
echo "    --analytics-query \"traces | where timestamp > ago(5m) | order by timestamp asc | project timestamp, message\""
