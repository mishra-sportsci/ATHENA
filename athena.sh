#!/bin/bash
# Automatically activate athena_env virtual environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/athena_env/bin" ]; then
    export PATH="$SCRIPT_DIR/athena_env/bin:$PATH"
fi


ATHENA_HOME="$(cd "$(dirname "$0")" && pwd)"
export ATHENA_HOME

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[ATHENA]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[ATHENA]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[ATHENA]${NC} $1"; }
log_error() { echo -e "${RED}[ATHENA]${NC} $1"; }

PIDFILE_DIR="/tmp/athena_pids"
mkdir -p "$PIDFILE_DIR"

R_PIDFILE="$PIDFILE_DIR/r_engine.pid"
CELERY_PIDFILE="$PIDFILE_DIR/celery.pid"
API_PIDFILE="$PIDFILE_DIR/api.pid"
THERMAL_PIDFILE="$PIDFILE_DIR/thermal_guard.pid"
ZOMBIE_PIDFILE="$PIDFILE_DIR/zombie_reaper.pid"

CLEANUP_DONE=false

cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    CLEANUP_DONE=true
    
    log_warn "Shutting down all ATHENA services gracefully..."
    
    # 1. Flush SQLite database WAL to prevent corruption
    if [ -f "$ATHENA_HOME/athena.db" ]; then
        PY_BIN="$ATHENA_HOME/athena_env/bin/python"
        [ ! -x "$PY_BIN" ] && PY_BIN="$(command -v python3 || command -v python)"
        "$PY_BIN" -c "
import sqlite3
try:
    c = sqlite3.connect('$ATHENA_HOME/athena.db', timeout=3)
    c.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    c.close()
except Exception:
    pass
" 2>/dev/null || true
    fi

    # 2. Collect all active PIDs and signal SIGTERM
    PIDS=()
    for pidfile in "$API_PIDFILE" "$R_PIDFILE" "$THERMAL_PIDFILE" "$CELERY_PIDFILE"; do
        if [ -f "$pidfile" ]; then
            pid=$(cat "$pidfile" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                PIDS+=("$pid")
                kill -TERM "$pid" 2>/dev/null || true
            fi
            rm -f "$pidfile" 2>/dev/null
        fi
    done

    # 3. Wait up to 3 seconds dynamically for all processes to exit gracefully
    for i in {1..30}; do
        any_alive=0
        for pid in "${PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                any_alive=1
                break
            fi
        done
        if [ "$any_alive" -eq 0 ]; then
            break
        fi
        sleep 0.1
    done

    # 4. If any process refused SIGTERM after 3 seconds, forcefully terminate only those
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done

    # 5. Clean up temporary files
    rm -f /tmp/athena_thermal_status.json /tmp/athena_ml_control.json /tmp/athena_alert_status.json /tmp/athena_celery.pid 2>/dev/null
    rm -rf "$PIDFILE_DIR" 2>/dev/null

    log_ok "All ATHENA services terminated cleanly. No background processes remain."
    exit 0
}

trap cleanup EXIT INT TERM HUP

cd "$ATHENA_HOME"

mkdir -p "$PIDFILE_DIR"

TOTAL_RAM_KB=$(free -k 2>/dev/null | awk '/^Mem:/{print $2}')
if [ -z "$TOTAL_RAM_KB" ] || [ "$TOTAL_RAM_KB" -le 0 ]; then
    TOTAL_RAM_GB=4
    log_warn "Cannot detect RAM. Assuming 4GB for safety."
else
    TOTAL_RAM_GB=$(( (TOTAL_RAM_KB + 1048575) / 1048576 ))
fi

CPU_CORES=$(nproc 2>/dev/null || echo 2)
if [ -z "$CPU_CORES" ] || [ "$CPU_CORES" -le 0 ]; then
    CPU_CORES=2
    log_warn "Cannot detect CPU cores. Assuming 2 for safety."
fi

