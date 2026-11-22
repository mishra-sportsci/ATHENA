# A.T.H.E.N.A. — Windows Deployment & Operation Guide

A.T.H.E.N.A. runs natively on **Windows 10 & Windows 11** with full hardware acceleration and zero virtualization overhead.

---

## 1. Prerequisites

Both required runtimes are standard open-source environments:

1. **Python 3.12+:**
   - Download: [python.org/downloads/windows](https://www.python.org/downloads/windows/)
   - *Installation Step:* Ensure the box **"Add python.exe to PATH"** is checked.
2. **R 4.4+:**
   - Download: [CRAN Windows Installer](https://cran.r-project.org/bin/windows/base/)
   - Run the standard installer using default settings.

---

## 2. One-Click Setup

1. Clone or download the repository to your Windows machine:
   ```cmd
   git clone https://github.com/mishra-sportsci/ATHENA.git
   ```
2. Navigate into the folder and double-click:
   ```
   deploy\windows\setup_windows.bat
   ```
   *This automated batch script will:*
   - Verify Python and R installations.
   - Create an isolated virtual environment (`athena_env`).
   - Install required scientific Python libraries (`FastAPI`, `SQLAlchemy`, `pandas`, `cryptography`).
   - Install verified R sports science packages (`shiny`, `plotly`, `RSQLite`, `DT`, `bslib`).
   - Generate a synthetic, de-identified testing database (`athena.db`).

---

## 3. Running the Operational Consoles

### Primary Clinical Hub (R Shiny Console)
Double-click:
```
run_shiny.bat
```
*(Located directly in the root repository directory)*

Your default browser (Edge, Chrome, Brave, Firefox) will automatically open:
* **URL:** `http://127.0.0.1:3838`

### FastAPI Master Web Gateway (Optional)
Double-click:
```
deploy\windows\run_fastapi.bat
```
* **REST API:** `http://127.0.0.1:8000`
* **Interactive OpenAPI Docs:** `http://127.0.0.1:8000/api/docs`

---

## 4. Clean Shutdown

To stop all active listeners and prevent background resource consumption:
* Double-click `deploy\windows\stop_windows.bat`
* Or simply press `Ctrl + C` in the running command prompt window.

---

## 5. Alternative: Windows Subsystem for Linux (WSL2)

If you prefer running ATHENA in a native Linux kernel on Windows:
1. Open PowerShell as Administrator and run:
   ```powershell
   wsl --install
   ```
2. Restart your PC, launch Ubuntu from the Start Menu, and clone ATHENA:
   ```bash
   git clone https://github.com/mishra-sportsci/ATHENA.git
   cd ATHENA
   ./run_shiny.sh
   ```
*(Both native Windows CMD/PowerShell and WSL2 workflows are supported).*
