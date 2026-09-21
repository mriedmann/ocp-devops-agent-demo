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
# The container uses opencode/config.snippet.json, which takes litellm's URL
# from the LITELLM_URL env var. This script looks up the Route (or uses
# $LITELLM_URL if you set it) and passes it in, so your host's own opencode
# config is neither needed nor touched.
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
#   LITELLM_URL          litellm base URL, https://<route-host> (default: looked up from
#                        the "litellm" Route via oc)
#   OPENCODE_CONFIG      config file to mount instead of opencode/config.snippet.json
#   NAMESPACE             oc project to look up litellm-secrets in, if LITELLM_MASTER_KEY
#                         isn't already exported (default: current `oc project`)
set -euo pipefail
cd "$(dirname "$0")/.."
PWD_ROOT="$PWD"

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

# The container runs the repo's own config, which reads the litellm URL and key
# from env vars ({env:LITELLM_URL}, {env:LITELLM_MASTER_KEY}) — nothing
# host-specific is baked in. Override with OPENCODE_CONFIG=/path/to/file.
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$PWD_ROOT/opencode/config.snippet.json}"
[ -f "$OPENCODE_CONFIG" ] || { echo "No opencode config at $OPENCODE_CONFIG" >&2; exit 1; }

# litellm's public Route, passed to the container as LITELLM_URL. `localhost`
# inside a container is the container itself, so a port-forward can't work here.
if [ -z "${LITELLM_URL:-}" ]; then
  NAMESPACE="${NAMESPACE:-$(oc project -q 2>/dev/null || true)}"
  HOST=$(oc get route litellm -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [ -n "$HOST" ] && LITELLM_URL="https://${HOST}"
fi
if [ -z "${LITELLM_URL:-}" ]; then
  echo "Couldn't determine litellm's Route. Set LITELLM_URL=https://<route-host> or log in with oc (project containing the 'litellm' Route)." >&2
  exit 1
fi
echo "Using litellm at ${LITELLM_URL}"

if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
  NAMESPACE="${NAMESPACE:-$(oc project -q 2>/dev/null || true)}"
  if [ -n "$NAMESPACE" ] && oc get secret litellm-secrets -n "$NAMESPACE" >/dev/null 2>&1; then
    LITELLM_MASTER_KEY=$(oc get secret litellm-secrets -n "$NAMESPACE" -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
  else
    echo "Warning: LITELLM_MASTER_KEY not set and couldn't fetch it via oc — opencode will fail to authenticate until you export it." >&2
    LITELLM_MASTER_KEY=""
  fi
fi

exec "$ENGINE" run --rm -it \
  -e LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" \
  -e LITELLM_URL="$LITELLM_URL" \
  -v "$TARGET_DIR:/workspace" \
  -v "$OPENCODE_CONFIG:/root/.config/opencode/opencode.json:ro" \
  -w /workspace \
  "$IMAGE" "${CMD[@]}"
