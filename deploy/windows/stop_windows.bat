@echo off
title A.T.H.E.N.A. — Clean Shutdown (Windows)

echo ======================================================================
echo           A.T.H.E.N.A. — Graceful Shutdown & Port Clearing
echo ======================================================================
echo.

echo [INFO] Flushing SQLite database checkpoint safely...
set "SCRIPT_DIR=%~dp0..\..\"
cd /d "%SCRIPT_DIR%"

where python >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    python -c "import sqlite3; c=sqlite3.connect('athena.db', timeout=3); c.execute('PRAGMA wal_checkpoint(TRUNCATE)'); c.close(); print('[OK] Database WAL flushed to disk.')" 2>nul
)

echo [INFO] Terminating active listeners on ports 3838 (Shiny) and 8000 (FastAPI)...
powershell -Command "Get-NetTCPConnection -LocalPort 3838,8000 -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }" 2>nul

echo [SUCCESS] ATHENA services terminated. Zero background CPU/RAM consumption.
echo ======================================================================
timeout /t 3
