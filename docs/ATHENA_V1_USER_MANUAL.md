# ATHENA v1 — Comprehensive User & Operational Manual
### Adaptive Telemetry · Health · Evidence-Based Nutrition Analytics
**Document Version:** 1.0 · STABLE  
**Target Audience:** Sports Scientists, Performance Directors, Exercise Physiologists, Strength & Conditioning Specialists, Team Physicians, and Senior Developers  
**Default Access Credentials:** User ID: `director` | Password: `Athena@2026`  
**Classification:** RESTRICTED · ATHENA v1

---

## 1. Executive Overview & System Purpose

**ATHENA v1** is a high-performance, clinical-grade athletic telemetry and sports science intelligence platform. Designed to bridge empirical sports physiology and modern distributed systems, ATHENA v1 enables real-time monitoring of physiological fatigue, neuromuscular readiness, cardiovascular stress, sleep architecture, and Relative Energy Deficiency in Sport (RED-S).

The platform operates under an **offline-first, zero-leakage paradigm**: all biometric, nutritional, and training data remain securely stored inside a hardened, transactional SQLite core on the local machine. ATHENA v1 guarantees **0.00% background resource consumption** when closed, preventing thermal throttling and conserving battery life in fieldwork and travel environments.

---

## 2. System Architecture & Dual-Console Environment

ATHENA v1 provides two distinct, synchronized operational consoles to accommodate differing operational contexts:

```
                                 ┌──────────────────────────────────────────────────┐
                                 │                 ATHENA v1 Core                   │
                                 │       Hardened SQLite DB (athena.db)             │
                                 │    91,000+ Biometric Rows · 2,600+ Athletes      │
                                 └─────────────────────────┬────────────────────────┘
                                                           │
                             ┌─────────────────────────────┴─────────────────────────────┐
                             ▼                                                           ▼
                ┌─────────────────────────┐                                 ┌─────────────────────────┐
                │      ATHENA Native      │                                 │     ATHENA R Shiny      │
                │  HTML5 / FastAPI GUI    │                                 │ Clinical Telemetry Hub  │
                │     (Port 8000)         │                                 │      (Port 3838)        │
                ├─────────────────────────┤                                 ├─────────────────────────┤
                │ • Lightweight & Fast    │                                 │ • Deep Interactive EDA │
                │ • Native PyWebView / Qt │                                 │ • Plotly Analytics      │
                │ • Quick Status & HUD    │                                 │ • 147 Zoom / Scale Tools│
                │ • Field Readiness       │                                 │ • Complex RED-S Matrix  │
                └─────────────────────────┘                                 └─────────────────────────┘
```

### A. Console 1: ATHENA (Native HTML / Web Intelligence Workspace)
* **Launcher:** Click **ATHENA** in the system dock or applications menu (`launch.sh`).
* **Underlying Stack:** Python 3.13 FastAPI backend + PyQt6 WebEngine wrapper + HTML5/CSS3 custom HUD.
* **Primary Use Case:** High-speed daily monitoring, field touchscreens, sideline tablet review, and rapid athlete check-ins.

### B. Console 2: ATHENA R Shiny (Elite Clinical Analytics Console)
* **Launcher:** Click **ATHENA R Shiny** (distinguished by the glowing **R SHINY** badge) in the system dock or applications menu (`run_shiny.sh`).
* **Underlying Stack:** R Shiny 1.14 + Plotly + DBI / RSQLite + High-DPI SVG clinical visualization engines.
* **Primary Use Case:** In-depth multi-athlete comparative analytics, squad load heatmaps, DXA bone health evaluation, hormonal menstrual cycle tracking, and academic research data exports.

### C. Resource Terminator: Stop ATHENA
* **Launcher:** Click **Stop ATHENA** (`stop.sh`).
* **Action:** Instantly checkpoints SQLite WAL logs, terminates background ports (`3838`, `8000`, `8001`), kills residual workers, and releases 100% of CPU and RAM allocations.

---

## 3. Authentication & Access Control

ATHENA v1 implements strict role-based access control (RBAC):

| Role | Username / ID | Password | Permissions |
| :--- | :--- | :--- | :--- |
| **Director / Admin** | `director` or `admin` | `Athena@2026` | Full administrative control, CSV dataset ingestion, database purging, clinical threshold customization, and raw telemetry export. |
| **Coach / Physiologist** | `coach` | `Athena@2026` | Full read/write access to athlete rosters, training plans, clinical decision support (CDSS) recommendations, and team load analytics. Cannot overwrite core system schemas. |
| **Athlete** | `ATH-XXX` (e.g. `ATH-001`) | `Athena@2026` | Restricted personal view: subjective wellness check-in, individual readiness score, and prescribed session targets. |

---

## 4. Key Functional Features & Operational Guide

### 4.1 Card Zoom In, Zoom Out & Autoscale Controls
Every graph, chart, and analytical panel across all tabs contains an integrated precision control group in the top-right corner of the panel card header:

* **`+` (Zoom In):** Scales the active chart inward by 30%, centering on the current view midpoint, or magnifies SVG diagrams.
* **`−` (Zoom Out):** Expands the chart viewing window outward by 40% with bounds protection to prevent axis inversion.
* **`↺` (Autoscale / Reset):** Resets axes to $1:1$ bounds (`autorange: true` in Plotly) and restores CSS transforms to unity.

### 4.2 High-Contrast Day & Night Light Modes
* Toggle between dark cybernetic theme and clean clinical high-contrast paper theme via the **☀ DAY** / **☾ NIGHT** button on the navigation bar.
* Day mode enforces high-contrast ink-black typography (`#0F172A`) over clean slate backgrounds (`#FFFFFF` and `#F8FAFC`), engineered specifically for bright outdoor tracks and sunlit training fields.

### 4.3 Multi-Lingual Localization Engine
Select any of the 10 internationally recognized sports medicine languages from the top dropdown:
* English (`en`), Hindi (`hi`), Spanish (`es`), French (`fr`), German (`de`), Portuguese (`pt`), Arabic (`ar` with native RTL layout), Russian (`ru`), Swahili (`sw`), and Chinese (`zh`).
* All labels, clinical caveats, axis titles, and analytical hints dynamically re-populate in real-time.

### 4.4 External CSV Dataset Ingestion (Data Ops Tab)
ATHENA v1 features an industrial-grade, error-resilient CSV ingestion pipeline:
1. Navigate to the **Data Ops** tab.
2. Under **CSV IMPORT**, drag and drop your `.csv` file or click **Browse...**.
3. Verify the 8-row preview and metadata (row count, columns, file size).
4. Click **Upload to backend**.
5. **Ingestion Engine:**
   * **Synonym Auto-Mapping:** Automatically resolves columns such as `athlete_id` $\rightarrow$ `user_id`, `day` $\rightarrow$ `date`, `load` $\rightarrow$ `daily_load`, `minutes` $\rightarrow$ `duration_minutes`.
   * **Conflict-Free UPSERT:** Executes parameterized `INSERT OR REPLACE INTO daily_checkins` inside an atomic transaction. Existing athlete records for that date are updated without throwing `UNIQUE constraint` errors.
   * **Auto-Population:** Automatically clears internal trend caches and reloads the entire dashboard, updating readiness distributions, athlete detail cards, and the **Data Completeness** audit table.

---

## 5. Scientific Principles & Mathematical Formulations

ATHENA v1 computes all metrics based on peer-reviewed sports science and clinical consensus models:

### 5.1 Acute:Chronic Workload Ratio (ACWR) — Gabbett (2016)
Workload is modeled using uncoupled exponentially weighted moving averages (EWMA) and rolling 7-day vs. 28-day windows:
$$\text{Acute Load (ATL)} = \frac{1}{7} \sum_{i=0}^{6} \text{Load}_{t-i}$$
$$\text{Chronic Load (CTL)} = \frac{1}{28} \sum_{i=0}^{27} \text{Load}_{t-i}$$
$$\text{ACWR} = \frac{\text{ATL}}{\text{CTL}}$$
* **$\text{ACWR} < 0.80$:** Under-training / increased injury vulnerability.
* **$0.80 \le \text{ACWR} \le 1.30$:** "Sweet Spot" — optimal adaptation zone with minimal relative injury risk.
* **$\text{ACWR} \ge 1.50$:** "Danger Zone" — exponentially elevated probability of soft-tissue and overuse injuries.

### 5.2 Training Monotony & Strain — Foster (1998)
Monotony measures the day-to-day load variation within a microcycle:
$$\text{Monotony} = \frac{\text{Mean Daily Load (7-Day)}}{\text{Standard Deviation of Load (7-Day)}}$$
$$\text{Strain} = \left(\sum_{i=1}^{7} \text{Daily Load}_i\right) \times \text{Monotony}$$
* High Monotony ($> 2.0$) coupled with high weekly Strain is strongly indicative of impending overreaching, neuroendocrine exhaustion, and illness susceptibility.

### 5.3 Relative Energy Deficiency in Sport (RED-S) & Energy Availability (EA)
Calculated in strict compliance with the **International Olympic Committee (IOC) RED-S Consensus** (Mountjoy et al., 2023):
$$\text{Energy Availability (EA)} = \frac{\text{Energy Intake (kcal)} - \text{Exercise Energy Expenditure (kcal)}}{\text{Fat-Free Mass (kg FFM)}}$$
* **$\text{EA} \ge 45\text{ kcal/kg FFM/day}$:** Optimal energy availability; physiological homeostasis maintained.
* **$30 \le \text{EA} < 45\text{ kcal/kg FFM/day}$:** Subclinical low energy availability; micro-nutritional adaptation required.
* **$\text{EA} < 30\text{ kcal/kg FFM/day}$:** Clinical Low Energy Availability (LEA). Triggers immediate clinical referral, bone mineral density review (DXA), and automated recommendation for high-intensity training suspension.

