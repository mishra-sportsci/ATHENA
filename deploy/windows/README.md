# A.T.H.E.N.A. — Windows User Guide (100% Free of Cost)

A.T.H.E.N.A. runs natively on **Windows 10 & Windows 11** with **zero commercial software, zero cloud subscriptions, and zero license costs**.

---

## 1. Free Software Requirements

Both required runtimes are open-source and free for academic, personal, and professional use:

1. **Python 3.12+ (Free, PSF License):**
   - Download: [python.org/downloads/windows](https://www.python.org/downloads/windows/)
   - *Crucial Installation Step:* During installation, check the box: **"Add python.exe to PATH"**.
2. **R 4.4+ (Free, GNU GPL License):**
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
*(Both native Windows and WSL2 approaches are 100% free of cost).*