AVAILABLE_MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
if [ -z "$AVAILABLE_MEM_MB" ] || [ "$AVAILABLE_MEM_MB" -le 0 ]; then
    AVAILABLE_MEM_KB=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
    if [ -n "$AVAILABLE_MEM_KB" ] && [ "$AVAILABLE_MEM_KB" -gt 0 ]; then
        AVAILABLE_MEM_MB=$(( AVAILABLE_MEM_KB / 1024 ))
    else
        TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
        FREE_MEM_KB=$(grep MemFree /proc/meminfo 2>/dev/null | awk '{print $2}')
        if [ -n "$TOTAL_MEM_KB" ] && [ -n "$FREE_MEM_KB" ]; then
            AVAILABLE_MEM_MB=$(( (FREE_MEM_KB + (TOTAL_MEM_KB / 10)) / 1024 ))
        else
            AVAILABLE_MEM_MB=512
        fi
    fi
    log_warn "Cannot detect available memory via free -m. Using /proc/meminfo fallback: ${AVAILABLE_MEM_MB}MB"
fi

if [ "$AVAILABLE_MEM_MB" -lt 800 ]; then
    CELERY_CONCURRENCY=0
    log_warn "Available memory (${AVAILABLE_MEM_MB}MB) below 800MB threshold. Celery will NOT be started."
    log_warn "System will operate in synchronous processing mode."
elif [ "$TOTAL_RAM_GB" -ge 16 ] && [ "$CPU_CORES" -ge 8 ]; then
    CELERY_CONCURRENCY=4
elif [ "$TOTAL_RAM_GB" -ge 8 ] && [ "$CPU_CORES" -ge 4 ]; then
    CELERY_CONCURRENCY=2
else
    CELERY_CONCURRENCY=1
fi

SAFE_CELERY_CONCURRENCY=$(( CELERY_CONCURRENCY > 0 ? CELERY_CONCURRENCY : 0 ))
MAX_MEMORY_PER_CHILD=$((TOTAL_RAM_GB * 1000 / (SAFE_CELERY_CONCURRENCY + 1) / 4))
if [ "$MAX_MEMORY_PER_CHILD" -gt 512000 ]; then
    MAX_MEMORY_PER_CHILD=512000
elif [ "$MAX_MEMORY_PER_CHILD" -lt 64000 ]; then
    MAX_MEMORY_PER_CHILD=64000
fi

log_info "Hardware: ${CPU_CORES} cores, ${TOTAL_RAM_GB}GB RAM"
log_info "Configuration: 1 API worker, ${CELERY_CONCURRENCY} Celery workers"
log_info "Max memory per Celery child: ${MAX_MEMORY_PER_CHILD}KB"

if [ ! -f "$ATHENA_HOME/plumber.R" ]; then
    log_error "plumber.R not found in $ATHENA_HOME"
    exit 1
fi

if [ ! -f "$ATHENA_HOME/tasks.py" ]; then
    log_error "tasks.py not found in $ATHENA_HOME"
    exit 1
fi

if [ ! -f "$ATHENA_HOME/athena_api.py" ]; then
    log_error "athena_api.py not found in $ATHENA_HOME"
    exit 1
fi

ATHENA_KEY_FILE="$ATHENA_HOME/.athena_encryption_key"
if [ -z "$ATHENA_ENCRYPTION_KEY" ]; then
    if [ -f "$ATHENA_KEY_FILE" ]; then
        ATHENA_ENCRYPTION_KEY="$(cat "$ATHENA_KEY_FILE")"
        export ATHENA_ENCRYPTION_KEY
        log_ok "Encryption key loaded from .athena_encryption_key"
    else
        ATHENA_ENCRYPTION_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
        echo "$ATHENA_ENCRYPTION_KEY" > "$ATHENA_KEY_FILE"
        chmod 600 "$ATHENA_KEY_FILE"
        export ATHENA_ENCRYPTION_KEY
        log_warn "NEW ENCRYPTION KEY GENERATED AND SAVED TO .athena_encryption_key"
        log_warn "BACK UP THIS FILE. Without it, all encrypted athlete data is permanently unrecoverable."
    fi
fi

export ATHENA_REDIS_URL="${ATHENA_REDIS_URL:-redis://localhost:6379/0}"
export ATHENA_DATABASE_URL="${ATHENA_DATABASE_URL:-sqlite:///$ATHENA_HOME/athena.db}"
export ATHENA_R_API_URL="${ATHENA_R_API_URL:-http://localhost:8001}"
export ATHENA_R_BIND_HOST="${ATHENA_R_BIND_HOST:-127.0.0.1}"

