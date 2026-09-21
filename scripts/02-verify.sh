#!/usr/bin/env bash
# Exercises the running litellm pod end-to-end: lists configured models,
# then sends a tiny chat completion to the verify model(s) and reports pass/fail,
# and finally checks the OpenShift MCP gateway.
#
# Env vars:
#   VERIFY_MODELS   comma-separated model names to test, or "all" (default: nex-n2.5-pro) Runs the
# checks *inside* the pod (via oc exec) since these are cluster-internal
# hostnames not reachable from your laptop without port-forwarding.
set -euo pipefail

NAMESPACE="${NAMESPACE:-$(oc project -q)}"

POD=$(oc get pods -n "$NAMESPACE" -l app=litellm -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || { echo "No litellm pod found in $NAMESPACE"; exit 1; }
echo "Using pod: $POD"

VERIFY_MODELS="${VERIFY_MODELS:-nex-n2.5-pro}"
MASTER_KEY=$(oc get secret litellm-secrets -n "$NAMESPACE" -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)

oc exec -n "$NAMESPACE" "$POD" -- python3 -c "
import urllib.request, urllib.error, json, sys

key = '$MASTER_KEY'
wanted = '$VERIFY_MODELS'
base = 'http://localhost:4000'
headers = {'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'}

req = urllib.request.Request(base + '/v1/models', headers=headers)
models = [m['id'] for m in json.loads(urllib.request.urlopen(req, timeout=10).read())['data']]
print('Configured models:', models)

if wanted != 'all':
    missing = [m for m in wanted.split(',') if m not in models]
    if missing:
        print('Not configured in litellm:', missing)
        sys.exit(1)
    models = wanted.split(',')

failed = []
for m in models:
    body = json.dumps({'model': m, 'messages': [{'role': 'user', 'content': 'Say OK.'}], 'max_tokens': 5}).encode()
    req = urllib.request.Request(base + '/v1/chat/completions', data=body, headers=headers)
    try:
        code = urllib.request.urlopen(req, timeout=30).getcode()
        print(f'  {m}: {code} OK')
    except urllib.error.HTTPError as e:
        # Free OpenRouter models are often rate-limited upstream; the proxy
        # relayed the 429 fine, so don't fail the whole check for it.
        if e.code == 429:
            print(f'  {m}: 429 rate-limited upstream (skipped)')
        else:
            print(f'  {m}: FAILED ({e})')
            failed.append(m)
    except Exception as e:
        print(f'  {m}: FAILED ({e})')
        failed.append(m)


# MCP gateway: initialize + tools/list against the registered openshift server.
mcp_headers = {'x-litellm-api-key': 'Bearer ' + key, 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'}
def rpc(method, params, id):
    body = json.dumps({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}).encode()
    req = urllib.request.Request(base + '/openshift/mcp', data=body, headers=mcp_headers)
    return urllib.request.urlopen(req, timeout=30).read().decode()

try:
    rpc('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'verify', 'version': '0'}}, 1)
    out = rpc('tools/list', {}, 2)
    print('  mcp/openshift: OK' if 'pods_list' in out else '  mcp/openshift: FAILED (no pods_list tool)')
    if 'pods_list' not in out:
        failed.append('mcp/openshift')
except Exception as e:
    print(f'  mcp/openshift: FAILED ({e})')
    failed.append('mcp/openshift')

sys.exit(1 if failed else 0)
"
