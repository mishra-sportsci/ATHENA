# ATHENA Changelog

All notable changes to the A.T.H.E.N.A. (Adaptive Telemetry, Health & Evidence-Based Nutrition Analytics) platform are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] - 2026-11-22 · STABLE (Initial Open-Source Release)

### Added
- **Clinical Decision Support System (CDSS):** Rule-based expert clinical evaluation for injury risk triaging, training load spikes, autonomic fatigue, and sleep deprivation based on IOC consensus, Gabbett, Foster, and Hooper-Mackinnon standards.
- **IOC 2023 RED-S Energy Availability Lab:** Dynamic quantification of Energy Availability ($\text{EA} = (\text{EI} - \text{EEE}) / \text{FFM}$) with automated clinical referral triggers for clinical LEA ($< 30\text{ kcal/kg FFM/day}$).
- **Coupled EWMA & Rolling ACWR:** Implementation of Gabbett's Acute:Chronic Workload Ratio with sweet-spot ($0.80\text{–}1.30$) and danger-zone ($> 1.50$) risk stratification.
- **Foster Monotony & Strain:** Day-to-day load variation tracking to detect neuroendocrine overreaching and illness vulnerability.
- **Universal Multilingual Localization:** Complete native internationalization across 10 global languages (`en`, `hi`, `es`, `fr`, `de`, `pt`, `ar`, `ru`, `sw`, `zh`), including native right-to-left (RTL) Arabic support.
- **Dual-Console Operational Environment:**
  - *Console 1:* Lightweight, high-speed HTML5 / FastAPI web and desktop application (port 8000).
  - *Console 2:* Elite R Shiny 1.14 Clinical Telemetry Hub with Plotly interactive visualization (port 3838).
- **100% Offline-First Architecture:** Hardened local SQLite storage (`athena.db`) with zero background resource consumption upon shutdown (`./stop.sh`).
- **High-Contrast Day & Night Modes:** Trackside high-contrast sunlight mode (`#0F172A` on `#FFFFFF`) and dark cybernetic mode.
- **Card-Level Precision Zoom:** Multi-tier `+` / `−` zoom and autoscale controls for fine inspection of telemetry curves.
- **Hardware Watchdog (Thermal Guard):** Proactive CPU temperature monitoring to throttle batch processing during excessive thermal stress.

---

## [5.0.0-legacy] - 2026-06-10 · Pre-Release Prototype
- Initial hardware capability detection prototype.
- Preliminary R Plumber service integration.
- Proof-of-concept synthetic cohort generation.
