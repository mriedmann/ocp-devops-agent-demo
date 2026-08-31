#!/usr/bin/env bash
# Exposes litellm on localhost so a local opencode can reach it.
# Keep this running in its own terminal while you use opencode; it forwards
# on the Service, not the pod, so it survives litellm-token-refresh
# restarting the pod underneath it.
#
# Usage: ./03-port-forward.sh [local-port]
set -euo pipefail

NAMESPACE="${NAMESPACE:-$(oc project -q)}"
LOCAL_PORT="${1:-4000}"

echo "Forwarding localhost:${LOCAL_PORT} -> service/litellm-service:4000 in ${NAMESPACE}"
echo "Leave this running. Ctrl+C to stop."
exec oc port-forward -n "$NAMESPACE" service/litellm-service "${LOCAL_PORT}:4000"