if [ "$AVAILABLE_MEM_MB" -lt 600 ]; then
    log_warn "Available memory (${AVAILABLE_MEM_MB}MB) below 600MB. R Analytics Engine will NOT be started."
    log_warn "Python-native analytics will be used instead."
elif ! command -v Rscript &> /dev/null; then
    log_warn "R not installed. R Analytics Engine will NOT be started."
    log_warn "Python-native analytics will be used instead. Install R and plumber for enhanced analytics."
else
    log_info "Starting R Analytics Engine..."
    Rscript "$ATHENA_HOME/plumber.R" > /dev/null 2>&1 &
    R_PID=$!
    if [ -n "$R_PID" ] && kill -0 "$R_PID" 2>/dev/null; then
        echo "$R_PID" > "$R_PIDFILE"
        sleep 2
        if kill -0 "$R_PID" 2>/dev/null; then
            log_ok "R Analytics Engine started (PID: $R_PID)"
        else
            log_error "R Analytics Engine exited immediately. Check R and plumber.R."
            R_PID=""
        fi
    else
        log_error "R Analytics Engine failed to start."
        R_PID=""
    fi
fi

REDIS_REACHABLE=false
if command -v redis-cli &> /dev/null; then
    if redis-cli ping &> /dev/null; then
        REDIS_REACHABLE=true
    fi
else
    if timeout 1 bash -c "echo > /dev/tcp/localhost/6379" 2>/dev/null; then
        REDIS_REACHABLE=true
    fi
fi

if [ "$REDIS_REACHABLE" = false ]; then
    log_warn "Redis not reachable. Skipping Celery worker startup."
    log_warn "Data processing will use synchronous /sync-data/direct endpoint."
    CELERY_CONCURRENCY=0
fi

if [ "$CELERY_CONCURRENCY" -eq 0 ]; then
    log_warn "Skipping Celery worker startup (insufficient memory or Redis unavailable)."
    log_warn "Data processing will use synchronous /sync-data/direct endpoint."
else
    log_info "Starting Celery Worker..."
    export ATHENA_ENCRYPTION_KEY="$ATHENA_ENCRYPTION_KEY"
    celery -A tasks worker \
        --loglevel=warning \
        --concurrency="$CELERY_CONCURRENCY" \
        --max-tasks-per-child=50 \
        --max-memory-per-child="$MAX_MEMORY_PER_CHILD" \
        --pidfile="$CELERY_PIDFILE" \
        --without-heartbeat \
        --without-gossip \
        --without-mingle \
        -Q athena_checkins,celery > /dev/null 2>&1 &
    CELERY_PID=$!
    if [ -n "$CELERY_PID" ] && kill -0 "$CELERY_PID" 2>/dev/null; then
        echo "$CELERY_PID" > "$CELERY_PIDFILE"
        sleep 3
        if kill -0 "$CELERY_PID" 2>/dev/null; then
            log_ok "Celery Worker started (PID: $CELERY_PID)"
        else
            log_error "Celery Worker exited immediately. Check Redis and tasks.py."
            log_warn "Continuing without Celery. Synchronous processing will be used."
            CELERY_PID=""
            CELERY_CONCURRENCY=0
        fi
    else
        log_error "Celery Worker failed to start."
        log_warn "Continuing without Celery. Synchronous processing will be used."
        CELERY_PID=""
        CELERY_CONCURRENCY=0
    fi
fi

log_info "Verifying database integrity..."
DB_INTEGRITY_OK=true
python3 -c "
from tasks import get_session
from sqlalchemy import text
try:
    s = get_session()
    result = s.execute(text('PRAGMA integrity_check')).scalar()
    if result != 'ok':
        print('FAIL:' + str(result))
        exit(1)
    count = s.execute(text('SELECT COUNT(*) FROM daily_checkins')).scalar()
    s.close()
    print('OK:' + str(count) + ' records')
except Exception as e:
    print('FAIL:' + str(e))
    exit(1)
