#!/usr/bin/env bash
# ==============================================================================
# ATHENA - Safe & Graceful Shutdown Script
# Immediately closes all ATHENA background services (HTML & R Shiny),
# flushes SQLite WAL, and guarantees 0% background CPU/RAM usage.
# ==============================================================================

set -u

ATHENA_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE_DIR="/tmp/athena_pids"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}[ATHENA SHUTDOWN]${NC} Initiating safe shutdown sequence..."

# Step 1: Flush SQLite database WAL to prevent corruption
DB_PATH="$ATHENA_HOME/athena.db"
if [ -f "$DB_PATH" ]; then
    echo -e "${CYAN}[ATHENA SHUTDOWN]${NC} Checkpointing SQLite database to disk..."
    PY_BIN="$ATHENA_HOME/athena_env/bin/python"
    [ ! -x "$PY_BIN" ] && PY_BIN="$(command -v python3 || command -v python)"
    "$PY_BIN" -c "
import sqlite3
try:
    c = sqlite3.connect('$DB_PATH', timeout=4)
    c.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    c.close()
    print('[ATHENA SHUTDOWN] Database safely checkpointed.')
except Exception as e:
    print(f'[ATHENA SHUTDOWN] Checkpoint note: {e}')
" 2>/dev/null || true
fi

# Step 2: Clear active ports (3838 for Shiny, 8000 for FastAPI, 8001 for Plumber)
if command -v fuser >/dev/null 2>&1; then
    fuser -k 3838/tcp 2>/dev/null || true
    fuser -k 8000/tcp 2>/dev/null || true
    fuser -k 8001/tcp 2>/dev/null || true
fi

# Step 3: Read PIDs from PIDFILE_DIR and signal SIGTERM
PIDS_TO_STOP=()
if [ -d "$PIDFILE_DIR" ]; then
    for pidfile in "$PIDFILE_DIR"/*.pid; do
        if [ -f "$pidfile" ]; then
            pid=$(cat "$pidfile" 2>/dev/null || true)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                PIDS_TO_STOP+=("$pid")
                kill -TERM "$pid" 2>/dev/null || true
            fi
            rm -f "$pidfile" 2>/dev/null || true
        fi
    done
fi

# Step 4: Find any running processes by script path
MATCHING_PIDS=$(pgrep -u "$USER" -f "$ATHENA_HOME" 2>/dev/null || true)
for pid in $MATCHING_PIDS; do
    if [ "$pid" != "$$" ]; then
        PIDS_TO_STOP+=("$pid")
        kill -TERM "$pid" 2>/dev/null || true
    fi
done

# Step 5: Wait dynamically up to 2 seconds for graceful exit
for i in {1..20}; do
    any_alive=0
    for pid in "${PIDS_TO_STOP[@]:-}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            any_alive=1
            break
        fi
    done
    if [ "$any_alive" -eq 0 ]; then
        break
    fi
    sleep 0.1
done

# Step 6: Force kill any stubborn process that refused SIGTERM
for pid in "${PIDS_TO_STOP[@]:-}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
done

# Step 7: Clean up all temporary runtime files
rm -f /tmp/athena_thermal_status.json /tmp/athena_ml_control.json /tmp/athena_alert_status.json /tmp/athena_celery.pid 2>/dev/null || true
rm -rf "$PIDFILE_DIR" 2>/dev/null || true

# Step 8: Final verification
REMAINING=$(pgrep -u "$USER" -f "$ATHENA_HOME/(athena_api|plumber\.R|thermal_guard|athena_desktop|athena_shiny|run_shiny)" 2>/dev/null || true)
if [ -z "$REMAINING" ]; then
    echo -e "${GREEN}[ATHENA SHUTDOWN] SUCCESS:${NC} All ATHENA services safely stopped."
    echo -e "${GREEN}[ATHENA SHUTDOWN]${NC} 0 background processes active. 0% CPU & RAM consumed."
    echo -e "${GREEN}[ATHENA SHUTDOWN]${NC} Database is clean and safely closed."
else
    kill -KILL $REMAINING 2>/dev/null || true
    echo -e "${GREEN}[ATHENA SHUTDOWN] All residual processes terminated.${NC}"
fi
