# A.T.H.E.N.A. — Disaster Recovery & System Restoration Guide

This runbook outlines operational recovery procedures, database verification, and service restoration for the A.T.H.E.N.A. Clinical Intelligence Workspace.

---

## 1. System Requirements
- **Operating System:** Linux (Debian 12/13, Ubuntu 22.04/24.04), macOS, or Windows 10/11 with WSL2
- **Python Environment:** Python 3.10+ with `virtualenv`
- **R Runtime:** R 4.2+ (for R Shiny & Plumber analytical engines)
- **Memory & Storage:** 4 GB RAM minimum (8 GB recommended), 500 MB disk space

---

## 2. Clean Installation & Setup

```bash
# 1. Clone repository
git clone https://github.com/mishra-sportsci/ATHENA.git
cd ATHENA

# 2. Initialize Python virtual environment
python3 -m venv athena_env
source athena_env/bin/activate
pip install -r requirements.txt

# 3. Configure environment
cp .env.example .env
```

---

## 3. Database Restoration & Verification

### Restoring from Backup
```bash
# Copy latest verified backup snapshot
cp backups/athena_auto_backup_YYYYMMDD_HHMMSS.db athena.db

# Apply pending schema migrations
python3 migrations.py
```

### Database Integrity Verification
Execute SQLite PRAGMA checks to ensure B-tree integrity:
```bash
sqlite3 athena.db "PRAGMA integrity_check;"
sqlite3 athena.db "PRAGMA foreign_key_check;"
sqlite3 athena.db "SELECT count(*) FROM daily_checkins;"
```

---

## 4. Service Health Check

Launch ATHENA services and verify full API diagnostic reporting:
```bash
# Start background services
./launch.sh

# Verify health endpoints
curl http://localhost:8000/api/health/full
python3 healthcheck.py
```

---

## 5. Troubleshooting & Diagnostics

| Symptom | Probable Cause | Remediation |
| :--- | :--- | :--- |
| **Port 3838 / 8000 in use** | Lingering background process | Execute `./stop.sh` or `pkill -f uvicorn` |
| **Database locked (`SQLITE_BUSY`)** | Unclosed transaction or missing WAL checkpoint | Execute `./stop.sh` to trigger `PRAGMA wal_checkpoint(TRUNCATE)` |
| **Redis connection refused** | Redis daemon inactive | System automatically falls back to local in-memory queue |
| **R engine unavailable** | Missing R dependencies | Verify R installation (`R --version`) or run Python API mode |