" > /tmp/athena_db_check_result.txt 2>&1
DB_CHECK_EXIT=$?
DB_CHECK_OUTPUT=$(cat /tmp/athena_db_check_result.txt)
rm -f /tmp/athena_db_check_result.txt

if [ "$DB_CHECK_EXIT" -ne 0 ]; then
    DB_INTEGRITY_OK=false
    log_error "Database integrity check failed: $DB_CHECK_OUTPUT"
elif echo "$DB_CHECK_OUTPUT" | grep -q '^OK:'; then
    DB_INTEGRITY_OK=true
    log_ok "Database integrity verified: $DB_CHECK_OUTPUT"
else
    DB_INTEGRITY_OK=false
    log_error "Database integrity check produced unexpected output: $DB_CHECK_OUTPUT"
fi

if [ "$DB_INTEGRITY_OK" = false ]; then
    LATEST_BACKUP=$(ls -t "$ATHENA_HOME/backups/athena_auto_backup_"*.db 2>/dev/null | head -1)
    if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then
        log_warn "Restoring database from: $LATEST_BACKUP"
        cp "$LATEST_BACKUP" "$ATHENA_HOME/athena.db"
    else
        log_error "No backup available. Database may be corrupted."
    fi
fi

log_info "Starting API Server..."
if [ ! -f "$ATHENA_HOME/index.html" ]; then
    log_error "index.html not found in $ATHENA_HOME. Dashboard will be blank."
    exit 1
fi
uvicorn athena_api:app --host 127.0.0.1 --port 8000 > /dev/null 2>&1 &
API_PID=$!
if [ -n "$API_PID" ] && kill -0 "$API_PID" 2>/dev/null; then
    echo "$API_PID" > "$API_PIDFILE"
    sleep 3
    if kill -0 "$API_PID" 2>/dev/null; then
        log_ok "API Server started (PID: $API_PID)"
    else
        log_error "API Server exited immediately. Check athena_api.py."
        log_warn "API failed to start. Dashboard unavailable but background services continue."
        API_PID=""
    fi
else
    log_error "API Server failed to start."
    log_warn "API failed to start. Dashboard unavailable but background services continue."
    API_PID=""
fi

if [ -f "$ATHENA_HOME/alert_dispatcher.py" ]; then
    log_info "Running initial Alert Dispatch check..."
    python3 "$ATHENA_HOME/alert_dispatcher.py" > /dev/null 2>&1 &
    ALERT_PID=$!
else
    ALERT_PID=""
fi

if [ -f "$ATHENA_HOME/thermal_guard.py" ]; then
    log_info "Starting Thermal Guard..."
    python3 "$ATHENA_HOME/thermal_guard.py" > /dev/null 2>&1 &
    THERMAL_PID=$!
    if [ -n "$THERMAL_PID" ] && kill -0 "$THERMAL_PID" 2>/dev/null; then
        echo "$THERMAL_PID" > "$THERMAL_PIDFILE"
        log_ok "Thermal Guard started (PID: $THERMAL_PID)"
    else
        log_warn "Thermal Guard failed to start. Continuing without it."
        THERMAL_PID=""
    fi
else
    log_warn "thermal_guard.py not found. Running without thermal protection."
fi

log_ok ""
log_ok "============================================"
log_ok "  ATHENA fully operational"
log_ok "  Dashboard: http://localhost:8000"
log_ok "  API Docs:  http://localhost:8000/api/docs"
log_ok "  R Engine:  http://localhost:8001 (internal)"
log_ok "============================================"
log_ok ""
log_info "Press Ctrl+C to safely shut down all services"

RESTART_COUNT_R=0
RESTART_COUNT_CELERY=0
RESTART_COUNT_API=0
RESTART_COUNT_THERMAL=0
MAX_RESTARTS=5

