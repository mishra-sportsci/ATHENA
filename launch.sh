#!/usr/bin/env bash
# ==============================================================================
# ATHENA - Clinical Telemetry & Evidence-Based Nutrition Intelligence
# Native Desktop GUI Launcher (Debian 13 KDE Plasma)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Clean up any lingering or stale processes on port 8000
if command -v fuser >/dev/null 2>&1; then
    if fuser "8000/tcp" >/dev/null 2>&1; then
        if curl -s -f -m 1 "http://127.0.0.1:8000/api/health" >/dev/null 2>&1; then
            echo "[ATHENA] Instance already active. Opening browser..."
            xdg-open "http://127.0.0.1:8000" &
            exit 0
        else
            echo "[ATHENA] Clearing stale process on port 8000..."
            fuser -k "8000/tcp" 2>/dev/null || true
            sleep 0.5
        fi
    fi
fi

PY_BIN="$SCRIPT_DIR/athena_env/bin/python"
[ ! -x "$PY_BIN" ] && PY_BIN="$(command -v python3 || command -v python)"
exec "$PY_BIN" "$SCRIPT_DIR/athena_desktop.py"
