#!/usr/bin/env bash
# Builds (if needed) and runs the portable opencode container image
# (opencode/Dockerfile) against any local directory — no opencode install
# needed on the host, just Docker or Podman.
#
# The image is rebuilt automatically whenever opencode/Dockerfile or
# opencode/entrypoint.sh change (a hash of both is stored on the image as a
# label and compared on every run). Since opencode's installer always
# fetches its *latest* release at build time, an unchanged Dockerfile still
# means a stale opencode binary over time — pass --rebuild to force a fresh
# build and pick up updates.
#
# Requires ~/.config/opencode/opencode.json to already exist (see
# ./print-opencode-config.sh) — this script reuses it as-is rather than
# regenerating opencode config itself.
#
# Usage:
#   ./run-opencode-container.sh [DIRECTORY] [-- command...]
#   ./run-opencode-container.sh                    # opencode against $PWD
#   ./run-opencode-container.sh ~/some-repo         # opencode against that dir
#   ./run-opencode-container.sh ~/some-repo bash    # plain shell instead of opencode
#   ./run-opencode-container.sh --rebuild ~/some-repo
#
# Env vars:
#   CONTAINER_ENGINE     override engine (default: docker if present, else podman)
#   OPENCODE_IMAGE        override image tag (default: ocp-devops-agent/opencode:local)
#   LITELLM_URL           litellm base URL (https://<route-host>) substituted for
#                         http://localhost:4000 if the host config still uses the
#                         port-forward address (default: looked up from the Route via oc)
#   NAMESPACE             oc project to look up litellm-secrets in, if LITELLM_MASTER_KEY
#                         isn't already exported (default: current `oc project`)
set -euo pipefail
cd "$(dirname "$0")/.."

REBUILD=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=true ;;
    *) ARGS+=("$arg") ;;
  esac
done

ENGINE="${CONTAINER_ENGINE:-}"
if [ -z "$ENGINE" ]; then
  if command -v docker >/dev/null 2>&1; then
    ENGINE=docker
  elif command -v podman >/dev/null 2>&1; then
    ENGINE=podman
  else
    echo "Neither docker nor podman found on PATH." >&2
    exit 1
  fi
fi

IMAGE="${OPENCODE_IMAGE:-ocp-devops-agent/opencode:local}"
LABEL_KEY="com.ocp-devops-agent.build-hash"

HASH=$(cat opencode/Dockerfile opencode/entrypoint.sh | sha256sum | cut -d' ' -f1)

EXISTING_HASH=""
if "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
  EXISTING_HASH=$("$ENGINE" image inspect "$IMAGE" --format "{{ index .Config.Labels \"$LABEL_KEY\" }}" 2>/dev/null || echo "")
fi

if [ "$REBUILD" = true ] || [ "$EXISTING_HASH" != "$HASH" ]; then
  echo "Building $IMAGE (opencode/Dockerfile or entrypoint.sh changed, image missing, or --rebuild passed)..."
  "$ENGINE" build --label "${LABEL_KEY}=${HASH}" -t "$IMAGE" opencode
else
  echo "$IMAGE is already up to date, skipping build."
fi

# First positional arg is the target directory if it's an existing
# directory; otherwise default to $PWD and treat all args as the container
# command override.
TARGET_DIR="$PWD"
CMD=("${ARGS[@]}")
if [ "${#ARGS[@]}" -gt 0 ] && [ -d "${ARGS[0]}" ]; then
  TARGET_DIR=$(cd "${ARGS[0]}" && pwd)
  CMD=("${ARGS[@]:1}")
fi

OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
if [ ! -f "$OPENCODE_CONFIG" ]; then
  echo "No opencode config at $OPENCODE_CONFIG — run ./print-opencode-config.sh first." >&2
  exit 1
fi

if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
  NAMESPACE="${NAMESPACE:-$(oc project -q 2>/dev/null || true)}"
  if [ -n "$NAMESPACE" ] && oc get secret litellm-secrets -n "$NAMESPACE" >/dev/null 2>&1; then
    LITELLM_MASTER_KEY=$(oc get secret litellm-secrets -n "$NAMESPACE" -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
  else
    echo "Warning: LITELLM_MASTER_KEY not set and couldn't fetch it via oc — opencode will fail to authenticate until you export it." >&2
    LITELLM_MASTER_KEY=""
  fi
fi

# Inside the container `localhost` is the container itself, so a config still
# pointing at the port-forward template (http://localhost:4000) can never work
# there. Rewrite it to litellm's public Route for this run only — the host
# file is left untouched.
if grep -q 'http://localhost:4000' "$OPENCODE_CONFIG"; then
  if [ -z "${LITELLM_URL:-}" ]; then
    NAMESPACE="${NAMESPACE:-$(oc project -q 2>/dev/null || true)}"
    HOST=$(oc get route litellm -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    [ -n "$HOST" ] && LITELLM_URL="https://${HOST}"
  fi
  if [ -z "${LITELLM_URL:-}" ]; then
    echo "Config points at http://localhost:4000, which the container can't reach, and the litellm Route couldn't be found via oc. Set LITELLM_URL=https://<route-host> or run ./print-opencode-config.sh." >&2
    exit 1
  fi
  echo "Using litellm Route ${LITELLM_URL} (config points at localhost:4000)."
  TMP_CONFIG=$(mktemp)
  trap 'rm -f "$TMP_CONFIG"' EXIT
  sed "s#http://localhost:4000#${LITELLM_URL}#g" "$OPENCODE_CONFIG" > "$TMP_CONFIG"
  OPENCODE_CONFIG="$TMP_CONFIG"
fi

# No `exec` here: it would replace the shell and skip the EXIT trap above.
"$ENGINE" run --rm -it \
  -e LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" \
  -v "$TARGET_DIR:/workspace" \
  -v "$OPENCODE_CONFIG:/root/.config/opencode/opencode.json:ro" \
  -w /workspace \
  "$IMAGE" "${CMD[@]}"
