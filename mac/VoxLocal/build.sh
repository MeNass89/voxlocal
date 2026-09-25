#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
APP_DIR="${VOXLOCAL_APP_DIR:-$PROJECT_DIR/dist/VoxLocal.app}"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# The agent API is intentionally packaged as source, not as a guessed Python
# runtime.  The source export is buildable when the repository's agent/ folder
# is present; callers extracting the export elsewhere can set this explicitly.
AGENT_SOURCE_DIR="${VOXLOCAL_AGENT_SOURCE_DIR:-$PROJECT_DIR/../../agent}"
AGENT_DOC_SOURCE_DIR="${VOXLOCAL_AGENT_DOC_SOURCE_DIR:-$PROJECT_DIR/../../docs}"
SWIFT_BUILD_PATH="${VOXLOCAL_SWIFT_BUILD_PATH:-$PROJECT_DIR/.build}"
[[ -f "$AGENT_SOURCE_DIR/voxlocal_agent_api.py" ]] || {
    print -u2 "Runtime agent manquant: $AGENT_SOURCE_DIR (définir VOXLOCAL_AGENT_SOURCE_DIR)"; exit 4
}
[[ -f "$AGENT_DOC_SOURCE_DIR/agent-api.md" ]] || {
    print -u2 "Documentation agent manquante: $AGENT_DOC_SOURCE_DIR/agent-api.md"; exit 4
}

RUNTIMES=(whisper-cli llama-cli llama-server)
for runtime in "${RUNTIMES[@]}"; do
    [[ -x "$PROJECT_DIR/Vendor/bin/$runtime" ]] || { print -u2 "Runtime manquant: Vendor/bin/$runtime (lancer ./build-runtimes.sh)"; exit 3; }
done

/bin/rm -rf -- "$APP_DIR"
/bin/mkdir -p "$MACOS" "$RESOURCES/Runtimes" "$RESOURCES/Agent/bin" "$RESOURCES/Agent/docs"
cd "$PROJECT_DIR"
/usr/bin/xcrun swift build -c release --product VoxLocal --scratch-path "$SWIFT_BUILD_PATH"
/bin/cp "$SWIFT_BUILD_PATH/release/VoxLocal" "$MACOS/VoxLocal"
/bin/cp "$PROJECT_DIR/App/Info.plist" "$CONTENTS/Info.plist"
/bin/cp "$PROJECT_DIR/assets/VoxLocal.icns" "$RESOURCES/VoxLocal.icns"
# llama-server keeps the selected LLM warm between dictations; llama-cli stays
# as the fallback when the server cannot start.
for runtime in "${RUNTIMES[@]}"; do
    /bin/cp "$PROJECT_DIR/Vendor/bin/$runtime" "$RESOURCES/Runtimes/$runtime"
done

# Keep the API contract beside the app so support can inspect exactly what a
# shipped DMG contains.  No Python interpreter or provider secret is copied.
/bin/mkdir -p "$RESOURCES/Agent/agent"
for source in __init__.py voxlocal_agent_api.py test_agent_api.py; do
    /bin/cp "$AGENT_SOURCE_DIR/$source" "$RESOURCES/Agent/agent/$source"
done
/bin/cp "$AGENT_DOC_SOURCE_DIR/agent-api.md" "$RESOURCES/Agent/docs/agent-api.md"
if [[ -f "$AGENT_DOC_SOURCE_DIR/agent-runtime-plan.md" ]]; then
    /bin/cp "$AGENT_DOC_SOURCE_DIR/agent-runtime-plan.md" "$RESOURCES/Agent/docs/agent-runtime-plan.md"
fi
if [[ -f "$AGENT_SOURCE_DIR/../pyproject.toml" ]]; then
    /bin/cp "$AGENT_SOURCE_DIR/../pyproject.toml" "$RESOURCES/Agent/pyproject.toml"
fi
if [[ -f "$AGENT_SOURCE_DIR/../setup.py" ]]; then
    /bin/cp "$AGENT_SOURCE_DIR/../setup.py" "$RESOURCES/Agent/setup.py"
fi
/bin/cat > "$RESOURCES/Agent/README.md" <<'EOF'
# VoxLocal agent runtime

This bundle contains the reviewed `agent/` source and API documentation. It
does not contain Python. Use the adjacent `bin/voxlocal-agent` launcher on a
machine with Python 3.11 or newer; it fails closed when that prerequisite is
not installed. Configure `VOXLOCAL_AGENT_TOKEN` through the service environment
and keep provider credentials out of command-line arguments and this bundle.
EOF
/bin/cat > "$RESOURCES/Agent/bin/voxlocal-agent" <<'EOF'
#!/bin/zsh
set -euo pipefail
AGENT_ROOT=${0:A:h:h}
if [[ -n "${VOXLOCAL_PYTHON:-}" ]]; then
    PYTHON="$VOXLOCAL_PYTHON"
else
    PYTHON="$(command -v python3 || true)"
fi
[[ -n "$PYTHON" && -x "$PYTHON" ]] || { print -u2 "Python 3.11+ requis (définir VOXLOCAL_PYTHON)."; exit 12; }
"$PYTHON" - "$AGENT_ROOT" <<'PY'
import sys
if sys.version_info < (3, 11):
    raise SystemExit("Python 3.11+ requis pour voxlocal-agent.")
PY
exec "$PYTHON" "$AGENT_ROOT/agent/voxlocal_agent_api.py" "$@"
EOF
/bin/chmod 0755 "$RESOURCES/Agent/bin/voxlocal-agent"
# iCloud can attach Finder/resource-fork metadata while source is hydrated;
# ad-hoc signing rejects those extended attributes.
/usr/bin/xattr -cr "$APP_DIR" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
print "Built native app: $APP_DIR"
