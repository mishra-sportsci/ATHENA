@echo off
setlocal enabledelayedexpansion
title A.T.H.E.N.A. — Elite Sports Science & Clinical Telemetry Console

echo ======================================================================
echo           A.T.H.E.N.A. — Elite R Shiny Analytics Console
echo   Adaptive Telemetry, Health ^& Evidence-Based Nutrition Analytics
echo ======================================================================
echo.

:: 1. Detect Rscript in PATH or standard Program Files locations
where Rscript >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    set "RSCRIPT=Rscript"
) else (
    set "RSCRIPT="
    for /d %%D in ("%ProgramFiles%\R\R-*") do (
        if exist "%%D\bin\Rscript.exe" set "RSCRIPT=%%D\bin\Rscript.exe"
    )
    if not defined RSCRIPT (
        for /d %%D in ("%ProgramFiles(x86)%\R\R-*") do (
            if exist "%%D\bin\Rscript.exe" set "RSCRIPT=%%D\bin\Rscript.exe"
        )
    )
    if not defined RSCRIPT (
        echo [ERROR] R is not detected in your PATH or Program Files.
        echo ----------------------------------------------------------------------
        echo To run ATHENA on Windows, install R:
        echo   https://cran.r-project.org/bin/windows/base/
        echo (Tip: During R installation, select "Add R to PATH")
        echo ----------------------------------------------------------------------
        echo.
        pause
        exit /b 1
    )
)

echo [INFO] Detected R: "!RSCRIPT!"

:: 2. Set Paths
set "SCRIPT_DIR=%~dp0"
set "SHINY_DIR=%SCRIPT_DIR%athena_shiny"
set "ATHENA_DB_PATH=%SCRIPT_DIR%athena.db"
set "ATHENA_SHINY_PORT=3838"
set "ATHENA_API_URL=http://127.0.0.1:8000"

:: 3. Clear stale port 3838 process if running
powershell -Command "Get-NetTCPConnection -LocalPort 3838 -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }" 2>nul

:: 4. Convert Windows backslashes to forward slashes for R path compatibility
set "SHINY_DIR_R=%SHINY_DIR:\=/%"
set "DB_PATH_R=%ATHENA_DB_PATH:\=/%"

echo [INFO] Launching ATHENA R Shiny Clinical Console...
echo [INFO] Console URL: http://127.0.0.1:3838
echo.
echo ======================================================================
echo [READY] Your default web browser will open automatically.
echo Press Ctrl+C in this command window when finished to safely close.
echo ======================================================================
echo.

"!RSCRIPT!" -e "options(shiny.port = 3838, shiny.host = '127.0.0.1'); shiny::runApp('%SHINY_DIR_R%', port=3838, host='127.0.0.1', launch.browser=TRUE)"

pause