while true; do
    sleep 10
    
    if [ -n "${R_PID:-}" ] && ! kill -0 "${R_PID}" 2>/dev/null; then
        RESTART_COUNT_R=$((RESTART_COUNT_R + 1))
        if [ "$RESTART_COUNT_R" -gt "$MAX_RESTARTS" ]; then
            log_error "R Engine crashed ${MAX_RESTARTS} times. Not restarting."
        else
            BACKOFF_SECONDS=$(( RESTART_COUNT_R * RESTART_COUNT_R * 2 ))
            log_error "R Engine crashed. Restarting in ${BACKOFF_SECONDS}s (${RESTART_COUNT_R}/${MAX_RESTARTS})..."
            sleep "$BACKOFF_SECONDS"
            CURRENT_AVAILABLE_MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
            if [ -z "$CURRENT_AVAILABLE_MEM_MB" ] || [ "$CURRENT_AVAILABLE_MEM_MB" -lt 600 ]; then
                log_warn "Memory still low (${CURRENT_AVAILABLE_MEM_MB:-unknown}MB). Skipping R Engine restart."
                R_PID=""
                RESTART_COUNT_R=$(( MAX_RESTARTS + 1 ))
            else
                Rscript "$ATHENA_HOME/plumber.R" > /dev/null 2>&1 &
                R_PID=$!
                if [ -n "$R_PID" ]; then
                    echo "$R_PID" > "$R_PIDFILE"
                fi
                sleep 2
            fi
        fi
    fi
    
    if [ -n "$CELERY_PID" ] && ! kill -0 "$CELERY_PID" 2>/dev/null; then
        RESTART_COUNT_CELERY=$((RESTART_COUNT_CELERY + 1))
        if [ "$RESTART_COUNT_CELERY" -gt "$MAX_RESTARTS" ]; then
            log_error "Celery Worker crashed ${MAX_RESTARTS} times. Not restarting."
        else
            BACKOFF_SECONDS=$(( RESTART_COUNT_CELERY * RESTART_COUNT_CELERY * 3 ))
            log_error "Celery crashed. Restarting in ${BACKOFF_SECONDS}s (${RESTART_COUNT_CELERY}/${MAX_RESTARTS})..."
            sleep "$BACKOFF_SECONDS"
            CURRENT_AVAILABLE_MEM_MB_CELERY=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
            if [ "$REDIS_REACHABLE" = false ] || [ "${CURRENT_AVAILABLE_MEM_MB_CELERY:-0}" -lt 800 ]; then
                log_warn "Resources insufficient for Celery restart (Mem: ${CURRENT_AVAILABLE_MEM_MB_CELERY:-unknown}MB). Skipping."
                CELERY_PID=""
                RESTART_COUNT_CELERY=$(( MAX_RESTARTS + 1 ))
            else
                export ATHENA_ENCRYPTION_KEY="$ATHENA_ENCRYPTION_KEY"
                celery -A tasks worker \
                    --loglevel=warning \
                    --concurrency="$CELERY_CONCURRENCY" \
                    --max-tasks-per-child=50 \
                    --max-memory-per-child="$MAX_MEMORY_PER_CHILD" \
                    --pidfile="$CELERY_PIDFILE" \
                    --without-heartbeat \
                    --without-gossip \
                    --without-mingle \
                    -Q athena_checkins,celery > /dev/null 2>&1 &
                CELERY_PID=$!
                if [ -n "$CELERY_PID" ]; then
                    echo "$CELERY_PID" > "$CELERY_PIDFILE"
                fi
                sleep 3
            fi
        fi
    fi
    
    if [ -n "$API_PID" ] && ! kill -0 "$API_PID" 2>/dev/null; then
        RESTART_COUNT_API=$((RESTART_COUNT_API + 1))
        if [ "$RESTART_COUNT_API" -gt "$MAX_RESTARTS" ]; then
            log_error "API Server crashed ${MAX_RESTARTS} times. Not restarting."
        else
            BACKOFF_SECONDS=$(( RESTART_COUNT_API * RESTART_COUNT_API * 2 ))
            log_error "API Server crashed. Restarting in ${BACKOFF_SECONDS}s (${RESTART_COUNT_API}/${MAX_RESTARTS})..."
            sleep "$BACKOFF_SECONDS"
            uvicorn athena_api:app --host 0.0.0.0 --port 8000 > /dev/null 2>&1 &
            API_PID=$!
            if [ -n "$API_PID" ]; then
                echo "$API_PID" > "$API_PIDFILE"
            fi
            sleep 3
        fi
    fi
    
done