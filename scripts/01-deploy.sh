#!/usr/bin/env bash
# Deploys litellm into your own sandbox project, wired to the shared
# InferenceServices. Idempotent — safe to re-run after editing a manifest.
#
# Env vars (all optional):
#   NAMESPACE               your own project to deploy into (default: current oc project)
#   SHARED_MODELS_NAMESPACE project holding the shared InferenceServices (default: sandbox-shared-models)
set -euo pipefail
cd "$(dirname "$0")/.."

export NAMESPACE="${NAMESPACE:-$(oc project -q)}"
export SHARED_MODELS_NAMESPACE="${SHARED_MODELS_NAMESPACE:-sandbox-shared-models}"

echo "Deploying into: $NAMESPACE (shared models from: $SHARED_MODELS_NAMESPACE)"

apply() {
  envsubst < "$1" | oc apply -f -
}

# 1. Master key for litellm's own proxy API, plus Postgres credentials for
#    the Admin UI (/ui/login fails with "Not connected to DB!" without
#    DATABASE_URL — see k8s/deployment-postgres.yaml). Auto-generate on
#    first run rather than applying the "REPLACE-ME" placeholders from the
#    example.
if ! oc get secret litellm-secrets -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Creating litellm-secrets with a fresh LITELLM_MASTER_KEY and Postgres credentials..."
  POSTGRES_PASSWORD="$(openssl rand -hex 24)"
  oc create secret generic litellm-secrets \
    -n "$NAMESPACE" \
    --from-literal=LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24)" \
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    --from-literal=DATABASE_URL="postgresql://litellm:${POSTGRES_PASSWORD}@postgres-service:5432/litellm"
elif ! oc get secret litellm-secrets -n "$NAMESPACE" -o jsonpath='{.data.DATABASE_URL}' | grep -q .; then
  echo "litellm-secrets exists but has no DATABASE_URL — adding Postgres credentials for the Admin UI..."
  POSTGRES_PASSWORD="$(openssl rand -hex 24)"
  oc patch secret litellm-secrets -n "$NAMESPACE" --type=merge -p "{\"stringData\":{\"POSTGRES_PASSWORD\":\"${POSTGRES_PASSWORD}\",\"DATABASE_URL\":\"postgresql://litellm:${POSTGRES_PASSWORD}@postgres-service:5432/litellm\"}}"
else
  echo "litellm-secrets already exists, leaving it as-is."
fi

# Hash the secret's actual current content (not a flag) so deployment-litellm's
# checksum/litellm-secrets annotation changes — and Kubernetes rolls the
# Deployment — whenever the content differs from what's currently running,
# regardless of what happened on any previous run of this script.
export LITELLM_SECRETS_HASH="$(oc get secret litellm-secrets -n "$NAMESPACE" -o jsonpath='{.data}' | sha256sum | cut -d' ' -f1)"

# 2. Postgres for the Admin UI — must be up before litellm starts, since
#    litellm runs its DB migration at startup.
apply k8s/pvc-postgres.yaml
apply k8s/service-postgres.yaml
apply k8s/deployment-postgres.yaml
echo "Waiting for postgres rollout..."
oc rollout status deployment/postgres-deployment -n "$NAMESPACE" --timeout=180s

# 3. ServiceAccount + RoleBinding for the token-refresh CronJob.
apply k8s/serviceaccount-litellm-restarter.yaml
apply k8s/rolebinding-litellm-restarter.yaml || {
  echo
  echo "WARNING: could not create the RoleBinding (likely insufficient RBAC-grant"
  echo "permissions on this account). The rest of the setup still works, but"
  echo "litellm-token-refresh CronJob will fail with 403 until this is applied:"
  echo "  oc apply -f k8s/rolebinding-litellm-restarter.yaml"
  echo
}

# 4. App config + workload + public Route (the default way to reach litellm
#    without cluster/oc access — see k8s/route-litellm.yaml for how to opt out).
apply k8s/configmap-litellm-config.yaml
apply k8s/deployment-litellm.yaml
apply k8s/service-litellm.yaml
apply k8s/cronjob-litellm-token-refresh.yaml
apply k8s/route-litellm.yaml

echo "Waiting for rollout..."
oc rollout status deployment/litellm-deployment -n "$NAMESPACE" --timeout=180s

ROUTE_HOST=$(oc get route litellm -n "$NAMESPACE" -o jsonpath='{.spec.host}')

echo
echo "Done. litellm is reachable at: https://${ROUTE_HOST}"
echo "Next: ./02-verify.sh, then ./print-opencode-config.sh for a ready-to-merge opencode config."
