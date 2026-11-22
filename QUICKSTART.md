# A.T.H.E.N.A. — Quickstart & Deployment Guide

This guide details setting up the A.T.H.E.N.A. Clinical Intelligence Workspace on Linux, macOS, and containerized Docker environments.

---

## 1. Automated Quickstart (Linux / Debian / Ubuntu)

```bash
# 1. Clone repository
git clone https://github.com/mishra-sportsci/ATHENA.git
cd ATHENA

# 2. Configure environment
cp .env.example .env

# 3. Create virtual environment & install dependencies
python3 -m venv athena_env
source athena_env/bin/activate
pip install -r requirements.txt

# 4. Verify R packages
R -e "if (!requireNamespace('plumber', quietly = TRUE)) install.packages('plumber', repos='https://cloud.r-project.org')"
R -e "if (!requireNamespace('jsonlite', quietly = TRUE)) install.packages('jsonlite', repos='https://cloud.r-project.org')"

# 5. Populate synthetic testing cohort (Zero Real PII)
python3 seed_demo_data.py

# 6. Start Operational Consoles
# Option A: FastAPI Application Gateway (:8000) & Plumber Engine (:8001)
./athena.sh

# Option B: Elite R Shiny Sports Science Telemetry Hub (:3838)
./run_shiny.sh
```

Once running:
* **R Shiny Clinical Hub:** [http://localhost:3838](http://localhost:3838)
* **Master Web Console:** [http://localhost:8000](http://localhost:8000)
* **API Documentation:** [http://localhost:8000/api/docs](http://localhost:8000/api/docs)
* **R Analytics Engine:** [http://localhost:8001](http://localhost:8001)

---

## 2. Automated Quickstart (Windows 10 / 11)

No Linux virtual machine or WSL required. ATHENA runs natively in Windows CMD/PowerShell:

### 1. Prerequisites
* [Python 3.12+](https://www.python.org/downloads/windows/) — *Ensure "Add python.exe to PATH" is checked.*
* [R 4.4+](https://cran.r-project.org/bin/windows/base/) — *Standard Windows installer.*

### 2. Automatic Dependency & Database Setup
Open Command Prompt in the ATHENA directory and run:
```cmd
deploy\windows\setup_windows.bat
```

### 3. Launch Console
Double-click:
```cmd
run_shiny.bat
```
ATHENA will start and automatically open your default browser to `http://127.0.0.1:3838`.

---

## 3. Desktop Application Mode (Linux KDE Plasma / GNOME / X11 / Wayland)

If you prefer a native, hardware-accelerated desktop window without browser chrome:

```bash
./launch.sh
```

---

## 3. Docker Deployment

To deploy in isolated containers with full service orchestration:

```bash
docker compose up -d --build
```

To view logs:
```bash
docker compose logs -f
```

---

## 4. Key Endpoints Reference

| Service | Port | Endpoint | Purpose |
| :--- | :---: | :--- | :--- |
| **FastAPI** | `8000` | `/` | Master Web Dashboard |
| **FastAPI** | `8000` | `/api/ping` | Service Health & Uptime |
| **FastAPI** | `8000` | `/api/system/profile` | Machine Capabilities & Memory Mode |
| **FastAPI** | `8000` | `/api/roster/all` | Active Athlete Roster |
| **R Plumber** | `8001` | `/health` | Statistical Kernel Status |
| **R Plumber** | `8001` | `/analytics/acwr` | EWMA ACWR Calculation |
| **R Plumber** | `8001` | `/analytics/energy-availability` | REDs Clinical Coordinates |
| **R Plumber** | `8001` | `/analytics/full-assessment` | Complete Longitudinal Profile Assessment |

---

## 5. Troubleshooting & FAQ

* **Redis Not Available?**  
  ATHENA automatically detects missing message brokers and falls back to **synchronous processing mode**. Celery is safely bypassed with zero disruption to the analytical pipeline.
* **Low Memory Environment?**  
  The built-in `CapabilityManager` probes available RAM on boot. If free memory is below 600 MB, high-memory R spline routines are safely bypassed and handed over to Python numerical routines.
