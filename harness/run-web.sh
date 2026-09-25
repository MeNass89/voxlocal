#!/usr/bin/env bash
# Launch the dsh web UI on the VoxLocal "scribe" profile (macOS / Linux dev).
# Usage: VOXLOCAL_LLM_URL=https://<pod>:8443/llm/v1 VOXLOCAL_LLM_TOKEN=... harness/run-web.sh [dsh web flags]
# Extra arguments reach the web app (for example --port 3081).
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$HARNESS_DIR/profile"
export DSH_HOME="$HARNESS_DIR/.dsh-home"
# Keep the operator's personal ~/.agents skills and instructions out of the
# clinical agent: dsh scans $DSH_AGENTS_HOME (default ~/.agents) for skills.
export DSH_AGENTS_HOME="$DSH_HOME/agents"

: "${VOXLOCAL_LLM_URL:?set VOXLOCAL_LLM_URL to the OpenAI-compatible base URL (ending in /v1)}"
: "${VOXLOCAL_LLM_TOKEN:?set VOXLOCAL_LLM_TOKEN to the GPU edge bearer token}"
export VOXLOCAL_LLM_URL VOXLOCAL_LLM_TOKEN

# Install the pinned dsh exactly as locked.
if [ ! -x "$PROFILE_DIR/node_modules/.bin/dsh" ]; then
  (cd "$PROFILE_DIR" && pnpm install --frozen-lockfile)
fi

# dsh looks up profiles under $DSH_HOME/profiles/<name>; point "scribe" at the
# tracked profile directory so the repository stays the single source.
mkdir -p "$DSH_HOME/profiles"
if [ ! -e "$DSH_HOME/profiles/scribe" ]; then
  ln -s "$PROFILE_DIR" "$DSH_HOME/profiles/scribe"
fi

exec "$PROFILE_DIR/node_modules/.bin/dsh" --profile scribe --no-open "$@"
