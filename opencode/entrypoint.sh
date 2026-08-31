#!/usr/bin/env bash
# Container entrypoint: boots straight into opencode by default, or runs
# whatever command was passed instead (e.g. `bash` for a plain shell with
# opencode on PATH).
set -euo pipefail

if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
  echo "Warning: LITELLM_MASTER_KEY is not set — opencode's litellm provider will fail to authenticate." >&2
fi

if [ "$#" -eq 0 ]; then
  exec opencode
fi
exec "$@"
