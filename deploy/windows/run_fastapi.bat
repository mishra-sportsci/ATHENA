@echo off
setlocal
title A.T.H.E.N.A. — FastAPI Application Gateway

echo ======================================================================
echo           A.T.H.E.N.A. — Master FastAPI Web Server (:8000)
echo ======================================================================
echo.

set "SCRIPT_DIR=%~dp0..\..\"
cd /d "%SCRIPT_DIR%"

if exist "athena_env\Scripts\activate.bat" (
    call athena_env\Scripts\activate.bat
)

echo [INFO] Starting FastAPI Gateway at http://127.0.0.1:8000 ...
echo [INFO] OpenAPI Docs: http://127.0.0.1:8000/api/docs
echo.
echo Press Ctrl+C to stop the FastAPI server.
echo ======================================================================

python -m uvicorn athena_api:app --host 127.0.0.1 --port 8000
pause
