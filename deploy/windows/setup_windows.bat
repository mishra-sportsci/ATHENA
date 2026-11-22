@echo off
setlocal enabledelayedexpansion
title A.T.H.E.N.A. — Windows Automated Dependency & Environment Setup

echo ======================================================================
echo           A.T.H.E.N.A. — Windows Automated Setup (100%% Free)
echo   Adaptive Telemetry, Health ^& Evidence-Based Nutrition Analytics
echo ======================================================================
echo.

set "SCRIPT_DIR=%~dp0..\..\"
cd /d "%SCRIPT_DIR%"

:: 1. Verify Python
echo [1/5] Checking Python 3.12+ installation...
where python >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Python is not installed or not in your Windows PATH.
    echo Please install Python free from: https://www.python.org/downloads/windows/
    echo IMPORTANT: Make sure to check "Add python.exe to PATH" during installation.
    echo.
    pause
    exit /b 1
)
python --version

:: 2. Verify R
echo.
echo [2/5] Checking R 4.4+ installation...
where Rscript >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    set "RSCRIPT="
    for /d %%D in ("%ProgramFiles%\R\R-*") do (
        if exist "%%D\bin\Rscript.exe" set "RSCRIPT=%%D\bin\Rscript.exe"
    )
    if not defined RSCRIPT (
        echo [ERROR] R is not detected.
        echo Please install R 4.4+ free from: https://cran.r-project.org/bin/windows/base/
        echo.
        pause
        exit /b 1
    )
) else (
    set "RSCRIPT=Rscript"
)
"!RSCRIPT!" --version

:: 3. Setup Python Virtual Environment
echo.
echo [3/5] Configuring Python virtual environment (athena_env)...
if not exist "athena_env\Scripts\activate.bat" (
    python -m venv athena_env
)
call athena_env\Scripts\activate.bat

echo Installing Python dependencies from requirements.txt...
python -m pip install --upgrade pip
pip install -r requirements.txt

:: 4. Install R Packages
echo.
echo [4/5] Installing verified R sports science packages...
"!RSCRIPT!" -e "packages <- c('shiny', 'plotly', 'RSQLite', 'jsonlite', 'DT', 'bslib', 'shinyWidgets', 'shinyjs', 'dplyr'); to_install <- packages[!packages %%in%% installed.packages()[, 'Package']]; if (length(to_install) > 0) install.packages(to_install, repos='https://cloud.r-project.org')"

:: 5. Initialize Synthetic Database
echo.
echo [5/5] Seeding synthetic, HIPAA/GDPR-compliant demonstration database...
python seed_demo_data.py

echo.
echo ======================================================================
echo [SUCCESS] ATHENA WINDOWS ENVIRONMENT READY!
echo.
echo To launch the Clinical Console:
echo   Double-click: run_shiny.bat in the root folder
echo.
echo To launch the FastAPI Gateway:
echo   Double-click: deploy\windows\run_fastapi.bat
echo ======================================================================
pause