---

## 6. Comprehensive System Pros & Cons

### Pros (Strengths)
1. **Total Data Sovereignty & Offline Independence:** Operates completely air-gapped without requiring external cloud connections, safeguarding confidential biometric records under GDPR and HIPAA equivalents.
2. **Dual-Console Flexibility:** Choose between the native, lightweight HTML application for swift field check-ins or the deep R Shiny console for research-grade statistical exploration.
3. **High-Speed Transactional Ingestion:** Handles large clinical datasets (e.g., 2,500+ daily check-in rows) in under **0.02 seconds** using parameterized SQLite transactions.
4. **Zero Residual Resource Footprint:** Shuts down cleanly; does not leak background daemons, cron workers, or memory pages when stopped.
5. **Triangulated Athlete Monitoring:** Combines internal training load ($\text{RPE} \times \text{Duration}$), external load (GPS / meters / watts), and subjective recovery markers (sleep hours, muscle soreness, psychometric stress).

### Cons (Considerations)
1. **Local Compute & Storage Bound:** Database capacity and query speeds scale with local hardware capabilities (NVMe SSD and multi-core CPU recommended for cohorts exceeding 10,000 athletes).
2. **Browser Engine Memory Overhead:** Simultaneous execution of both HTML webview and R Shiny across hundreds of active browser tabs can consume 1–2 GB of system RAM while active.
3. **No Automatic Multi-Machine Cloud Sync:** Because the platform prioritizes offline security, multi-station synchronization across different laptops requires manual SQLite file transfer or local network export.

---

## 7. Limitations & Delimitations

Understanding the scientific and engineering boundaries is vital for ethical, safe, and valid deployment:

### Limitations (Inherent Constraints Outside User/Developer Control)
1. **Photoplethysmography (PPG) Motion Artifacts:** Optical heart rate and HRV telemetry from commercial wrist wearables are susceptible to motion-induced signal degradation during high-cadence sprinting and combat sports.
2. **Subjective Self-Reporting Bias:** Readiness and RPE calculations rely partially on honest subjective ratings. Athlete under-reporting (hiding fatigue to avoid benching) or over-reporting (fatigue magnification) can temporarily skew acute load metrics.
3. **Correlational Risk Estimations:** High ACWR ($>1.5$) or elevated Foster Strain flags physiological vulnerability, but cannot definitively forecast an acute traumatic injury (e.g. contact fractures or freak collisions).
4. **Single-Writer Database Lock During Large Batches:** While SQLite WAL mode permits concurrent reads, simultaneous bulk CSV write transactions from multiple threads must execute sequentially.

### Delimitations (Deliberate Boundaries Established by Design)
1. **Clinical Decision Support, Not Automated Diagnosis:** ATHENA v1 provides algorithmic triaging and flags; it intentionally does **not** prescribe pharmaceutical dosages or replace licensed physicians, physiotherapists, or registered dietitians.
2. **Focus on Competitive & Elite Athletics:** Telemetry scoring curves, normative VO₂ max ranges, and ACWR thresholds are deliberately calibrated for competitive, collegiate, and elite performers, not sedentary or clinical inpatient populations.
3. **Local Privacy Sandbox:** The platform strictly prohibits silent third-party analytics, remote telemetry beaconing, or automated ad tracking.

---

## 8. Maintenance, Safety Protocols & Troubleshooting

### Safe Startup Sequence
* **For Field Monitoring:** Launch **ATHENA** from your dock or applications menu.
* **For Laboratory Analytics:** Launch **ATHENA R Shiny** from your dock or applications menu.
* *Note:* If an instance is already running on the required port, clicking the launcher will safely bring the existing interface into focus rather than crashing or creating conflicting processes.

### Safe Shutdown Sequence
* Always terminate operations by clicking **Stop ATHENA** or executing:
  ```bash
  ./stop.sh
  ```
* This checkpoints the database write-ahead log (`PRAGMA wal_checkpoint(TRUNCATE)`), preventing database corruption, and terminates all active processes on ports `3838`, `8000`, and `8001`.

### Common Diagnostics & Quick Fixes
* **Issue:** *Port 3838 or 8000 already in use.*
  * *Solution:* Run **Stop ATHENA** once. The script cleans all port bindings within 1 second.
* **Issue:** *CSV Upload shows "Upload failed: No records could be stored in database".*
  * *Solution:* Ensure your CSV file includes athlete identifiers and dates. ATHENA v1 automatically maps common synonyms (`athlete_id`, `load`, `day`), but empty files or unsupported file formats (`.xlsx` instead of `.csv`) will be rejected.
* **Issue:** *Charts appear too large or small on non-standard monitor resolutions.*
  * *Solution:* Use the card-level `+` / `−` zoom buttons or click the navigation bar zoom presets (`100%`, `+`, `−`).
