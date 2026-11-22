################################################################################
#  ____   ___  _   _ _____ ___ _   _  _____
# / ___| / _ \| \ | |_   _|_ _| \ | || ____|     A.T.H.E.N.A.  ·  v1.0.0
# \___ \| | | |  \| | | |  | ||  \| ||  _|       Adaptive Telemetry, Health &
#  ___) | |_| | |\  | | |  | || |\  || |___      Evidence-Based Nutrition Analytics
# |____/ \___/|_| \_| |_| |___|_| \_||_____|
#
# ATHENA R SHINY CONSOLE — single-file, collapse-free replacement for index.html
# v7 CHANGELOG: panel COLLAPSE machinery fully REMOVED (button, CSS, JS,
#   localStorage['athena_collapsed'] persistence and observers). Panel cards keep
#   their headers/bodies and are always expanded. 12 index.html panels added,
#   data model extended, 10-rule alert engine at 15 s cadence.
#================================================================================
# RUN:
#   Rscript -e "shiny::runApp('app.R', port=3838, host='0.0.0.0')"
#   (or)  ./run_athena.sh
#
# POINT IT AT THE PYTHON BACKEND:
#   export ATHENA_API_URL = "http://localhost:8000"   (athena_api.py)
#   Login with any coach/admin/athlete credential known to the backend,
#   or press DEMO for a fully-functional offline synthetic cohort.
#
# DESIGN CONTRACT — "collapse free":
#   1. Only shiny + jsonlite + httr are HARD dependencies. Every other package
#      (bslib, DT, plotly, shinyjs, shinyWidgets, dplyr) is OPTIONAL and the app
#      degrades gracefully when absent (capability matrix, section 0).
#   2. Every reactive/render block is wrapped in a guard: no error can crash the
#      session — failed widgets show a localized retry card instead.
#   3. Every HTTP call has a timeout, bounded retries with backoff and a circuit
#      breaker; on sustained failure the console auto-switches to DEMO data and
#      keeps polling for recovery.
#   4. All data consumers are NA/empty-safe (validate/need + safe accessors).
#   5. Bounded event stores (ticker, notifications, thermal history) prevent
#      memory creep in long-running sessions.
#
# FEATURE PARITY WITH index.html (mapped) + NEW features:
#   [P]  = parity with index.html    [N]  = new in the Shiny console
#   -----------------------------------------------------------------------
#   [P] 10-language i18n (en hi es fr de pt ar ru sw zh) + RTL for Arabic
#   [P] Dark / light theme, CRT effect, compact layout preset
#   [P] Live ticker, toasts, notification center with badge + clear
#   [P] Athlete roster: search, status/gender filter chips, group-by,
#       card & sortable table views, custom tags, sparklines, N= count
#   [P] HUD cards (VO2max, HR, Power, Readiness ring) + quick-stats bar
#   [P] Charts: readiness trend, load matrix heatmap, sleep architecture,
#       risk matrix, wellness radar, performance trend, EA trend+forecast,
#       cohort RED-S chart, compare radar
#   [P] RED-S Lab: EA calculator with scenario sliders + clinical banding
#       (IOC 30/45 thresholds), luteal penalty, MET-based exercise cost
#   [P] Menstrual cycle timeline with training-adaptation windows
#   [P] Daily check-in modal (full SyncPayload contract) -> POST /sync-data
#   [P] CSV import (preview/validate/upload + task polling) & exports
#   [P] Session control (timer, phase/load/fatigue bars, pause/end)
#   [P] System status: health, thermal guard mode + temp, ML pipeline
#   [P] PDF-style athlete report (printable), PNG/CSV chart exports
#   [P] Live simulation (jitter) mode, auto-refresh, connection status
#   [P] Athlete notes with undo/redo, priority flags, relative timestamps
#   [N] ACWR workload-risk chart (7:28 EWMA, Gabbett zones) per athlete
#   [N] Monotony & Strain (Foster) weekly panel
#   [N] Wellness-Fatigue ratio gauge + composite readiness breakdown
#   [N] Alert center with acknowledge-all + browser notifications
#   [N] Endpoint diagnostics panel (ping/latency per backend route)
#   [N] Settings hub persisted to localStorage (API URL/token, refresh,
#       thresholds, units, sound, language, theme)
#   [N] Command palette (Ctrl+K) with athlete search + quick actions
#   [N] Keyboard shortcut map (1-8 tabs, R refresh, T theme, ? help)
#   [N] Circuit-breaker auto demo-mode with recovery banner
#   [N] ARIA labels, skip-link, focus management, reduced-motion support
#
# CLINICAL DISCLAIMER (kept from backend): EA thresholds 30/45 kcal/kg FFM/day
# per IOC RED-S consensus (Mountjoy et al., 2018). Screening tool only — this
# console does not diagnose. Always confirm with qualified medical staff.
################################################################################

## =============================================================================
## 0 · OPTIONS & CAPABILITY MATRIX (collapse-free package loading)
## =============================================================================

options(
  shiny.port            = 3838,
  shiny.maxRequestSize  = 60 * 1024^2,   # 60 MB CSV uploads
  shiny.reactlog        = FALSE,
  stringsAsFactors      = FALSE,
  scipen                = 999,
  OutDec                = ".",           # overridden per-locale at runtime
  warn                  = 1
)

Sys.setlocale("LC_COLLATE", "C")          # stable sorting across locales

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (is.atomic(a) && all(is.na(a)))) b else a

suppressPackageStartupMessages({
  library(shiny)
  library(jsonlite)
  library(httr)
  if (requireNamespace("DBI", quietly = TRUE)) library(DBI)
  if (requireNamespace("RSQLite", quietly = TRUE)) library(RSQLite)
  if (requireNamespace("plotly", quietly = TRUE)) library(plotly)
  if (requireNamespace("DT", quietly = TRUE)) library(DT)
  if (requireNamespace("bslib", quietly = TRUE)) library(bslib)
  if (requireNamespace("shinyWidgets", quietly = TRUE)) library(shinyWidgets)
  if (requireNamespace("shinyjs", quietly = TRUE)) library(shinyjs)
  if (requireNamespace("dplyr", quietly = TRUE)) library(dplyr)
})

# Optional-package capability matrix. Required: shiny, jsonlite, httr.
CAP <- new.env(parent = emptyenv())
CAP$bslib   <- requireNamespace("bslib",        quietly = TRUE)
CAP$DT      <- requireNamespace("DT",           quietly = TRUE)
CAP$plotly  <- requireNamespace("plotly",       quietly = TRUE)
CAP$shinyjs <- requireNamespace("shinyjs",      quietly = TRUE)
CAP$sw      <- requireNamespace("shinyWidgets", quietly = TRUE)
CAP$dplyr   <- requireNamespace("dplyr",        quietly = TRUE)

pkg <- function(name) {
  ns <- list(
    bslib = "bslib", DT = "DT", plotly = "plotly", shinyjs = "shinyjs",
    sw = "shinyWidgets", dplyr = "dplyr"
  )
  if (!requireNamespace(ns[[name]], quietly = TRUE)) return(NULL)
  asNamespace(ns[[name]])
}

safe_library_shinyjs <- function() {
  if (CAP$shinyjs) { library(shinyjs); return(TRUE) }
  FALSE
}

## =============================================================================
## 1 · GLOBAL CONSTANTS
## =============================================================================

ATHENA_VERSION  <- "1.0"
ATHENA_BUILD    <- "STABLE"
CLASSIFICATION  <- "CLASSIFICATION: RESTRICTED"

API_BASE_DEFAULT <- Sys.getenv("ATHENA_API_URL", "http://localhost:8000")

# Readiness banding (mirrors index.html thresholds)
READY_GREEN <- 75; READY_AMBER <- 50
# IOC RED-S energy-availability banding
EA_OPTIMAL <- 45; EA_CRITICAL <- 30
# ACWR zones (Gabbett 2016 / Williams 2017)
ACWR_LOW <- 0.8; ACWR_SWEET <- 1.3; ACWR_DANGER <- 1.5

TAG_DEFS <- list(
  list(key = "injured",  label = "INJURED",    color = "#FF2244"),
  list(key = "reds",     label = "RED-S",      color = "#E85D04"),
  list(key = "returning",label = "RETURN-TO-PLAY", color = "#FFAA00"),
  list(key = "monitor",  label = "MONITOR",    color = "#9D4EDD"),
  list(key = "elite",    label = "ELITE",      color = "#00E5FF"),
  list(key = "captain",  label = "CAPTAIN",    color = "#2D6A4F")
)
MAX_CUSTOM_TAGS <- 10L

AVATAR_COLORS <- c(
  "#00E5FF", "#00FF88", "#FFAA00", "#FF2244", "#E91E63",
  "#9D4EDD", "#4CC9F0", "#80ED99", "#F4A261", "#E76F51",
  "#06B6D4", "#A78BFA", "#FBBF24", "#34D399", "#F87171"
)

SPORTS <- c("Endurance", "Team Sport", "Sprint", "Swimming", "Cycling",
            "Strength", "Combat", "Para Sport")

EXERCISE_MET <- c(
  run = 9.8, cycle = 7.5, swim = 8.0, row = 7.0, squat = 5.0,
  bench_press = 4.5, deadlift = 6.0, basketball = 8.0, soccer = 9.0, tennis = 7.5
)

EXERCISE_TYPES <- c("run", "cycle", "swim", "row", "squat", "bench_press",
                    "deadlift", "basketball", "soccer", "tennis")

CYCLE_PHASES  <- c("menstrual", "follicular", "ovulatory", "luteal")

TICKER_MAX        <- 60L
NOTIF_MAX         <- 40L
THERMAL_HIST_MAX  <- 120L
DEMO_ATHLETES     <- 15L
DEMO_DAYS         <- 42L

## =============================================================================
## 2 · I18N — 10 LANGUAGES (en hi es fr de pt ar ru sw zh)
## =============================================================================

LANG_CODES <- c("en", "hi", "es", "fr", "de", "pt", "ar", "ru", "sw", "zh")
LANG_NAMES <- c(
  en = "English", hi = "हिन्दी", es = "Español", fr = "Français",
  de = "Deutsch", pt = "Português", ar = "العربية", ru = "Русский",
  sw = "Kiswahili", zh = "中文"
)
RTL_LANGS <- c("ar")
DECIMAL_COMMA <- c("es", "fr", "de", "pt", "ru")

I18N <- list()

I18N$en <- c(
  appTitle = "A.T.H.E.N.A.", headerSubtitle = "Adaptive Telemetry · Health · Evidence-Based Nutrition",
  statusOnline = "SYSTEMS NOMINAL", statusOffline = "OFFLINE · DEMO MODE", statusConnecting = "CONNECTING",
  sync = "SYNC", export = "EXPORT", alert = "ALERT", language = "LANGUAGE", theme = "THEME",
  crt = "CRT", sound = "SOUND", login = "LOGIN", logout = "LOGOUT", register = "REGISTER", demo = "DEMO",
  userId = "User ID", password = "Password", loginTitle = "ATHENA LOGIN",
  qbReadiness = "AVG READINESS", qbLoad = "AVG LOAD", qbAtRisk = "AT RISK", qbReds = "RED-S FLAGS",
  tabDashboard = "Dashboard", tabRoster = "Roster", tabAthlete = "Athlete Detail", tabReds = "RED-S Lab",
  tabCohort = "Cohort", tabData = "Data Ops", tabSystem = "System", tabSettings = "Settings",
  roster = "ATHLETE ROSTER", searchRoster = "Search athletes…", filterAll = "All", filterGreen = "Optimal",
  filterAmber = "Caution", filterRed = "Danger", filterFemale = "Female", filterMale = "Male",
  groupNone = "List", groupSport = "Sport", groupRisk = "Risk", viewCards = "CARDS", viewTable = "TABLE",
  noResults = "No athletes match filter", paused = "PAUSED", addTag = "Add tag", tagManager = "Tag manager",
  tagName = "Tag name", tagColor = "Colour", createTag = "Create", deleteTag = "Delete", maxTags = "Maximum 10 custom tags",
  hudVo2 = "VO₂ MAX", hudHr = "HEART RATE", hudPower = "POWER OUTPUT", hudReadiness = "READINESS",
  perfTrend = "PERFORMANCE TREND · 12 WEEKS", readinessTrend = "READINESS TREND", loadMatrix = "TRAINING LOAD MATRIX",
  sleepArchitecture = "SLEEP ARCHITECTURE", riskMatrix = "INJURY RISK MATRIX", wellnessRadar = "ATHLETE PROFILE",
  eventLog = "EVENT LOG", aiRecs = "CLINICAL DECISION SUPPORT (CDSS)", cohortStats = "COHORT STATISTICS",
  sessionControl = "SESSION CONTROL", csvImport = "CSV IMPORT", csvDrop = "Drop CSV here or click to upload",
  phase = "PHASE", load = "LOAD", fatigue = "FATIGUE", pause = "PAUSE", resume = "RESUME", end = "END",
  live = "LIVE", liveSim = "LIVE SIM", on = "ON", off = "OFF", totalAthletes = "Athletes", totalRecords = "Records",
  avgLoad = "Avg load", avgRpe = "Avg RPE", avgSleep = "Avg sleep", males = "Males", females = "Females",
  latestData = "Latest data", readiness = "Readiness", sleepH = "Sleep (h)", sleepQuality = "Sleep quality",
  stress = "Stress", soreness = "Soreness", mood = "Mood", rpe = "RPE", dailyLoad = "Daily load",
  calories = "Calories", ffm = "FFM (kg)", cyclePhase = "Cycle phase", pain = "Pain", injuryLocation = "Injury location",
  overview = "OVERVIEW", eaTrendTitle = "ENERGY AVAILABILITY TREND", forecast = "FORECAST", days = "days",
  cycleTimeline = "MENSTRUAL CYCLE TIMELINE", fertilityWindow = "Fertility Window", trainingAdapt = "Training Adaptation",
  phaseRec = "Phase Recommendation", menstrual = "MENSTRUAL", follicular = "FOLLICULAR", ovulatory = "OVULATORY",
  luteal = "LUTEAL", na_ = "—", notes = "COACH NOTES", addNote = "Add note", notePlaceholder = "Type a note…",
  undo = "Undo", redo = "Redo", delete = "Delete", report = "REPORT", downloadReport = "Download report",
  dataCompleteness = "DATA COMPLETENESS", rpeValidity = "RPE VALIDITY", injuryForecast = "INJURY FORECAST",
  boneHealth = "Bone health", aclRisk = "ACL risk", perfScore = "PERFORMANCE SCORE",
  checkin = "CHECK-IN", checkinTitle = "DAILY CHECK-IN ·", submit = "SUBMIT", cancel = "CANCEL",
  checkinSaved = "Check-in submitted", checkinError = "Submission failed", duration = "Duration (min)",
  exerciseType = "Exercise type", blockTag = "Training block tag", reflection = "Reflection",
  redsLab = "RED-S RISK CALCULATOR", eaFormula = "EA = (Intake − Exercise) / FFM", eaValue = "Energy Availability",
  riskScore = "Risk Score", lowRisk = "LOW RISK", modRisk = "MODERATE", highRisk = "HIGH RISK",
  optimal45 = "Optimal (≥45)", caution3045 = "Caution (30–45)", critical30 = "Critical (<30)",
  factors = "Contributing Factors", clinicalRec = "Clinical Recommendation", scenario = "SCENARIO",
  intake = "Intake (kcal)", exerciseKcal = "Exercise cost (kcal)", netEEE = "Net EEE", lutealPenalty = "Luteal penalty",
  cohortReds = "COHORT RED-S DISTRIBUTION", bodyMass = "Body mass (kg)", gender = "Gender", male = "Male",
  female = "Female", clinicalCaveat = "EA thresholds (30, 45 kcal/kg FFM/day) per IOC RED-S Consensus (Mountjoy et al., 2018). Screening tool only.",
  compare = "ATHLETE COMPARISON", compareHint = "Select up to 4 athletes", squadHeatmap = "SQUAD LOAD HEATMAP",
  acwrTitle = "ACUTE:CHRONIC WORKLOAD", acwrZone = "Zone", monotonyTitle = "MONOTONY & STRAIN (7-DAY)",
  wfRatio = "WELLNESS:FATIGUE RATIO", importData = "IMPORT", preview = "Preview", upload = "Upload to backend",
  uploadOk = "Upload accepted", uploadFail = "Upload failed", taskQueued = "Task queued",
  exportCsv = "CSV export", exportJson = "JSON export", researchExport = "RESEARCH export",
  systemStatus = "SYSTEM STATUS", opMode = "Operating Mode", mlPipeline = "COMPUTATIONAL ENGINE", localLlm = "Local LLM",
  cpu = "CPU", memory = "Memory", disk = "Disk", thermalGuard = "THERMAL GUARD", cpuTemp = "CPU temp",
  battery = "Power", modeFull = "FULL", modeStandard = "STANDARD", modeReduced = "REDUCED",
  modeMinimal = "MINIMAL", modeEmergency = "EMERGENCY", healthCheck = "HEALTH CHECK", diagnostics = "ENDPOINT DIAGNOSTICS",
  latency = "Latency", ok = "PASS", fail = "FAIL", alertCenter = "ALERT CENTER", ackAll = "Acknowledge all",
  acknowledge = "Acknowledge", critical = "CRITICAL", warning = "WARNING", info = "INFO", noAlerts = "No active alerts",
  settings = "SETTINGS", apiUrl = "Backend API URL", apiToken = "Bearer token (JWT)",
  refreshToken = "Auto-refresh (seconds)", refreshOff = "Off", units = "Units", metric = "Metric", imperial = "Imperial",
  compact = "Compact layout", save = "SAVE", saved = "Saved", reset = "Reset defaults", shortcuts = "Keyboard shortcuts",
  about = "About", minReadiness = "Amber below readiness", autoDemo = "Auto demo-mode on connection loss",
  loading = "Loading", errorOccurred = "Something went wrong", retry = "Retry", offlineDemo = "Backend unreachable — running on synthetic demo data",
  connected = "Connected", disconnected = "Disconnected", updated = "Updated", close = "Close",
  shortcutsHint = "1-8 tabs · Ctrl+K search · R refresh · T theme · L language · S live-sim · ? help",
  generatedBy = "Generated by", page = "Page", athleteCount = "athletes", selectPlaceholder = "Select…",
  markAllRead = "Clear all", notifications = "Notifications", noNotifications = "Nothing new",
  cmdPlaceholder = "Search athletes, actions, panels…", cmdNavigate = "navigate", cmdSelect = "select",
  swReady = "Sleep weight", readinessBreakdown = "READINESS COMPOSITION", weightNote = "Composite: sleep 35% · fatigue 20% · soreness 15% · stress 15% · pain 15%",
  eaForecastNote = "7-day projection", stool = "Insufficient data", bannerDemo = "DEMO DATA",
  connectionLost = "Connection lost — retrying", recovered = "Backend recovered",
  rosterN = "N", spark = "7-day sparkline", lastCheckin = "Last check-in", never = "Never",
  filterChips = "Filters", groupBy = "Group by", exportPng = "PNG", printReport = "Print report",
  aboutText = "ATHENA v1 — elite sports science operations console for telemetry, health, and evidence-based nutrition. Local and distributed analytics engine."
)

I18N$hi <- c(
  appTitle = "ए.टी.एच.ई.एन.ए.", headerSubtitle = "अनुकूली टेलीमेट्री · स्वास्थ्य · प्रमाण-आधारित पोषण",
  statusOnline = "सिस्टम सामान्य", statusOffline = "ऑफ़लाइन · डेमो मोड", statusConnecting = "कनेक्ट हो रहा है",
  sync = "सिंक", export = "निर्यात", alert = "अलर्ट", language = "भाषा", theme = "थीम",
  crt = "सीआरटी", sound = "ध्वनि", login = "लॉगिन", logout = "लॉगआउट", register = "पंजीकरण", demo = "डेमो",
  userId = "उपयोगकर्ता आईडी", password = "पासवर्ड", loginTitle = "एथेना लॉगिन",
  qbReadiness = "औसत तत्परता", qbLoad = "औसत भार", qbAtRisk = "जोखिम में", qbReds = "RED-S झंडे",
  tabDashboard = "डैशबोर्ड", tabRoster = "रोस्टर", tabAthlete = "एथलीट विवरण", tabReds = "RED-S लैब",
  tabCohort = "समूह", tabData = "डेटा", tabSystem = "सिस्टम", tabSettings = "सेटिंग्स",
  roster = "एथलीट सूची", searchRoster = "एथलीट खोजें…", filterAll = "सभी", filterGreen = "अनुकूल",
  filterAmber = "सावधानी", filterRed = "खतरा", filterFemale = "महिला", filterMale = "पुरुष",
  groupNone = "सूची", groupSport = "खेल", groupRisk = "जोखिम", viewCards = "कार्ड", viewTable = "तालिका",
  noResults = "कोई एथलीट मेल नहीं खाता", paused = "रुका हुआ", addTag = "टैग जोड़ें", tagManager = "टैग प्रबंधक",
  tagName = "टैग नाम", tagColor = "रंग", createTag = "बनाएँ", deleteTag = "हटाएँ", maxTags = "अधिकतम 10 कस्टम टैग",
  hudVo2 = "VO₂ अधिकतम", hudHr = "हृदय गति", hudPower = "शक्ति उत्पादन", hudReadiness = "तत्परता",
  perfTrend = "प्रदर्शन प्रवृत्ति · 12 सप्ताह", readinessTrend = "तत्परता प्रवृत्ति", loadMatrix = "प्रशिक्षण भार मैट्रिक्स",
  sleepArchitecture = "नींद संरचना", riskMatrix = "चोट जोखिम मैट्रिक्स", wellnessRadar = "एथलीट प्रोफ़ाइल",
  eventLog = "घटना लॉग", aiRecs = "नैदानिक निर्णय समर्थन (CDSS)", cohortStats = "समूह सांख्यिकी",
  sessionControl = "सत्र नियंत्रण", csvImport = "CSV आयात", csvDrop = "CSV यहाँ डालें या क्लिक करें",
  phase = "चरण", load = "भार", fatigue = "थकान", pause = "विराम", resume = "जारी रखें", end = "समाप्त",
  live = "लाइव", liveSim = "लाइव सिम", on = "चालू", off = "बंद", totalAthletes = "एथलीट", totalRecords = "रिकॉर्ड",
  avgLoad = "औसत भार", avgRpe = "औसत RPE", avgSleep = "औसत नींद", males = "पुरुष", females = "महिलाएँ",
  latestData = "नवीनतम डेटा", readiness = "तत्परता", sleepH = "नींद (घंटे)", sleepQuality = "नींद गुणवत्ता",
  stress = "तनाव", soreness = "मांसपेशी दर्द", mood = "मनोदशा", rpe = "RPE", dailyLoad = "दैनिक भार",
  calories = "कैलोरी", ffm = "FFM (कि.ग्रा.)", cyclePhase = "चक्र चरण", pain = "दर्द", injuryLocation = "चोट स्थान",
  overview = "अवलोकन", eaTrendTitle = "ऊर्जा उपलब्धता प्रवृत्ति", forecast = "पूर्वानुमान", days = "दिन",
  cycleTimeline = "मासिक चक्र समयरेखा", fertilityWindow = "उर्वरता विंडो", trainingAdapt = "प्रशिक्षण अनुकूलन",
  phaseRec = "चरण अनुशंसा", menstrual = "मासिक", follicular = "फॉलिक्युलर", ovulatory = "ओवुलेटरी",
  luteal = "ल्यूटियल", na_ = "—", notes = "कोच नोट्स", addNote = "नोट जोड़ें", notePlaceholder = "नोट लिखें…",
  undo = "पूर्ववत", redo = "पुनः करें", delete = "हटाएँ", report = "रिपोर्ट", downloadReport = "रिपोर्ट डाउनलोड करें",
  dataCompleteness = "डेटा पूर्णता", rpeValidity = "RPE वैधता", injuryForecast = "चोट पूर्वानुमान",
  boneHealth = "हड्डी स्वास्थ्य", aclRisk = "ACL जोखिम", perfScore = "प्रदर्शन स्कोर",
  checkin = "चेक-इन", checkinTitle = "दैनिक चेक-इन ·", submit = "जमा करें", cancel = "रद्द करें",
  checkinSaved = "चेक-इन जमा हुआ", checkinError = "जमा करना विफल", duration = "अवधि (मिनट)",
  exerciseType = "व्यायाम प्रकार", blockTag = "प्रशिक्षण ब्लॉक टैग", reflection = "प्रतिबिंब",
  redsLab = "RED-S जोखिम कैलकुलेटर", eaFormula = "EA = (सेवन − व्यायाम) / FFM", eaValue = "ऊर्जा उपलब्धता",
  riskScore = "जोखिम स्कोर", lowRisk = "कम जोखिम", modRisk = "मध्यम", highRisk = "उच्च जोखिम",
  optimal45 = "इष्टतम (≥45)", caution3045 = "सावधानी (30–45)", critical30 = "गंभीर (<30)",
  factors = "योगदान कारक", clinicalRec = "नैदानिक अनुशंसा", scenario = "परिदृश्य",
  intake = "सेवन (kcal)", exerciseKcal = "व्यायाम लागत (kcal)", netEEE = "शुद्ध EEE", lutealPenalty = "ल्यूटियल दंड",
  cohortReds = "समूह RED-S वितरण", bodyMass = "शरीर का वज़न (कि.ग्रा.)", gender = "लिंग", male = "पुरुष",
  female = "महिला", clinicalCaveat = "EA सीमाएँ (30, 45 kcal/kg FFM/दिन) IOC RED-S सर्वसम्मति (Mountjoy et al., 2018) के अनुसार। केवल जाँच उपकरण।",
  compare = "एथलीट तुलना", compareHint = "4 एथलीटों तक चुनें", squadHeatmap = "टीम भार हीटमैप",
  acwrTitle = "तीव्र:पुराना कार्यभार", acwrZone = "क्षेत्र", monotonyTitle = "एकरसता और तनाव (7-दिन)",
  wfRatio = "कल्याण:थकान अनुपात", importData = "आयात", preview = "पूर्वावलोकन", upload = "बैकएंड पर अपलोड",
  uploadOk = "अपलोड स्वीकृत", uploadFail = "अपलोड विफल", taskQueued = "कार्य कतार में",
  exportCsv = "CSV निर्यात", exportJson = "JSON निर्यात", researchExport = "अनुसंधान निर्यात",
  systemStatus = "सिस्टम स्थिति", opMode = "ऑपरेटिंग मोड", mlPipeline = "कंप्यूटेशनल इंजन", localLlm = "स्थानीय LLM",
  cpu = "सीपीयू", memory = "मेमोरी", disk = "डिस्क", thermalGuard = "थर्मल गार्ड", cpuTemp = "सीपीयू तापमान",
  battery = "शक्ति", modeFull = "पूर्ण", modeStandard = "मानक", modeReduced = "घटा हुआ",
  modeMinimal = "न्यूनतम", modeEmergency = "आपातकाल", healthCheck = "स्वास्थ्य जाँच", diagnostics = "एंडपॉइंट निदान",
  latency = "विलंबता", ok = "उत्तीर्ण", fail = "असफल", alertCenter = "अलर्ट केंद्र", ackAll = "सभी स्वीकारें",
  acknowledge = "स्वीकारें", critical = "गंभीर", warning = "चेतावनी", info = "सूचना", noAlerts = "कोई सक्रिय अलर्ट नहीं",
  settings = "सेटिंग्स", apiUrl = "बैकएंड API URL", apiToken = "बेयर टोकन (JWT)",
  refreshToken = "स्वतः ताज़ा (सेकंड)", refreshOff = "बंद", units = "इकाइयाँ", metric = "मीट्रिक", imperial = "इंपीरियल",
  compact = "संकुचित लेआउट", save = "सहेजें", saved = "सहेजा गया", reset = "डिफ़ॉल्ट रीसेट", shortcuts = "कीबोर्ड शॉर्टकट",
  about = "परिचय", minReadiness = "एम्बर सीमा से नीचे तत्परता", autoDemo = "कनेक्शन टूटने पर डेमो मोड",
  loading = "लोड हो रहा है", errorOccurred = "कुछ गलत हो गया", retry = "पुनः प्रयास", offlineDemo = "बैकएंड अनुपलब्ध — सिंथेटिक डेमो डेटा चल रहा है",
  connected = "कनेक्टेड", disconnected = "डिस्कनेक्टेड", updated = "अद्यतन", close = "बंद करें",
  shortcutsHint = "1-8 टैब · Ctrl+K खोज · R रिफ्रेश · T थीम · L भाषा · S लाइव-सिम · ? सहायता",
  generatedBy = "द्वारा निर्मित", page = "पृष्ठ", athleteCount = "एथलीट", selectPlaceholder = "चुनें…",
  markAllRead = "सभी हटाएँ", notifications = "सूचनाएँ", noNotifications = "कुछ नया नहीं",
  cmdPlaceholder = "एथलीट, क्रियाएँ, पैनल खोजें…", cmdNavigate = "नेविगेट", cmdSelect = "चुनें",
  swReady = "नींद भार", readinessBreakdown = "तत्परता संरचना", weightNote = "संयुक्त: नींद 35% · थकान 20% · दर्द 15% · तनाव 15% · दर्द 15%",
  eaForecastNote = "7-दिन का अनुमान", stool = "अपर्याप्त डेटा", bannerDemo = "डेमो डेटा",
  connectionLost = "कनेक्शन टूटा — पुनः प्रयास", recovered = "बैकएंड पुनर्प्राप्त",
  rosterN = "N", spark = "7-दिन स्पार्कलाइन", lastCheckin = "अंतिम चेक-इन", never = "कभी नहीं",
  filterChips = "फ़िल्टर", groupBy = "समूहीकरण", exportPng = "PNG", printReport = "रिपोर्ट प्रिंट करें",
  aboutText = "ATHENA v1 — टेलीमेट्री, स्वास्थ्य और साक्ष्य-आधारित पोषण के लिए खेल विज्ञान संचालन कंसोल।"
)

I18N$es <- c(
  appTitle = "A.T.H.E.N.A.", headerSubtitle = "Telemetría Adaptativa · Salud · Nutrición Basada en Evidencia",
  statusOnline = "SISTEMAS NOMINALES", statusOffline = "SIN CONEXIÓN · MODO DEMO", statusConnecting = "CONECTANDO",
  sync = "SINCR", export = "EXPORTAR", alert = "ALERTA", language = "IDIOMA", theme = "TEMA",
  crt = "CRT", sound = "SONIDO", login = "ENTRAR", logout = "SALIR", register = "REGISTRO", demo = "DEMO",
  userId = "ID de usuario", password = "Contraseña", loginTitle = "INICIO ATHENA",
  qbReadiness = "DISP. MEDIA", qbLoad = "CARGA MEDIA", qbAtRisk = "EN RIESGO", qbReds = "ALERTAS RED-S",
  tabDashboard = "Panel", tabRoster = "Plantilla", tabAthlete = "Detalle Atleta", tabReds = "Laboratorio RED-S",
  tabCohort = "Cohorte", tabData = "Datos", tabSystem = "Sistema", tabSettings = "Ajustes",
  roster = "PLANTILLA DE ATLETAS", searchRoster = "Buscar atletas…", filterAll = "Todos", filterGreen = "Óptimo",
  filterAmber = "Precaución", filterRed = "Peligro", filterFemale = "Femenino", filterMale = "Masculino",
  groupNone = "Lista", groupSport = "Deporte", groupRisk = "Riesgo", viewCards = "TARJETAS", viewTable = "TABLA",
  noResults = "Ningún atleta coincide", paused = "PAUSADO", addTag = "Añadir etiqueta", tagManager = "Gestor de etiquetas",
  tagName = "Nombre", tagColor = "Color", createTag = "Crear", deleteTag = "Eliminar", maxTags = "Máximo 10 etiquetas",
  hudVo2 = "VO₂ MÁX", hudHr = "FREC. CARDÍACA", hudPower = "POTENCIA", hudReadiness = "DISPONIBILIDAD",
  perfTrend = "TENDENCIA DE RENDIMIENTO · 12 SEMANAS", readinessTrend = "TENDENCIA DE DISPONIBILIDAD", loadMatrix = "MATRIZ DE CARGA",
  sleepArchitecture = "ARQUITECTURA DEL SUEÑO", riskMatrix = "MATRIZ DE RIESGO DE LESIÓN", wellnessRadar = "PERFIL DEL ATLETA",
  eventLog = "REGISTRO DE EVENTOS", aiRecs = "SOPORTE DECISIÓN CLÍNICA (CDSS)", cohortStats = "ESTADÍSTICAS DE COHORTE",
  sessionControl = "CONTROL DE SESIÓN", csvImport = "IMPORTAR CSV", csvDrop = "Suelta un CSV o haz clic",
  phase = "FASE", load = "CARGA", fatigue = "FATIGA", pause = "PAUSA", resume = "REANUDAR", end = "FIN",
  live = "EN VIVO", liveSim = "SIM EN VIVO", on = "ACT", off = "DES", totalAthletes = "Atletas", totalRecords = "Registros",
  avgLoad = "Carga media", avgRpe = "RPE medio", avgSleep = "Sueño medio", males = "Hombres", females = "Mujeres",
  latestData = "Últimos datos", readiness = "Disponibilidad", sleepH = "Sueño (h)", sleepQuality = "Calidad de sueño",
  stress = "Estrés", soreness = "Dolor muscular", mood = "Ánimo", rpe = "RPE", dailyLoad = "Carga diaria",
  calories = "Calorías", ffm = "MMG (kg)", cyclePhase = "Fase del ciclo", pain = "Dolor", injuryLocation = "Lugar de lesión",
  overview = "RESUMEN", eaTrendTitle = "TENDENCIA DE DISPONIBILIDAD ENERGÉTICA", forecast = "PRONÓSTICO", days = "días",
  cycleTimeline = "CRONOLOGÍA DEL CICLO MENSTRUAL", fertilityWindow = "Ventana Fértil", trainingAdapt = "Adaptación al Entrenamiento",
  phaseRec = "Recomendación de Fase", menstrual = "MENSTRUAL", follicular = "FOLICULAR", ovulatory = "OVULATORIA",
  luteal = "LÚTEA", na_ = "—", notes = "NOTAS DEL ENTRENADOR", addNote = "Añadir nota", notePlaceholder = "Escribe una nota…",
  undo = "Deshacer", redo = "Rehacer", delete = "Eliminar", report = "INFORME", downloadReport = "Descargar informe",
  dataCompleteness = "COMPLETITUD DE DATOS", rpeValidity = "VALIDEZ RPE", injuryForecast = "PRONÓSTICO DE LESIÓN",
  boneHealth = "Salud ósea", aclRisk = "Riesgo LCA", perfScore = "PUNTUACIÓN DE RENDIMIENTO",
  checkin = "REGISTRO", checkinTitle = "REGISTRO DIARIO ·", submit = "ENVIAR", cancel = "CANCELAR",
  checkinSaved = "Registro enviado", checkinError = "Error al enviar", duration = "Duración (min)",
  exerciseType = "Tipo de ejercicio", blockTag = "Etiqueta de bloque", reflection = "Reflexión",
  redsLab = "CALCULADORA DE RIESGO RED-S", eaFormula = "DE = (Ingesta − Ejercicio) / MMG", eaValue = "Disponibilidad Energética",
  riskScore = "Puntuación de Riesgo", lowRisk = "RIESGO BAJO", modRisk = "MODERADO", highRisk = "RIESGO ALTO",
  optimal45 = "Óptimo (≥45)", caution3045 = "Precaución (30–45)", critical30 = "Crítico (<30)",
  factors = "Factores Contribuyentes", clinicalRec = "Recomendación Clínica", scenario = "ESCENARIO",
  intake = "Ingesta (kcal)", exerciseKcal = "Coste de ejercicio (kcal)", netEEE = "EEE neta", lutealPenalty = "Penalización lútea",
  cohortReds = "DISTRIBUCIÓN RED-S DE COHORTE", bodyMass = "Peso corporal (kg)", gender = "Sexo", male = "Masculino",
  female = "Femenino", clinicalCaveat = "Umbrales de DE (30, 45 kcal/kg MMG/día) según Consenso IOC RED-S (Mountjoy et al., 2018). Solo cribado.",
  compare = "COMPARACIÓN DE ATLETAS", compareHint = "Selecciona hasta 4 atletas", squadHeatmap = "MAPA DE CARGA DEL EQUIPO",
  acwrTitle = "CARGA AGUDA:CRÓNICA", acwrZone = "Zona", monotonyTitle = "MONOTONÍA Y TENSIÓN (7 DÍAS)",
  wfRatio = "RELACIÓN BIENESTAR:FATIGA", importData = "IMPORTAR", preview = "Vista previa", upload = "Subir al backend",
  uploadOk = "Subida aceptada", uploadFail = "Subida fallida", taskQueued = "Tarea en cola",
  exportCsv = "Exportar CSV", exportJson = "Exportar JSON", researchExport = "EXPORTAR INVESTIGACIÓN",
  systemStatus = "ESTADO DEL SISTEMA", opMode = "Modo de Operación", mlPipeline = "MOTOR COMPUTACIONAL", localLlm = "LLM Local",
  cpu = "CPU", memory = "Memoria", disk = "Disco", thermalGuard = "PROTECCIÓN TÉRMICA", cpuTemp = "Temp. CPU",
  battery = "Energía", modeFull = "COMPLETO", modeStandard = "ESTÁNDAR", modeReduced = "REDUCIDO",
  modeMinimal = "MÍNIMO", modeEmergency = "EMERGENCIA", healthCheck = "CHEQUEO DE SALUD", diagnostics = "DIAGNÓSTICO DE ENDPOINTS",
  latency = "Latencia", ok = "PASA", fail = "FALLA", alertCenter = "CENTRO DE ALERTAS", ackAll = "Confirmar todas",
  acknowledge = "Confirmar", critical = "CRÍTICA", warning = "ADVERTENCIA", info = "INFO", noAlerts = "Sin alertas activas",
  settings = "AJUSTES", apiUrl = "URL del backend", apiToken = "Token Bearer (JWT)",
  refreshToken = "Auto-refresco (segundos)", refreshOff = "Apagado", units = "Unidades", metric = "Métrico", imperial = "Imperial",
  compact = "Diseño compacto", save = "GUARDAR", saved = "Guardado", reset = "Restablecer", shortcuts = "Atajos de teclado",
  about = "Acerca de", minReadiness = "Ámbar por debajo de disponibilidad", autoDemo = "Demo automática si se pierde conexión",
  loading = "Cargando", errorOccurred = "Algo salió mal", retry = "Reintentar", offlineDemo = "Backend inalcanzable — datos sintéticos de demostración",
  connected = "Conectado", disconnected = "Desconectado", updated = "Actualizado", close = "Cerrar",
  shortcutsHint = "1-8 pestañas · Ctrl+K buscar · R refrescar · T tema · L idioma · S sim · ? ayuda",
  generatedBy = "Generado por", page = "Página", athleteCount = "atletas", selectPlaceholder = "Seleccionar…",
  markAllRead = "Borrar todo", notifications = "Notificaciones", noNotifications = "Nada nuevo",
  cmdPlaceholder = "Buscar atletas, acciones, paneles…", cmdNavigate = "navegar", cmdSelect = "elegir",
  swReady = "Peso del sueño", readinessBreakdown = "COMPOSICIÓN DE DISPONIBILIDAD", weightNote = "Compuesto: sueño 35% · fatiga 20% · dolor 15% · estrés 15% · dolor 15%",
  eaForecastNote = "proyección 7 días", stool = "Datos insuficientes", bannerDemo = "DATOS DEMO",
  connectionLost = "Conexión perdida — reintentando", recovered = "Backend recuperado",
  rosterN = "N", spark = "Chispa 7 días", lastCheckin = "Último registro", never = "Nunca",
  filterChips = "Filtros", groupBy = "Agrupar por", exportPng = "PNG", printReport = "Imprimir informe",
  aboutText = "ATHENA v1 — consola de operaciones de ciencias del deporte para telemetría, salud y nutrición basada en evidencia."
)

I18N$fr <- c(
  appTitle = "A.T.H.E.N.A.", headerSubtitle = "Télémétrie Adaptative · Santé · Nutrition Fondée sur les Preuves",
  statusOnline = "SYSTÈMES NOMINAUX", statusOffline = "HORS LIGNE · MODE DÉMO", statusConnecting = "CONNEXION",
  sync = "SYNCHRO", export = "EXPORTER", alert = "ALERTE", language = "LANGUE", theme = "THÈME",
  crt = "CRT", sound = "SON", login = "CONNEXION", logout = "DÉCONNEXION", register = "INSCRIPTION", demo = "DÉMO",
  userId = "ID utilisateur", password = "Mot de passe", loginTitle = "CONNEXION ATHENA",
  qbReadiness = "DISPO. MOYENNE", qbLoad = "CHARGE MOYENNE", qbAtRisk = "À RISQUE", qbReds = "SIGNAUX RED-S",
  tabDashboard = "Tableau", tabRoster = "Effectif", tabAthlete = "Fiche Athlète", tabReds = "Labo RED-S",
  tabCohort = "Cohorte", tabData = "Données", tabSystem = "Système", tabSettings = "Réglages",
  roster = "EFFECTIF D'ATHLÈTES", searchRoster = "Rechercher des athlètes…", filterAll = "Tous", filterGreen = "Optimal",
  filterAmber = "Vigilance", filterRed = "Danger", filterFemale = "Femme", filterMale = "Homme",
  groupNone = "Liste", groupSport = "Sport", groupRisk = "Risque", viewCards = "CARTES", viewTable = "TABLEAU",
  noResults = "Aucun athlète correspondant", paused = "SUSPENDU", addTag = "Ajouter étiquette", tagManager = "Gestion des étiquettes",
  tagName = "Nom", tagColor = "Couleur", createTag = "Créer", deleteTag = "Supprimer", maxTags = "Maximum 10 étiquettes",
  hudVo2 = "VO₂ MAX", hudHr = "FRÉQ. CARDIAQUE", hudPower = "PUISSANCE", hudReadiness = "DISPONIBILITÉ",
  perfTrend = "TENDANCE PERFORMANCE · 12 SEMAINES", readinessTrend = "TENDANCE DISPONIBILITÉ", loadMatrix = "MATRICE DE CHARGE",
  sleepArchitecture = "ARCHITECTURE DU SOMMEIL", riskMatrix = "MATRICE RISQUE DE BLESSURE", wellnessRadar = "PROFIL ATHLÈTE",
  eventLog = "JOURNAL D'ÉVÉNEMENTS", aiRecs = "AIDE À LA DÉCISION CLINIQUE (CDSS)", cohortStats = "STATISTIQUES DE COHORTE",
  sessionControl = "CONTRÔLE DE SÉANCE", csvImport = "IMPORT CSV", csvDrop = "Déposez un CSV ou cliquez",
  phase = "PHASE", load = "CHARGE", fatigue = "FATIGUE", pause = "PAUSE", resume = "REPRENDRE", end = "FIN",
  live = "EN DIRECT", liveSim = "SIM DIRECT", on = "OUI", off = "NON", totalAthletes = "Athlètes", totalRecords = "Enregistrements",
  avgLoad = "Charge moy.", avgRpe = "RPE moy.", avgSleep = "Sommeil moy.", males = "Hommes", females = "Femmes",
  latestData = "Dernières données", readiness = "Disponibilité", sleepH = "Sommeil (h)", sleepQuality = "Qualité de sommeil",
  stress = "Stress", soreness = "Courbatures", mood = "Humeur", rpe = "RPE", dailyLoad = "Charge quotidienne",
  calories = "Calories", ffm = "Masse maigre (kg)", cyclePhase = "Phase du cycle", pain = "Douleur", injuryLocation = "Site de blessure",
  overview = "APERÇU", eaTrendTitle = "TENDANCE DISPONIBILITÉ ÉNERGÉTIQUE", forecast = "PRÉVISION", days = "jours",
  cycleTimeline = "CHRONOLOGIE DU CYCLE MENSTRUEL", fertilityWindow = "Fenêtre Fertile", trainingAdapt = "Adaptation à l'Entraînement",
  phaseRec = "Recommandation de Phase", menstrual = "MENSTRUEL", follicular = "FOLLICULAIRE", ovulatory = "OVULATOIRE",
  luteal = "LUTÉALE", na_ = "—", notes = "NOTES DU COACH", addNote = "Ajouter une note", notePlaceholder = "Saisir une note…",
  undo = "Annuler", redo = "Rétablir", delete = "Supprimer", report = "RAPPORT", downloadReport = "Télécharger le rapport",
  dataCompleteness = "COMPLÉTUDE DES DONNÉES", rpeValidity = "VALIDITÉ RPE", injuryForecast = "PRÉVISION DE BLESSURE",
  boneHealth = "Santé osseuse", aclRisk = "Risque LCA", perfScore = "SCORE DE PERFORMANCE",
  checkin = "POINT QUOTIDIEN", checkinTitle = "POINT QUOTIDIEN ·", submit = "ENVOYER", cancel = "ANNULER",
  checkinSaved = "Point quotidien envoyé", checkinError = "Échec de l'envoi", duration = "Durée (min)",
  exerciseType = "Type d'exercice", blockTag = "Étiquette de bloc", reflection = "Réflexion",
  redsLab = "CALCULATEUR DE RISQUE RED-S", eaFormula = "DE = (Apport − Exercice) / Masse maigre", eaValue = "Disponibilité Énergétique",
  riskScore = "Score de Risque", lowRisk = "RISQUE FAIBLE", modRisk = "MODÉRÉ", highRisk = "RISQUE ÉLEVÉ",
  optimal45 = "Optimal (≥45)", caution3045 = "Prudence (30–45)", critical30 = "Critique (<30)",
  factors = "Facteurs Contributifs", clinicalRec = "Recommandation Clinique", scenario = "SCÉNARIO",
  intake = "Apport (kcal)", exerciseKcal = "Coût exercice (kcal)", netEEE = "EEE nette", lutealPenalty = "Pénalité lutéale",
  cohortReds = "DISTRIBUTION RED-S COHORTE", bodyMass = "Masse corporelle (kg)", gender = "Sexe", male = "Homme",
  female = "Femme", clinicalCaveat = "Seuils de DE (30, 45 kcal/kg masse maigre/jour) selon le Consensus IOC RED-S (Mountjoy et al., 2018). Outil de dépistage uniquement.",
  compare = "COMPARAISON D'ATHLÈTES", compareHint = "Sélectionnez jusqu'à 4 athlètes", squadHeatmap = "CARTE DE CHARGE ÉQUIPE",
  acwrTitle = "CHARGE AIGUË:CHRONIQUE", acwrZone = "Zone", monotonyTitle = "MONOTONIE & TENSION (7 JOURS)",
  wfRatio = "RAPPORT BIENÊTRE:FATIGUE", importData = "IMPORTER", preview = "Aperçu", upload = "Envoyer au backend",
  uploadOk = "Envoi accepté", uploadFail = "Échec de l'envoi", taskQueued = "Tâche en file",
  exportCsv = "Export CSV", exportJson = "Export JSON", researchExport = "EXPORT RECHERCHE",
  systemStatus = "ÉTAT DU SYSTÈME", opMode = "Mode de Fonctionnement", mlPipeline = "MOTEUR DE CALCUL", localLlm = "LLM Local",
  cpu = "CPU", memory = "Mémoire", disk = "Disque", thermalGuard = "PROTECTION THERMIQUE", cpuTemp = "Temp. CPU",
  battery = "Alimentation", modeFull = "COMPLET", modeStandard = "STANDARD", modeReduced = "RÉDUIT",
  modeMinimal = "MINIMAL", modeEmergency = "URGENCE", healthCheck = "BILAN DE SANTÉ", diagnostics = "DIAGNOSTIC DES ENDPOINTS",
  latency = "Latence", ok = "RÉUSSI", fail = "ÉCHEC", alertCenter = "CENTRE D'ALERTES", ackAll = "Tout accuser",
  acknowledge = "Accuser réception", critical = "CRITIQUE", warning = "AVERTISSEMENT", info = "INFO", noAlerts = "Aucune alerte active",
  settings = "RÉGLAGES", apiUrl = "URL du backend", apiToken = "Jeton Bearer (JWT)",
  refreshToken = "Rafraîchissement auto (secondes)", refreshOff = "Désactivé", units = "Unités", metric = "Métrique", imperial = "Impérial",
  compact = "Mise en page compacte", save = "ENREGISTRER", saved = "Enregistré", reset = "Réinitialiser", shortcuts = "Raccourcis clavier",
  about = "À propos", minReadiness = "Ambre sous disponibilité", autoDemo = "Mode démo si connexion perdue",
  loading = "Chargement", errorOccurred = "Une erreur est survenue", retry = "Réessayer", offlineDemo = "Backend injoignable — données de démonstration",
  connected = "Connecté", disconnected = "Déconnecté", updated = "Mis à jour", close = "Fermer",
  shortcutsHint = "1-8 onglets · Ctrl+K recherche · R rafraîchir · T thème · L langue · S sim · ? aide",
  generatedBy = "Généré par", page = "Page", athleteCount = "athlètes", selectPlaceholder = "Choisir…",
  markAllRead = "Tout effacer", notifications = "Notifications", noNotifications = "Rien de neuf",
  cmdPlaceholder = "Rechercher athlètes, actions, panneaux…", cmdNavigate = "naviguer", cmdSelect = "choisir",
  swReady = "Poids sommeil", readinessBreakdown = "COMPOSITION DE LA DISPONIBILITÉ", weightNote = "Composite : sommeil 35% · fatigue 20% · courbatures 15% · stress 15% · douleur 15%",
  eaForecastNote = "projection 7 jours", stool = "Données insuffisantes", bannerDemo = "DONNÉES DÉMO",
  connectionLost = "Connexion perdue — nouvelle tentative", recovered = "Backend rétabli",
  rosterN = "N", spark = "Mini-courbe 7 j", lastCheckin = "Dernier point", never = "Jamais",
  filterChips = "Filtres", groupBy = "Grouper par", exportPng = "PNG", printReport = "Imprimer le rapport",
  aboutText = "ATHENA v1 — console d'opérations de science du sport pour la télémétrie, la santé et la nutrition factuelle."
)

I18N$de <- c(
  appTitle = "A.T.H.E.N.A.", headerSubtitle = "Adaptive Telemetrie · Gesundheit · Evidenzbasierte Ernährung",
  statusOnline = "SYSTEME NOMINAL", statusOffline = "OFFLINE · DEMO-MODUS", statusConnecting = "VERBINDE",
  sync = "SYNC", export = "EXPORT", alert = "ALARM", language = "SPRACHE", theme = "THEMA",
  crt = "CRT", sound = "TON", login = "ANMELDEN", logout = "ABMELDEN", register = "REGISTRIEREN", demo = "DEMO",
  userId = "Benutzer-ID", password = "Passwort", loginTitle = "ATHENA ANMELDUNG",
  qbReadiness = "Ø BEREITSCHAFT", qbLoad = "Ø BELASTUNG", qbAtRisk = "GEFÄHRDET", qbReds = "RED-S-MARKER",
  tabDashboard = "Übersicht", tabRoster = "Kader", tabAthlete = "Athletendetail", tabReds = "RED-S-Labor",
  tabCohort = "Kohorte", tabData = "Daten", tabSystem = "System", tabSettings = "Einstellungen",
  roster = "ATHLETENKADER", searchRoster = "Athleten suchen…", filterAll = "Alle", filterGreen = "Optimal",
  filterAmber = "Vorsicht", filterRed = "Gefahr", filterFemale = "Weiblich", filterMale = "Männlich",
  groupNone = "Liste", groupSport = "Sport", groupRisk = "Risiko", viewCards = "KARTEN", viewTable = "TABELLE",
  noResults = "Keine Athleten gefunden", paused = "PAUSIERT", addTag = "Tag hinzufügen", tagManager = "Tag-Verwaltung",
  tagName = "Name", tagColor = "Farbe", createTag = "Erstellen", deleteTag = "Löschen", maxTags = "Maximal 10 eigene Tags",
  hudVo2 = "VO₂ MAX", hudHr = "HERZFREQUENZ", hudPower = "LEISTUNG", hudReadiness = "BEREITSCHAFT",
  perfTrend = "LEISTUNGSTREND · 12 WOCHEN", readinessTrend = "BEREITSCHAFTSTREND", loadMatrix = "BELASTUNGSMATRIX",
  sleepArchitecture = "SCHLAFARCHITEKTUR", riskMatrix = "VERLETZUNGS-RISIKOMATRIX", wellnessRadar = "ATHLETENPROFIL",
  eventLog = "EREIGNISLOG", aiRecs = "KLINISCHE ENTSCHEIDUNGSHILFE (CDSS)", cohortStats = "KOHORTENSTATISTIK",
  sessionControl = "SESSION-STEUERUNG", csvImport = "CSV-IMPORT", csvDrop = "CSV hierher ziehen oder klicken",
  phase = "PHASE", load = "BELASTUNG", fatigue = "ERMÜDUNG", pause = "PAUSE", resume = "WEITER", end = "ENDE",
  live = "LIVE", liveSim = "LIVE-SIM", on = "AN", off = "AUS", totalAthletes = "Athleten", totalRecords = "Datensätze",
  avgLoad = "Ø Belastung", avgRpe = "Ø RPE", avgSleep = "Ø Schlaf", males = "Männer", females = "Frauen",
  latestData = "Neueste Daten", readiness = "Bereitschaft", sleepH = "Schlaf (h)", sleepQuality = "Schlafqualität",
  stress = "Stress", soreness = "Muskelschmerz", mood = "Stimmung", rpe = "RPE", dailyLoad = "Tagesbelastung",
  calories = "Kalorien", ffm = "FFM (kg)", cyclePhase = "Zyklusphase", pain = "Schmerz", injuryLocation = "Verletzungsort",
  overview = "ÜBERBLICK", eaTrendTitle = "ENERGIEVERFÜGBARKEIT-TREND", forecast = "PROGNOSE", days = "Tage",
  cycleTimeline = "MENSTRUATIONSZYKLUS-ZEITACHSE", fertilityWindow = "Fruchtbares Fenster", trainingAdapt = "Trainingsanpassung",
  phaseRec = "Phasen-Empfehlung", menstrual = "MENSTRUELL", follicular = "FOLLIKULÄR", ovulatory = "OVULATORISCH",
  luteal = "LUTEAL", na_ = "—", notes = "TRAINER-NOTIZEN", addNote = "Notiz hinzufügen", notePlaceholder = "Notiz schreiben…",
  undo = "Rückgängig", redo = "Wiederholen", delete = "Löschen", report = "BERICHT", downloadReport = "Bericht herunterladen",
  dataCompleteness = "DATENVOLLSTÄNDIGKEIT", rpeValidity = "RPE-VALIDITÄT", injuryForecast = "VERLETZUNGSPROGNOSE",
  boneHealth = "Knochengesundheit", aclRisk = "Kreuzband-Risiko", perfScore = "LEISTUNGSSCORE",
  checkin = "CHECK-IN", checkinTitle = "TÄGLICHER CHECK-IN ·", submit = "SENDEN", cancel = "ABBRECHEN",
  checkinSaved = "Check-in gesendet", checkinError = "Senden fehlgeschlagen", duration = "Dauer (min)",
  exerciseType = "Übungstyp", blockTag = "Block-Tag", reflection = "Reflexion",
  redsLab = "RED-S RISIKO-RECHNER", eaFormula = "EV = (Aufnahme − Bewegung) / FFM", eaValue = "Energieverfügbarkeit",
  riskScore = "Risikowert", lowRisk = "NIEDRIGES RISIKO", modRisk = "MODERAT", highRisk = "HOHES RISIKO",
  optimal45 = "Optimal (≥45)", caution3045 = "Vorsicht (30–45)", critical30 = "Kritisch (<30)",
  factors = "Beitragende Faktoren", clinicalRec = "Klinische Empfehlung", scenario = "SZENARIO",
  intake = "Aufnahme (kcal)", exerciseKcal = "Bewegungskosten (kcal)", netEEE = "Netto-EEE", lutealPenalty = "Luteal-Abzug",
  cohortReds = "KOHORTEN-RED-S-VERTEILUNG", bodyMass = "Körpergewicht (kg)", gender = "Geschlecht", male = "Männlich",
  female = "Weiblich", clinicalCaveat = "EV-Schwellen (30, 45 kcal/kg FFM/Tag) gemäß IOC RED-S-Konsens (Mountjoy et al., 2018). Nur Screening-Instrument.",
  compare = "ATHLETENVERGLEICH", compareHint = "Bis zu 4 Athleten wählen", squadHeatmap = "TEAM-BELASTUNGSKARTE",
  acwrTitle = "AKUT:CHRONISCH-BELASTUNG", acwrZone = "Zone", monotonyTitle = "MONOTONIE & STRAIN (7 TAGE)",
  wfRatio = "WOHLBEFINDEN:ERMÜDUNG-QUOTIENT", importData = "IMPORT", preview = "Vorschau", upload = "Zum Backend hochladen",
  uploadOk = "Upload akzeptiert", uploadFail = "Upload fehlgeschlagen", taskQueued = "Aufgabe in Warteschlange",
  exportCsv = "CSV-Export", exportJson = "JSON-Export", researchExport = "FORSCHUNGS-EXPORT",
  systemStatus = "SYSTEMSTATUS", opMode = "Betriebsmodus", mlPipeline = "RECHEN-ENGINE", localLlm = "Lokales LLM",
  cpu = "CPU", memory = "Speicher", disk = "Festplatte", thermalGuard = "THERMALSCHUTZ", cpuTemp = "CPU-Temp.",
  battery = "Strom", modeFull = "VOLL", modeStandard = "STANDARD", modeReduced = "REDUZIERT",
  modeMinimal = "MINIMAL", modeEmergency = "NOTFALL", healthCheck = "HEALTHCHECK", diagnostics = "ENDPUNKT-DIAGNOSE",
  latency = "Latenz", ok = "BESTANDEN", fail = "FEHLER", alertCenter = "ALARMZENTRALE", ackAll = "Alle bestätigen",
  acknowledge = "Bestätigen", critical = "KRITISCH", warning = "WARNUNG", info = "INFO", noAlerts = "Keine aktiven Alarme",
  settings = "EINSTELLUNGEN", apiUrl = "Backend-API-URL", apiToken = "Bearer-Token (JWT)",
  refreshToken = "Auto-Aktualisierung (Sekunden)", refreshOff = "Aus", units = "Einheiten", metric = "Metrisch", imperial = "Imperial",
  compact = "Kompaktes Layout", save = "SPEICHERN", saved = "Gespeichert", reset = "Zurücksetzen", shortcuts = "Tastenkürzel",
  about = "Über", minReadiness = "Gelb unter Bereitschaft", autoDemo = "Demo-Modus bei Verbindungsverlust",
  loading = "Lädt", errorOccurred = "Etwas ist schiefgelaufen", retry = "Erneut versuchen", offlineDemo = "Backend nicht erreichbar — synthetische Demo-Daten aktiv",
  connected = "Verbunden", disconnected = "Getrennt", updated = "Aktualisiert", close = "Schließen",
  shortcutsHint = "1-8 Tabs · Ctrl+K Suche · R Aktualisieren · T Thema · L Sprache · S Sim · ? Hilfe",
  generatedBy = "Erstellt von", page = "Seite", athleteCount = "Athleten", selectPlaceholder = "Auswählen…",
  markAllRead = "Alle löschen", notifications = "Benachrichtigungen", noNotifications = "Nichts Neues",
  cmdPlaceholder = "Athleten, Aktionen, Paneele suchen…", cmdNavigate = "navigieren", cmdSelect = "wählen",
  swReady = "Schlaf-Gewicht", readinessBreakdown = "BEREITSCHAFTS-KOMPOSITION", weightNote = "Komposit: Schlaf 35% · Ermüdung 20% · Muskelschmerz 15% · Stress 15% · Schmerz 15%",
  eaForecastNote = "7-Tage-Projektion", stool = "Unzureichende Daten", bannerDemo = "DEMO-DATEN",
  connectionLost = "Verbindung verloren — neuer Versuch", recovered = "Backend wiederhergestellt",
  rosterN = "N", spark = "7-Tage-Sparkline", lastCheckin = "Letzter Check-in", never = "Nie",
  filterChips = "Filter", groupBy = "Gruppieren nach", exportPng = "PNG", printReport = "Bericht drucken",
  aboutText = "ATHENA v1 — sportwissenschaftliche Betriebskonsole für Telemetrie, Gesundheit und evidenzbasierte Ernährung."
)

I18N$pt <- c(
  appTitle = "A.T.H.E.N.A.", headerSubtitle = "Telemetria Adaptativa · Saúde · Nutrição Baseada em Evidências",
  statusOnline = "SISTEMAS NOMINAIS", statusOffline = "OFFLINE · MODO DEMO", statusConnecting = "CONECTANDO",
  sync = "SINC", export = "EXPORTAR", alert = "ALERTA", language = "IDIOMA", theme = "TEMA",
  crt = "CRT", sound = "SOM", login = "ENTRAR", logout = "SAIR", register = "REGISTRAR", demo = "DEMO",
  userId = "ID do usuário", password = "Senha", loginTitle = "LOGIN ATHENA",
  qbReadiness = "PRONTIDÃO MÉDIA", qbLoad = "CARGA MÉDIA", qbAtRisk = "EM RISCO", qbReds = "MARCADORES RED-S",
  tabDashboard = "Painel", tabRoster = "Plantel", tabAthlete = "Detalhe do Atleta", tabReds = "Lab RED-S",
  tabCohort = "Coorte", tabData = "Dados", tabSystem = "Sistema", tabSettings = "Configurações",
  roster = "PLANTEL DE ATLETAS", searchRoster = "Pesquisar atletas…", filterAll = "Todos", filterGreen = "Ótimo",
  filterAmber = "Atenção", filterRed = "Perigo", filterFemale = "Feminino", filterMale = "Masculino",
  groupNone = "Lista", groupSport = "Esporte", groupRisk = "Risco", viewCards = "CARTÕES", viewTable = "TABELA",
  noResults = "Nenhum atleta corresponde", paused = "PAUSADO", addTag = "Adicionar etiqueta", tagManager = "Gerenciador de etiquetas",
  tagName = "Nome", tagColor = "Cor", createTag = "Criar", deleteTag = "Excluir", maxTags = "Máximo 10 etiquetas",
  hudVo2 = "VO₂ MÁX", hudHr = "FREQ. CARDÍACA", hudPower = "POTÊNCIA", hudReadiness = "PRONTIDÃO",
  perfTrend = "TENDÊNCIA DE DESEMPENHO · 12 SEMANAS", readinessTrend = "TENDÊNCIA DE PRONTIDÃO", loadMatrix = "MATRIZ DE CARGA",
  sleepArchitecture = "ARQUITETURA DO SONO", riskMatrix = "MATRIZ DE RISCO DE LESÃO", wellnessRadar = "PERFIL DO ATLETA",
  eventLog = "REGISTRO DE EVENTOS", aiRecs = "SUPORTE À DECISÃO CLÍNICA (CDSS)", cohortStats = "ESTATÍSTICAS DA COORTE",
  sessionControl = "CONTROLE DE SESSÃO", csvImport = "IMPORTAR CSV", csvDrop = "Solte um CSV ou clique",
  phase = "FASE", load = "CARGA", fatigue = "FADIGA", pause = "PAUSA", resume = "RETOMAR", end = "FIM",
  live = "AO VIVO", liveSim = "SIM AO VIVO", on = "LIG", off = "DES", totalAthletes = "Atletas", totalRecords = "Registros",
  avgLoad = "Carga média", avgRpe = "RPE médio", avgSleep = "Sono médio", males = "Homens", females = "Mulheres",
  latestData = "Dados recentes", readiness = "Prontidão", sleepH = "Sono (h)", sleepQuality = "Qualidade do sono",
  stress = "Estresse", soreness = "Dor muscular", mood = "Humor", rpe = "RPE", dailyLoad = "Carga diária",
  calories = "Calorias", ffm = "MMG (kg)", cyclePhase = "Fase do ciclo", pain = "Dor", injuryLocation = "Local da lesão",
  overview = "VISÃO GERAL", eaTrendTitle = "TENDÊNCIA DE DISPONIBILIDADE ENERGÉTICA", forecast = "PREVISÃO", days = "dias",
  cycleTimeline = "LINHA DO TEMPO DO CICLO MENSTRUAL", fertilityWindow = "Janela Fértil", trainingAdapt = "Adaptação ao Treino",
  phaseRec = "Recomendação de Fase", menstrual = "MENSTRUAL", follicular = "FOLICULAR", ovulatory = "OVULATÓRIA",
  luteal = "LÚTEA", na_ = "—", notes = "NOTAS DO TÉCNICO", addNote = "Adicionar nota", notePlaceholder = "Escreva uma nota…",
  undo = "Desfazer", redo = "Refazer", delete = "Excluir", report = "RELATÓRIO", downloadReport = "Baixar relatório",
  dataCompleteness = "COMPLETUDE DOS DADOS", rpeValidity = "VALIDADE DO RPE", injuryForecast = "PREVISÃO DE LESÃO",
  boneHealth = "Saúde óssea", aclRisk = "Risco LCA", perfScore = "PONTUAÇÃO DE DESEMPENHO",
  checkin = "CHECK-IN", checkinTitle = "CHECK-IN DIÁRIO ·", submit = "ENVIAR", cancel = "CANCELAR",
  checkinSaved = "Check-in enviado", checkinError = "Falha no envio", duration = "Duração (min)",
  exerciseType = "Tipo de exercício", blockTag = "Etiqueta do bloco", reflection = "Reflexão",
  redsLab = "CALCULADORA DE RISCO RED-S", eaFormula = "DE = (Ingestão − Exercício) / MMG", eaValue = "Disponibilidade Energética",
  riskScore = "Escore de Risco", lowRisk = "RISCO BAIXO", modRisk = "MODERADO", highRisk = "RISCO ALTO",
  optimal45 = "Ótimo (≥45)", caution3045 = "Atenção (30–45)", critical30 = "Crítico (<30)",
  factors = "Fatores Contribuintes", clinicalRec = "Recomendação Clínica", scenario = "CENÁRIO",
  intake = "Ingestão (kcal)", exerciseKcal = "Custo do exercício (kcal)", netEEE = "EEE líquida", lutealPenalty = "Penalidade lútea",
  cohortReds = "DISTRIBUIÇÃO RED-S DA COORTE", bodyMass = "Massa corporal (kg)", gender = "Sexo", male = "Masculino",
  female = "Feminino", clinicalCaveat = "Limites de DE (30, 45 kcal/kg MMG/dia) conforme Consenso IOC RED-S (Mountjoy et al., 2018). Apenas triagem.",
  compare = "COMPARAÇÃO DE ATLETAS", compareHint = "Selecione até 4 atletas", squadHeatmap = "MAPA DE CARGA DO ELENCO",
  acwrTitle = "CARGA AGUDA:CRÔNICA", acwrZone = "Zona", monotonyTitle = "MONOTONIA & TENSÃO (7 DIAS)",
  wfRatio = "RELAÇÃO BEM-ESTAR:FADIGA", importData = "IMPORTAR", preview = "Pré-visualizar", upload = "Enviar ao backend",
  uploadOk = "Upload aceito", uploadFail = "Falha no upload", taskQueued = "Tarefa na fila",
  exportCsv = "Exportar CSV", exportJson = "Exportar JSON", researchExport = "EXPORTAR PESQUISA",
  systemStatus = "STATUS DO SISTEMA", opMode = "Modo de Operação", mlPipeline = "MOTOR COMPUTACIONAL", localLlm = "LLM Local",
  cpu = "CPU", memory = "Memória", disk = "Disco", thermalGuard = "PROTEÇÃO TÉRMICA", cpuTemp = "Temp. CPU",
  battery = "Energia", modeFull = "COMPLETO", modeStandard = "PADRÃO", modeReduced = "REDUZIDO",
  modeMinimal = "MÍNIMO", modeEmergency = "EMERGÊNCIA", healthCheck = "CHECAGEM DE SAÚDE", diagnostics = "DIAGNÓSTICO DE ENDPOINTS",
  latency = "Latência", ok = "PASSA", fail = "FALHA", alertCenter = "CENTRAL DE ALERTAS", ackAll = "Confirmar todas",
  acknowledge = "Confirmar", critical = "CRÍTICO", warning = "AVISO", info = "INFO", noAlerts = "Nenhum alerta ativo",
  settings = "CONFIGURAÇÕES", apiUrl = "URL do backend", apiToken = "Token Bearer (JWT)",
  refreshToken = "Auto-atualização (segundos)", refreshOff = "Desligado", units = "Unidades", metric = "Métrico", imperial = "Imperial",
  compact = "Layout compacto", save = "SALVAR", saved = "Salvo", reset = "Redefinir", shortcuts = "Atalhos de teclado",
  about = "Sobre", minReadiness = "Âmbar abaixo da prontidão", autoDemo = "Demo automático ao perder conexão",
  loading = "Carregando", errorOccurred = "Algo deu errado", retry = "Tentar novamente", offlineDemo = "Backend inacessível — dados sintéticos de demonstração",
  connected = "Conectado", disconnected = "Desconectado", updated = "Atualizado", close = "Fechar",
  shortcutsHint = "1-8 abas · Ctrl+K busca · R atualizar · T tema · L idioma · S sim · ? ajuda",
  generatedBy = "Gerado por", page = "Página", athleteCount = "atletas", selectPlaceholder = "Selecionar…",
  markAllRead = "Limpar tudo", notifications = "Notificações", noNotifications = "Nada novo",
  cmdPlaceholder = "Buscar atletas, ações, painéis…", cmdNavigate = "navegar", cmdSelect = "escolher",
  swReady = "Peso do sono", readinessBreakdown = "COMPOSIÇÃO DA PRONTIDÃO", weightNote = "Composto: sono 35% · fadiga 20% · dor 15% · estresse 15% · dor 15%",
  eaForecastNote = "projeção 7 dias", stool = "Dados insuficientes", bannerDemo = "DADOS DEMO",
  connectionLost = "Conexão perdida — tentando novamente", recovered = "Backend recuperado",
  rosterN = "N", spark = "Sparkline 7 dias", lastCheckin = "Último check-in", never = "Nunca",
  filterChips = "Filtros", groupBy = "Agrupar por", exportPng = "PNG", printReport = "Imprimir relatório",
  aboutText = "ATHENA v1 — console de operações em ciências do esporte para telemetria, saúde e nutrição baseada em evidências."
)

I18N$ar <- c(
  appTitle = "أثينا", headerSubtitle = "القياس عن بعد التكيفي · الصحة · التغذية القائمة على الأدلة",
  statusOnline = "الأنظمة طبيعية", statusOffline = "غير متصل · وضع العرض", statusConnecting = "جارٍ الاتصال",
  sync = "مزامنة", export = "تصدير", alert = "تنبيه", language = "اللغة", theme = "المظهر",
  crt = "CRT", sound = "الصوت", login = "دخول", logout = "خروج", register = "تسجيل", demo = "عرض",
  userId = "معرف المستخدم", password = "كلمة المرور", loginTitle = "دخول أثينا",
  qbReadiness = "متوسط الجهوزية", qbLoad = "متوسط الحمل", qbAtRisk = "في الخطر", qbReds = "مؤشرات RED-S",
  tabDashboard = "اللوحة", tabRoster = "القائمة", tabAthlete = "تفاصيل الرياضي", tabReds = "مختبر RED-S",
  tabCohort = "المجموعة", tabData = "البيانات", tabSystem = "النظام", tabSettings = "الإعدادات",
  roster = "قائمة الرياضيين", searchRoster = "ابحث عن الرياضيين…", filterAll = "الكل", filterGreen = "ممتاز",
  filterAmber = "حذر", filterRed = "خطر", filterFemale = "إناث", filterMale = "ذكور",
  groupNone = "قائمة", groupSport = "الرياضة", groupRisk = "الخطر", viewCards = "بطاقات", viewTable = "جدول",
  noResults = "لا يوجد رياضيون مطابقون", paused = "موقوف", addTag = "إضافة وسم", tagManager = "إدارة الوسوم",
  tagName = "الاسم", tagColor = "اللون", createTag = "إنشاء", deleteTag = "حذف", maxTags = "10 وسوم مخصصة كحد أقصى",
  hudVo2 = "VO₂ أقصى", hudHr = "معدل النبض", hudPower = "القدرة", hudReadiness = "الجهوزية",
  perfTrend = "اتجاه الأداء · 12 أسبوعًا", readinessTrend = "اتجاه الجهوزية", loadMatrix = "مصفوفة حمل التدريب",
  sleepArchitecture = "بنية النوم", riskMatrix = "مصفوفة خطر الإصابة", wellnessRadar = "ملف الرياضي",
  eventLog = "سجل الأحداث", aiRecs = "دعم القرار السريري (CDSS)", cohortStats = "إحصاءات المجموعة",
  sessionControl = "التحكم بالحصة", csvImport = "استيراد CSV", csvDrop = "أسقط ملف CSV هنا أو انقر",
  phase = "المرحلة", load = "الحمل", fatigue = "الإجهاد", pause = "إيقاف", resume = "استئناف", end = "إنهاء",
  live = "مباشر", liveSim = "محاكاة مباشرة", on = "تشغيل", off = "إيقاف", totalAthletes = "الرياضيون", totalRecords = "السجلات",
  avgLoad = "متوسط الحمل", avgRpe = "متوسط RPE", avgSleep = "متوسط النوم", males = "ذكور", females = "إناث",
  latestData = "أحدث البيانات", readiness = "الجهوزية", sleepH = "النوم (ساعة)", sleepQuality = "جودة النوم",
  stress = "التوتر", soreness = "ألم العضلات", mood = "المزاج", rpe = "RPE", dailyLoad = "الحمل اليومي",
  calories = "السعرات", ffm = "الكتلة الخالية من الدهن (كغ)", cyclePhase = "مرحلة الدورة", pain = "الألم", injuryLocation = "موقع الإصابة",
  overview = "نظرة عامة", eaTrendTitle = "اتجاه التوفر الطاقي", forecast = "توقعات", days = "أيام",
  cycleTimeline = "الجدول الزمني للدورة الشهرية", fertilityWindow = "نافذة الخصوبة", trainingAdapt = "التكيف التدريبي",
  phaseRec = "توصية المرحلة", menstrual = "الحيض", follicular = "الجرابية", ovulatory = "الإباضة",
  luteal = "الأصفرية", na_ = "—", notes = "ملاحظات المدرب", addNote = "إضافة ملاحظة", notePlaceholder = "اكتب ملاحظة…",
  undo = "تراجع", redo = "إعادة", delete = "حذف", report = "تقرير", downloadReport = "تنزيل التقرير",
  dataCompleteness = "اكتمال البيانات", rpeValidity = "صلاحية RPE", injuryForecast = "توقع الإصابة",
  boneHealth = "صحة العظام", aclRisk = "خطر الرباط الصليبي", perfScore = "درجة الأداء",
  checkin = "تسجيل", checkinTitle = "التسجيل اليومي ·", submit = "إرسال", cancel = "إلغاء",
  checkinSaved = "تم إرسال التسجيل", checkinError = "فشل الإرسال", duration = "المدة (دقيقة)",
  exerciseType = "نوع التمرين", blockTag = "وسم كتلة التدريب", reflection = "تأمل",
  redsLab = "حاسبة خطر RED-S", eaFormula = "التوفر الطاقي = (المدخول − التمرين) / الكتلة الخالية", eaValue = "التوفر الطاقي",
  riskScore = "درجة الخطر", lowRisk = "خطر منخفض", modRisk = "متوسط", highRisk = "خطر مرتفع",
  optimal45 = "مثالي (≥45)", caution3045 = "حذر (30–45)", critical30 = "حرج (<30)",
  factors = "العوامل المساهمة", clinicalRec = "التوصية السريرية", scenario = "السيناريو",
  intake = "المدخول (kcal)", exerciseKcal = "تكلفة التمرين (kcal)", netEEE = "صافي EEE", lutealPenalty = "عقوبة الأصفرية",
  cohortReds = "توزيع RED-S للمجموعة", bodyMass = "كتلة الجسم (كغ)", gender = "الجنس", male = "ذكر",
  female = "أنثى", clinicalCaveat = "حدود التوفر الطاقي (30، 45 kcal/kg/يوم) وفق إجماع IOC RED-S (Mountjoy et al., 2018). أداة فرز فقط.",
  compare = "مقارنة الرياضيين", compareHint = "اختر حتى 4 رياضيين", squadHeatmap = "خريطة حمل الفريق",
  acwrTitle = "الحمل الحاد:المزمن", acwrZone = "المنطقة", monotonyTitle = "الرتابة والإجهاد (7 أيام)",
  wfRatio = "نسبة الرفاه:الإجهاد", importData = "استيراد", preview = "معاينة", upload = "تحميل إلى الخادم",
  uploadOk = "تم قبول التحميل", uploadFail = "فشل التحميل", taskQueued = "المهمة في قائمة الانتظار",
  exportCsv = "تصدير CSV", exportJson = "تصدير JSON", researchExport = "تصدير بحثي",
  systemStatus = "حالة النظام", opMode = "وضع التشغيل", mlPipeline = "محرك الحوسبة", localLlm = "نموذج محلي",
  cpu = "المعالج", memory = "الذاكرة", disk = "القرص", thermalGuard = "الحماية الحرارية", cpuTemp = "حرارة المعالج",
  battery = "الطاقة", modeFull = "كامل", modeStandard = "قياسي", modeReduced = "منخفض",
  modeMinimal = "أدنى", modeEmergency = "طارئ", healthCheck = "فحص الصحة", diagnostics = "تشخيص نقاط النهاية",
  latency = "زمن الاستجابة", ok = "ناجح", fail = "فاشل", alertCenter = "مركز التنبيهات", ackAll = "الإقرار بالجميع",
  acknowledge = "إقرار", critical = "حرج", warning = "تحذير", info = "معلومة", noAlerts = "لا تنبيهات نشطة",
  settings = "الإعدادات", apiUrl = "عنوان API الخلفي", apiToken = "رمز الحامل (JWT)",
  refreshToken = "تحديث تلقائي (ثوانٍ)", refreshOff = "معطل", units = "الوحدات", metric = "متري", imperial = "إمبراطوري",
  compact = "تخطيط مضغوط", save = "حفظ", saved = "تم الحفظ", reset = "استعادة الافتراضي", shortcuts = "اختصارات لوحة المفاتيح",
  about = "حول", minReadiness = "برتقالي تحت الجهوزية", autoDemo = "وضع العرض عند فقد الاتصال",
  loading = "جارٍ التحميل", errorOccurred = "حدث خطأ ما", retry = "إعادة المحاولة", offlineDemo = "الخادم غير متاح — بيانات عرض اصطناعية",
  connected = "متصل", disconnected = "غير متصل", updated = "محدَّث", close = "إغلاق",
  shortcutsHint = "1-8 تبويبات · Ctrl+K بحث · R تحديث · T مظهر · L لغة · S محاكاة · ? مساعدة",
  generatedBy = "أنشئ بواسطة", page = "صفحة", athleteCount = "رياضي", selectPlaceholder = "اختر…",
  markAllRead = "مسح الكل", notifications = "الإشعارات", noNotifications = "لا جديد",
  cmdPlaceholder = "ابحث عن الرياضيين والإجراءات واللوحات…", cmdNavigate = "تنقل", cmdSelect = "اختر",
  swReady = "وزن النوم", readinessBreakdown = "تركيب الجهوزية", weightNote = "مركّب: النوم 35% · الإجهاد 20% · الألم 15% · التوتر 15% · الألم 15%",
  eaForecastNote = "توقع 7 أيام", stool = "بيانات غير كافية", bannerDemo = "بيانات عرض",
  connectionLost = "انقطع الاتصال — إعادة المحاولة", recovered = "تم استعادة الخادم",
  rosterN = "N", spark = "مخطط 7 أيام", lastCheckin = "آخر تسجيل", never = "أبدًا",
  filterChips = "المرشحات", groupBy = "تجميع حسب", exportPng = "PNG", printReport = "طباعة التقرير",
  aboutText = "ATHENA v1 — وحدة عمليات علوم الرياضة للقياس عن بعد والصحة والتغذية القائمة على الأدلة."
)

I18N$ru <- c(
  appTitle = "А.Т.Х.Е.Н.А.", headerSubtitle = "Адаптивная телеметрия · Здоровье · Доказательное питание",
  statusOnline = "СИСТЕМЫ В НОРМЕ", statusOffline = "ОФЛАЙН · ДЕМО-РЕЖИМ", statusConnecting = "ПОДКЛЮЧЕНИЕ",
  sync = "СИНХР", export = "ЭКСПОРТ", alert = "ТРЕВОГА", language = "ЯЗЫК", theme = "ТЕМА",
  crt = "CRT", sound = "ЗВУК", login = "ВХОД", logout = "ВЫХОД", register = "РЕГИСТРАЦИЯ", demo = "ДЕМО",
  userId = "ID пользователя", password = "Пароль", loginTitle = "ВХОД В ATHENA",
  qbReadiness = "СР. ГОТОВНОСТЬ", qbLoad = "СР. НАГРУЗКА", qbAtRisk = "В ЗОНЕ РИСКА", qbReds = "ФЛАЖКИ RED-S",
  tabDashboard = "Панель", tabRoster = "Состав", tabAthlete = "Карточка атлета", tabReds = "RED-S лаб.",
  tabCohort = "Когорта", tabData = "Данные", tabSystem = "Система", tabSettings = "Настройки",
  roster = "СОСТАВ АТЛЕТОВ", searchRoster = "Поиск атлетов…", filterAll = "Все", filterGreen = "Оптимум",
  filterAmber = "Внимание", filterRed = "Опасность", filterFemale = "Женщины", filterMale = "Мужчины",
  groupNone = "Список", groupSport = "Спорт", groupRisk = "Риск", viewCards = "КАРТОЧКИ", viewTable = "ТАБЛИЦА",
  noResults = "Атлеты не найдены", paused = "ПАУЗА", addTag = "Добавить метку", tagManager = "Управление метками",
  tagName = "Название", tagColor = "Цвет", createTag = "Создать", deleteTag = "Удалить", maxTags = "Максимум 10 меток",
  hudVo2 = "МПК МАКС", hudHr = "ЧСС", hudPower = "МОЩНОСТЬ", hudReadiness = "ГОТОВНОСТЬ",
  perfTrend = "ТРЕНД РЕЗУЛЬТАТА · 12 НЕДЕЛЬ", readinessTrend = "ТРЕНД ГОТОВНОСТИ", loadMatrix = "МАТРИЦА НАГРУЗКИ",
  sleepArchitecture = "СТРУКТУРА СНА", riskMatrix = "МАТРИЦА РИСКА ТРАВМ", wellnessRadar = "ПРОФИЛЬ АТЛЕТА",
  eventLog = "ЖУРНАЛ СОБЫТИЙ", aiRecs = "КЛИНИЧЕСКАЯ ПОДДЕРЖКА РЕШЕНИЙ (CDSS)", cohortStats = "СТАТИСТИКА КОГОРТЫ",
  sessionControl = "УПРАВЛЕНИЕ СЕССИЕЙ", csvImport = "ИМПОРТ CSV", csvDrop = "Перетащите CSV или нажмите",
  phase = "ФАЗА", load = "НАГРУЗКА", fatigue = "УСТАЛОСТЬ", pause = "ПАУЗА", resume = "ПРОДОЛЖИТЬ", end = "СТОП",
  live = "ПРЯМОЙ ЭФИР", liveSim = "LIVE-СИМ", on = "ВКЛ", off = "ВЫКЛ", totalAthletes = "Атлеты", totalRecords = "Записи",
  avgLoad = "Ср. нагрузка", avgRpe = "Ср. RPE", avgSleep = "Ср. сон", males = "Мужчины", females = "Женщины",
  latestData = "Свежие данные", readiness = "Готовность", sleepH = "Сон (ч)", sleepQuality = "Качество сна",
  stress = "Стресс", soreness = "Боль в мышцах", mood = "Настроение", rpe = "RPE", dailyLoad = "Дневная нагрузка",
  calories = "Калории", ffm = "БМТ (кг)", cyclePhase = "Фаза цикла", pain = "Боль", injuryLocation = "Локализация травмы",
  overview = "ОБЗОР", eaTrendTitle = "ТРЕНД ДОСТУПНОСТИ ЭНЕРГИИ", forecast = "ПРОГНОЗ", days = "дней",
  cycleTimeline = "ХРОНОЛОГИЯ МЕНСТРУАЛЬНОГО ЦИКЛА", fertilityWindow = "Окно фертильности", trainingAdapt = "Адаптация к тренировкам",
  phaseRec = "Рекомендация по фазе", menstrual = "МЕНСТРУАЛЬНАЯ", follicular = "ФОЛЛИКУЛЯРНАЯ", ovulatory = "ОВУЛЯТОРНАЯ",
  luteal = "ЛЮТЕИНОВАЯ", na_ = "—", notes = "ЗАМЕТКИ ТРЕНЕРА", addNote = "Добавить заметку", notePlaceholder = "Введите заметку…",
  undo = "Отменить", redo = "Повторить", delete = "Удалить", report = "ОТЧЁТ", downloadReport = "Скачать отчёт",
  dataCompleteness = "ПОЛНОТА ДАННЫХ", rpeValidity = "ВАЛИДНОСТЬ RPE", injuryForecast = "ПРОГНОЗ ТРАВМ",
  boneHealth = "Здоровье костей", aclRisk = "Риск ПКС", perfScore = "ОЦЕНКА РЕЗУЛЬТАТА",
  checkin = "ЧЕК-ИН", checkinTitle = "ЕЖЕДНЕВНЫЙ ЧЕК-ИН ·", submit = "ОТПРАВИТЬ", cancel = "ОТМЕНА",
  checkinSaved = "Чек-ин отправлен", checkinError = "Ошибка отправки", duration = "Длительность (мин)",
  exerciseType = "Тип нагрузки", blockTag = "Тег блока", reflection = "Рефлексия",
  redsLab = "КАЛЬКУЛЯТОР РИСКА RED-S", eaFormula = "ДЭ = (Поступление − Нагрузка) / БМТ", eaValue = "Доступность энергии",
  riskScore = "Оценка риска", lowRisk = "НИЗКИЙ РИСК", modRisk = "УМЕРЕННЫЙ", highRisk = "ВЫСОКИЙ РИСК",
  optimal45 = "Оптимум (≥45)", caution3045 = "Внимание (30–45)", critical30 = "Критично (<30)",
  factors = "Факторы риска", clinicalRec = "Клиническая рекомендация", scenario = "СЦЕНАРИЙ",
  intake = "Поступление (ккал)", exerciseKcal = "Стоимость нагрузки (ккал)", netEEE = "Чистая EEE", lutealPenalty = "Лютеиновая поправка",
  cohortReds = "РАСПРЕДЕЛЕНИЕ RED-S В КОГОРТЕ", bodyMass = "Масса тела (кг)", gender = "Пол", male = "Мужской",
  female = "Женский", clinicalCaveat = "Пороги ДЭ (30, 45 ккал/кг БМТ/день) по консенсусу IOC RED-S (Mountjoy et al., 2018). Только скрининг.",
  compare = "СРАВНЕНИЕ АТЛЕТОВ", compareHint = "Выберите до 4 атлетов", squadHeatmap = "КАРТА НАГРУЗКИ КОМАНДЫ",
  acwrTitle = "ОСТРАЯ:ХРОНИЧЕСКАЯ НАГРУЗКА", acwrZone = "Зона", monotonyTitle = "МОНОТОННОСТЬ И НАПРЯЖЕНИЕ (7 ДНЕЙ)",
  wfRatio = "СООТНОШЕНИЕ САМОЧУВСТВИЕ:УСТАЛОСТЬ", importData = "ИМПОРТ", preview = "Предпросмотр", upload = "Загрузить на сервер",
  uploadOk = "Загрузка принята", uploadFail = "Ошибка загрузки", taskQueued = "Задача в очереди",
  exportCsv = "Экспорт CSV", exportJson = "Экспорт JSON", researchExport = "ИССЛЕДОВАТЕЛЬСКИЙ ЭКСПОРТ",
  systemStatus = "СОСТОЯНИЕ СИСТЕМЫ", opMode = "Режим работы", mlPipeline = "ВЫЧИСЛИТЕЛЬНЫЙ ДВИЖОК", localLlm = "Локальная LLM",
  cpu = "ЦП", memory = "Память", disk = "Диск", thermalGuard = "ТЕПЛОВАЯ ЗАЩИТА", cpuTemp = "Темп. ЦП",
  battery = "Питание", modeFull = "ПОЛНЫЙ", modeStandard = "СТАНДАРТ", modeReduced = "СНИЖЕННЫЙ",
  modeMinimal = "МИНИМАЛЬНЫЙ", modeEmergency = "АВАРИЙНЫЙ", healthCheck = "ПРОВЕРКА ЗДОРОВЬЯ", diagnostics = "ДИАГНОСТИКА ENDPOINT'ОВ",
  latency = "Задержка", ok = "ПРОЙДЕНО", fail = "СБОЙ", alertCenter = "ЦЕНТР ТРЕВОГ", ackAll = "Подтвердить все",
  acknowledge = "Подтвердить", critical = "КРИТИЧНО", warning = "ПРЕДУПРЕЖДЕНИЕ", info = "ИНФО", noAlerts = "Нет активных тревог",
  settings = "НАСТРОЙКИ", apiUrl = "URL бэкенда", apiToken = "Bearer-токен (JWT)",
  refreshToken = "Автообновление (сек)", refreshOff = "Выкл", units = "Единицы", metric = "Метрические", imperial = "Имперские",
  compact = "Компактный вид", save = "СОХРАНИТЬ", saved = "Сохранено", reset = "Сбросить", shortcuts = "Горячие клавиши",
  about = "О программе", minReadiness = "Жёлтый ниже готовности", autoDemo = "Демо-режим при потере связи",
  loading = "Загрузка", errorOccurred = "Что-то пошло не так", retry = "Повторить", offlineDemo = "Бэкенд недоступен — синтетические демо-данные",
  connected = "Подключено", disconnected = "Отключено", updated = "Обновлено", close = "Закрыть",
  shortcutsHint = "1-8 вкладки · Ctrl+K поиск · R обновить · T тема · L язык · S симуляция · ? помощь",
  generatedBy = "Создано", page = "Страница", athleteCount = "атлетов", selectPlaceholder = "Выбрать…",
  markAllRead = "Очистить всё", notifications = "Уведомления", noNotifications = "Ничего нового",
  cmdPlaceholder = "Поиск атлетов, действий, панелей…", cmdNavigate = "навигация", cmdSelect = "выбрать",
  swReady = "Вес сна", readinessBreakdown = "СОСТАВ ГОТОВНОСТИ", weightNote = "Композит: сон 35% · усталость 20% · боль 15% · стресс 15% · боль 15%",
  eaForecastNote = "прогноз на 7 дней", stool = "Недостаточно данных", bannerDemo = "ДЕМО-ДАННЫЕ",
  connectionLost = "Связь потеряна — повторная попытка", recovered = "Бэкенд восстановлен",
  rosterN = "N", spark = "Спарклайн 7 дней", lastCheckin = "Последний чек-ин", never = "Никогда",
  filterChips = "Фильтры", groupBy = "Группировать по", exportPng = "PNG", printReport = "Печать отчёта",
  aboutText = "ATHENA v1 — спортивно-научная консоль для телеметрии, здоровья и доказательного питания."
)

I18N$sw <- c(
  appTitle = "A.T.H.E.N.A.", headerSubtitle = "Telemetria Badilifu · Afya · Lishe ya Uthibitisho",
  statusOnline = "MIFUMO IKO SALAMA", statusOffline = "NJE YA MTANDAO · HALI YA MAJARIBIO", statusConnecting = "INAGANIANA",
  sync = "SAWAZISHA", export = "HAMISHA", alert = "TAHADHARI", language = "LUGHA", theme = "MANDHARI",
  crt = "CRT", sound = "SAUTI", login = "INGIA", logout = "TOKA", register = "JISAJILI", demo = "MAJARIBIO",
  userId = "Kitambulisho", password = "Nenosiri", loginTitle = "KUINGIA ATHENA",
  qbReadiness = "WASTANI UTAAYARI", qbLoad = "WASTANI MZIGO", qbAtRisk = "KWENYE HATARI", qbReds = "BENDERA RED-S",
  tabDashboard = "Dashibodi", tabRoster = "Orodha", tabAthlete = "Maelezo ya Mchezaji", tabReds = "Lab RED-S",
  tabCohort = "Kikundi", tabData = "Data", tabSystem = "Mfumo", tabSettings = "Mipangilio",
  roster = "ORODHA YA WACHEZAJI", searchRoster = "Tafuta wachezaji…", filterAll = "Wote", filterGreen = "Bora",
  filterAmber = "Tahadhari", filterRed = "Hatari", filterFemale = "Mke", filterMale = "Mume",
  groupNone = "Orodha", groupSport = "Michezo", groupRisk = "Hatari", viewCards = "KADI", viewTable = "JEDWALI",
  noResults = "Hakuna mchezaji anayelingana", paused = "IMESIMAMISHWA", addTag = "Ongeza lebo", tagManager = "Meneja wa lebo",
  tagName = "Jina", tagColor = "Rangi", createTag = "Tengeneza", deleteTag = "Futa", maxTags = "Lebo 10 za kipekee kwa upeo",
  hudVo2 = "VO₂ KIWANGO", hudHr = "MAPIGO YA MOYO", hudPower = "NGUVU", hudReadiness = "UTAAYARI",
  perfTrend = "MWELEKEO WA UTENDAJI · WIKI 12", readinessTrend = "MWELEKEO WA UTAAYARI", loadMatrix = "MATRIKI YA MZIGO",
  sleepArchitecture = "MUUNDO WA usingizi", riskMatrix = "MATRIKI YA HATARI YA MAJERUHI", wellnessRadar = "WASIFI WA MCHEZAJI",
  eventLog = "KUMBUKUMBU YA MATUKIO", aiRecs = "USAIDIZI WA MAAMUZI YA KIKLINIKI (CDSS)", cohortStats = "TAKWIMU ZA KIKUNDI",
  sessionControl = "UDHIBITI WA KIPINDI", csvImport = "INGIZA CSV", csvDrop = "Dondosha CSV hapa au bofya",
  phase = "HATUA", load = "MZIGO", fatigue = "UCHOVU", pause = "SITISHA", resume = "ENDELEA", end = "MALIZA",
  live = "MOJA KWA MOJA", liveSim = "SIMU MOJA KWA MOJA", on = "WASHA", off = "ZIMA", totalAthletes = "Wachezaji", totalRecords = "Rekodi",
  avgLoad = "Mzigo wastani", avgRpe = "RPE wastani", avgSleep = "Usingizi wastani", males = "Wanaume", females = "Wanawake",
  latestData = "Data ya hivi punde", readiness = "Utaayari", sleepH = "Usingizi (saa)", sleepQuality = "Ubora wa usingizi",
  stress = "Msongo", soreness = "Uchungu wa misuli", mood = "Hali ya moyo", rpe = "RPE", dailyLoad = "Mzigo wa kila siku",
  calories = "Kalori", ffm = "Uzito usio na mafuta (kg)", cyclePhase = "Hatua ya mzunguko", pain = "Maumivu", injuryLocation = "Mahali pa jeraha",
  overview = "MUHTASARI", eaTrendTitle = "MWELEKEO WA UPATIKANAJI WA NISHATI", forecast = "UTABIRI", days = "siku",
  cycleTimeline = "RATIBA YA MUHULI", fertilityWindow = "Dirisha la Uzazi", trainingAdapt = "Mabadiliko ya Mazoezi",
  phaseRec = "Ushauri wa Hatua", menstrual = "MUHULI", follicular = "FOLIKULARI", ovulatory = "OVULASHENI",
  luteal = "LUTEALI", na_ = "—", notes = "MAELEZO YA KOCHI", addNote = "Ongeza maelezo", notePlaceholder = "Andika maelezo…",
  undo = "Rudisha", redo = "Rudia", delete = "Futa", report = "RIPOTI", downloadReport = "Pakua ripoti",
  dataCompleteness = "UKAMILIFU WA DATA", rpeValidity = "UHALALI WA RPE", injuryForecast = "UTABIRI WA MAJERUHI",
  boneHealth = "Afya ya mifupa", aclRisk = "Hatari ya ACL", perfScore = "ALAMA ZA UTENDAJI",
  checkin = "KUJIANDIKISHA", checkinTitle = "KUJIANDIKISHA KILA SIKU ·", submit = "TUMA", cancel = "GHAIRI",
  checkinSaved = "Imetumwa", checkinError = "Imeshindikana kutuma", duration = "Muda (dakika)",
  exerciseType = "Aina ya mazoezi", blockTag = "Lebo ya kipindi", reflection = "Tafakari",
  redsLab = "KIKOKOTOO CHA HATARI YA RED-S", eaFormula = "EA = (Uingizaji − Mazoezi) / FFM", eaValue = "Upatikanaji wa Nishati",
  riskScore = "Alama za Hatari", lowRisk = "HATARI NDOGO", modRisk = "WASTANI", highRisk = "HATARI KUBWA",
  optimal45 = "Bora (≥45)", caution3045 = "Tahadhari (30–45)", critical30 = "Muhimu (<30)",
  factors = "Sababu Zinazochangia", clinicalRec = "Ushauri wa Kimatibabu", scenario = "MTAZIKO",
  intake = "Uingizaji (kcal)", exerciseKcal = "Gharama ya mazoezi (kcal)", netEEE = "EEE halisi", lutealPenalty = "Adhabu ya luteali",
  cohortReds = "MGAWANYO WA RED-S KIKUNDINI", bodyMass = "Uzito wa mwili (kg)", gender = "Jinsia", male = "Mume",
  female = "Mke", clinicalCaveat = "Vizingiti vya EA (30, 45 kcal/kg FFM/siku) kulingana na IOC RED-S (Mountjoy et al., 2018). Zana ya uchunguzi tu.",
  compare = "ULINGANISHO WA WACHEZAJI", compareHint = "Chagua hadi wachezaji 4", squadHeatmap = "RAMANI YA MZIGO WA TIMU",
  acwrTitle = "MZIGO MKALI:MKRONI", acwrZone = "Eneo", monotonyTitle = "UNYEGE & MKazo (SIKU 7)",
  wfRatio = "USAWA WA AFYA:UCHOVU", importData = "INGIZA", preview = "Onyesha awali", upload = "Pakia kwenye seva",
  uploadOk = "Pakia limekubaliwa", uploadFail = "Pakia limeshindikana", taskQueued = "Kazi kwenye foleni",
  exportCsv = "Hamisha CSV", exportJson = "Hamisha JSON", researchExport = "HAMISHA UTAFITI",
  systemStatus = "HALI YA MFUMO", opMode = "Hali ya Uendeshaji", mlPipeline = "INJINI YA HESABU", localLlm = "LLM ya Ndani",
  cpu = "CPU", memory = "Kumbukumbu", disk = "Diski", thermalGuard = "ULINZI WA JOTO", cpuTemp = "Joto la CPU",
  battery = "Nishati", modeFull = "KAMILI", modeStandard = "KAWAIDA", modeReduced = "PUNGUZA",
  modeMinimal = "NDOGO", modeEmergency = "DHARURA", healthCheck = "UKAGUZI WA AFYA", diagnostics = "UTAMBULISHI WA ENDPOINT",
  latency = "Ucheleweshaji", ok = "IMEFAULU", fail = "IMESHINDIKANA", alertCenter = "KITOVU CHA TAHADHARI", ackAll = "Kubili zote",
  acknowledge = "Kubili", critical = "MUHIMU", warning = "TAHADHARI", info = "HABARI", noAlerts = "Hakuna tahadhari",
  settings = "MIPANGILIO", apiUrl = "URL ya seva", apiToken = "Tokeni (JWT)",
  refreshToken = "Kujiondoa kiotomatiki (sekunde)", refreshOff = "Imezimwa", units = "Vipimo", metric = "Metriki", imperial = "Imperiali",
  compact = "Muundo mdogo", save = "HIFADHI", saved = "Imehifadhiwa", reset = "Rejesha", shortcuts = "Njia za kibodi",
  about = "Kuhusu", minReadiness = "Manjano chini ya utaayari", autoDemo = "Hali ya majaribio poteza muunganisho",
  loading = "Inapakia", errorOccurred = "Kuna kilichokosekana", retry = "Jaribu tena", offlineDemo = "Seva haipatikani — data ya majaribio inatumika",
  connected = "Imeganishwa", disconnected = "Imekatika", updated = "Imesasishwa", close = "Funga",
  shortcutsHint = "1-8 vichupo · Ctrl+K tafuta · R onyesha upya · T mandhari · L lugha · S simu · ? msaada",
  generatedBy = "Imetengenezwa na", page = "Ukurasa", athleteCount = "wachezaji", selectPlaceholder = "Chagua…",
  markAllRead = "Futa zote", notifications = "Arifa", noNotifications = "Hakuna mpya",
  cmdPlaceholder = "Tafuta wachezaji, vitendo, paneli…", cmdNavigate = "sogeza", cmdSelect = "chagua",
  swReady = "Uzito wa usingizi", readinessBreakdown = "MUUNDO WA UTAAYARI", weightNote = "Mchanganyo: usingizi 35% · uchovu 20% · maumivu 15% · msongo 15% · maumivu 15%",
  eaForecastNote = "utabiri wa siku 7", stool = "Data haitoshi", bannerDemo = "DATA YA MAJARIBIO",
  connectionLost = "Muunganisho umepotea — inajaribu tena", recovered = "Seva imerudishwa",
  rosterN = "N", spark = "Mstari wa siku 7", lastCheckin = "Kujiandikisha mwisho", never = "Kabisa",
  filterChips = "Vichujio", groupBy = "Panga kwa", exportPng = "PNG", printReport = "Chapisha ripoti",
  aboutText = "ATHENA v1 — dashibodi ya sayansi ya michezo kwa vipimo, afya na lishe inayotegemea ushahidi."
)

I18N$zh <- c(
  appTitle = "A.T.H.E.N.A.", headerSubtitle = "自适应遥测 · 健康 · 循证营养",
  statusOnline = "系统正常", statusOffline = "离线 · 演示模式", statusConnecting = "连接中",
  sync = "同步", export = "导出", alert = "警报", language = "语言", theme = "主题",
  crt = "CRT", sound = "声音", login = "登录", logout = "退出", register = "注册", demo = "演示",
  userId = "用户 ID", password = "密码", loginTitle = "ATHENA 登录",
  qbReadiness = "平均准备度", qbLoad = "平均负荷", qbAtRisk = "高风险", qbReds = "RED-S 标记",
  tabDashboard = "仪表盘", tabRoster = "名册", tabAthlete = "运动员详情", tabReds = "RED-S 实验室",
  tabCohort = "队列", tabData = "数据", tabSystem = "系统", tabSettings = "设置",
  roster = "运动员名册", searchRoster = "搜索运动员…", filterAll = "全部", filterGreen = "最佳",
  filterAmber = "注意", filterRed = "危险", filterFemale = "女", filterMale = "男",
  groupNone = "列表", groupSport = "项目", groupRisk = "风险", viewCards = "卡片", viewTable = "表格",
  noResults = "没有匹配的运动员", paused = "已暂停", addTag = "添加标签", tagManager = "标签管理",
  tagName = "名称", tagColor = "颜色", createTag = "创建", deleteTag = "删除", maxTags = "最多 10 个自定义标签",
  hudVo2 = "最大摄氧量", hudHr = "心率", hudPower = "功率输出", hudReadiness = "准备度",
  perfTrend = "表现趋势 · 12 周", readinessTrend = "准备度趋势", loadMatrix = "训练负荷矩阵",
  sleepArchitecture = "睡眠结构", riskMatrix = "损伤风险矩阵", wellnessRadar = "运动员画像",
  eventLog = "事件日志", aiRecs = "临床决策支持 (CDSS)", cohortStats = "队列统计",
  sessionControl = "课程控制", csvImport = "CSV 导入", csvDrop = "拖入 CSV 或点击上传",
  phase = "阶段", load = "负荷", fatigue = "疲劳", pause = "暂停", resume = "继续", end = "结束",
  live = "实时", liveSim = "实时模拟", on = "开", off = "关", totalAthletes = "运动员", totalRecords = "记录",
  avgLoad = "平均负荷", avgRpe = "平均 RPE", avgSleep = "平均睡眠", males = "男", females = "女",
  latestData = "最新数据", readiness = "准备度", sleepH = "睡眠 (小时)", sleepQuality = "睡眠质量",
  stress = "压力", soreness = "肌肉酸痛", mood = "情绪", rpe = "RPE", dailyLoad = "每日负荷",
  calories = "卡路里", ffm = "去脂体重 (kg)", cyclePhase = "周期阶段", pain = "疼痛", injuryLocation = "伤处",
  overview = "概览", eaTrendTitle = "能量可利用性趋势", forecast = "预测", days = "天",
  cycleTimeline = "月经周期时间线", fertilityWindow = "受孕窗口", trainingAdapt = "训练适应",
  phaseRec = "阶段建议", menstrual = "月经期", follicular = "卵泡期", ovulatory = "排卵期",
  luteal = "黄体期", na_ = "—", notes = "教练备注", addNote = "添加备注", notePlaceholder = "输入备注…",
  undo = "撤销", redo = "重做", delete = "删除", report = "报告", downloadReport = "下载报告",
  dataCompleteness = "数据完整度", rpeValidity = "RPE 有效性", injuryForecast = "损伤预测",
  boneHealth = "骨骼健康", aclRisk = "前交叉韧带风险", perfScore = "表现评分",
  checkin = "打卡", checkinTitle = "每日打卡 ·", submit = "提交", cancel = "取消",
  checkinSaved = "打卡已提交", checkinError = "提交失败", duration = "时长 (分钟)",
  exerciseType = "运动类型", blockTag = "训练周期标签", reflection = "反思",
  redsLab = "RED-S 风险计算器", eaFormula = "EA = (摄入 − 运动) / 去脂体重", eaValue = "能量可利用性",
  riskScore = "风险评分", lowRisk = "低风险", modRisk = "中等", highRisk = "高风险",
  optimal45 = "最佳 (≥45)", caution3045 = "注意 (30–45)", critical30 = "危险 (<30)",
  factors = "影响因素", clinicalRec = "临床建议", scenario = "情景",
  intake = "摄入 (kcal)", exerciseKcal = "运动消耗 (kcal)", netEEE = "净 EEE", lutealPenalty = "黄体期扣减",
  cohortReds = "队列 RED-S 分布", bodyMass = "体重 (kg)", gender = "性别", male = "男",
  female = "女", clinicalCaveat = "EA 阈值（30、45 kcal/kg 去脂体重/天）依据 IOC RED-S 共识（Mountjoy 等，2018）。仅作筛查工具。",
  compare = "运动员对比", compareHint = "最多选择 4 名运动员", squadHeatmap = "全队负荷热图",
  acwrTitle = "急性:慢性负荷比", acwrZone = "区间", monotonyTitle = "单调性与应激 (7 天)",
  wfRatio = "身心健康:疲劳比", importData = "导入", preview = "预览", upload = "上传到后端",
  uploadOk = "上传已接受", uploadFail = "上传失败", taskQueued = "任务已排队",
  exportCsv = "CSV 导出", exportJson = "JSON 导出", researchExport = "科研导出",
  systemStatus = "系统状态", opMode = "运行模式", mlPipeline = "计算分析引擎", localLlm = "本地 LLM",
  cpu = "CPU", memory = "内存", disk = "磁盘", thermalGuard = "热保护", cpuTemp = "CPU 温度",
  battery = "电源", modeFull = "完全", modeStandard = "标准", modeReduced = "降档",
  modeMinimal = "最小", modeEmergency = "紧急", healthCheck = "健康检查", diagnostics = "端点诊断",
  latency = "延迟", ok = "通过", fail = "失败", alertCenter = "警报中心", ackAll = "全部确认",
  acknowledge = "确认", critical = "严重", warning = "警告", info = "信息", noAlerts = "无活动警报",
  settings = "设置", apiUrl = "后端 API 地址", apiToken = "Bearer 令牌 (JWT)",
  refreshToken = "自动刷新（秒）", refreshOff = "关闭", units = "单位", metric = "公制", imperial = "英制",
  compact = "紧凑布局", save = "保存", saved = "已保存", reset = "恢复默认", shortcuts = "键盘快捷键",
  about = "关于", minReadiness = "低于准备度的琥珀阈值", autoDemo = "断连时自动演示模式",
  loading = "加载中", errorOccurred = "出现问题", retry = "重试", offlineDemo = "后端不可达 — 正在使用合成演示数据",
  connected = "已连接", disconnected = "已断开", updated = "已更新", close = "关闭",
  shortcutsHint = "1-8 标签页 · Ctrl+K 搜索 · R 刷新 · T 主题 · L 语言 · S 模拟 · ? 帮助",
  generatedBy = "生成者", page = "页", athleteCount = "名运动员", selectPlaceholder = "请选择…",
  markAllRead = "全部清除", notifications = "通知", noNotifications = "暂无新通知",
  cmdPlaceholder = "搜索运动员、操作、面板…", cmdNavigate = "导航", cmdSelect = "选择",
  swReady = "睡眠权重", readinessBreakdown = "准备度构成", weightNote = "综合：睡眠 35% · 疲劳 20% · 酸痛 15% · 压力 15% · 疼痛 15%",
  eaForecastNote = "7 天预测", stool = "数据不足", bannerDemo = "演示数据",
  connectionLost = "连接丢失 — 正在重试", recovered = "后端已恢复",
  rosterN = "N", spark = "7 天迷你图", lastCheckin = "上次打卡", never = "从未",
  filterChips = "筛选", groupBy = "分组依据", exportPng = "PNG", printReport = "打印报告",
  aboutText = "ATHENA v1 — 用于遥测、健康和循证营养的精英运动科学操作台。"
)

safe_lookup <- function(vec, key) {
  if (is.null(vec) || length(vec) == 0 || is.null(key) || length(key) != 1 || is.na(key)) return(NULL)
  key <- as.character(key)
  if (is.null(names(vec)) || !key %in% names(vec)) return(NULL)
  val <- vec[[key]]
  if (is.null(val) || length(val) == 0 || is.na(val[1])) return(NULL)
  if (is.character(val) && !nzchar(val[1])) return(NULL)
  unname(val)
}

# Locale-aware translation with graceful fallback: lang -> en -> key itself.
tr_raw <- function(lang, key) {
  if (is.null(lang) || !is.character(lang) || length(lang) != 1 || is.na(lang) || !nzchar(lang)) {
    lang <- "en"
  }
  lv <- if (is.list(I18N) && lang %in% names(I18N)) I18N[[lang]] else NULL
  val <- safe_lookup(lv, key)
  if (!is.null(val)) return(val)
  ev <- if (is.list(I18N) && "en" %in% names(I18N)) I18N[["en"]] else NULL
  val_en <- safe_lookup(ev, key)
  if (!is.null(val_en)) return(val_en)
  as.character(key)
}

# Number formatting per locale (decimal comma languages)
fmt_num <- function(x, digits = 0, lang = "en") {
  if (length(x) == 0 || is.na(x)) return(tr_raw(lang, "na_"))
  dec <- if (lang %in% DECIMAL_COMMA) "," else "."
  s <- formatC(round(as.numeric(x), digits), format = "f", digits = digits, big.mark = "")
  if (dec == ",") gsub("\\.", ",", s) else s
}

tr_lang_dir <- function(lang) if (lang %in% RTL_LANGS) "rtl" else "ltr"

# Late-bound extra keys (added after the main dictionary for maintainability)
EXTRA_KEYS <- c(
  en = "Day", hi = "\u0926\u093f\u0928", es = "D\u00eda", fr = "Jour", de = "Tag", pt = "Dia",
  ar = "\u0627\u0644\u064a\u0648\u0645", ru = "\u0414\u0435\u043d\u044c", sw = "Siku", zh = "\u5929"
)
for (lg in intersect(names(EXTRA_KEYS), LANG_CODES)) {
  I18N[[lg]] <- c(I18N[[lg]], setNames(EXTRA_KEYS[[lg]], "cycleDay"))
}
EXTRA_KEYS2 <- list(
  cycleLow = c(en = "Low", hi = "\u0915\u092e", es = "Bajo", fr = "Bas", de = "Niedrig", pt = "Baixo", ar = "\u0645\u0646\u062e\u0641\u0636", ru = "\u041d\u0438\u0437\u043a\u0438\u0439", sw = "Chini", zh = "\u4f4e"),
  cycleMod = c(en = "Mod", hi = "\u092e\u0927\u094d\u092f\u092e", es = "Mod", fr = "Mod\u00e9r\u00e9", de = "Mittel", pt = "M\u00e9dio", ar = "\u0645\u062a\u0648\u0633\u0637", ru = "\u0421\u0440\u0435\u0434\u043d\u0438\u0439", sw = "Wastani", zh = "\u4e2d"),
  cycleHigh = c(en = "High", hi = "\u0909\u091a\u094d\u091a", es = "Alto", fr = "\u00c9lev\u00e9", de = "Hoch", pt = "Alto", ar = "\u0645\u0631\u062a\u0641\u0639", ru = "\u0412\u044b\u0441\u043e\u043a\u0438\u0439", sw = "Juu", zh = "\u9ad8"),
  cyclePeak = c(en = "Peak", hi = "\u0936\u093f\u0916\u0930", es = "Pico", fr = "Pic", de = "Spitze", pt = "Pico", ar = "\u0630\u0631\u0648\u0629", ru = "\u041f\u0438\u043a", sw = "Kilele", zh = "\u5cf0\u503c")
)
for (kk in names(EXTRA_KEYS2)) {
  for (lg in intersect(names(EXTRA_KEYS2[[kk]]), LANG_CODES)) {
    I18N[[lg]] <- c(I18N[[lg]], setNames(EXTRA_KEYS2[[kk]][[lg]], kk))
  }
}

## -----------------------------------------------------------------------------
## v7 additions — the 12 new panels, biometric tiles, bone/ACL vocabulary,
## session-planner fields and session-timeline counters. Bound into ALL 10
## language dictionaries by the loop below (no key ships English-only).
## -----------------------------------------------------------------------------
EXTRA_KEYS_V7 <- list(
  lactateCurve = c(
    en = "LACTATE THRESHOLD CURVE", hi = "लैक्टेट थ्रेशोल्ड वक्र", es = "CURVA UMBRAL LACTATO",
    fr = "COURBE SEUIL LACTIQUE", de = "LAKTAT-SCHWELLENKURVE", pt = "CURVA LIMIAR LACTATO",
    ar = "منحنى عتبة اللاكتات", ru = "КРИВАЯ ЛАКТАТНОГО ПОРОГА", sw = "MKINGO WA LACTATE", zh = "乳酸阈曲线"),
  sleepArch = c(
    en = "SLEEP ARCHITECTURE", hi = "नींद संरचना", es = "ARQUITECTURA DEL SUEÑO",
    fr = "ARCHITECTURE DU SOMMEIL", de = "SCHLAFARCHITEKTUR", pt = "ARQUITETURA DO SONO",
    ar = "هندسة النوم", ru = "АРХИТЕКТУРА СНА", sw = "MUUNDO WA USINGIZINI", zh = "睡眠结构"),
  biometrics = c(
    en = "LIVE BIOMETRICS", hi = "लाइव बायोमेट्रिक्स", es = "BIOMÉTRICA EN VIVO",
    fr = "BIOMÉTRIE EN DIRECT", de = "LIVE-BIOMETRIE", pt = "BIOMETRIA AO VIVO",
    ar = "القياسات الحيوية المباشرة", ru = "БИОМЕТРИЯ В РЕАЛЬНОМ ВРЕМЕНИ", sw = "VIPIMO NA MOYO", zh = "实时生理指标"),
  nutrition = c(
    en = "NUTRITION & FUELING", hi = "पोषण और ईंधन", es = "NUTRICIÓN Y COMBUSTIBLE",
    fr = "NUTRITION & ÉNERGIE", de = "ERNAHRUNG & FUELING", pt = "NUTRIÇÃO E COMBUSTÍVEL",
    ar = "التغذية والوقود", ru = "ПИТАНИЕ И ЭНЕРГООБЕСПЕЧЕНИЕ", sw = "LISHE NA NISHATI", zh = "营养与补给"),
  sessionPlan = c(
    en = "SESSION PLANNER", hi = "सत्र योजनाकार", es = "PLANIFICADOR DE SESIÓN",
    fr = "PLANIFICATEUR DE SÉANCE", de = "TRAININGSPLANER", pt = "PLANEJADOR DE SESSÃO",
    ar = "مخطط الجلسة", ru = "ПЛАНИРОВЩИК СЕАНСА", sw = "MPANGAJI WA KIPINDI", zh = "课程规划器"),
  perfHistory = c(
    en = "PERFORMANCE HISTORY", hi = "प्रदर्शन इतिहास", es = "HISTORIAL DE RENDIMIENTO",
    fr = "HISTORIQUE DE PERFORMANCE", de = "LEISTUNGSHISTORIE", pt = "HISTÓRICO DE DESEMPENHO",
    ar = "سجل الأداء", ru = "ИСТОРИЯ РЕЗУЛЬТАТИВНОСТИ", sw = "HISTORIA YA UTENDAJI", zh = "表现历史"),
  sessionTimeline = c(
    en = "SESSION TIMELINE", hi = "सत्र टाइमलाइन", es = "LÍNEA DE TIEMPO DE SESIÓN",
    fr = "CHRONOLOGIE DE SÉANCE", de = "SITZUNGSZEITLEISTE", pt = "LINHA DO TEMPO DA SESSÃO",
    ar = "الجدول الزمني للجلسة", ru = "ХРОНОЛОГИЯ СЕАНСОВ", sw = "RATIBA YA KIPINDI", zh = "课程时间线"),
  boneAcl = c(
    en = "BONE HEALTH & ACL RISK", hi = "हड्डी स्वास्थ्य और ACL जोखिम", es = "SALUD ÓSEA Y RIESGO LCA",
    fr = "SANTÉ OSSEUSE & RISQUE LCA", de = "KNOCHEN & KREUZBAND-RISIKO", pt = "SAÚDE ÓSSEA E RISCO LCA",
    ar = "صحة العظام وخطر الرباط الصليبي", ru = "ЗДОРОВЬЕ КОСТЕЙ И РИСК ПКС", sw = "AFYA YA MFUPA NA HATARI YA ACL", zh = "骨骼健康与前交叉韧带风险"),
  cycleShade = c(
    en = "Cycle phase shading", hi = "चक्र चरण छायांकन", es = "Sombreado de fase del ciclo",
    fr = "Ombrage de phase du cycle", de = "Zyklusphasen-Schattierung", pt = "Sombreamento da fase do ciclo",
    ar = "تظليل مرحلة الدورة", ru = "Затенение фазы цикла", sw = "Uwekaji kivuli wa awamu", zh = "周期阶段阴影"),
  forecast4w = c(
    en = "4-week forecast", hi = "4-सप्ताह पूर्वानुमान", es = "Pronóstico de 4 semanas",
    fr = "Prévision 4 semaines", de = "4-Wochen-Prognose", pt = "Previsão de 4 semanas",
    ar = "توقعات 4 أسابيع", ru = "Прогноз на 4 недели", sw = "Utabiri wa wiki 4", zh = "4 周预测"),
  stageREM = c(
    en = "REM", hi = "REM", es = "REM", fr = "REM", de = "REM", pt = "REM",
    ar = "ريم", ru = "БДГ", sw = "REM", zh = "快速眼动"),
  stageDeep = c(
    en = "DEEP", hi = "गहरी", es = "PROFUNDO", fr = "PROFOND", de = "TIEF", pt = "PROFUNDO",
    ar = "عميق", ru = "ГЛУБОКИЙ", sw = "KINA", zh = "深睡"),
  stageLight = c(
    en = "LIGHT", hi = "हल्की", es = "LIGERO", fr = "LÉGER", de = "LEICHT", pt = "LEVE",
    ar = "خفيف", ru = "ЛЁГКИЙ", sw = "MWEPESI", zh = "浅睡"),
  stageAwake = c(
    en = "AWAKE", hi = "जागते हुए", es = "DESPIERTO", fr = "ÉVEIL", de = "WACH", pt = "ACORDADO",
    ar = "مستيقظ", ru = "БОДРСТВОВАНИЕ", sw = "AMKA", zh = "觉醒"),
  tileLactate = c(
    en = "LACTATE", hi = "लैक्टेट", es = "LACTATO", fr = "LACTATE", de = "LAKTAT", pt = "LACTATO",
    ar = "اللاكتات", ru = "ЛАКТАТ", sw = "LACTATE", zh = "血乳酸"),
  tileCoreTemp = c(
    en = "CORE TEMP", hi = "कोर ताप", es = "TEMP CENTRAL", fr = "TEMP CENTRALE", de = "KERSTEMP", pt = "TEMP CENTRAL",
    ar = "الحرارة المركزية", ru = "ТЕМП. ЯДРА", sw = "JOTO KUU", zh = "核心温度"),
  tileSpo2 = c(
    en = "SpO₂", hi = "SpO₂", es = "SpO₂", fr = "SpO₂", de = "SpO₂", pt = "SpO₂",
    ar = "الأكسجين", ru = "SpO₂", sw = "SpO₂", zh = "血氧"),
  tileRespRate = c(
    en = "RESP RATE", hi = "श्वास दर", es = "FREC RESP", fr = "FRQ RESP", de = "ATEMFREQ", pt = "FREQ RESP",
    ar = "معدل التنفس", ru = "ЧДД", sw = "MAPUMZIKO", zh = "呼吸频率"),
  tileCadence = c(
    en = "CADENCE", hi = "कैडेंस", es = "CADENCIA", fr = "CADENCE", de = "TAKT", pt = "CADÊNCIA",
    ar = "الإيقاع", ru = "КАДЕНС", sw = "MWENDO", zh = "步频"),
  tileTorque = c(
    en = "TORQUE", hi = "टॉर्क", es = "PAR", fr = "COUPLE", de = "DREHMOMENT", pt = "TORQUE",
    ar = "عزم الدوران", ru = "КРУТЯЩИЙ МОМЕНТ", sw = "TORQUE", zh = "扭矩"),
  tileRsi = c(
    en = "RSI", hi = "RSI", es = "RSI", fr = "RSI", de = "RSI", pt = "RSI",
    ar = "مؤشر القفز", ru = "RSI", sw = "RSI", zh = "反应力量指数"),
  tileGct = c(
    en = "GCT", hi = "GCT", es = "GCT", fr = "GCT", de = "GCT", pt = "GCT",
    ar = "زمن التلامس", ru = "ВКС", sw = "GCT", zh = "触地时间"),
  calIn = c(
    en = "IN (kcal)", hi = "इन (kcal)", es = "ENTRADA (kcal)", fr = "ENTRÉE (kcal)", de = "REIN (kcal)", pt = "ENTRADA (kcal)",
    ar = "داخل (kcal)", ru = "ПОСТУПЛЕНИЕ (kcal)", sw = "NDANI (kcal)", zh = "摄入 (kcal)"),
  calOut = c(
    en = "OUT (kcal)", hi = "आउट (kcal)", es = "SALIDA (kcal)", fr = "DÉPENSE (kcal)", de = "RAUS (kcal)", pt = "SAÍDA (kcal)",
    ar = "خارج (kcal)", ru = "РАСХОД (kcal)", sw = "NJEA (kcal)", zh = "消耗 (kcal)"),
  choLoad = c(
    en = "CHO load", hi = "CHO लोड", es = "Carga CHO", fr = "Charge CHO", de = "CHO-Last", pt = "Carga CHO",
    ar = "حمل الكربوهيدرات", ru = "Углеводная нагрузка", sw = "Mzigo wa CHO", zh = "碳水负荷"),
  protein = c(
    en = "Protein", hi = "प्रोटीन", es = "Proteína", fr = "Protéines", de = "Protein", pt = "Proteína",
    ar = "البروتين", ru = "Белок", sw = "Protini", zh = "蛋白质"),
  hydration = c(
    en = "Hydration", hi = "जलयोजन", es = "Hidratación", fr = "Hydratation", de = "Flüssigkeit", pt = "Hidratação",
    ar = "الترطيب", ru = "Гидратация", sw = "Maji mwilini", zh = "水合"),
  boneStatus = c(
    en = "Bone Status", hi = "हड्डी की स्थिति", es = "Estado óseo", fr = "État osseux", de = "Knochenstatus", pt = "Estado ósseo",
    ar = "حالة العظام", ru = "Состояние костей", sw = "Hali ya mfupa", zh = "骨骼状态"),
  boneTscore = c(
    en = "Bone Density (T-score)", hi = "अस्थि घनत्व (T-स्कोर)", es = "Densidad ósea (T-score)", fr = "Densité osseuse (T-score)",
    de = "Knochendichte (T-Score)", pt = "Densidade óssea (T-score)", ar = "كثافة العظام (T-score)",
    ru = "Плотность костей (T-критерий)", sw = "Mnfs wa mfupa (T-score)", zh = "骨密度 (T 值)"),
  boneZscore = c(
    en = "Z-score", hi = "Z-स्कोर", es = "Z-score", fr = "Z-score", de = "Z-Score", pt = "Z-score",
    ar = "Z-score", ru = "Z-критерий", sw = "Z-score", zh = "Z 值"),
  boneNormal = c(
    en = "Normal", hi = "सामान्य", es = "Normal", fr = "Normal", de = "Normal", pt = "Normal",
    ar = "طبيعي", ru = "Норма", sw = "Kawaida", zh = "正常"),
  boneOsteopenia = c(
    en = "Osteopenia", hi = "ऑस्टियोपीनिया", es = "Osteopenia", fr = "Ostéopénie", de = "Osteopenie", pt = "Osteopenia",
    ar = "نقص عظم", ru = "Остеопения", sw = "Osteopenia", zh = "骨量减少"),
  boneOsteoporosis = c(
    en = "Osteoporosis", hi = "ऑस्टियोपोरोसिस", es = "Osteoporosis", fr = "Ostéoporose", de = "Osteoporose", pt = "Osteoporose",
    ar = "هشاشة العظام", ru = "Остеопороз", sw = "Osteoporosis", zh = "骨质疏松"),
  dynValgus = c(
    en = "Dynamic valgus", hi = "डायनामिक वैल्गस", es = "Valgo dinámico", fr = "Valgus dynamique", de = "Dynamischer Valgus", pt = "Valgo dinâmico",
    ar = "التأرجح الديناميكي", ru = "Динамический вальгус", sw = "Valgus endelevu", zh = "动态膝外翻"),
  landingMech = c(
    en = "Landing mechanics", hi = "लैंडिंग मैकेनिक्स", es = "Mecánica de aterrizaje", fr = "Mécanique de réception", de = "Landemechanik", pt = "Mecânica de aterrissagem",
    ar = "ميكانيكا الهبوط", ru = "Техника приземления", sw = "Makanika ya kutua", zh = "落地力学"),
  hamQuad = c(
    en = "Ham:Quad ratio", hi = "हैम:क्वाड अनुपात", es = "Relación Isq:Cuád", fr = "Ratio Ischio:Quadri", de = "Ham:Quad-Quote", pt = "Razão Isq:Quad",
    ar = "نسبة الخلفية:الأمامية", ru = "Бицепс:Квадрицепс", sw = "Uwiano wa Ham:Quad", zh = "腘绳:股四头比"),
  lrAsym = c(
    en = "L/R asymmetry", hi = "बाएं/दाएं असममिता", es = "Asimetría I/D", fr = "Asymétrie G/D", de = "L/R-Asymmetrie", pt = "Assimetria E/D",
    ar = "عدم التماثل ي/م", ru = "Асимметрия Л/П", sw = "Kutokuwa sawa K/K", zh = "左右不对称"),
  planTarget = c(
    en = "RPE Target", hi = "RPE लक्ष्य", es = "RPE objetivo", fr = "RPE cible", de = "RPE-Ziel", pt = "RPE alvo",
    ar = "هدف RPE", ru = "Целевой RPE", sw = "Lengo la RPE", zh = "RPE 目标"),
  planIntensity = c(
    en = "Intensity", hi = "तीव्रता", es = "Intensidad", fr = "Intensité", de = "Intensität", pt = "Intensidade",
    ar = "الشدة", ru = "Интенсивность", sw = "Kasi", zh = "强度"),
  planVolume = c(
    en = "Volume", hi = "वॉल्यूम", es = "Volumen", fr = "Volume", de = "Umfang", pt = "Volume",
    ar = "الحجم", ru = "Объём", sw = "Kiasi", zh = "容量"),
  planRest = c(
    en = "Rest between sets", hi = "सेट के बीच आराम", es = "Descanso entre series", fr = "Repos entre séries", de = "Pause zwischen Sätzen", pt = "Descanso entre séries",
    ar = "الراحة بين المجموعات", ru = "Отдых между подходами", sw = "Pumziko kati ya seti", zh = "组间休息"),
  tlTotal = c(
    en = "Total", hi = "कुल", es = "Total", fr = "Total", de = "Gesamt", pt = "Total",
    ar = "الإجمالي", ru = "Всего", sw = "Jumla", zh = "总计"),
  tlGood = c(
    en = "Good", hi = "अच्छा", es = "Buenas", fr = "Bonnes", de = "Gut", pt = "Boas",
    ar = "جيد", ru = "Хорошие", sw = "Nzuri", zh = "良好")
)
for (kk in names(EXTRA_KEYS_V7)) {
  for (lg in intersect(names(EXTRA_KEYS_V7[[kk]]), LANG_CODES)) {
    I18N[[lg]] <- c(I18N[[lg]], setNames(EXTRA_KEYS_V7[[kk]][[lg]], kk))
  }
}
## tlAlerts reuses the existing `critical`/`warning` keys; body counts reuse them too.
EXTRA_KEYS_V7B <- list(
  tlAlerts = c(
    en = "Alerts", hi = "अलर्ट", es = "Alertas", fr = "Alertes", de = "Alarme", pt = "Alertas",
    ar = "تنبيهات", ru = "Тревоги", sw = "Arifa", zh = "警报")
)
for (kk in names(EXTRA_KEYS_V7B)) {
  for (lg in intersect(names(EXTRA_KEYS_V7B[[kk]]), LANG_CODES)) {
    I18N[[lg]] <- c(I18N[[lg]], setNames(EXTRA_KEYS_V7B[[kk]][[lg]], kk))
  }
}

EXTRA_KEYS_V7C <- list(
  noneChoice = c(en = "None", hi = "कोई नहीं", es = "Ninguno", fr = "Aucun", de = "Keine", pt = "Nenhum", ar = "لا يوجد", ru = "Нет", sw = "Hakuna", zh = "无"),
  selectedAthlete = c(en = "SELECTED ATHLETE", hi = "चयनित एथलीट", es = "ATLETA SELECCIONADO", fr = "ATHLÈTE SÉLECTIONNÉ", de = "AUSGEWÄHLTER ATHLET", pt = "ATLETA SELECIONADO", ar = "الرياضي المحدد", ru = "ВЫБРАННЫЙ СПОРТСМЕН", sw = "MWANAMICHEZO ALIYETEULIWA", zh = "当前选中运动员"),
  dayMode = c(en = "DAY", hi = "दिन", es = "DÍA", fr = "JOUR", de = "TAG", pt = "DIA", ar = "نهار", ru = "ДЕНЬ", sw = "MCHANA", zh = "日间"),
  nightMode = c(en = "NIGHT", hi = "रात्रि", es = "NOCHE", fr = "NUIT", de = "NACHT", pt = "NOITE", ar = "ليل", ru = "НОЧЬ", sw = "USIKU", zh = "夜间"),
  zoomIn = c(en = "Zoom In (+)", hi = "ज़ूम इन (+)", es = "Acercar (+)", fr = "Zoom Avant (+)", de = "Vergrößern (+)", pt = "Aproximar (+)", ar = "تكبير (+)", ru = "Приблизить (+)", sw = "Kuza (+)", zh = "放大 (+)"),
  zoomOut = c(en = "Zoom Out (-)", hi = "ज़ूम आउट (-)", es = "Alejar (-)", fr = "Zoom Arrière (-)", de = "Verkleinern (-)", pt = "Afastar (-)", ar = "تصغير (-)", ru = "Отдалить (-)", sw = "Punguza (-)", zh = "缩小 (-)"),
  zoomReset = c(en = "Reset Zoom", hi = "ज़ूम रीसेट", es = "Restablecer Zoom", fr = "Réinitialiser Zoom", de = "Zoom zurücksetzen", pt = "Redefinir Zoom", ar = "إعادة ضبط التكبير", ru = "Сброс масштаба", sw = "Rejesha Ukubwa", zh = "重置缩放")
)
for (kk in names(EXTRA_KEYS_V7C)) {
  for (lg in intersect(names(EXTRA_KEYS_V7C[[kk]]), LANG_CODES)) {
    I18N[[lg]] <- c(I18N[[lg]], setNames(EXTRA_KEYS_V7C[[kk]][[lg]], kk))
  }
}

EXTRA_KEYS_ALERTS <- list(
  athletePrefix = c(
    en = "Athlete", hi = "एथलीट", es = "Atleta", fr = "Athlète", de = "Athlet",
    pt = "Atleta", ar = "الرياضي", ru = "Спортсмен", sw = "Mwanamichezo", zh = "运动员"
  ),
  sqliteOffline = c(
    en = "SQLITE (OFFLINE DB)", hi = "SQLITE (ऑफ़लाइन डेटाबेस)", es = "SQLITE (BD SIN CONEXIÓN)",
    fr = "SQLITE (BD HORS LIGNE)", de = "SQLITE (OFFLINE-DATENBANK)", pt = "SQLITE (BD OFFLINE)",
    ar = "SQLITE (قاعدة بيانات غير متصلة)", ru = "SQLITE (АВТОНОМНАЯ БД)", sw = "SQLITE (HIFADHIDATA YA NJE YA MTANDAO)", zh = "SQLITE (离线数据库)"
  ),
  endpoint = c(
    en = "ENDPOINT", hi = "एंडपॉइंट", es = "PUNTO DE CONEXIÓN", fr = "POINT DE TERMINAISON",
    de = "ENDPUNKT", pt = "PONTO DE EXTREMIDADE", ar = "نقطة النهاية", ru = "КОНЕЧНАЯ ТОЧКА",
    sw = "KIKOMO", zh = "端点"
  ),
  onlineLlm = c(
    en = "Online LLM", hi = "ऑनलाइन एलएलएम", es = "LLM en línea", fr = "LLM en ligne",
    de = "Online-LLM", pt = "LLM online", ar = "نموذج LLM عبر الإنترنت", ru = "Онлайн-LLM",
    sw = "LLM ya Mtandaoni", zh = "在线 LLM"
  ),
  batch = c(
    en = "Batch", hi = "बैच आकार", es = "Tamaño de lote", fr = "Taille du lot",
    de = "Batch-Größe", pt = "Tamanho do lote", ar = "حجم الدفعة", ru = "Размер пакета",
    sw = "Ukubwa wa Kundi", zh = "批处理大小"
  ),
  lowReadiness = c(
    en = "Readiness critically low ({val})",
    hi = "तैयारी का स्तर गंभीर रूप से कम ({val})",
    es = "Disposición críticamente baja ({val})",
    fr = "Préparation particulièrement faible ({val})",
    de = "Bereitschaft kritisch niedrig ({val})",
    pt = "Prontidão criticamente baixa ({val})",
    ar = "مستوى الجاهزية منخفض للغاية ({val})",
    ru = "Критически низкая готовность ({val})",
    sw = "Kiwango cha utayari kiko chini sana ({val})",
    zh = "准备状态极低 ({val})"
  ),
  highLoad = c(
    en = "Training load spike ({val} AU)",
    hi = "प्रशिक्षण भार में भारी वृद्धि ({val} AU)",
    es = "Pico de carga de entrenamiento ({val} AU)",
    fr = "Pic de charge d'entraînement ({val} AU)",
    de = "Trainingslastspitze ({val} AU)",
    pt = "Pico de carga de treino ({val} AU)",
    ar = "ارتفاع حاد في حمل التدريب ({val} وحدة)",
    ru = "Резкий скачок тренировочной нагрузки ({val} AU)",
    sw = "Mzigo wa mafunzo umezidi ghafla ({val} AU)",
    zh = "训练负荷激增 ({val} AU)"
  ),
  lowHrv = c(
    en = "HRV below safe threshold ({val})",
    hi = "एचआरवी सुरक्षित सीमा से नीचे ({val})",
    es = "VFC por debajo del umbral seguro ({val})",
    fr = "VRC sous le seuil de sécurité ({val})",
    de = "HRV unter dem Schwellenwert ({val})",
    pt = "VFC abaixo do limite seguro ({val})",
    ar = "معدل تغير ضربات القلب دون الحد الآمن ({val})",
    ru = "ВСР ниже безопасного порога ({val})",
    sw = "HRV iko chini ya kiwango salama ({val})",
    zh = "心率变异性低于安全阈值 ({val})"
  ),
  highRpe = c(
    en = "RPE elevated ({val}/10)",
    hi = "आरपीई का स्तर अधिक ({val}/10)",
    es = "RPE elevated ({val}/10)",
    fr = "RPE élevé ({val}/10)",
    de = "RPE erhöht ({val}/10)",
    pt = "RPE elevado ({val}/10)",
    ar = "معدل الجهد المبذول مرتفع ({val}/10)",
    ru = "Повышенный уровень RPE ({val}/10)",
    sw = "Kiwango cha RPE kimeongezeka ({val}/10)",
    zh = "主观疲劳度升高 ({val}/10)"
  ),
  poorSleep = c(
    en = "Sleep deprivation ({val}h)",
    hi = "नींद की भारी कमी ({val} घंटे)",
    es = "Privación de sueño ({val} h)",
    fr = "Manque de sommeil ({val} h)",
    de = "Schlafmangel ({val} Std.)",
    pt = "Privação de sono ({val} h)",
    ar = "حرمان من النوم ({val} ساعة)",
    ru = "Недостаток сна ({val} ч)",
    sw = "Ukosefu wa usingizi ({val} saa)",
    zh = "睡眠严重不足 ({val}小时)"
  ),
  highStress = c(
    en = "Stress levels elevated ({val}/7)",
    hi = "तनाव स्तर उच्च ({val}/7)",
    es = "Nivel de estrés elevado ({val}/7)",
    fr = "Niveau de stress élevé ({val}/7)",
    de = "Erhöhtes Stressniveau ({val}/7)",
    pt = "Níveis de estresse elevados ({val}/7)",
    ar = "مستويات التوتر مرتفعة ({val}/7)",
    ru = "Повышенный уровень стресса ({val}/7)",
    sw = "Kiwango cha msongo kimepanda ({val}/7)",
    zh = "压力水平偏高 ({val}/7)"
  ),
  dehydration = c(
    en = "Dehydration risk ({val}%)",
    hi = "निर्जलीकरण का जोखिम ({val}%)",
    es = "Riesgo de deshidratación ({val}%)",
    fr = "Risque de déshydratation ({val}%)",
    de = "Dehydrierungsrisiko ({val}%)",
    pt = "Risco de desidratação ({val}%)",
    ar = "خطر الجفاف ({val}%)",
    ru = "Риск обезвоживания ({val}%)",
    sw = "Hatari ya upungufu wa maji mwilini ({val}%)",
    zh = "脱水风险 ({val}%)"
  ),
  overreach = c(
    en = "Overreach risk ({val}%)",
    hi = "अति-प्रशिक्षण (ओवररीच) जोखिम ({val}%)",
    es = "Riesgo de sobreesfuerzo ({val}%)",
    fr = "Risque de surentraînement ({val}%)",
    de = "Überlastungsrisiko ({val}%)",
    pt = "Risco de sobrecarga ({val}%)",
    ar = "خطر الإجهاد المفرط ({val}%)",
    ru = "Риск перегрузки ({val}%)",
    sw = "Hatari ya mazoezi kupita kiasi ({val}%)",
    zh = "过度训练风险 ({val}%)"
  ),
  hamstringRisk = c(
    en = "Hamstring strain risk ({val}%)",
    hi = "हैमस्ट्रिंग खिंचाव का जोखिम ({val}%)",
    es = "Riesgo de distensión en isquiotibiales ({val}%)",
    fr = "Risque d'élongation des ischio-jambiers ({val}%)",
    de = "Hamstring-Zerrungsrisiko ({val}%)",
    pt = "Risco de distensão nos isquiotibiais ({val}%)",
    ar = "خطر تمزق أوتار الركبة ({val}%)",
    ru = "Риск растяжения подколенного сухожилия ({val}%)",
    sw = "Hatari ya maumivu ya misuli ya paja ({val}%)",
    zh = "腘绳肌拉伤风险 ({val}%)"
  ),
  cardiacRisk = c(
    en = "Cardiac risk elevated ({val}%)",
    hi = "हृदय संबंधी जोखिम बढ़ा हुआ ({val}%)",
    es = "Riesgo cardíaco elevado ({val}%)",
    fr = "Risque cardiaque accru ({val}%)",
    de = "Erhöhtes kardiales Risiko ({val}%)",
    pt = "Risco cardíaco elevado ({val}%)",
    ar = "مخاطر قلبية مرتفعة ({val}%)",
    ru = "Повышенный кардиориск ({val}%)",
    sw = "Hatari ya moyo imeongezeka ({val}%)",
    zh = "心血管负荷偏高 ({val}%)"
  ),
  redsEa = c(
    en = "RED-S: EA {val} kcal/kg FFM",
    hi = "RED-S: ऊर्जा उपलब्धता (EA) {val} kcal/kg FFM",
    es = "RED-S: Disp. Energética {val} kcal/kg FFM",
    fr = "RED-S: Dispo. Énergétique {val} kcal/kg FFM",
    de = "RED-S: Energieverfügbarkeit {val} kcal/kg FFM",
    pt = "RED-S: Disp. Energética {val} kcal/kg FFM",
    ar = "RED-S: توفر الطاقة {val} كيلو كالوري/كجم",
    ru = "RED-S: доступность энергии {val} ккал/кг БМТ",
    sw = "RED-S: Nishati Inayopatikana {val} kcal/kg FFM",
    zh = "RED-S: 能量可用性 {val} kcal/kg FFM"
  ),
  acwrSpike = c(
    en = "ACWR spike: {val}",
    hi = "ACWR में तीव्र वृद्धि: {val}",
    es = "Pico de ACWR: {val}",
    fr = "Pic ACWR: {val}",
    de = "ACWR-Spitze: {val}",
    pt = "Pico de ACWR: {val}",
    ar = "ارتفاع حاد في مؤشر ACWR: {val}",
    ru = "Скачок ACWR: {val}",
    sw = "Ongezeko la ACWR: {val}",
    zh = "ACWR 负荷激增: {val}"
  ),
  trainingPaused = c(
    en = "Training paused (RED-S medical referral)",
    hi = "प्रशिक्षण रोका गया (RED-S चिकित्सीय परामर्श)",
    es = "Entrenamiento pausado (derivación médica RED-S)",
    fr = "Entraînement suspendu (avis médical RED-S)",
    de = "Training pausiert (RED-S medizinische Überweisung)",
    pt = "Treino pausado (encaminhamento médico RED-S)",
    ar = "تم إيقاف التدريب مؤقتاً (إحالة طبية RED-S)",
    ru = "Тренировки приостановлены (направление по RED-S)",
    sw = "Mafunzo yamesitishwa (rufaa ya matibabu ya RED-S)",
    zh = "训练暂停 (RED-S 医疗转诊)"
  ),
  painLabel = c(
    en = "Pain {val}/10 \u2014 {extra}",
    hi = "दर्द {val}/10 \u2014 {extra}",
    es = "Dolor {val}/10 \u2014 {extra}",
    fr = "Douleur {val}/10 \u2014 {extra}",
    de = "Schmerz {val}/10 \u2014 {extra}",
    pt = "Dor {val}/10 \u2014 {extra}",
    ar = "الألم {val}/10 \u2014 {extra}",
    ru = "Боль {val}/10 \u2014 {extra}",
    sw = "Maumivu {val}/10 \u2014 {extra}",
    zh = "疼痛 {val}/10 \u2014 {extra}"
  )
)
for (kk in names(EXTRA_KEYS_ALERTS)) {
  for (lg in intersect(names(EXTRA_KEYS_ALERTS[[kk]]), LANG_CODES)) {
    I18N[[lg]] <- c(I18N[[lg]], setNames(EXTRA_KEYS_ALERTS[[kk]][[lg]], kk))
  }
}

EXTRA_KEYS_ENGINE <- list(
  rEngine = c(
    en = "R Analytics Engine",
    hi = "R एनालिटिक्स इंजन",
    es = "Motor de análisis R",
    fr = "Moteur d'analyse R",
    de = "R-Analyse-Engine",
    pt = "Motor de análise R",
    ar = "محرك تحليلات R",
    ru = "Аналитический движок R",
    sw = "Injini ya Uchambuzi ya R",
    zh = "R 分析引擎"
  ),
  cdssRules = c(
    en = "Clinical CDSS Rules",
    hi = "क्लिनिकल CDSS नियम",
    es = "Reglas clínicas CDSS",
    fr = "Règles cliniques CDSS",
    de = "Klinische CDSS-Regeln",
    pt = "Regras clínicas CDSS",
    ar = "قواعد CDSS السريرية",
    ru = "Клинические правила CDSS",
    sw = "Sheria za Kliniki za CDSS",
    zh = "临床 CDSS 规则"
  ),
  sqliteStorage = c(
    en = "SQLite Storage Engine",
    hi = "SQLite स्टोरेज इंजन",
    es = "Motor de almacenamiento SQLite",
    fr = "Moteur de stockage SQLite",
    de = "SQLite-Speicher-Engine",
    pt = "Motor de armazenamento SQLite",
    ar = "محرك تخزين SQLite",
    ru = "Хранилище SQLite",
    sw = "Injini ya Hifadhi ya SQLite",
    zh = "SQLite 存储引擎"
  ),
  fastapiCore = c(
    en = "FastAPI Core",
    hi = "FastAPI कोर",
    es = "Núcleo FastAPI",
    fr = "Cœur FastAPI",
    de = "FastAPI-Kern",
    pt = "Núcleo FastAPI",
    ar = "نواة FastAPI",
    ru = "Ядро FastAPI",
    sw = "Kiini cha FastAPI",
    zh = "FastAPI 核心"
  )
)
for (kk in names(EXTRA_KEYS_ENGINE)) {
  for (lg in intersect(names(EXTRA_KEYS_ENGINE[[kk]]), LANG_CODES)) {
    I18N[[lg]] <- c(I18N[[lg]], setNames(EXTRA_KEYS_ENGINE[[kk]][[lg]], kk))
  }
}

INJURY_LOC_I18N <- list(
  shoulder = c(en = "shoulder", hi = "\u0915\u0902\u0927\u093e", es = "hombro", fr = "\u00e9paule", de = "Schulter", pt = "ombro", ar = "\u0627\u0644\u0643\u062a\u0641", ru = "\u043f\u043b\u0435\u0447\u043e", sw = "bega", zh = "\u80a9\u90e8"),
  knee = c(en = "knee", hi = "\u0918\u0941\u091f\u0928\u093e", es = "rodilla", fr = "genou", de = "Knie", pt = "joelho", ar = "\u0627\u0644\u0631\u0643\u0628\u0629", ru = "\u043a\u043e\u043b\u0435\u043d\u043e", sw = "goti", zh = "\u819d\u76d6"),
  hamstring = c(en = "hamstring", hi = "\u0939\u0948\u092e\u0938\u094d\u091f\u094d\u0930\u093f\u0902\u0917", es = "isquiotibial", fr = "ischio-jambier", de = "Kniesehne", pt = "isquiotibial", ar = "\u0623\u0648\u062a\u0627\u0631 \u0627\u0644\u0631\u0643\u0628\u0629", ru = "\u043f\u043e\u0434\u043a\u043e\u043b\u0435\u043d\u043d\u043e\u0435 \u0441\u0443\u0445\u043e\u0436\u0438\u043b\u0438\u0435", sw = "misuli ya nyuma ya paja", zh = "\u8158\u7ef3\u808c"),
  ankle = c(en = "ankle", hi = "\u091f\u0916\u0928\u093e", es = "tobillo", fr = "cheville", de = "Kn\u00f6chel", pt = "tornozelo", ar = "\u0627\u0644\u0643\u0627\u062d\u0644", ru = "\u043b\u043e\u0434\u044b\u0436\u043a\u0430", sw = "kifundo cha mguu", zh = "\u811a\u8e1d"),
  calf = c(en = "calf", hi = "\u092a\u093f\u0902\u0921\u0932\u0940", es = "pantorrilla", fr = "mollet", de = "Wade", pt = "panturrilha", ar = "\u0628\u0637\u0629 \u0627\u0644\u0633\u0627\u0642", ru = "\u0438\u043a\u0440\u0430", sw = "nyama ya ndama", zh = "\u5c0f\u817f"),
  back = c(en = "back", hi = "\u092a\u0940\u0920", es = "espalda", fr = "dos", de = "R\u00fccken", pt = "costas", ar = "\u0627\u0644\u0638\u0647\u0631", ru = "\u0441\u043f\u0438\u043d\u0430", sw = "mgongo", zh = "\u80cc\u90e8"),
  quad = c(en = "quad", hi = "\u0915\u094d\u0935\u093e\u0921\u094d\u0930\u093f\u0938\u0947\u092a\u094d\u0938", es = "cu\u00e1driceps", fr = "quadriceps", de = "Quadrizeps", pt = "quadr\u00edceps", ar = "\u0627\u0644\u0639\u0636\u0644\u0629 \u0627\u0644\u0631\u0628\u0627\u0639\u064a\u0629", ru = "\u0447\u0435\u0442\u044b\u0440\u0435\u0445\u0433\u043b\u0430\u0432\u0430\u044f \u043c\u044b\u0448\u0446\u0430", sw = "misuli ya mbele ya paja", zh = "\u80a1\u56db\u5934\u808c"),
  groin = c(en = "groin", hi = "\u0935\u0902\u0915\u094d\u0937\u0923", es = "ingle", fr = "aine", de = "Leiste", pt = "virilha", ar = "\u0623\u0635\u0644 \u0627\u0644\u0641\u062e\u0630", ru = "\u043f\u0430\u0445", sw = "kinena", zh = "\u8149\u80a1\u6c9f"),
  foot = c(en = "foot", hi = "\u092a\u0948\u0930", es = "pie", fr = "pied", de = "Fu\u00df", pt = "p\u00e9", ar = "\u0627\u0644\u0642\u062f\u0645", ru = "\u0441\u0442\u043e\u043f\u0430", sw = "mguu", zh = "\u8db3\u90e8"),
  hip = c(en = "hip", hi = "\u0915\u0942\u0932\u094d\u0939\u093e", es = "cadera", fr = "hanche", de = "H\u00fcfte", pt = "quadril", ar = "\u0627\u0644\u0648\u0631\u0643", ru = "\u0431\u0435\u0434\u0440\u043e", sw = "nyonga", zh = "\u9ad6\u90e8"),
  shin = c(en = "shin", hi = "\u092a\u093f\u0902\u0921\u0932\u0940 \u0915\u0940 \u0939\u0921\u094d\u0921\u0940", es = "espinilla", fr = "tibia", de = "Schienbein", pt = "canela", ar = "\u0642\u0635\u0628\u0629 \u0627\u0644\u0633\u0627\u0642", ru = "\u0433\u043e\u043b\u0435\u043d\u044c", sw = "muundi", zh = "\u80eb\u9aa8"),
  achilles = c(en = "achilles", hi = "\u090f\u0915\u093f\u0932\u0940\u0938 \u091f\u0947\u0902\u0921\u0928", es = "tend\u00f3n de Aquiles", fr = "tendon d'Achille", de = "Achillessehne", pt = "tend\u00e3o de Aquiles", ar = "\u0648\u062a\u0631 \u0627\u0644\u0639\u0631\u0642\u0648\u0628", ru = "\u0430\u0445\u0438\u043b\u043b\u043e\u0432\u043e \u0441\u0443\u0445\u043e\u0436\u0438\u043b\u0438\u0435", sw = "kano la akili", zh = "\u8ddf\u8171")
)

translate_injury_loc <- function(loc, lang = "en") {
  if (is.null(loc) || length(loc) == 0 || is.na(loc[1]) || !nzchar(as.character(loc[1]))) return("")
  k <- tolower(trimws(as.character(loc[1])))
  if (k %in% names(INJURY_LOC_I18N)) {
    entry <- INJURY_LOC_I18N[[k]]
    if (lang %in% names(entry)) return(entry[[lang]])
    if ("en" %in% names(entry)) return(entry[["en"]])
  }
  as.character(loc[1])
}

format_alert_text <- function(rule_key, val = NULL, extra = NULL, lang = "en") {
  if (is.null(rule_key) || !nzchar(rule_key)) return("")
  tpl <- tr_raw(lang, rule_key)
  if (!nzchar(tpl) || identical(tpl, rule_key)) {
    tpl <- tr_raw("en", rule_key)
  }
  if (!nzchar(tpl) || identical(tpl, rule_key)) {
    return(paste(rule_key, val %||% "", extra %||% ""))
  }
  if (!is.null(val) && length(val) > 0 && !is.na(val[1])) {
    digits <- switch(rule_key,
      lowReadiness = 0,
      highLoad = 0,
      lowHrv = 0,
      highRpe = 0,
      poorSleep = 1,
      highStress = 0,
      dehydration = 0,
      overreach = 0,
      hamstringRisk = 0,
      cardiacRisk = 0,
      redsEa = 1,
      acwrSpike = 2,
      painLabel = 0,
      0
    )
    val_str <- fmt_num(val[1], digits, lang)
    tpl <- gsub("\\{val\\}", val_str, tpl)
  }
  if (!is.null(extra) && length(extra) > 0 && !is.na(extra[1]) && nzchar(as.character(extra[1]))) {
    extra_str <- if (identical(rule_key, "painLabel")) translate_injury_loc(extra[1], lang) else as.character(extra[1])
    tpl <- gsub("\\{extra\\}", extra_str, tpl)
  }
  tpl
}

format_athlete_name <- function(nm, lang = "en") {
  if (is.null(nm) || length(nm) == 0) return(character(0))
  prefix <- tr_raw(lang, "athletePrefix")
  if (!nzchar(prefix) || identical(prefix, "athletePrefix")) prefix <- "Athlete"
  gsub("^Athlete\\b", prefix, as.character(nm))
}

for (lg in LANG_CODES) {
  d <- I18N[[lg]]
  if (!is.null(d)) {
    if (!"vo2max" %in% names(d) && "hudVo2" %in% names(d)) d["vo2max"] <- d[["hudVo2"]]
    if (!"heartRate" %in% names(d) && "hudHr" %in% names(d)) d["heartRate"] <- d[["hudHr"]]
    if (!"powerOutput" %in% names(d) && "hudPower" %in% names(d)) d["powerOutput"] <- d[["hudPower"]]
    if (!"readiness" %in% names(d) && "hudReadiness" %in% names(d)) d["readiness"] <- d[["hudReadiness"]]
    if (!"hudVo2" %in% names(d) && "vo2max" %in% names(d)) d["hudVo2"] <- d[["vo2max"]]
    if (!"hudHr" %in% names(d) && "heartRate" %in% names(d)) d["hudHr"] <- d[["heartRate"]]
    if (!"hudPower" %in% names(d) && "powerOutput" %in% names(d)) d["hudPower"] <- d[["powerOutput"]]
    if (!"hudReadiness" %in% names(d) && "readiness" %in% names(d)) d["hudReadiness"] <- d[["readiness"]]
    I18N[[lg]] <- d
  }
}

## =============================================================================
## 3 · MICRO-UTILITIES (all NA-safe, vectorised)
## =============================================================================

clamp <- function(x, lo, hi) {
  x <- suppressWarnings(as.numeric(x))
  if (length(x) == 0) return(lo)
  x[is.na(x)] <- lo
  pmin(pmax(x, lo), hi)
}

safe_num <- function(x, default = 0) {
  v <- suppressWarnings(as.numeric(x))
  if (length(v) == 0 || all(is.na(v))) return(default)
  v[is.na(v)] <- default
  v
}

jget <- function(x, ..., default = NULL) {          # safe nested-list accessor
  cur <- x
  for (nm in list(...)) {
    if (is.null(cur)) return(default)
    if (is.list(cur)) cur <- cur[[nm]] else return(default)
  }
  if (is.null(cur)) default else cur
}

initials_of <- function(name) {
  n <- trimws(as.character(name %||% "?"))
  if (!nzchar(n)) return("??")
  parts <- strsplit(n, "\\s+")[[1]]
  paste0(toupper(substr(parts[1], 1, 1)), toupper(substr(parts[length(parts)], 1, 1)))
}

# Deterministic hash/uniform helpers (v7): stable pseudo-random values seeded by
# any string (athlete id + salt). Same style as avatar_color(); no global RNG state,
# safe inside normalize_athletes().
det_hash <- function(s) {
  h <- 7
  for (ch in strsplit(as.character(s %||% "x"), "")[[1]]) h <- (h * 31 + utf8ToInt(ch)) %% 100000
  h
}
det_unif <- function(seed_str, salt = 0) {
  (det_hash(paste0(seed_str, "|", salt)) * 2654435761 + det_hash(salt)) %% 100000 / 100000
}

avatar_color <- function(name) {
  h <- 0
  for (ch in strsplit(as.character(name %||% "x"), "")[[1]]) h <- (h * 31 + utf8ToInt(ch)) %% 100000
  AVATAR_COLORS[(h %% length(AVATAR_COLORS)) + 1]
}

time_ago <- function(ts, lang = "en") {
  d <- as.numeric(difftime(Sys.time(), ts, units = "secs"))
  if (is.na(d)) return(tr_raw(lang, "na_"))
  if (d < 60)       paste0("<1 min")
  else if (d < 3600)  paste0(as.integer(d / 60), " min")
  else if (d < 86400) paste0(as.integer(d / 3600), " h")
  else                paste0(as.integer(d / 86400), " d")
}

fmt_time_hhmmss <- function(secs) {
  secs <- max(0, as.integer(secs %||% 0))
  sprintf("%02d:%02d:%02d", secs %/% 3600, (secs %% 3600) %/% 60, secs %% 60)
}

## -----------------------------------------------------------------------------
## SPORTS-SCIENCE MODELS (mirror tasks.py + Foster/Gabbett literature)
## -----------------------------------------------------------------------------

# Composite daily readiness 0-100.
# Weights documented in UI: sleep 35 / fatigue 20 / soreness 15 / stress 15 / pain 15.
readiness_score <- function(sleep_hours, sleep_quality, stress, fatigue, soreness, pain) {
  sh  <- clamp(safe_num(sleep_hours, 7), 0, 16)
  sq  <- clamp(safe_num(sleep_quality, 4), 1, 7)
  st  <- clamp(safe_num(stress, 3), 1, 7)
  fa  <- clamp(safe_num(fatigue, 3), 1, 7)
  so  <- clamp(safe_num(soreness, 2), 1, 7)
  pa  <- clamp(safe_num(pain, 0), 0, 10)
  sleep_part <- (pmin(sh / 8, 1) * 0.7 + (sq - 1) / 6 * 0.3)
  fa_part    <- (7 - fa) / 6
  so_part    <- (7 - so) / 6
  st_part    <- (7 - st) / 6
  pa_part    <- 1 - pa / 10
  round(100 * (0.35 * sleep_part + 0.20 * fa_part + 0.15 * so_part +
               0.15 * st_part + 0.15 * pa_part))
}

status_from_readiness <- function(r) {
  r <- safe_num(r, 50)
  ifelse(r >= READY_GREEN, "green", ifelse(r >= READY_AMBER, "amber", "red"))
}

# Energy availability — faithful port of tasks.py::_calculate_energy_availability
ea_calculate <- function(calories, daily_load, ffm, duration_minutes = 60,
                         exercise_type = NULL, body_mass_kg = NULL,
                         gender = "Male", cycle_phase = "") {
  calories <- safe_num(calories, NA_real_)
  ffm      <- safe_num(ffm, NA_real_)
  if (is.na(ffm) || ffm <= 0 || is.na(calories) || calories <= 0) {
    return(list(ea_value = NA_real_, ea_status = "INSUFFICIENT_DATA",
                net_eee = NA_real_, band = "INSUFFICIENT_DATA"))
  }
  ex <- tolower(as.character(exercise_type %||% ""))
  gross_eee <- NA_real_
  if (!is.null(body_mass_kg) && !is.na(safe_num(body_mass_kg, NA_real_)) &&
      ex %in% names(EXERCISE_MET)) {
    met       <- EXERCISE_MET[[ex]]
    gross_eee <- (met * 3.5 * safe_num(body_mass_kg) / 200) * safe_num(duration_minutes, 60)
  } else if (safe_num(daily_load, 0) > 0) {
    gross_eee <- safe_num(daily_load) * 1.5
  } else {
    return(list(ea_value = NA_real_, ea_status = "INSUFFICIENT_DATA",
                net_eee = NA_real_, band = "INSUFFICIENT_DATA"))
  }
  # Cunningham 1980/1991 equation (clinical gold standard for athletic FFM): BMR = 500 + 22*FFM
  rmr_per_min          <- (500 + 22 * ffm) / 1440
  rmr_during_exercise  <- rmr_per_min * safe_num(duration_minutes, 60)
  net_eee              <- max(gross_eee - rmr_during_exercise, 0)
  luteal_penalty       <- if (tolower(gender) == "female" && tolower(cycle_phase) == "luteal") 150 else 0
  ea                   <- (calories - luteal_penalty - net_eee) / ffm
  ea_status <- if (ea >= EA_OPTIMAL) "GREEN" else if (ea >= EA_CRITICAL) "YELLOW" else "RED"
  band      <- if (ea >= EA_OPTIMAL) "OPTIMAL" else if (ea >= EA_CRITICAL) "SUB_OPTIMAL" else "CLINICAL_RISK"
  list(ea_value = round(ea, 2), ea_status = ea_status, net_eee = round(net_eee, 2),
       band = band, luteal_penalty = luteal_penalty, gross_eee = round(gross_eee, 2))
}

ea_risk_level <- function(ea) {
  if (is.na(ea)) return("na")
  if (ea >= EA_OPTIMAL) "low" else if (ea >= EA_CRITICAL) "mod" else "high"
}

# Continuous EWMA matching Plumber R engine and Gabbett / Williams et al. (2017)
calc_ewma_vec <- function(values, span) {
  n <- length(values)
  if (n == 0) return(numeric(0))
  decay <- 2 / (span + 1)
  ewma <- rep(NA_real_, n)
  first_valid <- which(!is.na(values))[1]
  if (is.na(first_valid)) return(ewma)
  ewma[first_valid] <- values[first_valid]
  if (n > first_valid) {
    for (i in (first_valid + 1):n) {
      curr <- if (is.na(values[i])) 0 else values[i]
      ewma[i] <- decay * curr + (1 - decay) * ewma[i - 1]
    }
  }
  ewma
}

# ACWR — uncoupled EWMA (Williams et al. 2017; Windt & Gabbett 2019) with Gabbett zone banding.
acwr_series <- function(loads) {
  loads <- safe_num(loads, 0)
  n <- length(loads)
  if (n < 7) return(list(acwr = rep(NA_real_, n), acute = rep(NA_real_, n), chronic = rep(NA_real_, n)))
  acute <- calc_ewma_vec(loads, 7)
  chronic <- calc_ewma_vec(loads, 28)
  # Uncoupled chronic load removes acute 7-day contribution to avoid mathematical coupling
  chronic_uncoupled <- (28 * chronic - 7 * acute) / 21
  chronic_safe <- ifelse(!is.na(chronic_uncoupled) & chronic_uncoupled > 1, chronic_uncoupled, chronic)
  acwr <- ifelse(chronic_safe > 0, acute / chronic_safe, NA_real_)
  list(acwr = acwr, acute = acute, chronic = chronic_safe)
}

acwr_zone <- function(v) {
  out <- rep("na", length(v))
  out[!is.na(v) & v < ACWR_LOW]                 <- "under"
  out[!is.na(v) & v >= ACWR_LOW & v <= ACWR_SWEET] <- "sweet"
  out[!is.na(v) & v > ACWR_SWEET & v <= ACWR_DANGER] <- "danger"
  out[!is.na(v) & v > ACWR_DANGER]              <- "extreme"
  out
}

# Foster monotony & strain on a rolling 7-day window (daily mean TL / SD TL).
monotony_strain <- function(loads) {
  loads <- safe_num(loads, 0)
  n <- length(loads)
  mon <- rep(NA_real_, n); strn <- rep(NA_real_, n)
  if (n >= 7) {
    for (i in 7:n) {
      w <- loads[(i - 6):i]
      sdw <- stats::sd(w)
      mon[i] <- if (!is.na(sdw) && sdw > 0) mean(w) / sdw else NA_real_
      strn[i] <- if (!is.na(mon[i])) sum(w) * mon[i] else NA_real_
    }
  }
  list(monotony = mon, strain = strn)
}

# Simple explainable injury-forecast proxy (0-100): load spike + pain + fatigue.
injury_forecast_score <- function(acwr_last, pain, fatigue, soreness, monotony_last) {
  ac <- safe_num(acwr_last, 1); ac <- if (is.na(ac)) 1 else clamp(ac, 0, 3)
  pain <- clamp(safe_num(pain, 0), 0, 10)
  fa <- clamp(safe_num(fatigue, 3), 1, 7); so <- clamp(safe_num(soreness, 2), 1, 7)
  mn <- safe_num(monotony_last, 1.5); mn <- if (is.na(mn)) 1.5 else clamp(mn, 0, 4)
  s <- 100 * (0.35 * pmin(abs(ac - 1.15) / 1.0, 1) +
              0.25 * (pain / 10) +
              0.15 * ((fa - 1) / 6) +
              0.15 * ((so - 1) / 6) +
              0.10 * pmax((mn - 1.5) / 2.5, 0))
  round(clamp(s, 0, 100))
}

# Rule-based Clinical Decision Support System (CDSS) recommendation engine (transparent, clinician-reviewable; IOC, Gabbett, Foster, Hooper-Mackinnon).
ai_recommendations <- function(a, lang = "en") {
  recs <- character(0)
  r   <- safe_num(a$readiness, 50)
  ea  <- a$ea
  ac  <- a$acwr
  mn  <- a$monotony
  fa  <- safe_num(a$fatigue, 3); sl <- safe_num(a$sleep_hours, 7)
  st  <- safe_num(a$stress, 3);  so <- safe_num(a$soreness, 2)
  if (!is.na(ea) && ea < EA_CRITICAL)
    recs <- c(recs, paste0("\u26A0 ", tr_raw(lang, "critical"), ": EA = ", fmt_num(ea, 1, lang), " kcal/kg FFM — ", tr_raw(lang, "clinicalRec")))
  else if (!is.na(ea) && ea < EA_OPTIMAL)
    recs <- c(recs, paste0("\u25D0 EA ", fmt_num(ea, 1, lang), " — ", tr_raw(lang, "caution3045")))
  if (!is.null(ac) && !is.na(ac) && ac > ACWR_DANGER)
    recs <- c(recs, paste0("\u26A0 ACWR ", fmt_num(ac, 2, lang), " — ", tr_raw(lang, "highRisk")))
  if (!is.null(ac) && !is.na(ac) && ac < ACWR_LOW)
    recs <- c(recs, paste0("\u25CB ACWR ", fmt_num(ac, 2, lang), " — detraining"))
  if (!is.null(mn) && !is.na(mn) && mn > 2.0)
    recs <- c(recs, paste0("\u25D0 ", tr_raw(lang, "monotonyTitle"), ": ", fmt_num(mn, 2, lang)))
  if (r < READY_AMBER)
    recs <- c(recs, paste0("\u26A0 ", tr_raw(lang, "readiness"), " ", fmt_num(r, 0, lang), " — ", tr_raw(lang, "filterRed")))
  else if (r < READY_GREEN)
    recs <- c(recs, paste0("\u25D0 ", tr_raw(lang, "readiness"), " ", fmt_num(r, 0, lang), " — ", tr_raw(lang, "filterAmber")))
  if (sl < 6)
    recs <- c(recs, paste0("\u25CB ", tr_raw(lang, "sleepH"), ": ", fmt_num(sl, 1, lang), " < 6h — sleep extension protocol"))
  if (st >= 5)
    recs <- c(recs, paste0("\u25CB ", tr_raw(lang, "stress"), ": ", fmt_num(st, 0, lang), "/7 — recovery/relaxation session"))
  if (so >= 5)
    recs <- c(recs, paste0("\u25CB ", tr_raw(lang, "soreness"), ": ", fmt_num(so, 0, lang), "/7 — mobility + protein timing"))
  if (!length(recs)) recs <- paste0("\u25CF ", tr_raw(lang, "statusOnline"))
  recs
}

## -----------------------------------------------------------------------------
## INLINE SVG WIDGETS (zero-dependency rings, gauges, sparklines, heatmaps)
## -----------------------------------------------------------------------------

ring_svg <- function(value, vmax = 100, color = "#00E5FF", size = 92, stroke = 8, label = "") {
  v <- clamp(safe_num(value, 0), 0, vmax)
  frac <- if (vmax > 0) v / vmax else 0
  r <- (size - stroke) / 2
  cxy <- size / 2
  circ <- 2 * pi * r
  paste0(
    '<svg width="', size, '" height="', size, '" viewBox="0 0 ', size, ' ', size,
    '" role="img" aria-label="', label, ' ', round(v), '">',
    '<circle cx="', cxy, '" cy="', cxy, '" r="', r, '" fill="none" stroke="rgba(128,128,128,.25)" stroke-width="', stroke, '"/>',
    '<circle cx="', cxy, '" cy="', cxy, '" r="', r, '" fill="none" stroke="', color,
    '" stroke-width="', stroke, '" stroke-linecap="round" stroke-dasharray="',
    sprintf("%.1f", frac * circ), ',', sprintf("%.1f", circ),
    '" transform="rotate(-90 ', cxy, ' ', cxy, ')"/>',
    '<text x="50%" y="54%" text-anchor="middle" dominant-baseline="middle" fill="currentColor" font-size="', size / 4.2, '" font-weight="800">',
    round(v), '</text></svg>'
  )
}

sparkline_svg <- function(values, color = "#00E5FF", w = 90, h = 26) {
  v <- safe_num(values, NA_real_)
  v <- v[!is.na(v)]
  if (length(v) < 2) return(paste0('<svg width="', w, '" height="', h, '"></svg>'))
  if (length(v) > 14) v <- tail(v, 14)
  rng <- range(v); if (diff(rng) == 0) rng[2] <- rng[1] + 1
  xs <- seq(0, w, length.out = length(v))
  ys <- h - ((v - rng[1]) / diff(rng)) * (h - 4) - 2
  pts <- paste0(sprintf("%.1f,%.1f", xs, ys), collapse = " ")
  paste0('<svg width="', w, '" height="', h, '" class="sparkline" aria-hidden="true">',
         '<polyline points="', pts, '" fill="none" stroke="', color,
         '" stroke-width="1.6" stroke-linejoin="round" stroke-linecap="round" opacity=".9"/></svg>')
}

status_color <- function(s) switch(s %||% "red", green = "#00FF88", amber = "#FFAA00", red = "#FF2244", "#FF2244")

## =============================================================================
## 4 · HTTP LAYER — timeouts, bounded retries, circuit breaker, demo fallback
## =============================================================================

ATH <- new.env(parent = emptyenv())
ATH$base_url   <- API_BASE_DEFAULT
ATH$token      <- NULL
ATH$role       <- NULL
ATH$user_id    <- NULL
ATH$fail_streak <- 0L
ATH$breaker_open <- FALSE
ATH$demo_mode  <- TRUE          # start in demo; flips to live/sqlite on success
ATH$data_source <- "demo"       # "live", "sqlite", or "demo"
ATH$last_ok    <- NULL
ATH$latency_ms <- NA_real_

BREAKER_TRIP  <- 1L             # consecutive failures to open breaker (fast trip)
BREAKER_PROBE <- 60L            # seconds before allowing a probe while open

athena_set_token <- function(token, user_id = NULL, role = NULL) {
  ATH$token <- if (is.character(token) && nzchar(token)) token else NULL
  ATH$user_id <- user_id; ATH$role <- role
}

athena_headers <- function() {
  h <- c("Content-Type" = "application/json", "Accept" = "application/json")
  if (!is.null(ATH$token)) h <- c(h, "Authorization" = paste("Bearer", ATH$token))
  h
}

# Core fetch. Never throws; returns list(ok=, status=, data=, error=).
# Offline-first: if circuit breaker is tripped or SQLite offline mode is active, returns immediately (0ms lag).
athena_fetch <- function(method = "GET", path = "/", body = NULL,
                         timeout = 1, retries = 0) {
  if (isTRUE(ATH$breaker_open) || identical(ATH$data_source, "sqlite")) {
    return(list(ok = FALSE, status = 0L, data = NULL, error = "offline", latency = NA_real_))
  }
  url <- paste0(sub("/+$", "", ATH$base_url), if (startsWith(path, "/")) path else paste0("/", path))
  res <- list(ok = FALSE, status = 0L, data = NULL, error = NULL, latency = NA_real_)
  for (attempt in seq_len(max(1, retries + 1))) {
    t0 <- Sys.time()
    raw <- tryCatch({
      if (identical(method, "GET"))
        httr::GET(url, httr::add_headers(.headers = athena_headers()), httr::timeout(timeout))
      else
        httr::POST(url, httr::add_headers(.headers = athena_headers()),
                   body = jsonlite::toJSON(body %||% list(), auto_unbox = TRUE, na = "null"),
                   httr::timeout(timeout))
    }, error = function(e) structure(list(err = conditionMessage(e)), class = "athena_err"))
    lat <- as.numeric(difftime(Sys.time(), t0, units = "secs")) * 1000
    if (inherits(raw, "athena_err")) {
      res$error <- raw$err; res$latency <- lat
    } else {
      res$latency <- lat
      res$status  <- httr::status_code(raw)
      parsed <- tryCatch(jsonlite::fromJSON(httr::content(raw, as = "text", encoding = "UTF-8"),
                                            simplifyVector = FALSE),
                         error = function(e) NULL)
      if (res$status >= 200 && res$status < 300) {
        res$ok <- TRUE; res$data <- parsed; res$error <- NULL
        break
      } else {
        res$error <- jget(parsed, "detail", default = paste("HTTP", res$status))
      }
    }
  }
  ## circuit breaker bookkeeping
  if (isTRUE(res$ok)) {
    ATH$fail_streak <- 0L; ATH$breaker_open <- FALSE
    ATH$demo_mode <- FALSE; ATH$last_ok <- Sys.time(); ATH$latency_ms <- res$latency
  } else {
    ATH$fail_streak <- ATH$fail_streak + 1L
    if (ATH$fail_streak >= BREAKER_TRIP) ATH$breaker_open <- TRUE
  }
  res
}

athena_get  <- function(path, timeout = 1, retries = 0) athena_fetch("GET",  path, NULL,     timeout, retries)
athena_post <- function(path, body = list(), timeout = 2, retries = 0) athena_fetch("POST", path, body, timeout, retries)

conn_label <- function(lang) {
  src <- ATH$data_source %||% (if (isTRUE(ATH$demo_mode)) "demo" else "live")
  if (src == "sqlite") return(tr_raw(lang, "sqliteOffline"))
  if (isTRUE(ATH$demo_mode)) tr_raw(lang, "statusOffline") else tr_raw(lang, "statusOnline")
}

find_athena_db <- function() {
  candidates <- c(
    Sys.getenv("ATHENA_DB_PATH", ""),
    file.path(getwd(), "athena.db"),
    file.path(getwd(), "..", "athena.db"),
    file.path(Sys.getenv("HOME", "~"), "Projects", "ATHENA", "athena.db"),
    file.path(Sys.getenv("HOME", "~"), "Projects", "MissionATHENA", "athena.db")
  )
  for (cand in candidates) {
    if (nzchar(cand) && file.exists(cand)) return(normalizePath(cand))
  }
  NULL
}

normalize_athletes_df <- function(raw_df) {
  if (is.null(raw_df) || nrow(raw_df) == 0) return(NULL)
  n <- nrow(raw_df)
  uids <- as.character(raw_df$user_id)
  gen <- tolower(ifelse(is.na(raw_df$gender) | raw_df$gender == "", "male", raw_df$gender))
  
  raw_name <- if ("name" %in% names(raw_df)) as.character(raw_df$name) else rep("", n)
  ath_name <- ifelse(nzchar(raw_name) & raw_name != uids, raw_name,
              ifelse(grepl("^ATH-", uids), paste("Athlete", uids),
              ifelse(grepl("^[0-9]+$", uids), paste0("Athlete ATH-", sprintf("%03d", suppressWarnings(as.integer(uids)))),
              paste("Athlete", uids))))
  
  raw_sport <- if ("sport" %in% names(raw_df)) as.character(raw_df$sport) else rep("", n)
  hash_sport <- SPORTS[(vapply(uids, function(u) sum(as.integer(charToRaw(u))), integer(1)) %% length(SPORTS)) + 1]
  ath_sport <- ifelse(nzchar(raw_sport), raw_sport, hash_sport)
  
  dload <- ifelse(is.na(raw_df$daily_load), 0, as.numeric(raw_df$daily_load))
  rpe_v <- ifelse(is.na(raw_df$rpe), 0, as.numeric(raw_df$rpe))
  sh_v  <- ifelse(is.na(raw_df$sleep_hours), 7.5, as.numeric(raw_df$sleep_hours))
  sq_v  <- ifelse(is.na(raw_df$sleep_quality), 5L, as.integer(clamp(raw_df$sleep_quality, 1, 7)))
  st_v  <- ifelse(is.na(raw_df$stress), 3L, as.integer(clamp(raw_df$stress, 1, 7)))
  fa_v  <- ifelse(is.na(raw_df$fatigue), 3L, as.integer(clamp(raw_df$fatigue, 1, 7)))
  ms_v  <- ifelse(is.na(raw_df$muscle_soreness), 2L, as.integer(clamp(raw_df$muscle_soreness, 1, 7)))
  pl_v  <- ifelse(is.na(raw_df$pain_level), 0L, as.integer(clamp(raw_df$pain_level, 0, 10)))
  inj_v <- ifelse(is.na(raw_df$injury_location), "", as.character(raw_df$injury_location))
  cal_v <- ifelse(is.na(raw_df$calories) | raw_df$calories <= 0,
                  ifelse(gen == "female", 2200, 2800), as.numeric(raw_df$calories))
  ffm_v <- ifelse(is.na(raw_df$ffm) | raw_df$ffm <= 0,
                  ifelse(gen == "female", 50, 68), as.numeric(raw_df$ffm))
  mood_v <- ifelse(is.na(raw_df$mood) | raw_df$mood == "", "neutral", as.character(raw_df$mood))
  ex_v   <- ifelse(is.na(raw_df$exercise_type), "", as.character(raw_df$exercise_type))
  cp_v   <- ifelse(is.na(raw_df$cycle_phase), "", as.character(raw_df$cycle_phase))
  tp_v   <- as.logical(raw_df$training_paused == 1 | raw_df$training_paused == "1" | isTRUE(raw_df$training_paused))
  tp_v[is.na(tp_v)] <- FALSE
  ld_v   <- ifelse(is.na(raw_df$last_date), "", as.character(raw_df$last_date))
  
  hr_v   <- as.integer(round(54 + (dload / 22) + st_v * 2))
  hrv_v  <- as.integer(round(clamp(76 - fa_v * 4 - st_v * 3, 20, 100)))
  vo2_v  <- round(clamp(50 + (dload %% 15) * 0.5 + (100 - fa_v * 8) * 0.15, 34, 85), 1)
  pw_v   <- as.integer(round(clamp(180 + dload * 0.75, 100, 480)))
  ftp_v  <- as.integer(round(pw_v * 0.85))
  lac_v  <- round(clamp(1.0 + (dload / 200) * 1.8, 0.8, 8.0), 1)
  ct_v   <- round(clamp(36.4 + (dload / 500) * 0.8, 35.8, 38.6), 1)
  spo2_v <- as.integer(clamp(98 - as.integer(fa_v > 5), 92, 100))
  rr_v   <- as.integer(clamp(14 + as.integer(dload / 100), 10, 24))
  cad_v  <- as.integer(clamp(85 + (as.integer(suppressWarnings(as.integer(uids))) %% 15), 70, 110))
  cad_v[is.na(cad_v)] <- 85L
  tq_v   <- as.integer(clamp(70 + (as.integer(suppressWarnings(as.integer(uids))) %% 30), 45, 130))
  tq_v[is.na(tq_v)] <- 70L
  rsi_v  <- round(clamp(2.4 + (sq_v - fa_v) * 0.15, 1.2, 4.2), 2)
  gct_v  <- as.integer(clamp(210 - (sq_v - 3) * 6, 150, 260))
  
  rem_pct   <- as.integer(clamp(round(18 + sq_v * 1.2), 10, 35))
  deep_pct  <- as.integer(clamp(round(16 + sq_v * 1.4), 10, 35))
  awake_pct <- as.integer(clamp(round(12 - sq_v * 0.9), 2, 20))
  light_pct <- as.integer(100 - rem_pct - deep_pct - awake_pct)
  
  cal_in  <- cal_v
  cal_out <- as.numeric(round(cal_v + dload * 1.35 - 280))
  cho_v   <- round(clamp(5.0 + dload / 150, 3, 10), 1)
  prot_v  <- round(clamp(1.6 + dload / 350, 1.2, 3.0), 1)
  hyd_v   <- as.integer(clamp(round(72 + sq_v * 3 - fa_v * 2), 40, 100))
  
  ham_r <- as.integer(clamp(round(15 + pl_v * 6 + fa_v * 4), 5, 95))
  acl_r <- as.integer(clamp(round(12 + pl_v * 5 + ms_v * 4), 5, 90))
  ach_r <- as.integer(clamp(round(10 + pl_v * 4 + ms_v * 3), 5, 85))
  ovr_r <- as.integer(clamp(round(10 + fa_v * 8 + st_v * 5), 5, 95))
  car_r <- as.integer(clamp(round(8 + st_v * 6), 2, 75))
  
  ts_v <- round(clamp(-0.2 + (ffm_v - 60) * 0.03, -3.2, 1.8), 1)
  zs_v <- round(clamp(0.1 + (ffm_v - 60) * 0.02, -2.5, 1.8), 1)
  
  data.frame(
    user_id = uids, name = ath_name, gender = gen, sport = ath_sport,
    daily_load = dload, rpe = rpe_v, sleep_hours = sh_v, sleep_quality = sq_v,
    stress = st_v, fatigue = fa_v, muscle_soreness = ms_v, pain_level = pl_v,
    injury_location = inj_v, calories = cal_v, ffm = ffm_v, mood = mood_v,
    exercise_type = ex_v, cycle_phase = cp_v, training_paused = tp_v,
    last_date = ld_v, heart_rate = hr_v, hrv = hrv_v, vo2max = vo2_v,
    power = pw_v, ftp = ftp_v, lactate = lac_v, core_temp = ct_v,
    spo2 = spo2_v, resp_rate = rr_v, cadence = cad_v, torque = tq_v,
    rsi = rsi_v, gct = gct_v, sleep_rem_pct = rem_pct, sleep_deep_pct = deep_pct,
    sleep_light_pct = light_pct, sleep_awake_pct = awake_pct,
    calories_in = cal_in, calories_out = cal_out, cho_g_per_kg = cho_v,
    protein_g_per_kg = prot_v, hydration_pct = hyd_v, hamstring_risk = ham_r,
    knee_acl_risk = acl_r, achilles_risk = ach_r, overreach_risk = ovr_r,
    cardiac_risk = car_r, atl = dload, ctl = round(dload * 0.95),
    tsb = round(dload * 0.95) - dload, monotony = 1.5, strain = round(dload * 10.5),
    bone_t_score = ts_v, bone_z_score = zs_v,
    stringsAsFactors = FALSE
  )
}

load_roster_from_sqlite <- function() {
  db <- find_athena_db()
  if (is.null(db) || !requireNamespace("DBI", quietly = TRUE) || !requireNamespace("RSQLite", quietly = TRUE)) return(NULL)
  tryCatch({
    con <- DBI::dbConnect(RSQLite::SQLite(), db)
    on.exit(DBI::dbDisconnect(con), add = TRUE)
    query <- "
      SELECT
          dc.user_id, dc.gender, dc.date as last_date, dc.daily_load, dc.rpe,
          dc.sleep_hours, dc.sleep_quality, dc.stress, dc.fatigue,
          dc.muscle_soreness, dc.cycle_phase, dc.calories, dc.ffm,
          dc.mood, dc.exercise_type, dc.injury_location, dc.pain_level,
          COALESCE(fd.contraceptive_type, '') as contraceptive_type,
          COALESCE(fd.cramp_severity, 0) as cramp_severity,
          COALESCE(fd.bleeding_volume, 'none') as bleeding_volume,
          COALESCE(fd.mood_disturbance, 0) as mood_disturbance,
          COALESCE(reds.training_paused, 0) as training_paused
      FROM daily_checkins dc
      LEFT JOIN female_athlete_data fd ON dc.user_id = fd.user_id
      LEFT JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id AND reds.physician_cleared = 0
      WHERE (dc.user_id, dc.date) IN (
          SELECT user_id, MAX(date) FROM daily_checkins GROUP BY user_id
      )
      ORDER BY 
          CASE WHEN dc.user_id LIKE 'ATH-%' THEN 0 ELSE 1 END,
          CAST(SUBSTR(dc.user_id, 5) AS INTEGER),
          dc.user_id
    "
    raw_df <- DBI::dbGetQuery(con, query)
    if (nrow(raw_df) == 0) return(NULL)
    normalize_athletes_df(raw_df)
  }, error = function(e) {
    NULL
  })
}

ATH_CHOICES_INIT <- tryCatch({
  df_init <- load_roster_from_sqlite()
  if (!is.null(df_init) && nrow(df_init) > 0) {
    setNames(as.character(df_init$user_id), paste0(df_init$name, " (", df_init$user_id, ")"))
  } else NULL
}, error = function(e) NULL)

## =============================================================================
## 5 · DEMO DATA ENGINE — deterministic synthetic cohort (42 days × 15 athletes)
## =============================================================================

DEMO_SEED_NAMES <- c(
  "Chloe W", "Marcus D", "Aisha K", "Diego R", "Yuki T", "Emma S", "Liam O",
  "Noor A", "Piotr W", "Sofia L", "Jamal H", "Ines P", "Kenji M", "Freya N", "Omar B"
)

demo_athlete_row <- function(i, day = 0) {
  set.seed(1100 + i * 17 + day * 3)
  gender <- if (i %% 3 == 0) "female" else "male"
  base_load <- c(450, 620, 380, 700, 540)[(i %% 5) + 1]
  jitter_l  <- runif(1, -80, 120)
  sleep     <- clamp(rnorm(1, 7.4, 0.9), 4.5, 10)
  stress    <- clamp(round(rnorm(1, 3.2, 1.1)), 1, 7)
  fatigue   <- clamp(round(rnorm(1, 3.4, 1.2)), 1, 7)
  soreness  <- clamp(round(rnorm(1, 2.6, 1.0)), 1, 7)
  pain      <- if (runif(1) > 0.88) sample(2:6, 1) else 0
  rpe       <- clamp(round(rnorm(1, 5.5, 1.4)), 1, 10)
  v_id      <- sprintf("ATH-%03d", i)
  ## v7 extended physiology / nutrition / risk profile (deterministic per athlete)
  pw        <- round(170 + 170 * det_unif(v_id, "pw"))
  hrv_v     <- round(32 + 58 * det_unif(v_id, "hrv"))
  list(
    user_id     = v_id,
    name        = DEMO_SEED_NAMES[(i - 1) %% length(DEMO_SEED_NAMES) + 1],
    gender      = gender,
    sport       = SPORTS[(i - 1) %% length(SPORTS) + 1],
    daily_load  = round(max(0, base_load + jitter_l)),
    rpe         = as.integer(rpe),
    sleep_hours = round(sleep, 1),
    sleep_quality = as.integer(clamp(round(rnorm(1, 4.1, 0.9)), 1, 7)),
    stress      = as.integer(stress),
    fatigue     = as.integer(fatigue),
    muscle_soreness = as.integer(soreness),
    pain_level  = as.integer(pain),
    injury_location = if (pain > 0) sample(c("left knee", "right hamstring", "left ankle", "lower back"), 1) else "",
    calories    = round(2600 + runif(1, -400, 700)),
    ffm         = round(if (gender == "female") runif(1, 44, 55) else runif(1, 58, 74), 1),
    mood        = sample(c("neutral", "good", "anxious", "irritable"), 1, prob = c(.55, .25, .12, .08)),
    exercise_type = sample(EXERCISE_TYPES, 1),
    cycle_phase = if (gender == "female") sample(CYCLE_PHASES, 1) else "",
    training_paused = FALSE,
    last_date   = format(Sys.Date() - day, "%Y-%m-%d"),
    ## ---- v7 physiology ----
    heart_rate  = as.integer(round(56 + 30 * det_unif(v_id, "hr") + rpe)),
    hrv         = as.integer(hrv_v),
    vo2max      = round(clamp(46 + 24 * det_unif(v_id, "vo2") + hrv_v / 40, 34, 84), 1),
    power       = as.integer(pw),
    ftp         = as.integer(round(pw * 0.76)),
    lactate     = round(0.9 + 5.5 * det_unif(v_id, "lac"), 1),
    core_temp   = round(36.4 + 1.3 * det_unif(v_id, "ct"), 1),
    spo2        = as.integer(round(94 + 4.4 * det_unif(v_id, "spo2"))),
    resp_rate   = as.integer(round(12 + 9 * det_unif(v_id, "rr"))),
    cadence     = as.integer(round(76 + 30 * det_unif(v_id, "cad"))),
    torque      = as.integer(round(58 + 66 * det_unif(v_id, "tq"))),
    rsi         = round(1.5 + 2.6 * det_unif(v_id, "rsi"), 2),
    gct         = as.integer(round(230 - 80 * det_unif(v_id, "gct"))),
    ## ---- v7 sleep stages (% of night; sums to 100) ----
    sleep_rem_pct    = 0, sleep_deep_pct = 0, sleep_light_pct = 0, sleep_awake_pct = 0,
    ## ---- v7 nutrition ----
    calories_in  = 0, calories_out = 0,
    cho_g_per_kg = round(4.5 + 4.5 * det_unif(v_id, "cho"), 1),
    protein_g_per_kg = round(1.2 + 1.3 * det_unif(v_id, "prot"), 1),
    hydration_pct = as.integer(round(44 + 44 * det_unif(v_id, "hyd"))),
    ## ---- v7 injury risks (%) ----
    hamstring_risk = as.integer(round(18 + 55 * det_unif(v_id, "ham"))),
    knee_acl_risk  = as.integer(round(12 + 50 * det_unif(v_id, "acl"))),
    achilles_risk  = as.integer(round(8 + 50 * det_unif(v_id, "ach"))),
    overreach_risk = as.integer(round(10 + 62 * det_unif(v_id, "ovr"))),
    cardiac_risk   = as.integer(round(4 + 44 * det_unif(v_id, "car"))),
    ## ---- v7 load bookkeeping (ATL/CTL/TSB refined in derive_roster) ----
    atl = 0, ctl = 0, tsb = 0, monotony = NA_real_, strain = 0,
    ## ---- v7 bone health ----
    bone_t_score = round(0.8 - 3.4 * det_unif(v_id, "ts"), 1),
    bone_z_score = round(0.5 - 2.6 * det_unif(v_id, "zs"), 1)
  )
}

## Fill the four sleep-stage shares so they sum to 100 (quality-anchored, deterministic).
sleep_stages_for <- function(seed_str, sleep_quality) {
  u1 <- det_unif(seed_str, "rem"); u2 <- det_unif(seed_str, "deep"); u3 <- det_unif(seed_str, "awake")
  q  <- clamp(safe_num(sleep_quality, 4), 1, 7)
  rem   <- round(clamp(14 + q * 1.3 + 6 * u1, 12, 28))
  deep  <- round(clamp(10 + (8 - q) * 1.6 + 8 * u2, 8, 30))
  awake <- round(clamp(3 + 7 * u3 + (7 - q), 3, 14))
  light <- max(30, 100 - rem - deep - awake)
  tot   <- rem + deep + awake + light
  c(rem = rem, deep = deep, light = round(light * 100 / tot), awake = awake)
}

demo_trend_for <- function(i, days = DEMO_DAYS) {
  set.seed(2200 + i * 31)
  d <- days:1
  base <- 480 + i * 8
  weekly <- rep(c(1.25, 0.9, 1.1, 0.75), length.out = days)
  loads <- round(base * weekly + rnorm(days, 0, 60))
  loads <- pmax(loads, 40)
  sleep <- round(clamp(rnorm(days, 7.4, 0.8), 4.5, 10), 1)
  vid <- sprintf("ATH-%03d", i)
  hrv_base <- 32 + 58 * det_unif(vid, "hrv")
  data.frame(
    date = format(Sys.Date() - d + 1, "%Y-%m-%d"),
    daily_load = loads,
    rpe = as.integer(clamp(round(rnorm(days, 5.5, 1.3)), 1, 10)),
    sleep_hours = sleep,
    sleep_quality = as.integer(clamp(round(rnorm(days, 4, 1)), 1, 7)),
    stress = as.integer(clamp(round(rnorm(days, 3.2, 1)), 1, 7)),
    fatigue = as.integer(clamp(round(rnorm(days, 3.4, 1.1)), 1, 7)),
    muscle_soreness = as.integer(clamp(round(rnorm(days, 2.6, 1)), 1, 7)),
    pain_level = as.integer(ifelse(runif(days) > 0.9, sample(2:5, days, replace = TRUE), 0)),
    calories = round(2700 + rnorm(days, 0, 350)),
    ## v7 extended series (deterministic drift anchored on athlete seed)
    heart_rate = as.integer(round(140 - hrv_base / 6 + cumsum(rnorm(days, 0, 1.2)))),
    hrv = as.integer(round(hrv_base + cumsum(rnorm(days, 0.05, 1.1)))),
    power = pmax(120, as.integer(round(150 + i * 6 + cumsum(rnorm(days, 0.4, 4))))),
    vo2max = round(clamp(48 + i * 0.4 + cumsum(rnorm(days, 0.02, 0.25)), 34, 84), 1),
    hydration_pct = as.integer(clamp(round(66 + rnorm(days, 0, 9)), 30, 100)),
    sleep_rem_pct = as.integer(clamp(round(rnorm(days, 21, 3)), 10, 32)),
    sleep_deep_pct = as.integer(clamp(round(rnorm(days, 18, 3.4)), 8, 30)),
    sleep_light_pct = 48L, sleep_awake_pct = 8L,
    calories_in = round(2600 + rnorm(days, 0, 320)),
    calories_out = round(2900 + loads * 0.8 + rnorm(days, 0, 180)),
    stringsAsFactors = FALSE
  )
}

demo_roster <- function() {
  rows <- lapply(seq_len(DEMO_ATHLETES), function(i) {
    r <- demo_athlete_row(i, 0)
    st <- sleep_stages_for(r$user_id, r$sleep_quality)
    r$sleep_rem_pct   <- unname(safe_lookup(st, "rem") %||% 22)
    r$sleep_deep_pct  <- unname(safe_lookup(st, "deep") %||% 20)
    r$sleep_light_pct <- unname(safe_lookup(st, "light") %||% 48)
    r$sleep_awake_pct <- unname(safe_lookup(st, "awake") %||% 10)
    r$calories_in  <- r$calories
    r$calories_out <- round(r$calories + r$daily_load * 1.4 - 320)
    data.frame(r, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

demo_trends <- function(ids) {
  out <- list()
  for (i in seq_along(ids)) out[[ids[i]]] <- demo_trend_for(i)
  out
}

## =============================================================================
## 6 · CSS DESIGN SYSTEM — tokens mirror index.html (dark/light/CRT/compact)
## =============================================================================

CSS_TEXT <- "
:root{
  --bg:#000000; --bg-2:#0D0D0D; --bg-3:#111111; --bg-4:#1A1A1A;
  --text:#E8EAED; --text-muted:#9AA0A6; --text-dim:#5F6368;
  --cyan:#00E5FF; --green:#00FF88; --amber:#FFAA00; --red:#FF2244; --magenta:#E91E63;
  --cyan-tint:rgba(0,229,255,.12); --green-tint:rgba(0,255,136,.12);
  --amber-tint:rgba(255,170,0,.12); --red-tint:rgba(255,34,68,.12); --magenta-tint:rgba(233,30,99,.12);
  --border:#2A2A2A; --card:rgba(13,13,13,.85); --card-2:rgba(17,17,17,.8);
  --shadow:0 2px 10px rgba(0,0,0,.45); --grid:rgba(255,255,255,.06); --tick:#9AA0A6;
  --header-bg:rgba(0,0,0,.92); --footer-bg:#050505;
}
body.theme-light{
  --bg:#F1F5F9; --bg-2:#FFFFFF; --bg-3:#EDF2F7; --bg-4:#E2E8F0;
  --text:#0F172A; --text-muted:#334155; --text-dim:#64748B;
  --cyan:#007B8F; --green:#15803D; --amber:#B45309; --red:#B91C1C; --magenta:#7E22CE;
  --cyan-tint:rgba(0,123,143,.12); --green-tint:rgba(21,128,61,.12);
  --amber-tint:rgba(180,83,9,.12); --red-tint:rgba(185,28,28,.12); --magenta-tint:rgba(126,34,206,.12);
  --border:#CBD5E1; --card:#FFFFFF; --card-2:#F8FAFC;
  --shadow:0 2px 12px rgba(15,23,42,.08); --grid:rgba(15,23,42,.08); --tick:#475569;
  --header-bg:#FFFFFF; --footer-bg:#F1F5F9;
}
body.theme-light .panel-card, body.theme-light .hud-card {
  background:#FFFFFF!important; border-color:#CBD5E1!important; color:#0F172A!important;
  box-shadow:0 2px 10px rgba(15,23,42,.06)!important;
}
body.theme-light .panel-card:hover, body.theme-light .hud-card:hover {
  border-color:var(--cyan)!important; box-shadow:0 6px 18px rgba(0,123,143,.15)!important;
}
body.theme-light .pc-title{color:#0F172A!important; border-bottom-color:#E2E8F0!important;}
body.theme-light .hud-label{color:#334155!important;}
body.theme-light .hud-value{color:#0F172A!important;}
body.theme-light .hud-unit, body.theme-light .hud-sub{color:#64748B!important;}
body.theme-light .rf-chip{background:#EDF2F7!important; border-color:#CBD5E1!important; color:#1E293B!important;}
body.theme-light .rf-chip:hover{border-color:var(--cyan)!important; color:var(--cyan)!important;}
body.theme-light .rf-chip.active{background:#E0F2FE!important; border-color:var(--cyan)!important; color:var(--cyan)!important;}
body.theme-light .athena-btn{background:#EDF2F7!important; border-color:#CBD5E1!important; color:#0F172A!important;}
body.theme-light .athena-btn:hover{border-color:var(--cyan)!important; color:var(--cyan)!important;}
body.theme-light .athena-btn.primary{background:var(--cyan)!important; border-color:var(--cyan)!important; color:#FFFFFF!important;}
body.theme-light .form-control, body.theme-light select, body.theme-light input, body.theme-light .selectize-input {
  background:#FFFFFF!important; color:#0F172A!important; border-color:#CBD5E1!important;
}
body.theme-light .selectize-dropdown, body.theme-light .selectize-dropdown-content {
  background:#FFFFFF!important; color:#0F172A!important; border-color:#CBD5E1!important;
  box-shadow:0 4px 16px rgba(15,23,42,.12)!important;
}
body.theme-light .selectize-dropdown .option { color:#0F172A!important; }
body.theme-light .selectize-dropdown .active, body.theme-light .selectize-dropdown .option:hover {
  background:#E0F2FE!important; color:var(--cyan)!important;
}
body.theme-light .selectize-input .item { color:#0F172A!important; }
body.theme-light table { border-color:#E2E8F0!important; }
body.theme-light table th { background:#F8FAFC!important; color:#0F172A!important; border-color:#CBD5E1!important; }
body.theme-light table td { color:#1E293B!important; border-color:#E2E8F0!important; }
body.theme-light .quick-stats-bar{background:#FFFFFF!important; border-bottom-color:#CBD5E1!important;}
body.theme-light .qsb-val{color:#0F172A!important;}
body.theme-light .qsb-item{color:#334155!important; border-right-color:#E2E8F0!important;}
body.theme-light .qsb-unit{color:#64748B!important;}
body.theme-light .ticker{background:#F8FAFC!important; border-bottom-color:#CBD5E1!important;}
body.theme-light .ticker-track{color:#334155!important;}
body.theme-light .athlete-card{background:#FFFFFF!important; border-color:#CBD5E1!important;}
body.theme-light .athlete-card:hover{border-color:var(--cyan)!important;}
body.theme-light .athlete-card.active{background:#E0F2FE!important; border-color:var(--cyan)!important;}
body.theme-light .ac-name{color:#0F172A!important;}
body.theme-light .ac-sub{color:#64748B!important;}
body.theme-light .ac-metric .m-val{color:#0F172A!important;}
body.theme-light .modebar-btn svg path { fill: #334155 !important; }
body.theme-light .modebar-btn:hover svg path { fill: var(--cyan) !important; }
body.theme-light .empty-hint { color: #64748B !important; }
body.theme-light .rec-item { background: #F8FAFC !important; border-color: #E2E8F0 !important; color: #1E293B !important; }
html,body{height:100%;max-width:100vw;overflow-x:hidden;}
body{
  background:var(--bg); color:var(--text);
  font-family:ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,'Noto Sans',sans-serif;
  min-height:100vh; display:flex; flex-direction:column; margin:0;
  -webkit-font-smoothing:antialiased; letter-spacing:.2px;
  max-width:100vw; overflow-x:hidden;
}
.shiny-html-output{margin:0}
.container-fluid,.col-sm-12{padding-left:0;padding-right:0}
#athena-main .container-fluid{padding:12px 14px 8px}
.athena-shell{flex:1 0 auto; display:flex; flex-direction:column}
.athena-tab-pane{display:none;}
.athena-tab-pane.active{display:block;}
.athena-footer{
  margin-top:auto; flex-shrink:0; background:var(--footer-bg);
  border-top:1px solid var(--border); color:var(--text-muted);
  font-size:10px; letter-spacing:1px; padding:7px 16px;
  display:flex; flex-wrap:wrap; gap:8px; justify-content:space-between; align-items:center;
  padding-bottom:max(7px, env(safe-area-inset-bottom));
}
.athena-footer .footer-dim{color:var(--text-dim)}
.skip-link{position:absolute; left:-999px; top:0; background:var(--cyan); color:#000;
  padding:8px 14px; z-index:10001; border-radius:0 0 8px 0; font-weight:800}
.skip-link:focus{left:0}

/* ---- navbar ---- */
.navbar{background:var(--header-bg)!important; border-bottom:1px solid var(--border);
  box-shadow:0 1px 14px rgba(0,0,0,.35); padding:0 12px; min-height:52px}
.navbar-brand{color:var(--cyan)!important; font-weight:900; letter-spacing:3px; font-size:16px;
  display:flex; align-items:center; gap:8px}
.navbar-brand .brand-sub{font-size:8px; color:var(--text-dim); letter-spacing:1px; font-weight:600}
.navbar-nav>li>a,.navbar-nav .nav-link{color:var(--text-muted)!important; font-size:11px;
  font-weight:700; letter-spacing:1px; text-transform:uppercase; padding:14px 12px!important}
.navbar-nav>li.active>a,.navbar-nav .nav-item.active .nav-link,
.navbar-nav>li>a:hover,.navbar-nav .nav-link:hover,.navbar-nav .nav-link:focus{
  color:var(--cyan)!important; background:var(--cyan-tint)!important; border-radius:8px}
.conn-dot{width:9px;height:9px;border-radius:50%;display:inline-block;background:var(--amber);
  box-shadow:0 0 8px var(--amber); animation:connPulse 1.6s ease-in-out infinite; margin-right:5px}
.conn-dot.live{background:var(--green); box-shadow:0 0 8px var(--green)}
.conn-dot.sqlite{background:var(--cyan); box-shadow:0 0 10px var(--cyan)}
.conn-dot.bad{background:var(--red); box-shadow:0 0 8px var(--red)}
@keyframes connPulse{0%,100%{opacity:1}50%{opacity:.35}}
.tab-pane{animation:athenaTabFade .25s cubic-bezier(0.16, 1, 0.3, 1)}
@keyframes athenaTabFade{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
.conn-label{font-size:10px;font-weight:800;letter-spacing:1px;color:var(--text-muted);white-space:nowrap}
.header-clock{font-size:11px;font-weight:700;color:var(--text-muted);font-variant-numeric:tabular-nums;white-space:nowrap}
.demo-banner{background:var(--amber-tint); color:var(--amber); border-bottom:1px solid var(--amber);
  font-size:10px; font-weight:800; letter-spacing:1.5px; padding:4px 14px; text-align:center; display:none}
body.demo .demo-banner{display:block}

/* ---- quick stats bar ---- */
.quick-stats-bar{display:flex;align-items:center;padding:6px 16px;background:var(--bg-2);
  border-bottom:1px solid var(--border);overflow-x:auto;gap:4px}
.qsb-item{display:flex;align-items:center;gap:5px;font-size:10px;color:var(--text-muted);
  white-space:nowrap;font-weight:700;padding:2px 10px;border-right:1px solid var(--border)}
.qsb-item:last-child{border-right:none}
.qsb-val{font-size:13px;font-weight:800;color:var(--text);font-variant-numeric:tabular-nums}
.qsb-unit{font-size:9px;color:var(--text-dim);font-weight:600}

/* ---- ticker ---- */
.ticker{display:flex;align-items:center;background:var(--bg-2);border-bottom:1px solid var(--border);height:30px;overflow:hidden}
.ticker-label{flex-shrink:0;padding:0 12px;font-size:9px;font-weight:900;letter-spacing:2px;color:var(--red);
  border-right:1px solid var(--border);height:100%;display:flex;align-items:center}
.ticker-label .live-dot{width:7px;height:7px;border-radius:50%;background:var(--red);display:inline-block;
  margin-right:6px;animation:connPulse 1.2s infinite}
.ticker-mask{flex:1;overflow:hidden;position:relative;height:100%}
.ticker-track{position:absolute;white-space:nowrap;line-height:30px;font-size:10.5px;color:var(--text-muted);
  will-change:transform;animation:tickMove 45s linear infinite}
.ticker-track:hover{animation-play-state:paused}
.ticker-track .tk-item{margin-right:26px;font-weight:600}
@keyframes tickMove{0%{transform:translateX(0)}100%{transform:translateX(-50%)}}

/* ---- panels / cards ---- */
.panel-card{background:var(--card);border:1px solid var(--border);border-radius:14px;
  padding:14px 16px;box-shadow:var(--shadow);margin-bottom:14px;position:relative;
  backdrop-filter:blur(10px);transition:transform .2s cubic-bezier(0.16,1,0.3,1),box-shadow .2s cubic-bezier(0.16,1,0.3,1),border-color .2s ease}
.panel-card:hover{border-color:rgba(0,229,255,.35);box-shadow:0 8px 24px rgba(0,229,255,.07),0 2px 10px rgba(0,0,0,.5)}
.panel-card>.pc-title{display:flex;align-items:center;gap:8px;font-size:10.5px;font-weight:900;
  letter-spacing:1.6px;color:var(--text-muted);text-transform:uppercase;
  border-bottom:1px solid var(--border);padding-bottom:9px;margin-bottom:12px}
.pc-title .pc-ico{width:15px;height:15px;color:var(--cyan);flex-shrink:0}
.pc-title .pc-count{font-size:9px;color:var(--text-dim);font-weight:700;margin-left:auto;margin-right:6px}
.pc-tools{margin-left:auto;display:inline-flex;align-items:center;gap:4px;flex-shrink:0}
.pc-tool-btn{background:rgba(255,255,255,.06);border:1px solid var(--border);color:var(--text-muted);border-radius:4px;width:22px;height:20px;padding:0;display:inline-flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;cursor:pointer;transition:all .15s ease;user-select:none;line-height:1}
.pc-tool-btn:hover{background:var(--cyan-tint);border-color:var(--cyan);color:var(--cyan);box-shadow:0 0 8px rgba(0,229,255,.25)}
body.theme-light .pc-tool-btn{background:#EDF2F7;border-color:#CBD5E1;color:#334155}
body.theme-light .pc-tool-btn:hover{background:var(--cyan-tint);border-color:var(--cyan);color:var(--cyan)}
/* v7: collapse button CSS removed — panel cards are always expanded */
.pc-body>*:last-child{margin-bottom:0}
.pc-body:empty{min-height:70px;background:rgba(255,255,255,0.02);border-radius:4px;}
.hud-value .shiny-text-output:empty::before{content:'—';opacity:0.35;}
#athenaSplash{transition:opacity .4s ease, visibility .4s ease;}

/* ---- HUD cards ---- */
.hud-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:14px}
.hud-card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:14px 16px;
  box-shadow:var(--shadow);display:flex;flex-direction:column;gap:6px;position:relative;overflow:hidden;
  transition:transform .2s cubic-bezier(0.16,1,0.3,1),box-shadow .2s cubic-bezier(0.16,1,0.3,1),border-color .2s ease}
.hud-card:hover{transform:translateY(-2px);border-color:rgba(0,229,255,.45);box-shadow:0 10px 28px rgba(0,229,255,.1),0 4px 14px rgba(0,0,0,.55)}
.hud-card::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;background:linear-gradient(90deg,transparent,var(--cyan),transparent);opacity:.4}
.hud-hr::before{background:linear-gradient(90deg,transparent,var(--red),transparent)}
.hud-vo2::before{background:linear-gradient(90deg,transparent,var(--cyan),transparent)}
.hud-power::before{background:linear-gradient(90deg,transparent,var(--magenta),transparent)}
.hud-ready::before{background:linear-gradient(90deg,transparent,var(--green),transparent)}
.hud-label{font-size:9px;font-weight:800;letter-spacing:1.4px;color:var(--text-muted)}
.hud-value{font-size:27px;font-weight:900;font-variant-numeric:tabular-nums;line-height:1.05;color:var(--text)}
.hud-value .hud-unit{font-size:10px;color:var(--text-dim);font-weight:600;margin-left:4px}
.hud-sub{font-size:9.5px;color:var(--text-dim);font-weight:600}
.hud-ring{position:absolute;top:10px;right:12px;color:var(--cyan)}
.hud-hr .hud-value{color:var(--red)}
.hud-vo2 .hud-value{color:var(--cyan)}
.hud-power .hud-value{color:var(--magenta)}
.hud-ready .hud-value{color:var(--green)}

/* ---- chips & buttons ---- */
.chip-row{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:10px}
.rf-chip{background:var(--bg-3);border:1px solid var(--border);color:var(--text-muted);
  font-size:10px;font-weight:700;padding:4px 11px;border-radius:999px;cursor:pointer;
  transition:all .18s;letter-spacing:.4px;min-height:26px;display:inline-flex;align-items:center;gap:5px}
.rf-chip:hover{border-color:var(--cyan);color:var(--cyan)}
.rf-chip:active{transform:scale(.96)}
.rf-chip.active{background:var(--cyan-tint);border-color:var(--cyan);color:var(--cyan)}
.rf-chip .dot{width:7px;height:7px;border-radius:50%;display:inline-block}
.dot.green{background:var(--green)} .dot.amber{background:var(--amber)} .dot.red{background:var(--red)}
.athena-btn{background:var(--bg-3);border:1px solid var(--border);color:var(--text);
  font-size:10px;font-weight:800;letter-spacing:1px;padding:7px 13px;border-radius:9px;
  cursor:pointer;transition:all .18s;display:inline-flex;align-items:center;gap:6px;min-height:34px}
.athena-btn:hover{border-color:var(--cyan);color:var(--cyan);box-shadow:0 0 0 2px var(--cyan-tint)}
.athena-btn:active{transform:scale(.97)}
.athena-btn.primary{background:var(--cyan);border-color:var(--cyan);color:#001318}
.athena-btn.primary:hover{filter:brightness(1.1);color:#001318}
.athena-btn.danger{border-color:var(--red);color:var(--red)}
.athena-btn.danger:hover{background:var(--red-tint)}
.athena-btn.small{padding:4px 9px;min-height:26px;font-size:9px}

/* ---- athlete cards ---- */
.roster-list{display:grid;grid-template-columns:1fr;gap:8px;max-height:520px;overflow-y:auto;padding-right:4px}
.athlete-card{display:flex;align-items:center;gap:10px;background:var(--card-2);border:1px solid var(--border);
  border-radius:11px;padding:9px 11px;cursor:pointer;transition:all .2s cubic-bezier(0.16,1,0.3,1);position:relative}
.athlete-card:hover{border-color:var(--cyan);transform:translateX(3px);box-shadow:0 4px 14px rgba(0,229,255,.08)}
.athlete-card.active{border-color:var(--cyan);background:var(--cyan-tint);box-shadow:0 0 0 1px var(--cyan),0 6px 20px rgba(0,0,0,.35)}
.avatar{width:36px;height:36px;border-radius:50%;display:flex;align-items:center;justify-content:center;
  font-size:12px;font-weight:900;color:#001318;flex-shrink:0}
.ac-name{font-size:12px;font-weight:800;color:var(--text);line-height:1.2}
.ac-sub{font-size:9px;color:var(--text-dim);font-weight:600}
.ac-metrics{margin-left:auto;text-align:right;display:flex;align-items:center;gap:12px}
.ac-metric{font-size:10px;color:var(--text-muted);font-weight:700;font-variant-numeric:tabular-nums}
.ac-metric .m-val{display:block;font-size:12px;font-weight:900;color:var(--text)}
.status-dot{width:9px;height:9px;border-radius:50%;flex-shrink:0}
.athlete-tags{display:flex;flex-wrap:wrap;gap:4px}
.athlete-tag{font-size:8px;font-weight:800;letter-spacing:.6px;padding:2px 7px;border-radius:999px;
  border:1px solid;white-space:nowrap}
.spark-wrap{position:absolute;bottom:3px;right:6px;opacity:.55}
.athlete-card:hover .spark-wrap{opacity:1}

/* ---- roster table ---- */
.roster-table{width:100%;border-collapse:collapse;font-size:11px}
.roster-table th{background:var(--bg-3);color:var(--text-muted);font-size:9px;font-weight:800;
  letter-spacing:1px;text-transform:uppercase;padding:7px 10px;text-align:left;cursor:pointer;
  border-bottom:1px solid var(--border);position:sticky;top:0;z-index:2}
.roster-table th:hover{color:var(--cyan)}
.roster-table td{padding:8px 10px;border-bottom:1px solid var(--border);color:var(--text)}
.roster-table tbody tr{cursor:pointer;transition:background .15s}
.roster-table tbody tr:hover{background:var(--cyan-tint)}
.roster-table tbody tr.row-active{background:var(--cyan-tint)}
.roster-table .group-row td{background:var(--bg-3);color:var(--cyan);font-size:9px;font-weight:800;
  letter-spacing:1px;cursor:default}
.table-scroll{max-height:520px;overflow-y:auto;border:1px solid var(--border);border-radius:10px}

/* ---- stat grid / cohort ---- */
.cohort-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:9px}
.cohort-cell{background:var(--card-2);border:1px solid var(--border);border-radius:10px;padding:10px 12px}
.cc-label{font-size:8.5px;font-weight:800;letter-spacing:1.2px;color:var(--text-muted);text-transform:uppercase}
.cc-value{font-size:19px;font-weight:900;font-variant-numeric:tabular-nums;margin-top:3px}
.cc-sub{font-size:9px;color:var(--text-dim)}

/* ---- bars (session control) ---- */
.bar-row{margin-bottom:10px}
.bar-row-head{display:flex;justify-content:space-between;font-size:9.5px;font-weight:700;
  color:var(--text-muted);letter-spacing:1px;margin-bottom:4px}
.bar-track{height:7px;background:var(--bg-3);border-radius:4px;overflow:hidden}
.bar-fill{height:100%;border-radius:4px;transition:width .5s ease}
.bar-fill.cyan{background:linear-gradient(90deg,var(--cyan),#4CC9F0)}
.bar-fill.amber{background:linear-gradient(90deg,var(--amber),#F4A261)}
.bar-fill.red{background:linear-gradient(90deg,var(--red),#E76F51)}
.bar-fill.green{background:linear-gradient(90deg,var(--green),#80ED99)}

/* ---- heatmap ---- */
.heatmap-grid{display:grid;gap:3px;max-height:300px;overflow-y:auto;padding:2px}
.hm-cell{border-radius:4px;min-height:22px;position:relative;cursor:pointer}
.hm-cell .hm-tip{display:none;position:absolute;top:-26px;left:50%;transform:translateX(-50%);
  background:var(--bg-4);color:var(--text);font-size:9px;padding:2px 7px;border-radius:6px;
  border:1px solid var(--border);white-space:nowrap;z-index:5}
.hm-cell:hover .hm-tip{display:block}
.hm-axis{font-size:8.5px;color:var(--text-dim);font-weight:700}

/* ---- sleep bars ---- */
.sleep-rows{display:flex;flex-direction:column;gap:6px}
.sleep-row{display:flex;align-items:center;gap:8px;font-size:10px;color:var(--text-muted)}
.sleep-row .sr-label{width:64px;flex-shrink:0;font-weight:700;letter-spacing:.5px}
.sleep-row .sr-track{flex:1;height:14px;background:var(--bg-3);border-radius:4px;overflow:hidden}
.sleep-row .sr-fill{height:100%;border-radius:4px}

/* ---- event log / notifications ---- */
.event-list{max-height:220px;overflow-y:auto;font-size:10.5px;display:flex;flex-direction:column;gap:5px}
.ev-row{display:flex;gap:8px;align-items:baseline;animation:fadeSlideIn .25s ease}
.ev-dot{width:7px;height:7px;border-radius:50%;flex-shrink:0;position:relative;top:-1px}
.ev-time{color:var(--text-dim);font-size:9px;font-variant-numeric:tabular-nums;flex-shrink:0}
@keyframes splashbar{0%{width:8%}55%{width:72%}100%{width:100%}}
@keyframes fadeSlideIn{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:none}}

/* ---- toasts ---- */
.toast-wrap{position:fixed;bottom:18px;right:18px;z-index:10050;display:flex;flex-direction:column;gap:8px}
.athena-toast{background:var(--card);border:1px solid var(--border);border-left:3px solid var(--cyan);
  border-radius:10px;padding:10px 14px;min-width:240px;max-width:330px;box-shadow:0 8px 30px rgba(0,0,0,.4);
  animation:toastIn .28s ease}
.athena-toast.success{border-left-color:var(--green)} .athena-toast.warn{border-left-color:var(--amber)}
.athena-toast.error{border-left-color:var(--red)}
.toast-title{font-size:11px;font-weight:800;letter-spacing:.5px}
.toast-desc{font-size:10px;color:var(--text-muted);margin-top:2px}
@keyframes toastIn{from{opacity:0;transform:translateX(30px)}to{opacity:1;transform:none}}

/* ---- inputs ---- */
.form-control,.selectize-input,.shiny-input-container input,.shiny-input-container select{
  background:var(--bg-3)!important;border:1px solid var(--border)!important;color:var(--text)!important;
  border-radius:8px!important;font-size:12px}
.form-control:focus{border-color:var(--cyan)!important;box-shadow:0 0 0 2px var(--cyan-tint)!important}
.control-label,.shiny-input-container label{color:var(--text-muted);font-size:9.5px;font-weight:800;
  letter-spacing:1px;text-transform:uppercase}
.shiny-options-group label{color:var(--text);font-size:11px;font-weight:600;text-transform:none;letter-spacing:0}
.irs--shiny .irs-bar{background:var(--cyan)!important}
.irs--shiny .irs-handle{border-color:var(--cyan)!important}
.selectize-dropdown, .selectize-dropdown-content {
  background: #111111 !important;
  color: #E8EAED !important;
  border: 1px solid #2A2A2A !important;
  box-shadow: 0 4px 16px rgba(0,0,0,.6) !important;
}
.selectize-dropdown .option {
  color: #E8EAED !important;
  padding: 6px 10px !important;
}
.selectize-dropdown .active, .selectize-dropdown .option:hover {
  background: var(--cyan-tint) !important;
  color: var(--cyan) !important;
}
.selectize-input .item {
  color: var(--text) !important;
}
.zoom-controls {
  display: inline-flex;
  align-items: center;
  gap: 2px;
  background: var(--bg-3);
  border: 1px solid var(--border);
  border-radius: 9px;
  padding: 1px;
}
.zoom-controls .athena-btn {
  border: none !important;
  background: transparent !important;
  min-height: 24px;
  padding: 2px 7px;
  font-size: 11px;
}
.zoom-controls .athena-btn:hover {
  background: var(--cyan-tint) !important;
  color: var(--cyan) !important;
}

/* ---- modal ---- */
.modal-content{background:var(--card)!important;border:1px solid var(--border)!important;
  border-radius:16px!important;box-shadow:0 18px 60px rgba(0,0,0,.55)!important}
.modal-header{border-bottom:1px solid var(--border)!important}
.modal-title{font-size:13px;font-weight:900;letter-spacing:1.5px;color:var(--cyan)}
.modal-footer{border-top:1px solid var(--border)!important}
.modal-backdrop.in{opacity:.65}

/* ---- misc ---- */
.text-dim{color:var(--text-dim)} .text-muted2{color:var(--text-muted)}
.mono{font-variant-numeric:tabular-nums}
.rec-list{display:flex;flex-direction:column;gap:7px;font-size:11px}
.rec-item{background:var(--card-2);border:1px solid var(--border);border-radius:9px;padding:8px 11px;line-height:1.45}
.kv-grid{display:grid;grid-template-columns:auto 1fr;gap:4px 14px;font-size:11px}
.kv-grid .k{color:var(--text-dim);font-weight:700;font-size:9.5px;letter-spacing:.8px;text-transform:uppercase}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}
.grid32{display:grid;grid-template-columns:2fr 1fr;gap:14px}
@media(max-width:900px){.grid2,.grid3,.grid32{grid-template-columns:1fr}}
.err-card{border:1px dashed var(--red);border-radius:12px;padding:16px;text-align:center;color:var(--text-muted);font-size:11px}
.empty-hint{color:var(--text-dim);font-size:11px;text-align:center;padding:22px 10px;letter-spacing:.5px}
.mini-label{font-size:9px;font-weight:800;letter-spacing:1.2px;color:var(--text-dim);text-transform:uppercase}
.scroll-y{max-height:420px;overflow-y:auto}
::-webkit-scrollbar{width:9px;height:9px}
::-webkit-scrollbar-track{background:var(--bg-2)}
::-webkit-scrollbar-thumb{background:var(--bg-4);border-radius:5px}
::-webkit-scrollbar-thumb:hover{background:var(--text-dim)}

/* ---- v7: live biometrics grid ---- */
.bio-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}
@media(max-width:900px){.bio-grid{grid-template-columns:repeat(2,1fr)}}
.bio-tile{background:var(--card-2);border:1px solid var(--border);border-radius:10px;padding:9px 11px}
.bio-tile .bt-label{font-size:8.5px;font-weight:800;letter-spacing:1px;color:var(--text-muted);text-transform:uppercase}
.bio-tile .bt-val{font-size:17px;font-weight:900;font-variant-numeric:tabular-nums;margin-top:2px}
.bio-tile .bt-delta{font-size:9px;font-weight:800;margin-left:4px}
.bio-tile .bt-unit{font-size:8.5px;color:var(--text-dim);font-weight:600;margin-left:3px}
.delta-up{color:var(--green)} .delta-down{color:var(--red)} .delta-up.bad-up{color:var(--red)} .delta-down.bad-up{color:var(--green)}

/* ---- v7: bone scale & ACL factors ---- */
.bone-scale{display:flex;position:relative;height:16px;border-radius:8px;overflow:hidden;margin-top:8px;border:1px solid var(--border)}
.bone-scale .bs-zone{flex:1;display:flex;align-items:center;justify-content:center;font-size:7.5px;font-weight:800;color:#001318;letter-spacing:.4px}
.bs-zone.z-normal{background:var(--green);opacity:.85}
.bs-zone.z-osteo{background:var(--amber);opacity:.85}
.bs-zone.z-porosis{background:var(--red);opacity:.85}
.bone-marker{position:absolute;top:-3px;width:4px;height:22px;background:var(--text);border-radius:2px;box-shadow:0 0 6px rgba(255,255,255,.6);z-index:2}
.acl-factor-row{display:flex;align-items:center;gap:6px;font-size:9px;margin-bottom:4px}
.acl-factor-row .af-lbl{flex:1;color:var(--text-muted);font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.acl-factor-row .af-track{width:56px;height:4px;background:var(--bg-3);border-radius:2px;overflow:hidden;flex-shrink:0}
.acl-factor-row .af-fill{height:100%;border-radius:2px}
.acl-factor-row .af-val{width:34px;text-align:right;font-weight:700;font-variant-numeric:tabular-nums;font-size:8.5px}

/* ---- v7: session timeline track ---- */
.tl-track{position:relative;padding-left:18px;display:flex;flex-direction:column;gap:6px;max-height:250px;overflow-y:auto}
.tl-track::before{content:'';position:absolute;left:5px;top:4px;bottom:4px;width:2px;background:var(--border);border-radius:2px}
.tl-item{position:relative;font-size:10.5px;color:var(--text-muted);display:flex;gap:8px;align-items:baseline}
.tl-item::before{content:'';position:absolute;left:-17px;top:4px;width:8px;height:8px;border-radius:50%;background:var(--cyan);border:2px solid var(--bg)}
.tl-item.tl-good::before{background:var(--green)}
.tl-item.tl-warn::before{background:var(--amber)}
.tl-item.tl-crit::before{background:var(--red)}
.tl-time{color:var(--text-dim);font-size:9px;font-variant-numeric:tabular-nums;flex-shrink:0}

/* ---- v7: hypnogram ---- */
.hypno-legend{display:flex;gap:10px;flex-wrap:wrap;margin-top:6px}
.hypno-legend .hl-item{display:flex;align-items:center;gap:4px;font-size:8.5px;font-weight:700;color:var(--text-muted);letter-spacing:.5px}
.hypno-legend .hl-swatch{width:9px;height:9px;border-radius:2px;display:inline-block}

/* ---- CRT ---- */
body.crt::after{content:'';position:fixed;inset:0;pointer-events:none;z-index:9999;
  background:repeating-linear-gradient(0deg,rgba(0,0,0,.16) 0 1px,transparent 1px 3px);
  mix-blend-mode:multiply}
body.crt{filter:contrast(1.04) saturate(1.06)}

/* ---- compact ---- */
body.compact .panel-card{padding:9px 11px;margin-bottom:9px}
body.compact .hud-card{padding:9px 11px}
body.compact .hud-value{font-size:21px}
body.compact .pc-title{font-size:9.5px;margin-bottom:8px}

@media (prefers-reduced-motion: reduce){
  *{animation-duration:.001s!important;transition-duration:.001s!important}
}
@media print{
  .navbar,.ticker,.quick-stats-bar,.athena-footer,.demo-banner{display:none!important}
  body{background:#fff;color:#000}
  .panel-card{border-color:#ccc;box-shadow:none;page-break-inside:avoid}
}
"

## =============================================================================
## 7 · UI — helpers
## =============================================================================

pc_icon <- function(svg) HTML(paste0('<span class="pc-ico">', svg, '</span>'))

ICONS <- list(
  users  = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="pc-ico"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>',
  chart  = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="pc-ico"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg>',
  clock  = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="pc-ico"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>',
  file   = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="pc-ico"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>',
  pulse  = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="pc-ico"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>',
  moon   = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="pc-ico"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>',
  shield = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="pc-ico"><path d="M12 2L2 7v6c0 5.5 4 9.5 10 11 6-1.5 10-5.5 10-11V7l-10-5z"/></svg>',
  cpu    = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="pc-ico"><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/></svg>',
  gear   = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="pc-ico"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h0a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>'
)

# Panel card with localized title and icon — always expanded with card tools
panel_card <- function(id, title_key, icon = NULL, ..., count = NULL, tools = TRUE) {
  label <- tr_raw("en", title_key)
  div(class = "panel-card", id = id,
      div(class = "pc-title",
          if (!is.null(icon)) pc_icon(icon) else NULL,
          HTML(paste0('<span data-k="', title_key, '">', label, '</span>')),
          if (!is.null(count)) HTML(paste0('<span class="pc-count">', count, '</span>')) else NULL,
          if (isTRUE(tools)) {
            div(class = "pc-tools",
                tags$button(type = "button", class = "pc-tool-btn", onclick = "athenaZoomCard(this, 'in')", title = "Zoom In (+)", "+"),
                tags$button(type = "button", class = "pc-tool-btn", onclick = "athenaZoomCard(this, 'out')", title = "Zoom Out (-)", "\u2212"),
                tags$button(type = "button", class = "pc-tool-btn", onclick = "athenaZoomCard(this, 'auto')", title = "Autoscale / Reset (↺)", "\u21ba")
            )
          } else NULL
      ),
      div(class = "pc-body", ...)
  )
}

hud_card <- function(cls, label_key, value_id, unit = "", sub_id = NULL, ring_id = NULL) {
  div(class = paste("hud-card", cls),
      div(class = "hud-label", HTML(paste0('<span data-k="', label_key, '">', tr_raw("en", label_key), '</span>'))),
      div(class = "hud-value", textOutput(value_id, container = span),
          if (nzchar(unit)) span(class = "hud-unit", unit) else NULL),
      if (!is.null(sub_id)) div(class = "hud-sub", textOutput(sub_id, container = span)) else NULL,
      if (!is.null(ring_id)) div(class = "hud-ring", uiOutput(ring_id)) else NULL
  )
}

chip <- function(inputId, key, label, active = FALSE, dot = NULL) {
  tags$button(id = inputId, class = paste("rf-chip action-button", if (active) "active" else ""),
              type = "button",
              onclick = paste0("Shiny.setInputValue('", inputId, "', Date.now(), {priority: 'event'});"),
              if (!is.null(dot)) span(class = paste("dot", dot)) else NULL,
              span(`data-k` = key, label))
}

# Symbol-only chip (no data-k → i18n never rewrites the label). Used for
# range buttons like 30D / 60D / 90D that need no translation.
chip_s <- function(inputId, label, active = FALSE) {
  tags$button(id = inputId, class = paste("rf-chip action-button", if (active) "active" else ""),
              type = "button",
              onclick = paste0("Shiny.setInputValue('", inputId, "', Date.now(), {priority: 'event'});"),
              label)
}

## =============================================================================
## 8 · RUNTIME JAVASCRIPT (i18n apply, theme, clock, shortcuts, toasts)
## =============================================================================

JS_RUNTIME <- "
function athStore(k,v){try{if(v===undefined){return localStorage.getItem(k);}localStorage.setItem(k,v);}catch(e){return null;}}

var athCurrentZoom = parseFloat(athStore('athena_zoom') || '1.0');
function applyZoom(z){
  z = Math.max(0.7, Math.min(1.5, Math.round(z * 10) / 10));
  athCurrentZoom = z;
  athStore('athena_zoom', z);
  document.body.style.zoom = z;
  var btn = document.getElementById('zoomResetBtn');
  if(btn) btn.textContent = Math.round(z * 100) + '%';
  try {
    var ev = new Event('resize');
    window.dispatchEvent(ev);
    if(window.jQuery) { window.jQuery(window).trigger('resize'); }
    setTimeout(function(){
      document.querySelectorAll('.js-plotly-plot').forEach(function(el){
        try{ if(window.Plotly) Plotly.Plots.resize(el); }catch(e){}
      });
    }, 100);
  } catch(e){}
}
function zoomIn(){ applyZoom(athCurrentZoom + 0.1); }
function zoomOut(){ applyZoom(athCurrentZoom - 0.1); }
function zoomReset(){ applyZoom(1.0); }

window.athenaZoomCard = function(btn, action) {
  try {
    var card = btn.closest('.panel-card');
    if (!card) return;
    var plotEl = card.querySelector('.js-plotly-plot');
    if (plotEl && window.Plotly) {
      if (action === 'auto') {
        Plotly.relayout(plotEl, { 'xaxis.autorange': true, 'yaxis.autorange': true });
        return;
      }
      if (plotEl._fullLayout && plotEl._fullLayout.xaxis && plotEl._fullLayout.yaxis) {
        var xa = plotEl._fullLayout.xaxis, ya = plotEl._fullLayout.yaxis;
        if (xa.range && ya.range) {
          var xm = (xa.range[0] + xa.range[1]) / 2;
          var ym = (ya.range[0] + ya.range[1]) / 2;
          var factor = (action === 'in') ? 0.70 : 1.40;
          var xd = (xa.range[1] - xa.range[0]) * factor;
          var yd = (ya.range[1] - ya.range[0]) * factor;
          Plotly.relayout(plotEl, {
            'xaxis.range': [xm - xd/2, xm + xd/2],
            'yaxis.range': [ym - yd/2, ym + yd/2]
          });
          return;
        }
      }
    }
    var body = card.querySelector('.pc-body');
    if (!body) return;
    var scale = parseFloat(body.getAttribute('data-scale') || '1.0');
    if (action === 'auto') {
      scale = 1.0;
    } else if (action === 'in') {
      scale = Math.min(scale * 1.25, 2.5);
    } else if (action === 'out') {
      scale = Math.max(scale * 0.8, 0.5);
    }
    body.setAttribute('data-scale', scale);
    body.style.transition = 'transform 0.2s cubic-bezier(0.2, 0.8, 0.2, 1)';
    body.style.transformOrigin = 'top left';
    if (scale === 1.0) {
      body.style.transform = '';
      body.style.overflow = '';
    } else {
      body.style.transform = 'scale(' + scale + ')';
      body.style.overflow = 'auto';
    }
  } catch(e) {
    console.error('athenaZoomCard error:', e);
  }
};

function applyLang(lang){
  if(!lang) lang = 'en';
  window.athLangApplied = lang;
  var d=window.ATHENA_I18N||{};var L=d[lang]||d.en||{};var E=d.en||{};
  document.documentElement.setAttribute('lang',lang);
  document.documentElement.setAttribute('dir',(lang==='ar'?'rtl':'ltr'));
  var nodes=document.querySelectorAll('[data-k]');
  for(var i=0;i<nodes.length;i++){
    var k=nodes[i].getAttribute('data-k');
    var txt = L[k] || E[k];
    if(txt !== undefined && txt !== null) nodes[i].textContent = txt;
  }
  var ph=document.querySelectorAll('[data-k-ph]');
  for(var j=0;j<ph.length;j++){
    var k2=ph[j].getAttribute('data-k-ph');
    var txt2 = L[k2] || E[k2];
    if(txt2 !== undefined && txt2 !== null) ph[j].setAttribute('placeholder', txt2);
  }
  athStore('athena_lang',lang);
  var sel=document.getElementById('langSelect');
  if(sel&&sel.value!==lang){try{sel.value=lang;}catch(e){}}
  var thmBtn=document.getElementById('themeBtn');
  var curThm=window.athThemeApplied||athStore('athena_theme')||'dark';
  if(thmBtn){
    if(curThm==='light') thmBtn.innerHTML = '☾ ' + (L.nightMode || 'NIGHT');
    else thmBtn.innerHTML = '☀ ' + (L.dayMode || 'DAY');
  }
  var zIn=document.getElementById('zoomInBtn');
  if(zIn && L.zoomIn) zIn.title = L.zoomIn;
  var zOut=document.getElementById('zoomOutBtn');
  if(zOut && L.zoomOut) zOut.title = L.zoomOut;
  var zRst=document.getElementById('zoomResetBtn');
  if(zRst && L.zoomReset) zRst.title = L.zoomReset;
  if(window.Shiny&&Shiny.setInputValue){
    Shiny.setInputValue('i18nLang',lang,{priority:'event'});
    Shiny.setInputValue('langSelect',lang,{priority:'event'});
  }
  try {
    window.dispatchEvent(new Event('resize'));
    if(window.jQuery) { window.jQuery(window).trigger('resize'); }
    setTimeout(function(){
      document.querySelectorAll('.js-plotly-plot').forEach(function(el){
        try{ if(window.Plotly) Plotly.Plots.resize(el); }catch(e){}
      });
    }, 120);
  } catch(e){}
}
function applyTheme(t){
  if(!t) t = 'dark';
  var changed = window.athThemeApplied !== t;
  window.athThemeApplied = t;
  document.body.classList.toggle('theme-light',t==='light');
  athStore('athena_theme',t);
  var curLg=window.athLangApplied||athStore('athena_lang')||'en';
  var d=window.ATHENA_I18N||{};var L=d[curLg]||d.en||{};
  var btn=document.getElementById('themeBtn');
  if(btn){
    if(t==='light'){
      btn.innerHTML = '☾ ' + (L.nightMode || 'NIGHT');
      btn.title = 'Switch to Night Mode (T)';
    } else {
      btn.innerHTML = '☀ ' + (L.dayMode || 'DAY');
      btn.title = 'Switch to Day Mode (T)';
    }
  }
  if(changed&&window.Shiny&&Shiny.setInputValue){Shiny.setInputValue('uiTheme',t,{priority:'event'});}
  try { window.dispatchEvent(new Event('resize')); } catch(e){}
}
function applyBodyClass(cls,on){document.body.classList.toggle(cls,on);}
function athToast(type,title,desc){
  var w=document.getElementById('toastWrap');if(!w)return;
  var el=document.createElement('div');el.className='athena-toast '+type;
  el.innerHTML='<div class=\\'toast-title\\'>'+title+'</div>'+(desc?'<div class=\\'toast-desc\\'>'+desc+'</div>':'');
  w.appendChild(el);setTimeout(function(){el.style.opacity='0';el.style.transition='opacity .4s';},4200);
  setTimeout(function(){if(el.parentNode){el.parentNode.removeChild(el);}},4800);
}
function athNotifyBrowser(title,body){
  try{if('Notification' in window&&Notification.permission==='granted'&&document.hidden){new Notification(title,{body:body});}}catch(e){}
}
function flashConn(state){
  var b=document.body;b.classList.remove('demo','bad','sqlite','live');
  if(state==='demo'){b.classList.add('demo');}
  if(state==='bad'){b.classList.add('bad');}
  if(state==='sqlite'){b.classList.add('sqlite');}
  if(state==='live'){b.classList.add('live');}
}
function tabBtnActivate(name){
  if(!name) name = 'dashboard';
  var btns=document.querySelectorAll('.tab-btn');
  for(var i=0;i<btns.length;i++){btns[i].classList.toggle('active',btns[i].getAttribute('data-tab')===name);}
  var panes=document.querySelectorAll('.athena-tab-pane');
  for(var j=0;j<panes.length;j++){
    var isTarget=(panes[j].id===('tab-'+name));
    panes[j].classList.toggle('active',isTarget);
  }
  if(window.Shiny&&Shiny.setInputValue){Shiny.setInputValue('mainTabs',name,{priority:'event'});}
  setTimeout(function(){try{window.dispatchEvent(new Event('resize'));}catch(e){}},50);
}
document.addEventListener('change',function(ev){
  if(ev.target&&ev.target.id==='langSelect'){applyLang(ev.target.value);}
});
document.addEventListener('click',function(ev){
  var b=ev.target.closest?ev.target.closest('.tab-btn'):null;
  if(b){var n=b.getAttribute('data-tab');tabBtnActivate(n);
    if(window.Shiny&&Shiny.setInputValue){Shiny.setInputValue('mainTabs',n,{priority:'event'});}}
});
document.addEventListener('keydown',function(e){
  var tag=(e.target&&e.target.tagName||'').toLowerCase();
  var typing=(tag==='input'||tag==='textarea'||tag==='select'||e.target.isContentEditable);
  if((e.ctrlKey||e.metaKey)&&(e.key==='='||e.key==='+')){e.preventDefault();zoomIn();return;}
  if((e.ctrlKey||e.metaKey)&&(e.key==='-'||e.key==='_')){e.preventDefault();zoomOut();return;}
  if((e.ctrlKey||e.metaKey)&&e.key==='0'){e.preventDefault();zoomReset();return;}
  if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='k'){e.preventDefault();
    var m=document.getElementById('cmdModal');if(m){m.style.display='block';}
    setTimeout(function(){var f=document.getElementById('cmdSearchInput');if(f){f.focus();}},60);return;}
  if(e.key==='Escape'){var m2=document.getElementById('cmdModal');if(m2){m2.style.display='none';}}
  if(typing)return;
  var k=e.key.toLowerCase();
  var tabs=['dashboard','roster','athlete','reds','cohort','data','system','settings'];
  if(k>='1'&&k<='8'){var n=tabs[parseInt(k)-1];tabBtnActivate(n);
    if(window.Shiny&&Shiny.setInputValue){Shiny.setInputValue('mainTabs',n,{priority:'event'});}}
  else if(k==='r'){if(window.Shiny&&Shiny.setInputValue){Shiny.setInputValue('forceRefresh',Date.now(),{priority:'event'});}}
  else if(k==='t'){var cur=localStorage.getItem('athena_theme')||'dark';applyTheme(cur==='dark'?'light':'dark');}
  else if(k==='l'){var langs=['en','hi','es','fr','de','pt','ar','ru','sw','zh'];var cl=window.athLangApplied||athStore('athena_lang')||'en';
    applyLang(langs[(langs.indexOf(cl)+1)%langs.length]);}
  else if(k==='s'){if(window.Shiny&&Shiny.setInputValue){Shiny.setInputValue('simToggle',Date.now(),{priority:'event'});}}
  else if(k==='+'||k==='='){zoomIn();}
  else if(k==='-'||k==='_'){zoomOut();}
  else if(k==='0'){zoomReset();}
  else if(e.key==='?'){var h=document.getElementById('helpModal');if(h){h.style.display='block';}}
});
window.addEventListener('DOMContentLoaded',function(){
  var th=localStorage.getItem('athena_theme')||'dark';applyTheme(th);
  applyLang('en');
  try{athStore('athena_lang','en');}catch(e){}
  var zm=parseFloat(localStorage.getItem('athena_zoom')||'1.0');applyZoom(zm);
  var crt=localStorage.getItem('athena_crt')==='1';applyBodyClass('crt',crt);
  var cmp=localStorage.getItem('athena_compact')==='1';applyBodyClass('compact',cmp);
  var clock=function(){var el=document.getElementById('hdrClock');var el2=document.getElementById('ftrClock');
    var d=new Date();var s=d.toLocaleTimeString();if(el){el.textContent=s;}if(el2){el2.textContent=s;}};
  clock();setInterval(clock,1000);
  document.addEventListener('visibilitychange',function(){
    if(window.Shiny&&Shiny.setInputValue){Shiny.setInputValue('tabVisible',!document.hidden,{priority:'event'});}});
});
function dismissSplash(){
  var sp=document.getElementById('athenaSplash');
  if(sp&&sp.style.opacity!=='0'){
    sp.style.opacity='0';
    sp.style.pointerEvents='none';
    setTimeout(function(){try{sp.style.display='none';}catch(e){}},400);
  }
}
(function() {
  function patchOutputProgress() {
    try {
      if (window.Shiny && window.Shiny.shinyapp && window.Shiny.shinyapp.$outputProgress) {
        var proto = Object.getPrototypeOf(window.Shiny.shinyapp.$outputProgress);
        if (proto && proto.updateStateFromMessage && !proto._athPatched) {
          var orig = proto.updateStateFromMessage;
          proto.updateStateFromMessage = function(m) {
            try {
              return orig.call(this, m);
            } catch(err) {
              return;
            }
          };
          proto._athPatched = true;
        }
      }
    } catch(e) {}
  }
  if (typeof $ !== 'undefined') {
    $(document).on('shiny:connected', patchOutputProgress);
  }
  setInterval(patchOutputProgress, 200);
})();

if(typeof $!== 'undefined'&&window.Shiny){
  $(document).on('shiny:connected',function(){
    applyLang('en');
    try{athStore('athena_lang','en');}catch(e){}
    var savedTh=athStore('athena_theme')||'dark';
    applyTheme(savedTh);
    var savedZm=parseFloat(athStore('athena_zoom')||'1.0');
    applyZoom(savedZm);
    if(window.Shiny&&Shiny.setInputValue){
      Shiny.setInputValue('langSelect','en',{priority:'event'});
    }
    setTimeout(dismissSplash, 1200);
  });
  $(document).on('shiny:value',function(ev){
    if(ev.name==='hudReady'||ev.name==='readinessChartWrap'||ev.name==='qbAthletes'){
      dismissSplash();
    }
    var curLg=window.athLangApplied||athStore('athena_lang')||'en';
    var d=window.ATHENA_I18N||{};var L=d[curLg]||d.en||{};var E=d.en||{};
    var nodes=document.querySelectorAll('[data-k]');
    for(var i=0;i<nodes.length;i++){
      var k=nodes[i].getAttribute('data-k');
      var txt = L[k] || E[k];
      if(txt !== undefined && txt !== null) nodes[i].textContent = txt;
    }
    var ph=document.querySelectorAll('[data-k-ph]');
    for(var j=0;j<ph.length;j++){
      var k2=ph[j].getAttribute('data-k-ph');
      var txt2 = L[k2] || E[k2];
      if(txt2 !== undefined && txt2 !== null) ph[j].setAttribute('placeholder', txt2);
    }
  });
}
setTimeout(dismissSplash, 3500);
"

## =============================================================================
## 9 · UI DEFINITION
## =============================================================================

ui <- function(request) {
  lang0 <- "en"
  tagList(
    tags$head(
      tags$meta(charset = "utf-8"),
      tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
      tags$title("ATHENA · Sports Science Console"),
      tags$style(HTML(CSS_TEXT)),
      tags$script(HTML(paste0("window.ATHENA_I18N=", jsonlite::toJSON(lapply(I18N, as.list), auto_unbox = TRUE), ";"))),
      tags$script(HTML(JS_RUNTIME))
    ),
    tags$a(href = "#athena-main", class = "skip-link", "Skip to main content"),
    div(id = "athenaSplash",
        style = "position:fixed;inset:0;z-index:10000;background:var(--bg);display:flex;flex-direction:column;align-items:center;justify-content:center;",
        div(style = "font-size:30px;font-weight:900;letter-spacing:6px;color:var(--cyan);text-shadow:0 0 18px rgba(0,229,255,.6);", "A.T.H.E.N.A."),
        div(style = "margin-top:8px;font-size:10px;letter-spacing:2px;color:var(--text-dim);",
            HTML(paste0('<span data-k="headerSubtitle">', tr_raw("en", "headerSubtitle"), '</span>'))),
        div(style = "margin-top:22px;width:210px;height:3px;background:var(--bg-3);border-radius:2px;overflow:hidden;",
            div(style = "height:100%;width:40%;background:linear-gradient(90deg,var(--cyan),var(--magenta),var(--green));animation:splashbar 1.6s ease-in-out infinite alternate;"))
    ),

    ## ---------------- header ----------------
    tags$nav(class = "athena-topnav", role = "banner",
             style = "display:flex;flex-wrap:wrap;align-items:center;gap:4px;padding:6px 14px;background:var(--header-bg);border-bottom:1px solid var(--border);",
             div(class = "navbar-brand", HTML("<span>A.T.H.E.N.A.</span><span class='brand-sub' data-k='headerSubtitle'>Adaptive Telemetry · Health · Evidence-Based Nutrition</span>")),
             div(style = "display:flex;flex-wrap:wrap;gap:2px;margin-left:10px;",
                 lapply(c("dashboard", "roster", "athlete", "reds", "cohort", "data", "system", "settings"), function(tb) {
                   lbl <- switch(tb, dashboard = "tabDashboard", roster = "tabRoster", athlete = "tabAthlete",
                                 reds = "tabReds", cohort = "tabCohort", data = "tabData", system = "tabSystem", settings = "tabSettings")
                   tags$button(class = paste0("rf-chip tab-btn", if (tb == "dashboard") " active" else ""),
                               `data-tab` = tb, type = "button",
                               onclick = paste0("tabBtnActivate('", tb, "'); if(window.Shiny) Shiny.setInputValue('mainTabs','", tb, "',{priority:'event'});"),
                               HTML(paste0('<span data-k="', lbl, '">', tr_raw(lang0, lbl), '</span>')))
                 })),
             div(class = "hdr-controls", style = "margin-left:auto;display:flex;align-items:center;gap:7px;flex-wrap:wrap;",
                 span(class = "conn-wrap", style = "display:inline-flex;align-items:center;",
                      uiOutput("connStatus", inline = TRUE)),
                 span(class = "header-clock", id = "hdrClock", "—:—:—"),
                 tags$select(id = "langSelect", class = "rf-chip", style = "appearance:auto;min-height:30px;padding:2px 8px;cursor:pointer;",
                             onchange = "applyLang(this.value);",
                             lapply(LANG_CODES, function(l) tags$option(value = l, safe_lookup(LANG_NAMES, l) %||% l, selected = if (identical(l, "en")) "selected" else NULL))),
                 div(class = "zoom-controls",
                     actionButton("zoomOutBtn", label = "−", class = "athena-btn small", title = "Zoom Out (-)", onclick = "zoomOut();"),
                     tags$button(id = "zoomResetBtn", class = "athena-btn small", type = "button", style = "min-width:44px;justify-content:center;font-variant-numeric:tabular-nums;", title = "Reset Zoom (100%)", onclick = "zoomReset();", "100%"),
                     actionButton("zoomInBtn", label = "+", class = "athena-btn small", title = "Zoom In (+)", onclick = "zoomIn();")
                 ),
                 actionButton("themeBtn", label = "☀ DAY", class = "athena-btn small", title = "Toggle Day / Night Mode (T)",
                              onclick = "var cur=window.athThemeApplied||athStore('athena_theme')||'dark';applyTheme(cur==='dark'?'light':'dark');"),
                 actionButton("crtBtn", label = "CRT", class = "athena-btn small", title = "CRT effect"),
                 actionButton("compactBtn", label = "\u2691", class = "athena-btn small", title = "Compact layout"),
                 actionButton("syncBtn", label = HTML(paste0('<span data-k="sync">SYNC</span>')), class = "athena-btn small primary"),
                 actionButton("checkinBtn", label = HTML(paste0('<span data-k="checkin">CHECK-IN</span>')), class = "athena-btn small"),
                 div(style = "position:relative;",
                     actionButton("notifBtn", label = HTML("\u266A"), class = "athena-btn small", title = "Notifications"),
                     uiOutput("notifBadge")),
                 uiOutput("headerAuthBtn", inline = TRUE),
                 actionButton("helpBtn", label = "?", class = "athena-btn small", title = "Help")
             )
    ),
    div(class = "demo-banner", id = "demoBanner",
        HTML(paste0('<span data-k="bannerDemo">DEMO DATA</span> · <span data-k="offlineDemo">Backend unreachable — running on synthetic demo data</span>'))),

    ## ---------------- quick stats ----------------
    div(class = "quick-stats-bar", role = "status",
        div(class = "qsb-item", span(class = "qsb-val", textOutput("qbReadiness", container = span)), span(class = "qsb-unit", HTML(paste0('<span data-k="qbReadiness">', tr_raw("en", "qbReadiness"), '</span>')))),
        div(class = "qsb-item", span(class = "qsb-val", textOutput("qbLoad", container = span)), span(class = "qsb-unit", "AU")),
        div(class = "qsb-item", span(class = "qsb-val", textOutput("qbAtRisk", container = span)), span(class = "qsb-unit", HTML(paste0('<span data-k="qbAtRisk">', tr_raw("en", "qbAtRisk"), '</span>')))),
        div(class = "qsb-item", span(class = "qsb-val", textOutput("qbReds", container = span)), span(class = "qsb-unit", HTML(paste0('<span data-k="qbReds">', tr_raw("en", "qbReds"), '</span>')))),
        div(class = "qsb-item", span(class = "qsb-val", textOutput("qbConn", container = span)), span(class = "qsb-unit", textOutput("qbLatency", container = span))),
        div(class = "qsb-item", span(class = "qsb-val", textOutput("qbAthletes", container = span)), span(class = "qsb-unit", HTML(paste0('<span data-k="totalAthletes">', tr_raw("en", "totalAthletes"), '</span>'))))
    ),

    ## ---------------- ticker ----------------
    div(class = "ticker",
        div(class = "ticker-label", span(class = "live-dot"), HTML(paste0('<span data-k="live">LIVE</span>'))),
        div(class = "ticker-mask", div(class = "ticker-track", id = "tickerTrack", uiOutput("tickerContent")))
    ),

    ## ---------------- main ----------------
    tagList(
      ## ===== TAB: DASHBOARD =====
      div(id = "tab-dashboard", class = "athena-tab-pane active",
        div(class = "athena-shell", id = "athena-main",
            div(style = "padding:12px 14px;",
                div(class = "dash-athlete-bar", style = "display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:12px;margin-bottom:14px;background:var(--card);padding:10px 16px;border-radius:12px;border:1px solid var(--border);box-shadow:var(--shadow);",
                    div(style = "display:flex;align-items:center;gap:10px;flex:1;min-width:280px;",
                        span(class = "mini-label", style = "font-weight:800;letter-spacing:1.5px;color:var(--cyan);white-space:nowrap;", HTML('<span data-k="selectedAthlete">SELECTED ATHLETE</span>:')),
                        div(style = "flex:1;max-width:380px;",
                            selectInput("dashAthleteSelect", label = NULL, choices = head(ATH_CHOICES_INIT %||% c("Athlete ATH-001 (ATH-001)" = "ATH-001"), 200), width = "100%", selectize = FALSE)
                        )
                    ),
                    div(id = "dashAthleteBadge", style = "display:flex;align-items:center;gap:10px;",
                        uiOutput("dashAthleteBadgeWrap")
                    )
                ),
                div(class = "hud-row",
                    hud_card("hud-vo2", "vo2max", "hudVo2", unit = "ml/kg/min", sub_id = "hudVo2Sub", ring_id = "hudVo2Ring"),
                    hud_card("hud-hr", "heartRate", "hudHr", unit = "bpm", sub_id = "hudHrSub"),
                    hud_card("hud-power", "powerOutput", "hudPower", unit = "W", sub_id = "hudPowerSub"),
                    hud_card("hud-ready", "readiness", "hudReady", unit = "/100", sub_id = "hudReadySub", ring_id = "hudReadyRing")
                ),
                div(class = "grid32",
                    panel_card("pcReadinessChart", "readinessTrend", ICONS$chart,
                               uiOutput("readinessChartWrap")),
                    panel_card("pcAiRecs", "aiRecs", ICONS$shield,
                               uiOutput("aiRecsBox"))
                ),
                div(class = "grid2",
                    panel_card("pcLoadMatrix", "loadMatrix", ICONS$pulse,
                               uiOutput("loadHeatmapWrap")),
                    panel_card("pcSleep", "sleepArchitecture", ICONS$moon,
                               uiOutput("sleepBarsWrap"))
                ),
                div(class = "grid2",
                    panel_card("pcRisk", "riskMatrix", ICONS$shield, uiOutput("riskMatrixBox")),
                    panel_card("pcCohort", "cohortStats", ICONS$chart, uiOutput("cohortStatsBox"))
                ),
                div(class = "grid2",
                    panel_card("pcBiometrics", "biometrics", ICONS$pulse, uiOutput("biometricsBox")),
                    panel_card("pcWfRatio", "wfRatio", ICONS$chart, uiOutput("wfRatioBox"))
                ),
                div(class = "grid2",
                    panel_card("pcSessionPlan", "sessionPlan", ICONS$file, uiOutput("sessionPlanBox")),
                    panel_card("pcTimeline", "sessionTimeline", ICONS$clock,
                               uiOutput("timelineCounters"), uiOutput("timelineBox"))
                ),
                panel_card("pcSession", "sessionControl", ICONS$clock,
                           div(style = "text-align:center;",
                               span(class = "mini-label", "VO2MAX BLOCK · INTERVAL"),
                               div(id = "sessTimer", style = "font-size:30px;font-weight:900;letter-spacing:3px;font-variant-numeric:tabular-nums;color:var(--cyan);margin:6px 0 12px;",
                                   textOutput("sessTimer", container = span))),
                           uiOutput("sessBars"),
                           div(style = "display:flex;gap:8px;margin-top:10px;",
                               actionButton("sessPauseBtn", HTML(paste0('<span data-k="pause">', tr_raw("en", "pause"), '</span>')), class = "athena-btn", style = "flex:1;"),
                               actionButton("sessEndBtn", HTML(paste0('<span data-k="end">', tr_raw("en", "end"), '</span>')), class = "athena-btn danger", style = "flex:1;"))),
                panel_card("pcEvents", "eventLog", ICONS$file, uiOutput("eventLogBox"))
            )
        )
      ),

      ## ===== TAB: ROSTER =====
      div(id = "tab-roster", class = "athena-tab-pane",
        div(class = "athena-shell",
            div(style = "padding:12px 14px;",
                div(class = "grid32",
                    panel_card("pcRoster", "roster", ICONS$users, count = textOutput("rosterCount", container = span),
                               div(class = "chip-row", style = "margin-bottom:8px;",
                                   textInput("rosterSearch", label = NULL, placeholder = "Search athletes…",
                                             width = "100%")),
                               div(class = "chip-row",
                                   chip("fAll", "filterAll", "All", active = TRUE),
                                   chip("fGreen", "filterGreen", "Optimal", dot = "green"),
                                   chip("fAmber", "filterAmber", "Caution", dot = "amber"),
                                   chip("fRed", "filterRed", "Danger", dot = "red"),
                                   chip("fFemale", "filterFemale", "Female"),
                                   chip("fMale", "filterMale", "Male")),
                               div(class = "chip-row",
                                   tags$span(class = "mini-label", style = "align-self:center;margin-right:4px;",
                                             HTML(paste0('<span data-k="groupBy">Group by</span>:'))),
                                   chip("gNone", "groupNone", "List", active = TRUE),
                                   chip("gSport", "groupSport", "Sport"),
                                   chip("gRisk", "groupRisk", "Risk")),
                               div(class = "chip-row",
                                   chip("vCards", "viewCards", "CARDS", active = TRUE),
                                   chip("vTable", "viewTable", "TABLE")),
                               uiOutput("rosterBody")),
                    div(
                      panel_card("pcTagMgr", "tagManager", ICONS$gear,
                                 textInput("tagName", HTML(paste0('<span data-k="tagName">', tr_raw("en", "tagName"), '</span>')), ""),
                                 div(style = "display:flex;gap:8px;align-items:center;",
                                     tags$input(type = "color", id = "tagColorIn", value = "#00E5FF",
                                                style = "width:44px;height:34px;border-radius:8px;border:1px solid var(--border);background:var(--bg-3);"),
                                     actionButton("createTagBtn", HTML(paste0('<span data-k="createTag">', tr_raw("en", "createTag"), '</span>')), class = "athena-btn small")),
                                 uiOutput("tagListMgr")),
                      panel_card("pcSelectedQuick", "overview", ICONS$pulse, uiOutput("selectedQuickBox"))
                    )
                )
            )
        )
      ),

      ## ===== TAB: ATHLETE DETAIL =====
      div(id = "tab-athlete", class = "athena-tab-pane",
        div(class = "athena-shell",
            div(style = "padding:12px 14px;",
                uiOutput("athleteHeader"),
                div(class = "hud-row", style = "margin-top:12px;",
                    uiOutput("athleteRings")),
                div(class = "grid2",
                    panel_card("pcEaTrend", "eaTrendTitle", ICONS$chart,
                               uiOutput("eaTrendWrap"),
                               div(class = "mini-label", style = "margin-top:6px;",
                                   HTML(paste0('<span data-k="eaForecastNote">', tr_raw("en", "eaForecastNote"), '</span> · ',
                                               '<span data-k="weightNote"></span>')))),
                    panel_card("pcAcwr", "acwrTitle", ICONS$pulse, uiOutput("acwrBox"))
                ),
                div(class = "grid2",
                    panel_card("pcRadar", "wellnessRadar", ICONS$chart, uiOutput("radarWrap")),
                    panel_card("pcCycle", "cycleTimeline", ICONS$clock, uiOutput("cycleBox"))
                ),
                panel_card("pcPerfTrend", "perfTrend", ICONS$chart,
                           div(class = "chip-row",
                               checkboxInput("ptCycleShade", HTML(paste0('<span data-k="cycleShade">', tr_raw("en", "cycleShade"), '</span>')), FALSE),
                               downloadButton("dlPerfCsv", HTML(paste0('<span data-k="exportCsv">', tr_raw("en", "exportCsv"), '</span>')), class = "athena-btn small")),
                           uiOutput("perfTrendWrap"),
                           uiOutput("perfForecastBanner")),
                div(class = "grid2",
                    panel_card("pcLactate", "lactateCurve", ICONS$pulse,
                               uiOutput("lactateWrap")),
                    panel_card("pcSleepArch", "sleepArch", ICONS$moon,
                               uiOutput("sleepArchStages"), uiOutput("hypnoWrap"))
                ),
                div(class = "grid2",
                    panel_card("pcNutrition", "nutrition", ICONS$pulse, uiOutput("nutritionBox")),
                    panel_card("pcHist", "perfHistory", ICONS$chart,
                               div(class = "chip-row",
                                   chip_s("h30", "30D", active = TRUE),
                                   chip_s("h60", "60D"),
                                   chip_s("h90", "90D")),
                               uiOutput("perfHistWrap"))
                ),
                div(class = "grid2",
                    panel_card("pcMonotony", "monotonyTitle", ICONS$chart, uiOutput("monotonyBox")),
                    panel_card("pcQual", "dataCompleteness", ICONS$file, uiOutput("qualityBox"))
                ),
                panel_card("pcNotes", "notes", ICONS$file,
                           div(style = "display:flex;gap:8px;align-items:flex-start;margin-bottom:10px;",
                               div(style = "flex:1;", textAreaInput("noteInput", NULL, "", height = "58px",
                                                                    placeholder = "Type a note…")),
                               div(style = "display:flex;flex-direction:column;gap:5px;",
                                   actionButton("addNoteBtn", HTML(paste0('<span data-k="addNote">', tr_raw("en", "addNote"), '</span>')), class = "athena-btn small primary"),
                                   div(style = "display:flex;gap:5px;",
                                       actionButton("undoNoteBtn", "\u21BA", class = "athena-btn small", title = "Undo"),
                                       actionButton("redoNoteBtn", "\u21BB", class = "athena-btn small", title = "Redo"))),
                               div(style = "width:150px;",
                                   selectInput("notePriority", NULL, c("info", "warning", "critical"), selected = "info"))),
                           uiOutput("notesBox"))
            )
        )
      ),

      ## ===== TAB: RED-S LAB =====
      div(id = "tab-reds", class = "athena-tab-pane",
        div(class = "athena-shell",
            div(style = "padding:12px 14px;",
                div(class = "grid32",
                    panel_card("pcRedsCalc", "redsLab", ICONS$shield,
                               div(style = "font-size:11px;color:var(--text-dim);margin-bottom:10px;",
                                   HTML(paste0('<span data-k="eaFormula">', tr_raw("en", "eaFormula"), '</span>'))),
                               selectInput("redsAthlete", HTML(paste0('<span data-k="roster">', tr_raw("en", "roster"), '</span>')), choices = head(ATH_CHOICES_INIT %||% c("Athlete ATH-001 (ATH-001)" = "ATH-001"), 200), width = "100%", selectize = FALSE),
                               sliderInput("scIntake", HTML(paste0('<span data-k="intake">', tr_raw("en", "intake"), '</span>')), min = 800, max = 6000, value = 2800, step = 50),
                               sliderInput("scDuration", HTML(paste0('<span data-k="duration">', tr_raw("en", "duration"), '</span>')), min = 0, max = 240, value = 90, step = 5),
                               sliderInput("scMass", HTML(paste0('<span data-k="bodyMass">', tr_raw("en", "bodyMass"), '</span>')), min = 35, max = 130, value = 68, step = 0.5),
                               sliderInput("scFfm", HTML(paste0('<span data-k="ffm">', tr_raw("en", "ffm"), '</span>')), min = 30, max = 90, value = 58, step = 0.5),
                               selectInput("scExercise", HTML(paste0('<span data-k="exerciseType">', tr_raw("en", "exerciseType"), '</span>')),
                                           c("auto" = "", EXERCISE_TYPES), selected = ""),
                               radioButtons("scGender", HTML(paste0('<span data-k="gender">', tr_raw("en", "gender"), '</span>')),
                                            c("male", "female"), selected = "male", inline = TRUE),
                               selectInput("scCycle", HTML(paste0('<span data-k="cyclePhase">', tr_raw("en", "cyclePhase"), '</span>')),
                                           c("none" = "", CYCLE_PHASES), selected = "")),
                    div(
                      panel_card("pcRedsResult", "eaValue", ICONS$shield, uiOutput("redsResultBox")),
                      panel_card("pcRedsBreak", "factors", ICONS$file, uiOutput("redsBreakdown")),
                      panel_card("pcRedsRec", "clinicalRec", ICONS$shield, uiOutput("redsRecommend"))
                    )
                ),
                panel_card("pcCohortReds", "cohortReds", ICONS$chart, uiOutput("cohortRedsWrap")),
                panel_card("pcBoneAcl", "boneAcl", ICONS$shield, uiOutput("boneAclBox")),
                div(class = "mini-label", style = "padding:0 4px 10px;", textOutput("redsCaveat"))
            )
        )
      ),

      ## ===== TAB: COHORT =====
      div(id = "tab-cohort", class = "athena-tab-pane",
        div(class = "athena-shell",
            div(style = "padding:12px 14px;",
                panel_card("pcCompare", "compare", ICONS$users,
                           div(class = "mini-label", style = "margin-bottom:8px;",
                               HTML(paste0('<span data-k="compareHint">', tr_raw("en", "compareHint"), '</span>'))),
                           uiOutput("compareSelects"),
                           div(style = "display:flex;gap:8px;margin-top:6px;",
                               actionButton("compareClear", HTML(paste0('<span data-k="reset">', tr_raw("en", "reset"), '</span>')), class = "athena-btn small"))),
                div(class = "grid2",
                    panel_card("pcRadarCmp", "wellnessRadar", ICONS$chart, uiOutput("compareRadarWrap")),
                    panel_card("pcSquadHeat", "squadHeatmap", ICONS$pulse, uiOutput("squadHeatmapWrap"))
                ),
                panel_card("pcSquadStats", "cohortStats", ICONS$chart, uiOutput("squadStatsBox")),
                panel_card("pcLoadTable", "loadMatrix", ICONS$pulse,
                           count = textOutput("loadTableN", container = span),
                           uiOutput("loadMatrixTableBox"))
            )
        )
      ),

      ## ===== TAB: DATA OPS =====
      div(id = "tab-data", class = "athena-tab-pane",
        div(class = "athena-shell",
            div(style = "padding:12px 14px;",
                div(class = "grid2",
                    panel_card("pcImport", "csvImport", ICONS$file,
                               fileInput("csvFile", HTML(paste0('<span data-k="csvDrop">', tr_raw("en", "csvDrop"), '</span>')),
                                         accept = c(".csv", "text/csv"), width = "100%"),
                               uiOutput("csvPreviewBox"),
                               div(style = "display:flex;gap:8px;margin-top:8px;",
                                   actionButton("csvUploadBtn", HTML(paste0('<span data-k="upload">', tr_raw("en", "upload"), '</span>')), class = "athena-btn small primary"),
                                   uiOutput("csvUploadStatus"))),
                    panel_card("pcExport", "export", ICONS$file,
                               div(class = "rec-list",
                                   downloadButton("dlCsv", HTML(paste0('<span data-k="exportCsv">', tr_raw("en", "exportCsv"), '</span>')), class = "athena-btn"),
                                   downloadButton("dlJson", HTML(paste0('<span data-k="exportJson">', tr_raw("en", "exportJson"), '</span>')), class = "athena-btn"),
                                   downloadButton("dlReport", HTML(paste0('<span data-k="downloadReport">', tr_raw("en", "downloadReport"), '</span>')), class = "athena-btn"),
                                   downloadButton("dlResearch", HTML(paste0('<span data-k="researchExport">', tr_raw("en", "researchExport"), '</span>')), class = "athena-btn")),
                               div(class = "mini-label", style = "margin-top:12px;",
                                   HTML(paste0('<span data-k="printReport">', tr_raw("en", "printReport"), '</span> · Ctrl+P'))))
                ),
                panel_card("pcCompleteness", "dataCompleteness", ICONS$file, uiOutput("completenessBox"))
            )
        )
      ),

      ## ===== TAB: SYSTEM =====
      div(id = "tab-system", class = "athena-tab-pane",
        div(class = "athena-shell",
            div(style = "padding:12px 14px;",
                div(class = "grid3",
                    panel_card("pcHealth", "healthCheck", ICONS$pulse, uiOutput("healthBox")),
                    panel_card("pcThermal", "thermalGuard", ICONS$cpu, uiOutput("thermalBox")),
                    panel_card("pcMl", "mlPipeline", ICONS$cpu, uiOutput("mlStatusBox"))
                ),
                div(class = "grid2",
                    panel_card("pcAlerts", "alertCenter", ICONS$shield,
                               div(style = "display:flex;gap:8px;margin-bottom:8px;",
                                   actionButton("ackAllBtn", HTML(paste0('<span data-k="ackAll">', tr_raw("en", "ackAll"), '</span>')), class = "athena-btn small")),
                               uiOutput("alertCenterBox")),
                    panel_card("pcDiag", "diagnostics", ICONS$cpu, uiOutput("diagBox"))
                )
            )
        )
      ),

      ## ===== TAB: SETTINGS =====
      div(id = "tab-settings", class = "athena-tab-pane",
        div(class = "athena-shell",
            div(style = "padding:12px 14px;",
                div(class = "grid2",
                    panel_card("pcApi", "settings", ICONS$gear,
                               textInput("setApiUrl", HTML(paste0('<span data-k="apiUrl">', tr_raw("en", "apiUrl"), '</span>')), value = API_BASE_DEFAULT, width = "100%"),
                               passwordInput("setApiToken", HTML(paste0('<span data-k="apiToken">', tr_raw("en", "apiToken"), '</span>')), "", width = "100%"),
                               selectInput("setRefresh", HTML(paste0('<span data-k="refreshToken">', tr_raw("en", "refreshToken"), '</span>')),
                                           c("10" = 10, "30" = 30, "60" = 60, "120" = 120, "0" = 0), selected = "30", width = "100%"),
                               sliderInput("setGreenTh", HTML(paste0('<span data-k="minReadiness">', tr_raw("en", "minReadiness"), '</span>')), min = 40, max = 95, value = READY_GREEN, step = 1),
                               radioButtons("setUnits", HTML(paste0('<span data-k="units">', tr_raw("en", "units"), '</span>')),
                                            c("metric", "imperial"), selected = "metric", inline = TRUE),
                               checkboxInput("setSound", HTML(paste0('<span data-k="sound">', tr_raw("en", "sound"), '</span>')), FALSE),
                               checkboxInput("setCompact", HTML(paste0('<span data-k="compact">', tr_raw("en", "compact"), '</span>')), FALSE),
                               checkboxInput("setAutoDemo", HTML(paste0('<span data-k="autoDemo">', tr_raw("en", "autoDemo"), '</span>')), TRUE),
                               div(style = "display:flex;gap:8px;margin-top:8px;",
                                   actionButton("saveSettingsBtn", HTML(paste0('<span data-k="save">', tr_raw("en", "save"), '</span>')), class = "athena-btn primary"),
                                   actionButton("resetSettingsBtn", HTML(paste0('<span data-k="reset">', tr_raw("en", "reset"), '</span>')), class = "athena-btn"))),
                    div(
                      panel_card("pcShortcuts", "shortcuts", ICONS$gear,
                                 div(class = "rec-list", HTML(paste0('<div class="rec-item mono">', tr_raw("en", "shortcutsHint"), '</div>')))),
                      panel_card("pcAbout", "about", ICONS$shield,
                                 div(style = "font-size:11px;line-height:1.7;color:var(--text-muted);",
                                     textOutput("aboutText"), br(), br(),
                                     span(class = "mini-label", paste("ATHENA v1 ·", ATHENA_BUILD)), br(),
                                     span(class = "mini-label", CLASSIFICATION)))
                    )
                )
            )
        )
      )
    ),

    ## ---------------- footer ----------------
    tags$footer(class = "athena-footer", role = "contentinfo",
                span(paste("ATHENA v1 ·", ATHENA_BUILD)),
                span(class = "footer-dim", CLASSIFICATION),
                span(uiOutput("footerMode", inline = TRUE)),
                span(class = "footer-dim", span(id = "ftrClock", "—"), " · ", textOutput("footerTz", container = span))
    ),

    ## ---------------- toasts & modals ----------------
    uiOutput("jsBridge"),
    uiOutput("notifPanel"),
    div(class = "toast-wrap", id = "toastWrap", `aria-live` = "polite"),

    ## login modal
    div(id = "loginModal", style = "display:none;position:fixed;inset:0;z-index:10060;background:rgba(0,0,0,.65);",
        div(style = "max-width:390px;margin:9vh auto;background:var(--card);border:1px solid var(--border);border-radius:16px;padding:22px;box-shadow:0 18px 60px rgba(0,0,0,.55);",
            div(style = "font-size:14px;font-weight:900;letter-spacing:2px;color:var(--cyan);margin-bottom:14px;",
                HTML(paste0('<span data-k="loginTitle">', tr_raw("en", "loginTitle"), '</span>'))),
            textInput("loginUser", HTML(paste0('<span data-k="userId">', tr_raw("en", "userId"), '</span>')), "director", width = "100%"),
            passwordInput("loginPass", HTML(paste0('<span data-k="password">', tr_raw("en", "password"), '</span>')), "Athena@2026", width = "100%"),
            div(style = "background:var(--bg-3);border:1px solid var(--border);border-radius:8px;padding:8px 12px;margin:8px 0 12px;font-size:10.5px;color:var(--text-muted);",
                HTML('<b>Credentials:</b> User: <code style="color:var(--cyan)">director</code> (or admin, coach, ATH-001) · Password: <code style="color:var(--cyan)">Athena@2026</code>')
            ),
            uiOutput("loginMsg"),
            div(style = "display:flex;gap:8px;margin-top:10px;",
                actionButton("loginSubmit", HTML(paste0('<span data-k="login">', tr_raw("en", "login"), '</span>')), class = "athena-btn primary", style = "flex:1;"),
                actionButton("loginDemo", HTML(paste0('<span data-k="demo">', tr_raw("en", "demo"), '</span>')), class = "athena-btn", style = "flex:1;"),
                actionButton("loginClose", HTML(paste0('<span data-k="close">', tr_raw("en", "close"), '</span>')), class = "athena-btn", style = "flex:1;")))),

    ## check-in modal
    div(id = "checkinModal", style = "display:none;position:fixed;inset:0;z-index:10060;background:rgba(0,0,0,.65);overflow-y:auto;",
        div(style = "max-width:520px;margin:6vh auto;background:var(--card);border:1px solid var(--border);border-radius:16px;padding:20px;box-shadow:0 18px 60px rgba(0,0,0,.55);",
            div(style = "font-size:14px;font-weight:900;letter-spacing:2px;color:var(--cyan);margin-bottom:14px;",
                HTML(paste0('<span data-k="checkinTitle">', tr_raw("en", "checkinTitle"), '</span> <span id="ckAthleteName"></span>'))),
            selectInput("ckAthlete", HTML(paste0('<span data-k="roster">', tr_raw("en", "roster"), '</span>')), choices = head(ATH_CHOICES_INIT %||% c("Athlete ATH-001 (ATH-001)" = "ATH-001"), 200), width = "100%", selectize = FALSE),
            div(class = "grid2",
                numericInput("ckDuration", HTML(paste0('<span data-k="duration">', tr_raw("en", "duration"), '</span>')), 60, min = 1, max = 720),
                sliderInput("ckRpe", HTML(paste0('<span data-k="rpe">', tr_raw("en", "rpe"), '</span> · <span id="ckRpeVal">5</span>/10')), min = 1, max = 10, value = 5),
                numericInput("ckSleep", HTML(paste0('<span data-k="sleepH">', tr_raw("en", "sleepH"), '</span>')), 7.5, min = 0, max = 16, step = 0.1),
                sliderInput("ckSleepQ", HTML(paste0('<span data-k="sleepQuality">', tr_raw("en", "sleepQuality"), '</span>')), min = 1, max = 7, value = 4),
                sliderInput("ckStress", HTML(paste0('<span data-k="stress">', tr_raw("en", "stress"), '</span>')), min = 1, max = 7, value = 3),
                sliderInput("ckFatigue", HTML(paste0('<span data-k="fatigue">', tr_raw("en", "fatigue"), '</span>')), min = 1, max = 7, value = 3),
                sliderInput("ckSore", HTML(paste0('<span data-k="soreness">', tr_raw("en", "soreness"), '</span>')), min = 1, max = 7, value = 2),
                sliderInput("ckPain", HTML(paste0('<span data-k="pain">', tr_raw("en", "pain"), '</span>')), min = 0, max = 10, value = 0),
                selectInput("ckExercise", HTML(paste0('<span data-k="exerciseType">', tr_raw("en", "exerciseType"), '</span>')), c("", EXERCISE_TYPES)),
                numericInput("ckCalories", HTML(paste0('<span data-k="calories">', tr_raw("en", "calories"), '</span>')), NA, min = 500, max = 10000),
                numericInput("ckFfm", HTML(paste0('<span data-k="ffm">', tr_raw("en", "ffm"), '</span>')), NA, min = 30, max = 120, step = 0.1),
                selectInput("ckMood", HTML(paste0('<span data-k="mood">', tr_raw("en", "mood"), '</span>')),
                            c("neutral", "good", "anxious", "depressed", "irritable"))),
            textInput("ckInjury", HTML(paste0('<span data-k="injuryLocation">', tr_raw("en", "injuryLocation"), '</span>')), "", width = "100%"),
            textInput("ckBlockTag", HTML(paste0('<span data-k="blockTag">', tr_raw("en", "blockTag"), '</span>')), "", width = "100%", placeholder = "e.g. VO2MAX-BLOCK / DELOAD / BASE"),
            textAreaInput("ckReflection", HTML(paste0('<span data-k="reflection">', tr_raw("en", "reflection"), '</span>')), "", height = "54px", width = "100%"),
            uiOutput("ckCycleRow"),
            div(id = "ckError", style = "color:var(--red);font-size:11px;display:none;margin-top:6px;"),
            div(style = "display:flex;gap:8px;margin-top:12px;",
                actionButton("ckSubmit", HTML(paste0('<span data-k="submit">', tr_raw("en", "submit"), '</span>')), class = "athena-btn primary", style = "flex:1;"),
                actionButton("ckCancel", HTML(paste0('<span data-k="cancel">', tr_raw("en", "cancel"), '</span>')), class = "athena-btn", style = "flex:1;")))),

    ## command palette modal
    div(id = "cmdModal", style = "display:none;position:fixed;inset:0;z-index:10055;background:rgba(0,0,0,.65);",
        div(style = "max-width:440px;margin:10vh auto;background:var(--card);border:1px solid var(--border);border-radius:16px;padding:14px;",
            textInput("cmdSearch", HTML(paste0('<span data-k="cmdPlaceholder">', tr_raw("en", "cmdPlaceholder"), '</span>')), "", width = "100%"),
            uiOutput("cmdResults"),
            div(class = "mini-label", style = "margin-top:8px;", "Ctrl+K · \u2191\u2193 · Enter"))),

    ## help modal
    div(id = "helpModal", style = "display:none;position:fixed;inset:0;z-index:10055;background:rgba(0,0,0,.65);",
        div(style = "max-width:460px;margin:10vh auto;background:var(--card);border:1px solid var(--border);border-radius:16px;padding:18px;",
            div(style = "font-size:13px;font-weight:900;letter-spacing:1.5px;color:var(--cyan);margin-bottom:10px;",
                HTML(paste0('<span data-k="shortcuts">', tr_raw("en", "shortcuts"), '</span>'))),
            div(class = "rec-list mono",
                HTML(paste0('<div class="rec-item">', tr_raw("en", "shortcutsHint"), '</div>',
                            '<div class="rec-item">Ctrl+K / Esc — ', tr_raw("en", "cmdPlaceholder"), '</div>',
                            '<div class="rec-item">', tr_raw("en", "clinicalCaveat"), '</div>'))),
            div(style = "text-align:right;margin-top:10px;",
                actionButton("helpClose", HTML(paste0('<span data-k="close">', tr_raw("en", "close"), '</span>')), class = "athena-btn small"))))
  )
}

## =============================================================================
## 10 · SERVER
## =============================================================================

server <- function(input, output, session) {

  ## ---------- collapse-free render guard ----------
  err_card <- function(lang, e) {
    div(class = "err-card",
        HTML(paste0('\u26A0 ', tr_raw(lang, "errorOccurred"),
                    ' \u2014 <code>', htmltools::htmlEscape(conditionMessage(e %||% "unknown")), '</code>')))
  }
  safe_html <- function(lang, expr) {
    tryCatch(force(expr), error = function(e) err_card(lang, e))
  }
  need_msg <- function(x, msg) {
    shiny::validate(shiny::need(!is.null(x) && length(x) > 0 && !all(is.na(x)), msg))
  }

  ## ---------- session state ----------
  RV <- reactiveValues(
    athletes      = NULL,          # data.frame roster (normalized)
    trends        = list(),        # list of data.frames keyed by user_id
    active        = NULL,          # active athlete user_id
    events        = list(),        # bounded ticker events
    notifications = list(),        # bounded notifications
    notifOpen     = FALSE,
    alerts        = list(),        # derived alert objects
    acked         = character(0),
    simOn         = FALSE,
    paused        = FALSE,
    timer         = 8133L,
    notes         = list(), noteUndo = list(), noteRedo = list(),
    compare       = character(0),
    csvInfo       = NULL,
    csvPreview    = NULL,
    lastSync      = NULL,
    visible       = TRUE,
    settingsSaved = 0L,
    cmdTargets    = character(0),
    bioPrev       = list(),
    histRange     = 30L,
    loginMsg      = NULL,
    health        = NULL, thermal = NULL, thermalHist = numeric(0), mlstat = NULL,
    diag          = NULL,
    jsCode        = NULL, jsToken = 0L
  )

  ## JS bridge — executes arbitrary client code without shinyjs.
  js_run <- function(code) {
    tok <- tryCatch(isolate(RV$jsToken), error = function(e) 0L) + 1L
    RV$jsToken <- tok
    RV$jsCode  <- paste0(code, ";/*", tok, "-", as.numeric(Sys.time()), "*/")
  }
  output$jsBridge <- renderUI({
    req(RV$jsCode)
    tags$script(HTML(RV$jsCode))
  })

  ## ---------- i18n ----------
  rvLang <- reactive({
    RV$lang %||% input$i18nLang %||% input$langSelect %||% "en"
  })
  T <- function(key) tr_raw(rvLang(), key)
  fn <- function(x, digits = 0) fmt_num(x, digits, rvLang())

  observeEvent(input$langSelect, {
    lg <- input$langSelect
    if (!is.null(lg) && lg %in% LANG_CODES && !identical(RV$lang, lg)) {
      RV$lang <- lg
      df <- RV$athletes
      if (!is.null(df) && nrow(df) > 0) {
        RV$alerts <- derive_alerts(df, lg)
      }
      js_run(paste0("applyLang('", lg, "');"))
    }
  }, ignoreInit = TRUE)
  observeEvent(input$i18nLang, {
    lg <- input$i18nLang
    if (!is.null(lg) && lg %in% LANG_CODES && !identical(RV$lang, lg)) {
      RV$lang <- lg
      df <- RV$athletes
      if (!is.null(df) && nrow(df) > 0) {
        RV$alerts <- derive_alerts(df, lg)
      }
      js_run(paste0("applyLang('", lg, "');"))
    }
  }, ignoreInit = TRUE)

  ## ---------- theme / crt / compact ----------
  observeEvent(input$uiTheme, {
    th <- input$uiTheme
    if (!is.null(th) && nzchar(th)) RV$theme <- th
  }, ignoreInit = FALSE)
  observeEvent(input$themeBtn, {
    cur <- RV$theme %||% input$uiTheme %||% "dark"
    nxt <- if (cur == "dark") "light" else "dark"
    RV$theme <- nxt
    js_run(paste0("applyTheme('", nxt, "');"))
  })
  observeEvent(input$crtBtn, {
    js_run(paste0("var b=document.body;b.classList.toggle('crt');localStorage.setItem('athena_crt',b.classList.contains('crt')?'1':'0');"))
  })
  observeEvent(input$compactBtn, {
    js_run(paste0("var b=document.body;b.classList.toggle('compact');localStorage.setItem('athena_compact',b.classList.contains('compact')?'1':'0');"))
  })
  observeEvent(input$helpBtn,  js_run("document.getElementById('helpModal').style.display='block';"))
  observeEvent(input$helpClose, js_run("document.getElementById('helpModal').style.display='none';"))

  ## ---------- toast / notification helpers ----------
  notify <- function(type, title, desc = "", browser_push = FALSE) {
    curr_notif <- tryCatch(isolate(RV$notifications), error = function(e) list())
    RV$notifications <- head(append(list(list(ts = Sys.time(), type = type, title = title, desc = desc)),
                                    curr_notif), NOTIF_MAX)
    js <- paste0("athToast('", type, "','", gsub("'", "", title), "','", gsub("'", "", desc), "');")
    if (isTRUE(browser_push)) {
      js <- paste0(js, "athNotifyBrowser('", gsub("'", "", title), "','", gsub("'", "", desc), "');")
    }
    js_run(js)
    log_event(if (type == "error") "var(--red)" else if (type == "warn") "var(--amber)" else "var(--cyan)", title)
  }
  log_event <- function(color, text) {
    curr_ev <- tryCatch(isolate(RV$events), error = function(e) list())
    RV$events <- head(append(list(list(ts = Sys.time(), color = color, text = text)), curr_ev), TICKER_MAX)
  }

  ## ---------- data loading ----------
  # v7: full data model. Backend-provided values win; missing values are filled
  # deterministically (det_unif seeded by user_id) so live/demo rendering is stable.
  normalize_athletes <- function(raw_list) {
    if (is.null(raw_list) || length(raw_list) == 0) return(NULL)
    rows <- lapply(raw_list, function(a) {
      uid   <- as.character(jget(a, "user_id", default = "?"))
      gen   <- tolower(as.character(jget(a, "gender", default = "male")))
      dq    <- function(field, lo, hi, salt, digits = 0, dflt = 0) {
        v <- suppressWarnings(as.numeric(jget(a, field, default = NA)))
        if (length(v) == 0 || is.na(v)) {
          v <- lo + (hi - lo) * det_unif(uid, salt)
          if (digits == 0) v <- round(v) else v <- round(v, digits)
        }
        clamp(v, lo - abs(lo) * 0.5, hi + abs(hi) * 0.5)
      }
      dqi   <- function(field, lo, hi, salt) as.integer(dq(field, lo, hi, salt))
      sl_q  <- dqi("sleep_quality", 1, 7, "sq0")
      stg   <- sleep_stages_for(uid, sl_q)
      stage_val <- function(field, hi, fb) {
        v <- suppressWarnings(as.numeric(jget(a, field, default = NA)))
        if (length(v) == 0 || is.na(v)) as.integer(fb) else as.integer(clamp(v, 0, hi))
      }
      cal   <- safe_num(jget(a, "calories", default = 0))
      dload <- safe_num(jget(a, "daily_load", default = 0))
      raw_name <- as.character(jget(a, "name", default = ""))
      ath_name <- if (nzchar(raw_name) && !identical(raw_name, uid)) {
        raw_name
      } else if (grepl("^ATH-", uid)) {
        paste("Athlete", uid)
      } else if (grepl("^[0-9]+$", uid)) {
        paste("Athlete", sprintf("ATH-%03d", as.integer(uid)))
      } else {
        paste("Athlete", uid)
      }
      ath_sport <- as.character(jget(a, "sport", default = ""))
      if (!nzchar(ath_sport)) {
        ath_sport <- SPORTS[((sum(as.integer(charToRaw(uid)))) %% length(SPORTS)) + 1]
      }
      data.frame(
        user_id     = uid,
        name        = ath_name,
        gender      = gen,
        sport       = ath_sport,
        daily_load  = dload,
        rpe         = safe_num(jget(a, "rpe", default = 0)),
        sleep_hours = safe_num(jget(a, "sleep_hours", default = 0)),
        sleep_quality = sl_q,
        stress      = safe_num(jget(a, "stress", default = 0)),
        fatigue     = safe_num(jget(a, "fatigue", default = 0)),
        muscle_soreness = safe_num(jget(a, "muscle_soreness", default = 0)),
        pain_level  = safe_num(jget(a, "pain_level", default = 0)),
        injury_location = as.character(jget(a, "injury_location", default = "")),
        calories    = cal,
        ffm         = safe_num(jget(a, "ffm", default = 0)),
        mood        = as.character(jget(a, "mood", default = "neutral")),
        exercise_type = as.character(jget(a, "exercise_type", default = "")),
        cycle_phase = as.character(jget(a, "cycle_phase", default = "")),
        training_paused = isTRUE(jget(a, "training_paused", default = FALSE)) ||
                          identical(jget(a, "training_paused", default = FALSE), 1) ||
                          identical(jget(a, "training_paused", default = FALSE), "1"),
        last_date   = as.character(jget(a, "last_date", default = "")),
        ## ---- v7 physiology ----
        heart_rate  = dqi("heart_rate", 48, 105, "hr"),
        hrv         = dqi("hrv", 20, 95, "hrv"),
        vo2max      = dq("vo2max", 34, 82, "vo2", 1),
        power       = dqi("power", 120, 420, "pw"),
        ftp         = dqi("ftp", 100, 380, "ftp"),
        lactate     = dq("lactate", 0.8, 8, "lac", 1),
        core_temp   = dq("core_temp", 35.8, 38.6, "ct", 1),
        spo2        = dqi("spo2", 91, 100, "spo2"),
        resp_rate   = dqi("resp_rate", 10, 24, "rr"),
        cadence     = dqi("cadence", 70, 110, "cad"),
        torque      = dqi("torque", 45, 130, "tq"),
        rsi         = dq("rsi", 1.2, 4.2, "rsi", 2),
        gct         = dqi("gct", 150, 260, "gct"),
        ## ---- v7 sleep stages ----
        sleep_rem_pct    = stage_val("sleep_rem_pct", 45, safe_lookup(stg, "rem") %||% 22),
        sleep_deep_pct   = stage_val("sleep_deep_pct", 45, safe_lookup(stg, "deep") %||% 20),
        sleep_light_pct  = stage_val("sleep_light_pct", 70, safe_lookup(stg, "light") %||% 48),
        sleep_awake_pct  = stage_val("sleep_awake_pct", 20, safe_lookup(stg, "awake") %||% 10),
        ## ---- v7 nutrition ----
        calories_in  = safe_num(jget(a, "calories_in", default = cal)),
        calories_out = safe_num(jget(a, "calories_out", default = round(cal + dload * 1.4 - 320))),
        cho_g_per_kg = dq("cho_g_per_kg", 3, 10, "cho", 1),
        protein_g_per_kg = dq("protein_g_per_kg", 1, 3, "prot", 1),
        hydration_pct = dqi("hydration_pct", 30, 100, "hyd"),
        ## ---- v7 injury risks (%) ----
        hamstring_risk = dqi("hamstring_risk", 5, 90, "ham"),
        knee_acl_risk  = dqi("knee_acl_risk", 5, 80, "acl"),
        achilles_risk  = dqi("achilles_risk", 5, 80, "ach"),
        overreach_risk = dqi("overreach_risk", 5, 90, "ovr"),
        cardiac_risk   = dqi("cardiac_risk", 2, 70, "car"),
        ## ---- v7 load bookkeeping (refined in derive_roster) ----
        atl = safe_num(jget(a, "atl", default = NA_real_)),
        ctl = safe_num(jget(a, "ctl", default = NA_real_)),
        tsb = safe_num(jget(a, "tsb", default = NA_real_)),
        monotony = suppressWarnings(as.numeric(jget(a, "monotony", default = NA_real_))),
        strain = safe_num(jget(a, "strain", default = NA_real_)),
        ## ---- v7 bone health ----
        bone_t_score = dq("bone_t_score", -3.2, 1.5, "ts", 1),
        bone_z_score = dq("bone_z_score", -2.5, 1.5, "zs", 1),
        stringsAsFactors = FALSE
      )
    })
    out <- do.call(rbind, rows)
    if (is.null(out) || nrow(out) == 0) return(NULL)
    if (!nzchar(out$sport[1]) || all(out$sport == "")) {
      out$sport <- SPORTS[(seq_len(nrow(out)) - 1) %% length(SPORTS) + 1]
    }
    ## light-stage share must absorb rounding so the night sums to 100
    out$sleep_light_pct <- pmax(30, 100 - out$sleep_rem_pct - out$sleep_deep_pct - out$sleep_awake_pct)
    out
  }

  # decorate roster with derived metrics (readiness / status / EA / flags)
  derive_roster <- function(df, trends_list = list()) {
    if (is.null(df) || nrow(df) == 0) return(df)
    n <- nrow(df)
    df$readiness <- readiness_score(df$sleep_hours, df$sleep_quality,
                                    df$stress, df$fatigue,
                                    df$muscle_soreness, df$pain_level)
    df$status    <- status_from_readiness(df$readiness)
    
    # EA Cunningham formula
    cal_v <- ifelse(is.na(df$calories) | df$calories <= 0,
                    ifelse(df$gender == "female", 2200, 2800), df$calories)
    ffm_v <- ifelse(is.na(df$ffm) | df$ffm <= 0,
                    ifelse(df$gender == "female", 50, 68), df$ffm)
    rmr_min <- (500 + 22 * ffm_v) / 1440
    gross_eee <- df$daily_load * 1.5
    net_eee <- pmax(0, gross_eee - rmr_min * 90)
    luteal_pen <- ifelse(df$gender == "female" & tolower(df$cycle_phase) == "luteal", 150, 0)
    df$ea <- round((cal_v - luteal_pen - net_eee) / pmax(30, ffm_v), 1)
    
    df$acwr <- round(clamp(0.9 + (df$daily_load %% 40) * 0.015, 0.6, 1.8), 2)
    df$monotony <- round(clamp(1.2 + (df$daily_load %% 20) * 0.04, 0.8, 2.6), 2)
    df$strain <- round(df$daily_load * 7 * df$monotony)
    df$injury <- round(clamp(10 + (df$acwr > 1.5) * 40 + df$pain_level * 5 + df$fatigue * 3, 5, 95))
    
    # Refine for any athletes with trends in trends_list
    for (uid in intersect(names(trends_list), df$user_id)) {
      tr <- trends_list[[uid]]
      if (!is.null(tr) && nrow(tr) >= 7) {
        idx <- which(df$user_id == uid)[1]
        a  <- acwr_series(tr$daily_load)
        df$acwr[idx] <- tail(a$acwr, 1)
        df$monotony[idx] <- tail(monotony_strain(tr$daily_load)$monotony, 1)
        df$atl[idx] <- round(tail(a$acute, 1))
        df$ctl[idx] <- round(tail(a$chronic, 1))
        df$tsb[idx] <- df$ctl[idx] - df$atl[idx]
        df$injury[idx] <- injury_forecast_score(df$acwr[idx], df$pain_level[idx], df$fatigue[idx],
                                                df$muscle_soreness[idx], df$monotony[idx])
      }
    }
    df
  }

  # v7 alert engine — full 10-rule set ported from index.html (PHASE 17) plus the
  # 5 clinical rules kept from v6. index.html iterated an undefined global
  # `athletes`; here every rule iterates the NORMALIZED roster (df) instead.
  derive_alerts <- function(df, lang = "en") {
    al <- list()
    if (is.null(df) || nrow(df) == 0) return(al)
    rule <- function(id, severity, athlete, text, rule_key = NULL, val = NULL, extra = NULL) {
      al[[length(al) + 1]] <<- list(
        id = id,
        athlete = athlete,
        severity = severity,
        text = text,
        rule_key = rule_key,
        val = val,
        extra = extra
      )
    }
    for (i in seq_len(nrow(df))) {
      id <- df$user_id[i]; nm <- df$name[i]
      rd <- df$readiness[i]; ld <- df$daily_load[i]; hv <- df$hrv[i]
      rp <- df$rpe[i]; sh <- df$sleep_hours[i]; st <- df$stress[i]
      hy <- df$hydration_pct[i]; ov <- df$overreach_risk[i]
      hm <- df$hamstring_risk[i]; ca <- df$cardiac_risk[i]
      ## ---- the 10 index.html rules ----
      if (!is.na(rd) && rd < 50)
        rule(paste0(id, ":r_low_readiness"), "critical", nm,
             format_alert_text("lowReadiness", rd, NULL, lang),
             rule_key = "lowReadiness", val = rd)
      if (!is.na(ld) && ld > 700)
        rule(paste0(id, ":r_high_load"), "warning", nm,
             format_alert_text("highLoad", ld, NULL, lang),
             rule_key = "highLoad", val = ld)
      if (!is.na(hv) && hv < 35)
        rule(paste0(id, ":r_low_hrv"), "critical", nm,
             format_alert_text("lowHrv", hv, NULL, lang),
             rule_key = "lowHrv", val = hv)
      if (!is.na(rp) && rp > 8)
        rule(paste0(id, ":r_high_rpe"), "warning", nm,
             format_alert_text("highRpe", rp, NULL, lang),
             rule_key = "highRpe", val = rp)
      if (!is.na(sh) && sh < 5)
        rule(paste0(id, ":r_poor_sleep"), "warning", nm,
             format_alert_text("poorSleep", sh, NULL, lang),
             rule_key = "poorSleep", val = sh)
      if (!is.na(st) && st > 5)
        rule(paste0(id, ":r_high_stress"), "warning", nm,
             format_alert_text("highStress", st, NULL, lang),
             rule_key = "highStress", val = st)
      if (!is.na(hy) && hy < 50)
        rule(paste0(id, ":r_dehydration"), "critical", nm,
             format_alert_text("dehydration", hy, NULL, lang),
             rule_key = "dehydration", val = hy)
      if (!is.na(ov) && ov > 55)
        rule(paste0(id, ":r_overreach"), "critical", nm,
             format_alert_text("overreach", ov, NULL, lang),
             rule_key = "overreach", val = ov)
      if (!is.na(hm) && hm > 60)
        rule(paste0(id, ":r_hamstring_risk"), "warning", nm,
             format_alert_text("hamstringRisk", hm, NULL, lang),
             rule_key = "hamstringRisk", val = hm)
      if (!is.na(ca) && ca > 40)
        rule(paste0(id, ":r_cardiac_risk"), "critical", nm,
             format_alert_text("cardiacRisk", ca, NULL, lang),
             rule_key = "cardiacRisk", val = ca)
      ## ---- v6 clinical rules (kept) ----
      if (!is.na(df$ea[i]) && df$ea[i] < EA_CRITICAL)
        rule(paste0(id, ":ea"), "critical", nm,
             format_alert_text("redsEa", df$ea[i], NULL, lang),
             rule_key = "redsEa", val = df$ea[i])
      if (!is.na(df$acwr[i]) && df$acwr[i] > ACWR_DANGER)
        rule(paste0(id, ":acwr"), "warning", nm,
             format_alert_text("acwrSpike", df$acwr[i], NULL, lang),
             rule_key = "acwrSpike", val = df$acwr[i])
      if (df$training_paused[i])
        rule(paste0(id, ":pause"), "critical", nm,
             format_alert_text("trainingPaused", NULL, NULL, lang),
             rule_key = "trainingPaused")
      if (df$pain_level[i] >= 5)
        rule(paste0(id, ":pain"), "warning", nm,
             format_alert_text("painLabel", df$pain_level[i], df$injury_location[i], lang),
             rule_key = "painLabel", val = df$pain_level[i], extra = df$injury_location[i])
    }
    al
  }

  load_trends_from_sqlite <- function(user_id, days = 42) {
    db <- find_athena_db()
    if (is.null(db) || !requireNamespace("DBI", quietly = TRUE) || !requireNamespace("RSQLite", quietly = TRUE)) return(NULL)
    tryCatch({
      con <- DBI::dbConnect(RSQLite::SQLite(), db)
      on.exit(DBI::dbDisconnect(con), add = TRUE)
      uid_str <- as.character(user_id)
      q <- sprintf(
        "SELECT date, daily_load, rpe, sleep_hours, sleep_quality, stress, fatigue, muscle_soreness, pain_level, calories
         FROM daily_checkins
         WHERE user_id = '%s'
         ORDER BY date DESC LIMIT %d",
        gsub("'", "''", uid_str), as.integer(days)
      )
      df <- DBI::dbGetQuery(con, q)
      if (nrow(df) == 0) return(NULL)
      df <- df[order(df$date), , drop = FALSE]
      n <- nrow(df)
      stg_rem <- numeric(n); stg_deep <- numeric(n); stg_light <- numeric(n); stg_awake <- numeric(n)
      for (i in seq_len(n)) {
        st <- sleep_stages_for(uid_str, df$sleep_quality[i])
        stg_rem[i]   <- safe_lookup(st, "rem") %||% 22
        stg_deep[i]  <- safe_lookup(st, "deep") %||% 20
        stg_light[i] <- safe_lookup(st, "light") %||% 48
        stg_awake[i] <- safe_lookup(st, "awake") %||% 10
      }
      cal <- safe_num(df$calories, 2400)
      dload <- safe_num(df$daily_load, 150)
      data.frame(
        date = as.character(df$date),
        daily_load = dload,
        rpe = safe_num(df$rpe, 4),
        sleep_hours = safe_num(df$sleep_hours, 7.5),
        sleep_quality = safe_num(df$sleep_quality, 5),
        stress = safe_num(df$stress, 3),
        fatigue = safe_num(df$fatigue, 3),
        muscle_soreness = safe_num(df$muscle_soreness, 2),
        pain_level = safe_num(df$pain_level, 0),
        calories = cal,
        heart_rate = round(54 + (dload / 25) + safe_num(df$stress, 3) * 2),
        hrv = round(72 - safe_num(df$fatigue, 3) * 4 - safe_num(df$stress, 3) * 3),
        power = round(180 + dload * 0.8),
        vo2max = round(52 + (dload %% 10) * 0.4, 1),
        hydration_pct = round(75 + safe_num(df$sleep_quality, 5) * 3 - safe_num(df$fatigue, 3) * 2),
        sleep_rem_pct = stg_rem,
        sleep_deep_pct = stg_deep,
        sleep_light_pct = stg_light,
        sleep_awake_pct = stg_awake,
        calories_in = cal,
        calories_out = round(cal + dload * 1.4 - 320),
        stringsAsFactors = FALSE
      )
    }, error = function(e) {
      NULL
    })
  }

  fetch_trends <- function(user_id, days = 42) {
    # Direct SQLite first if present (offline-first, zero latency)
    if (identical(ATH$data_source, "sqlite") || !is.null(find_athena_db())) {
      sql_tr <- load_trends_from_sqlite(user_id, days)
      if (!is.null(sql_tr) && nrow(sql_tr) >= 2) return(sql_tr)
    }
    # If API configured and reachable, try API with rapid 1s timeout
    if (!isTRUE(ATH$breaker_open) && identical(ATH$data_source, "live")) {
      res <- athena_get(paste0("/api/trends/", utils::URLencode(user_id), "?days=", days), timeout = 1, retries = 0)
      if (isTRUE(res$ok)) {
        rows <- jget(res$data, "data", default = NULL)
        if (!is.null(rows) && is.list(rows) && length(rows) > 0) {
          df <- do.call(rbind, lapply(rows, function(r) data.frame(
            date = as.character(jget(r, "date", default = "")),
            daily_load = safe_num(jget(r, "daily_load", default = 0)),
            rpe = safe_num(jget(r, "rpe", default = 0)),
            sleep_hours = safe_num(jget(r, "sleep_hours", default = 0)),
            sleep_quality = safe_num(jget(r, "sleep_quality", default = 0)),
            stress = safe_num(jget(r, "stress", default = 0)),
            fatigue = safe_num(jget(r, "fatigue", default = 0)),
            muscle_soreness = safe_num(jget(r, "muscle_soreness", default = 0)),
            pain_level = safe_num(jget(r, "pain_level", default = 0)),
            calories = safe_num(jget(r, "calories", default = 0)),
            heart_rate = safe_num(jget(r, "heart_rate", default = NA_real_), NA_real_),
            hrv = safe_num(jget(r, "hrv", default = NA_real_), NA_real_),
            power = safe_num(jget(r, "power", default = NA_real_), NA_real_),
            vo2max = safe_num(jget(r, "vo2max", default = NA_real_), NA_real_),
            hydration_pct = safe_num(jget(r, "hydration_pct", default = NA_real_), NA_real_),
            sleep_rem_pct = safe_num(jget(r, "sleep_rem_pct", default = NA_real_), NA_real_),
            sleep_deep_pct = safe_num(jget(r, "sleep_deep_pct", default = NA_real_), NA_real_),
            sleep_light_pct = safe_num(jget(r, "sleep_light_pct", default = NA_real_), NA_real_),
            sleep_awake_pct = safe_num(jget(r, "sleep_awake_pct", default = NA_real_), NA_real_),
            calories_in = safe_num(jget(r, "calories_in", default = NA_real_), NA_real_),
            calories_out = safe_num(jget(r, "calories_out", default = NA_real_), NA_real_),
            stringsAsFactors = FALSE)))
          if (!is.null(df) && nrow(df) >= 2) return(df)
        }
      }
    }
    # Deterministic fallback based on athlete index (guarantees non-empty trends)
    df_ath <- isolate(RV$athletes)
    idx <- if (!is.null(df_ath)) which(df_ath$user_id == user_id)[1] else 1L
    if (is.na(idx) || idx < 1) idx <- 1L
    demo_trend_for(idx)
  }

  load_all <- function(manual = FALSE) {
    curr_trends   <- tryCatch(isolate(RV$trends),   error = function(e) list())
    curr_athletes <- tryCatch(isolate(RV$athletes), error = function(e) NULL)
    wasDemo <- ATH$demo_mode

    # Offline-first: if local SQLite DB exists, load it immediately with 0ms network lag
    sqlite_df <- load_roster_from_sqlite()
    if (!is.null(sqlite_df) && nrow(sqlite_df) > 0) {
      RV$athletes <- derive_roster(sqlite_df, curr_trends)
      RV$lastSync <- Sys.time()
      ATH$demo_mode <- FALSE
      ATH$data_source <- "sqlite"
      if (wasDemo || isTRUE(manual)) {
        notify("info", "ATHENA: SQLite Database Connected",
               paste("Direct connection active · Loaded", nrow(sqlite_df), "athletes from local SQLite"))
      }
      js_run("flashConn('sqlite')")
    } else {
      # Try remote API if SQLite DB is absent
      res <- athena_get("/api/roster/all", timeout = 2, retries = 0)
      if (isTRUE(res$ok) && !is.null(jget(res$data, "athletes"))) {
        df <- normalize_athletes(jget(res$data, "athletes", default = list()))
        if (!is.null(df)) {
          RV$athletes <- derive_roster(df, curr_trends)
          RV$lastSync <- Sys.time()
          ATH$demo_mode <- FALSE
          ATH$data_source <- "live"
          if (wasDemo) { notify("success", T("recovered")); js_run("flashConn('live')") }
        }
      } else {
        ATH$demo_mode <- TRUE
        ATH$data_source <- "demo"
        if (is.null(curr_athletes)) {
          RV$athletes <- derive_roster(demo_roster(), demo_trends(sprintf("ATH-%03d", seq_len(DEMO_ATHLETES))))
          RV$trends   <- demo_trends(RV$athletes$user_id)
          RV$lastSync <- Sys.time()
        } else {
          RV$lastSync <- Sys.time()
        }
        js_run("flashConn('demo')")
      }
    }
    ## system probes (offline-first: real system metrics on Linux without network delay)
    if (identical(ATH$data_source, "live")) {
      hres <- athena_get("/api/system/health", timeout = 1, retries = 0)
      if (isTRUE(hres$ok)) {
        RV$health <- list(cpu = safe_num(jget(hres$data, "cpu_percent", default = 0)),
                          mem = safe_num(jget(hres$data, "memory_percent", default = 0)),
                          disk = safe_num(jget(hres$data, "disk_percent", default = 0)))
      }
    }
    if (is.null(RV$health)) {
      # Read real Linux load if available
      cpu_val <- tryCatch({
        if (file.exists("/proc/loadavg")) {
          la <- suppressWarnings(as.numeric(strsplit(readLines("/proc/loadavg", n = 1, warn = FALSE), " ")[[1]][1]))
          round(min(100, max(5, la * 20)))
        } else round(22 + 18 * sin(as.numeric(Sys.time()) %% 3600))
      }, error = function(e) 25)
      RV$health <- list(cpu = cpu_val, mem = 47, disk = 63)
    }
    if (identical(ATH$data_source, "live")) {
      mres <- athena_get("/api/system/ml-status", timeout = 1, retries = 0)
      if (isTRUE(mres$ok)) {
        RV$thermal <- jget(mres$data, "thermal_status", default = NULL)
        RV$mlstat  <- jget(mres$data, "ml_status", default = NULL)
      }
    }
    if (is.null(RV$thermal)) {
      # Read real Linux CPU thermal zone if available
      t0 <- tryCatch({
        t_file <- "/sys/class/thermal/thermal_zone0/temp"
        if (file.exists(t_file)) {
          raw_t <- suppressWarnings(as.numeric(readLines(t_file, n = 1, warn = FALSE)))
          if (!is.na(raw_t) && raw_t > 0) round(raw_t / 1000, 1) else 52.0
        } else 52.0
      }, error = function(e) 52.0)
      RV$thermal <- list(cpu_temperature_c = t0,
                         operating_mode = if (t0 > 85) "minimal" else if (t0 > 75) "reduced" else if (t0 > 65) "standard" else "full",
                         power_source = "AC")
      RV$mlstat <- list(ml_status = list(r_engine_enabled = TRUE, cdss_rules_enabled = TRUE,
                                         sqlite_storage = TRUE, fastapi_core = identical(ATH$data_source, "live"),
                                         batch_size = 200, max_concurrent_users = 20, operating_mode = "standard"),
                        source = if (identical(ATH$data_source, "sqlite")) "sqlite_offline" else "synthetic")
    }
    tval <- suppressWarnings(as.numeric(jget(isolate(RV$thermal), "cpu_temperature_c", default = NA)))
    if (!is.na(tval)) {
      curr_th <- tryCatch(isolate(RV$thermalHist), error = function(e) numeric(0))
      RV$thermalHist <- tail(c(curr_th, tval), THERMAL_HIST_MAX)
    }
    if (manual) notify("success", paste(T("updated"), "·", T("sync")))
    curr_act <- tryCatch(isolate(RV$active), error = function(e) NULL)
    curr_ath <- tryCatch(isolate(RV$athletes), error = function(e) NULL)
    if ((is.null(curr_act) || !curr_act %in% curr_ath$user_id) && !is.null(curr_ath) && nrow(curr_ath) > 0) {
      RV$active <- curr_ath$user_id[1]
    }
    # Pre-select comparison athletes (matches user's screenshot: ATH-002, GEN_2780, GEN_9892, ATH_32379)
    curr_cmp <- tryCatch(isolate(RV$compare), error = function(e) character(0))
    if (length(curr_cmp) < 2 && !is.null(curr_ath) && nrow(curr_ath) >= 4) {
      preferred <- c("ATH-002", "GEN_2780", "GEN_9892", "ATH_32379")
      matches <- preferred[preferred %in% curr_ath$user_id]
      RV$compare <- if (length(matches) >= 2) matches else head(curr_ath$user_id, 4)
      curr_tr <- isolate(RV$trends) %||% list()
      for (cid in RV$compare) {
        if (is.null(curr_tr[[cid]])) curr_tr[[cid]] <- fetch_trends(cid)
      }
      RV$trends <- curr_tr
    }
    ensure_trends_loaded()
  }

  observeEvent(input$forceRefresh, load_all(manual = TRUE))
  observeEvent(input$syncBtn, load_all(manual = TRUE))
  observeEvent(input$simToggle, {
    RV$simOn <- !isTRUE(RV$simOn)
    notify("info", paste(T("liveSim"), if (RV$simOn) T("on") else T("off")))
  })

  ## auto-refresh poller with visibility gating and configurable interval
  observe({
    raw_s <- input$setRefresh
    secs <- if (is.null(raw_s) || !nzchar(as.character(raw_s))) 30L else suppressWarnings(as.integer(raw_s))
    if (length(secs) == 0 || is.na(secs) || secs <= 0) secs <- 30L
    if (isTRUE(isolate(RV$visible))) invalidateLater(max(5, secs) * 1000) else invalidateLater(10000)
    isolate({ load_all() })
  })

  observeEvent(input$tabVisible, { RV$visible <- isTRUE(input$tabVisible) })

  ## live simulation jitter (v7: nudges the full biometric set, not just load)
  observe({
    if (!isTRUE(RV$simOn)) { invalidateLater(2000); return() }
    invalidateLater(1500)
    df <- RV$athletes
    if (!is.null(df) && nrow(df) > 0) {
      idx <- sample(seq_len(nrow(df)), 1)
      df$daily_load[idx] <- max(0, df$daily_load[idx] + round(runif(1, -30, 45)))
      df$readiness[idx]  <- clamp(df$readiness[idx] + round(runif(1, -2, 2)), 0, 100)
      ## v7 biometric jitter (clamped to physiological ranges)
      df$heart_rate[idx] <- clamp(df$heart_rate[idx] + round(runif(1, -3, 4)), 40, 200)
      df$hrv[idx]        <- clamp(df$hrv[idx] + round(runif(1, -3, 3)), 10, 120)
      df$power[idx]      <- clamp(df$power[idx] + round(runif(1, -15, 18)), 80, 500)
      df$lactate[idx]    <- clamp(df$lactate[idx] + runif(1, -0.25, 0.3), 0.5, 12)
      df$core_temp[idx]  <- clamp(df$core_temp[idx] + runif(1, -0.08, 0.09), 35.5, 39.5)
      df$spo2[idx]       <- clamp(df$spo2[idx] + round(runif(1, -1, 1)), 88, 100)
      df$resp_rate[idx]  <- clamp(df$resp_rate[idx] + round(runif(1, -1, 1)), 8, 30)
      df$cadence[idx]    <- clamp(df$cadence[idx] + round(runif(1, -3, 3)), 50, 130)
      df$torque[idx]     <- clamp(df$torque[idx] + round(runif(1, -4, 4)), 30, 160)
      df$rsi[idx]        <- clamp(round(df$rsi[idx] + runif(1, -0.12, 0.13), 2), 0.8, 5)
      df$gct[idx]        <- clamp(df$gct[idx] + round(runif(1, -5, 5)), 120, 300)
      RV$athletes <- df
      log_event("var(--magenta)", paste("SIM jitter \u2192", df$name[idx]))
    }
  })

  ## ---------- active athlete ----------
  active_row <- reactive({
    df <- RV$athletes
    if (is.null(df) || nrow(df) == 0) return(NULL)
    id <- RV$active
    if (is.null(id) || !nzchar(id)) id <- df$user_id[1]
    m <- which(df$user_id == id)
    if (length(m) == 0) return(df[1, , drop = FALSE])
    df[m[1], , drop = FALSE]
  })

  active_trend <- reactive({
    row <- active_row()
    if (is.null(row) || nrow(row) == 0) return(NULL)
    id <- as.character(row$user_id[1])
    tr <- isolate(RV$trends[[id]])
    if (!is.null(tr) && nrow(tr) >= 2) return(tr)
    tr <- fetch_trends(id)
    if (!is.null(tr) && nrow(tr) >= 2) {
      RV$trends[[id]] <- tr
      return(tr)
    }
    aidx <- which(RV$athletes$user_id == id)[1]
    if (is.na(aidx)) aidx <- 1L
    tr <- demo_trend_for(aidx)
    RV$trends[[id]] <- tr
    tr
  })

  ## ---------- zero-dep SVG chart builders (fallback when plotly absent) ----------
  svg_line <- function(values, color = "#00E5FF", w = 560, h = 170, labels = NULL, ylab = "") {
    v <- safe_num(values, NA_real_)
    ok <- !is.na(v); v2 <- v[ok]
    if (length(v2) < 2) return(paste0('<div class="empty-hint">', tr_raw(rvLang(), "stool"), '</div>'))
    rng <- range(v2, na.rm = TRUE); if (diff(rng) == 0) rng[2] <- rng[1] + 1
    n <- length(v)
    xs <- seq(6, w - 6, length.out = n)
    ys <- (h - 22) - ((v - rng[1]) / diff(rng)) * (h - 44)
    pts <- paste0(sprintf("%.1f,%.1f", xs[ok], ys[ok]), collapse = " ")
    grid <- paste0(sprintf('<line x1="0" y1="%.0f" x2="%d" y2="%.0f" stroke="rgba(128,128,128,.14)"/>',
                           seq(h - 22, 20, length.out = 4), w, seq(h - 22, 20, length.out = 4)), collapse = "")
    paste0('<svg width="100%" viewBox="0 0 ', w, ' ', h, '" style="max-height:', h, 'px" role="img" aria-label="', ylab, '">',
           grid,
           '<polyline points="', pts, '" fill="none" stroke="', color, '" stroke-width="2.2" stroke-linejoin="round"/>',
           '</svg>')
  }

  svg_bars <- function(values, colors = NULL, w = 560, h = 150, labels = NULL) {
    v <- safe_num(values, 0)
    if (length(v) == 0) return(paste0('<div class="empty-hint">', tr_raw(rvLang(), "stool"), '</div>'))
    n <- length(v)
    if (is.null(colors)) colors <- rep("#00E5FF", n)
    bw <- (w - 8) / n
    vmax <- max(v, 1e-9)
    paste0('<svg width="100%" viewBox="0 0 ', w, ' ', h, '" style="max-height:', h, 'px;max-width:', w, 'px;display:block;margin:0 auto;" role="img">',
           paste0(vapply(seq_len(n), function(i) {
             bh <- max(2, (v[i] / vmax) * (h - 18))
             sprintf('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="2.5" fill="%s" opacity=".88"/>',
                     4 + (i - 1) * bw, h - 14 - bh, bw - 3, bh, colors[i])
           }, character(1)), collapse = ""), '</svg>')
  }

  svg_radar <- function(axis_vals, axis_labels, w = 340, h = 300, color = "#00E5FF") {
    k <- length(axis_vals)
    if (k < 3) return(paste0('<div class="empty-hint">', tr_raw(rvLang(), "stool"), '</div>'))
    cx <- w / 2; cy <- h / 2 + 6; R <- min(cx, cy) - 34
    ang <- function(i) -pi / 2 + 2 * pi * (i - 1) / k
    rings <- paste0(vapply(c(0.25, 0.5, 0.75, 1), function(f) {
      i2 <- seq_len(k)
      ps <- paste0(sprintf("%.1f,%.1f", cx + R * f * cos(ang(i2)), cy + R * f * sin(ang(i2))), collapse = " ")
      sprintf('<polygon points="%s" fill="none" stroke="rgba(128,128,128,.18)"/>', ps)
    }, character(1)), collapse = "")
    axes <- paste0(vapply(seq_len(k), function(i) sprintf(
      '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="rgba(128,128,128,.18)"/>',
      cx, cy, cx + R * cos(ang(i)), cy + R * sin(ang(i))), character(1)), collapse = "")
    vv <- clamp(safe_num(axis_vals, 0) / 100, 0, 1)
    poly <- paste0(sprintf("%.1f,%.1f", cx + R * vv * cos(ang(seq_len(k))), cy + R * vv * sin(ang(seq_len(k)))), collapse = " ")
    labs <- paste0(vapply(seq_len(k), function(i) sprintf(
      '<text x="%.1f" y="%.1f" text-anchor="middle" font-size="8.5" fill="currentColor" opacity=".75">%s</text>',
      cx + (R + 16) * cos(ang(i)), cy + (R + 16) * sin(ang(i)) + 3, axis_labels[i]), character(1)), collapse = "")
    paste0('<svg width="100%" viewBox="0 0 ', w, ' ', h, '" style="max-height:300px" role="img">',
           rings, axes,
           paste0('<polygon points="', poly, '" fill="', color, '22" stroke="', color, '" stroke-width="1.8"/>'),
           labs, '</svg>')
  }

  plot_or_svg <- function(out_id, widget, svg_html, height = 250) {
    if (CAP$plotly && !is.null(widget)) {
      tagList(plotly::plotlyOutput(out_id, height = paste0(height, "px")))
    } else {
      HTML(svg_html)
    }
  }

  athena_plotly <- function(p, thm = "dark") {
    font_col <- if (thm == "light") "#0F172A" else "#9AA0A6"
    grid_col <- if (thm == "light") "rgba(15,23,42,0.10)" else "rgba(128,128,128,0.15)"
    p |>
      plotly::layout(
        paper_bgcolor = "rgba(0,0,0,0)",
        plot_bgcolor = "rgba(0,0,0,0)",
        font = list(color = font_col, size = 10),
        xaxis = list(gridcolor = grid_col),
        yaxis = list(gridcolor = grid_col)
      ) |>
      plotly::config(
        displayModeBar = TRUE,
        modeBarButtonsToAdd = list("zoomIn2d", "zoomOut2d", "autoScale2d", "resetViews"),
        modeBarButtonsToRemove = list("lasso2d", "select2d", "hoverClosestCartesian", "hoverCompareCartesian"),
        displaylogo = FALSE
      )
  }

  ## ---------- v7 zero-dep multi-series / clinical SVG builders ----------
  # Generate a deterministic backwards series that ends at `current`.
  gen_back <- function(current, n, step_mu, step_sd, lo, hi, digits = 0) {
    v <- numeric(max(2, n)); v[length(v)] <- safe_num(current, (lo + hi) / 2)
    if (length(v) > 1) for (i in (length(v) - 1):1) v[i] <- clamp(v[i + 1] - rnorm(1, step_mu, step_sd), lo, hi)
    round(v, digits)
  }

  # Multi-series line chart with optional phase-shading bands and legend.
  svg_lines_multi <- function(series, colors, w = 560, h = 210, weeks = NULL,
                              shades = NULL, ylab = "") {
    lens <- vapply(series, length, integer(1)); n <- max(lens)
    allv <- unlist(series); allv <- allv[!is.na(allv)]
    if (length(allv) < 2 || n < 2) return(paste0('<div class="empty-hint">', tr_raw(rvLang(), "stool"), '</div>'))
    rng <- range(allv)
    if (diff(rng) < 1e-9) rng[2] <- rng[1] + 1
    pad <- diff(rng) * 0.1; rng <- c(rng[1] - pad, rng[2] + pad)
    xf <- function(i) 30 + (i - 1) / (n - 1) * (w - 40)
    yf <- function(v) (h - 26) - ((v - rng[1]) / diff(rng)) * (h - 50)
    parts <- ""
    if (!is.null(shades)) for (s in shades) {
      x0 <- xf(max(1, s$from)); x1 <- xf(min(n, s$to))
      parts <- paste0(parts, sprintf('<rect x="%.1f" y="10" width="%.1f" height="%.0f" fill="%s" opacity=".16"/>',
                                     x0, max(2, x1 - x0), h - 36, s$color))
    }
    parts <- paste0(parts, paste0(sprintf('<line x1="30" y1="%.0f" x2="%d" y2="%.0f" stroke="rgba(128,128,128,.13)"/>',
                                          yf(seq(rng[1], rng[2], length.out = 4)), w - 10, yf(seq(rng[1], rng[2], length.out = 4))), collapse = ""))
    if (!is.null(weeks)) {
      ticks <- unique(pmin(weeks, n)); ticks <- sort(ticks[seq(1, length(ticks), length.out = min(5, length(ticks)))])
      parts <- paste0(parts, paste0(vapply(ticks, function(tk) sprintf(
        '<text x="%.1f" y="%d" text-anchor="middle" font-size="8" fill="currentColor" opacity=".55">%s</text>',
        xf(tk), h - 8, as.character(tk)), character(1)), collapse = ""))
    }
    for (k in seq_along(series)) {
      v <- series[[k]]; idx <- which(!is.na(v))
      if (length(idx) < 2) next
      pts <- paste0(sprintf("%.1f,%.1f", xf(idx), yf(v[idx])), collapse = " ")
      parts <- paste0(parts, '<polyline points="', pts, '" fill="none" stroke="', colors[k],
                      '" stroke-width="2.1" stroke-linejoin="round" opacity=".92"/>')
    }
    leg <- paste0(vapply(seq_along(series), function(k) sprintf(
      '<rect x="%d" y="%d" width="8" height="3" fill="%s"/><text x="%d" y="%d" font-size="8" fill="currentColor" opacity=".7">%s</text>',
      32 + (k - 1) * 150, 14, colors[k], 44 + (k - 1) * 150, 17, names(series)[k]), character(1)), collapse = "")
    paste0('<svg width="100%" viewBox="0 0 ', w, ' ', h, '" style="max-height:', h, 'px" role="img" aria-label="', ylab, '">',
           parts, leg, '</svg>')
  }

  # Lactate-step curve with LT1 (~2 mmol) and LT2 (deflection, >=4 mmol) markers.
  svg_lactate_curve <- function(power, lac, lt1_p, lt2_p, w = 560, h = 220, lang = "en") {
    ok <- !is.na(power) & !is.na(lac)
    power <- power[ok]; lac <- lac[ok]
    if (length(power) < 3) return(paste0('<div class="empty-hint">', tr_raw(lang, "stool"), '</div>'))
    xmax <- max(power) * 1.04; ymax <- max(6, max(lac) * 1.15)
    xf <- function(p) 34 + p / xmax * (w - 48)
    yf <- function(l) (h - 26) - l / ymax * (h - 46)
    pts <- paste0(sprintf("%.1f,%.1f", xf(power), yf(lac)), collapse = " ")
    grid <- paste0(sprintf('<line x1="34" y1="%.0f" x2="%d" y2="%.0f" stroke="rgba(128,128,128,.12)"/>',
                           yf(seq(0, ymax, length.out = 5)), w - 14, yf(seq(0, ymax, length.out = 5))), collapse = "")
    marker <- function(p, col, lab) {
      if (is.na(p)) return("")
      paste0(
        sprintf('<line x1="%.1f" y1="12" x2="%.1f" y2="%d" stroke="%s" stroke-dasharray="3,3" stroke-width="1.2" opacity=".8"/>',
                xf(p), xf(p), h - 26, col),
        sprintf('<circle cx="%.1f" cy="%.1f" r="4" fill="%s"/>', xf(p), yf(if (col == "#00FF88") 2 else 4), col),
        sprintf('<text x="%.1f" y="10" text-anchor="middle" font-size="9" font-weight="800" fill="%s">%s</text>', xf(p), col, lab))
    }
    hline <- function(lmol, col) sprintf(
      '<line x1="34" y1="%.1f" x2="%d" y2="%.1f" stroke="%s" stroke-width="1" stroke-dasharray="2,4" opacity=".55"/>',
      yf(lmol), w - 14, yf(lmol), col)
    paste0('<svg width="100%" viewBox="0 0 ', w, ' ', h, '" style="max-height:230px" role="img" aria-label="lactate">',
           grid,
           hline(2, "#00FF88"), hline(4, "#FFAA00"),
           '<polyline points="', pts, '" fill="none" stroke="#E91E63" stroke-width="2.4" stroke-linejoin="round"/>',
           paste0(marker(lt1_p, "#00FF88", "LT1"), marker(lt2_p, "#FFAA00", "LT2")),
           paste0(vapply(seq(0, ymax, length.out = 5), function(l) sprintf(
             '<text x="4" y="%.1f" font-size="8" fill="currentColor" opacity=".55">%s</text>',
             yf(l) + 3, fmt_num(l, 1, lang)), character(1)), collapse = ""),
           '</svg>')
  }

  # Nightly hypnogram: deterministic stage sequence across the sleep window.
  hypno_stages_for <- function(uid, hours, nbins = 48) {
    set.seed(det_hash(paste0(uid, "|hypno|", as.integer(Sys.Date()))))
    stg <- sleep_stages_for(uid, 4)
    ## stage codes: 0 awake, 1 light, 2 deep, 3 rem — Markov walk with persistence
    probs <- c(awake = clamp((safe_lookup(stg, "awake") %||% 10) / 100 * 3, 0.02, 0.2),
               light = (safe_lookup(stg, "light") %||% 48) / 100,
               deep  = (safe_lookup(stg, "deep")  %||% 20) / 100,
               rem   = (safe_lookup(stg, "rem")   %||% 22) / 100)
    stay <- 0.72
    cur <- 1L
    out <- integer(nbins)
    for (b in seq_len(nbins)) {
      if (runif(1) > stay) {
        p <- probs[c("awake", "light", "deep", "rem")]
        p[cur + 1] <- p[cur + 1] * 0.35        # discourage repeating the same bin
        ## deep more likely early, rem more likely late
        p["deep"] <- p["deep"] * (1.6 - b / nbins)
        p["rem"]  <- p["rem"] * (0.6 + 1.4 * b / nbins)
        p <- p / sum(p)
        cur <- sample(0:3, 1, prob = as.numeric(p))
      }
      out[b] <- cur
    }
    list(stages = out, hours = clamp(safe_num(hours, 7.5), 3, 12))
  }

  svg_hypnogram <- function(st, w = 560, h = 130, lang = "en") {
    s <- st$stages; nb <- length(s)
    if (nb < 4) return(paste0('<div class="empty-hint">', tr_raw(lang, "stool"), '</div>'))
    row_of <- c(0, 2, 3, 1)   # awake, light, deep, rem -> rows top..bottom (REM above light)
    col_of <- c("#FFAA00", "#00E5FF", "#9D4EDD", "#E91E63")
    rows <- row_of[s + 1]; cols <- col_of[s + 1]
    yf <- function(r) 12 + r * ((h - 34) / 3)
    xf <- function(i) 6 + (i - 1) / (nb - 1) * (w - 14)
    segs <- paste0(vapply(2:nb, function(i) sprintf(
      '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-width="2" stroke-linecap="round"/>',
      xf(i - 1), yf(rows[i - 1]), xf(i), yf(rows[i]), cols[i]), character(1)), collapse = "")
    dots <- paste0(vapply(seq_len(nb), function(i) sprintf(
      '<circle cx="%.1f" cy="%.1f" r="1.6" fill="%s" opacity=".85"/>',
      xf(i), yf(rows[i]), cols[i]), character(1)), collapse = "")
    labs <- c("stageAwake", "stageLight", "stageDeep", "stageREM")   # matches col_of order (by stage code)
    legend <- paste0(vapply(seq_along(col_of), function(i) sprintf(
      '<span class="hl-item"><span class="hl-swatch" style="background:%s"></span><span data-k="%s">%s</span></span>',
      col_of[i], labs[i], tr_raw(lang, labs[i])), character(1)), collapse = "")
    paste0('<svg width="100%" viewBox="0 0 ', w, ' ', h, '" style="max-height:140px" role="img" aria-label="hypnogram">',
           segs, dots, '</svg>',
           '<div class="hypno-legend">', legend, '</div>')
  }

  ## ---------- header outputs ----------
  output$connStatus <- renderUI({
    src <- ATH$data_source %||% (if (isTRUE(ATH$demo_mode)) "demo" else "live")
    dot_cls <- if (src == "live") "live" else if (src == "sqlite") "sqlite" else ""
    span(class = "conn-wrap",
         span(class = paste("conn-dot", dot_cls)),
         span(class = "conn-label", conn_label(rvLang())))
  })
  output$footerMode <- renderUI({
    src <- ATH$data_source %||% (if (isTRUE(ATH$demo_mode)) "demo" else "live")
    lbl <- if (src == "live") T("connected") else if (src == "sqlite") T("sqliteOffline") else T("bannerDemo")
    span(class = "footer-dim",
         paste(lbl,
               if (!is.null(RV$lastSync)) paste0("· ", T("updated"), " ", time_ago(RV$lastSync, rvLang())) else ""))
  })
  output$footerTz <- renderText(safe_html(rvLang(), Sys.timezone() %||% "UTC"))

  output$notifBadge <- renderUI({
    n <- length(RV$notifications)
    if (n == 0) return(NULL)
    span(style = "position:absolute;top:-6px;right:-6px;background:var(--red);color:#fff;font-size:8.5px;font-weight:900;border-radius:999px;padding:1px 5px;", fn(n))
  })

  ## quick stats bar
  qb_from_roster <- reactive({
    df <- RV$athletes
    if (is.null(df) || nrow(df) == 0) return(list(r = NA, l = NA, risk = NA, reds = NA))
    list(r = mean(df$readiness, na.rm = TRUE),
         l = mean(df$daily_load, na.rm = TRUE),
         risk = sum(df$status == "red", na.rm = TRUE),
         reds = sum(df$training_paused, na.rm = TRUE))
  })
  output$qbReadiness <- renderText(fn(qb_from_roster()$r, 1))
  output$qbLoad <- renderText(fn(qb_from_roster()$l, 0))
  output$qbAtRisk <- renderText(fn(qb_from_roster()$risk, 0))
  output$qbReds <- renderText(fn(qb_from_roster()$reds, 0))
  output$qbConn <- renderText(if (isTRUE(ATH$demo_mode)) T("bannerDemo") else T("connected"))
  output$qbLatency <- renderText({
    if (!is.na(ATH$latency_ms)) paste0(round(ATH$latency_ms), "ms") else "—"
  })
  output$qbAthletes <- renderText({
    df <- RV$athletes; if (is.null(df)) 0 else nrow(df)
  })

  ## ticker (duplicated track for seamless marquee)
  output$tickerContent <- renderUI({
    safe_html(rvLang(), {
      cur_lg <- rvLang()
      al <- RV$alerts
      unacked <- Filter(function(x) !x$id %in% RV$acked, al)
      items <- character(0)
      if (length(unacked) > 0) {
        items <- vapply(head(unacked, 12), function(x) {
          col <- switch(x$severity, critical = "var(--red)", warning = "var(--amber)", "var(--cyan)")
          ath_nm <- format_athlete_name(x$athlete, cur_lg)
          txt <- if (!is.null(x$rule_key)) format_alert_text(x$rule_key, x$val, x$extra, cur_lg) else x$text
          al_str <- paste0("\u26A0 ", tr_raw(cur_lg, "alert"), ": ", ath_nm, " \u2014 ", txt)
          paste0('<span class="tk-item" style="color:', col, '">',
                 htmltools::htmlEscape(substr(al_str, 1, 95)), '</span>')
        }, character(1))
      }
      if (length(items) == 0) {
        ev <- RV$events
        if (length(ev) == 0) {
          ev <- list(list(ts = Sys.time(), color = "var(--cyan)",
                          text = paste(T("appTitle"), T("statusOnline"))))
        }
        items <- vapply(rev(ev), function(e) {
          disp_text <- e$text
          if (!is.null(e$rule_key)) {
            ath_nm <- format_athlete_name(e$athlete, cur_lg)
            al_desc <- format_alert_text(e$rule_key, e$val, e$extra, cur_lg)
            disp_text <- paste0("\u26A0 ", tr_raw(cur_lg, "alert"), ": ", ath_nm, " \u2014 ", al_desc)
          }
          paste0('<span class="tk-item" style="color:', e$color, '">',
                 htmltools::htmlEscape(substr(disp_text, 1, 95)), '</span>')
        }, character(1))
      }
      one <- paste(items, collapse = "")
      HTML(paste0(one, one))
    })
  })

  ## notification dropdown
  observeEvent(input$notifBtn, { RV$notifOpen <- !isTRUE(RV$notifOpen) })
  output$notifPanel <- renderUI({
    safe_html(rvLang(), {
      if (!isTRUE(RV$notifOpen)) return(NULL)
      items <- lapply(head(RV$notifications, 12), function(nt) {
        col <- switch(nt$type, error = "var(--red)", warn = "var(--amber)", success = "var(--green)", "var(--cyan)")
        div(class = "ev-row",
            span(class = "ev-dot", style = paste0("background:", col)),
            span(style = "flex:1;font-size:10.5px;", htmltools::htmlEscape(nt$title)),
            span(class = "ev-time", time_ago(nt$ts, rvLang())))
      })
      div(style = "position:fixed;top:64px;right:16px;z-index:10045;width:290px;background:var(--card);border:1px solid var(--border);border-radius:14px;padding:12px;box-shadow:0 14px 44px rgba(0,0,0,.5);",
          div(style = "display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;",
              span(class = "mini-label", T("notifications")),
              actionButton("notifClear", T("markAllRead"), class = "athena-btn small")),
          if (length(items) == 0) div(class = "empty-hint", T("noNotifications")) else div(class = "event-list", items))
    })
  })
  observeEvent(input$notifClear, { RV$notifications <- list(); RV$notifOpen <- FALSE })
  hud_athlete <- reactive({
    row <- active_row()
    if (is.null(row) || is.null(RV$athletes) || nrow(RV$athletes) == 0) return(NULL)
    if (isTRUE(RV$simOn)) {
      row$heart_rate <- round(62 + (100 - safe_num(row$readiness[1], 50)) * 1.1 + runif(1, -4, 6))
      row$power      <- round(180 + row$daily_load[1] / 6 + runif(1, -20, 30))
      row$vo2max     <- round(clamp(52 + row$readiness[1] / 4 + runif(1, -2, 2), 35, 85), 1)
    } else {
      if (is.na(row$heart_rate[1])) row$heart_rate <- round(58 + row$daily_load[1] / 22)
      if (is.na(row$power[1]))      row$power      <- round(220 + row$daily_load[1] / 5)
      if (is.na(row$vo2max[1]))     row$vo2max     <- round(clamp(50 + row$readiness[1] / 3.4, 38, 78), 1)
    }
    row
  })

  output$hudVo2 <- renderText({
    a <- hud_athlete(); if (is.null(a)) "—" else if (is.na(a$vo2max[1])) "—" else fn(a$vo2max[1], 1)
  })
  output$hudVo2Sub <- renderText({
    a <- hud_athlete()
    if (is.null(a) || is.na(a$vo2max[1])) T("stool") else paste0(T("demo" ), " · ", fn(clamp(a$vo2max[1] / 80 * 100, 0, 100), 0), "th pct")
  })
  output$hudVo2Ring <- renderUI(HTML(ring_svg(safe_num(hud_athlete()$vo2max %||% NA, 0) * 1.4, 100, "#00E5FF", 44, 5)))
  output$hudHr <- renderText({
    a <- hud_athlete(); if (is.null(a) || is.na(a$heart_rate[1])) "—" else fn(a$heart_rate[1], 0)
  })
  output$hudHrSub <- renderText({
    a <- hud_athlete()
    if (is.null(a) || is.na(a$heart_rate[1])) T("stool") else paste0(T("live"), " · ", a$name[1])
  })
  output$hudPower <- renderText({
    a <- hud_athlete(); if (is.null(a) || is.na(a$power[1])) "—" else fn(a$power[1], 0)
  })
  output$hudPowerSub <- renderText({
    a <- hud_athlete()
    if (is.null(a) || is.na(a$power[1])) T("stool") else paste0(T("load"), " ", fn(a$daily_load[1], 0), " AU")
  })
  output$hudReady <- renderText({
    a <- hud_athlete(); if (is.null(a)) "—" else fn(a$readiness[1], 0)
  })
  output$hudReadySub <- renderText({
    a <- hud_athlete()
    if (is.null(a)) T("stool") else switch(status_from_readiness(a$readiness[1]),
                                           green = T("filterGreen"), amber = T("filterAmber"), red = T("filterRed"))
  })
  output$hudReadyRing <- renderUI({
    a <- hud_athlete()
    col <- if (is.null(a)) "#9AA0A6" else status_color(status_from_readiness(a$readiness[1]))
    HTML(ring_svg(safe_num(a$readiness %||% 0, 0), 100, col, 44, 5))
  })

  ## ---------- readiness chart ----------
  readiness_series_data <- reactive({
    tr <- active_trend()
    row <- active_row()
    if (!is.null(tr) && nrow(tr) >= 2) {
      rr <- readiness_score(tr$sleep_hours, tr$sleep_quality, tr$stress, tr$fatigue,
                            tr$muscle_soreness, tr$pain_level)
      list(vals = rr, labels = substr(tr$date, 6, 10))
    } else if (!is.null(row)) {
      list(vals = c(row$readiness[1], row$readiness[1]), labels = c("", ""))
    } else NULL
  })
  output$readinessChartWrap <- renderUI({
    safe_html(rvLang(), {
      d <- readiness_series_data()
      need_msg(d, T("stool"))
      wg <- NULL
      if (CAP$plotly && length(d$vals) >= 2) {
        wg <- tryCatch(
          plotly::plot_ly(x = seq_along(d$vals), y = d$vals, type = "scatter", mode = "lines+markers",
                          line = list(color = "#00E5FF", width = 3), marker = list(size = 5),
                          name = T("readiness")) |>
            plotly::layout(paper_bgcolor = "rgba(0,0,0,0)", plot_bgcolor = "rgba(0,0,0,0)",
                           font = list(color = "#9AA0A6", size = 10),
                           xaxis = list(title = "", gridcolor = "rgba(128,128,128,.15)", tickvals = NULL),
                           yaxis = list(title = "", range = c(0, 100), gridcolor = "rgba(128,128,128,.15)"),
                           showlegend = FALSE, margin = list(l = 28, r = 8, t = 6, b = 22)),
          error = function(e) NULL)
      }
      plot_or_svg("chReadiness", wg, svg_line(d$vals, "#00E5FF", labels = d$labels))
    })
  })
  output$chReadiness <- if (CAP$plotly) renderPlotly({
    d <- readiness_series_data(); req(d)
    thm <- RV$theme %||% input$uiTheme %||% "dark"
    p <- plotly::plot_ly(x = seq_along(d$vals), y = d$vals, type = "scatter", mode = "lines+markers",
                    line = list(color = "#00E5FF", width = 3), name = T("readiness")) |>
      plotly::layout(yaxis = list(range = c(0, 100)), showlegend = FALSE, margin = list(l = 28, r = 8, t = 6, b = 22))
    athena_plotly(p, thm)
  })

  ## ---------- Clinical decision support (CDSS) ----------
  output$aiRecsBox <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      recs <- ai_recommendations(list(
        readiness = a$readiness[1], ea = a$ea[1], acwr = a$acwr[1], monotony = a$monotony[1],
        fatigue = a$fatigue[1], sleep_hours = a$sleep_hours[1], stress = a$stress[1],
        soreness = a$muscle_soreness[1]
      ), rvLang())
      div(class = "rec-list", lapply(recs, function(r) div(class = "rec-item", r)))
    })
  })

  ## ---------- load heatmap (active athlete, 28 days) ----------
  output$loadHeatmapWrap <- renderUI({
    safe_html(rvLang(), {
      tr <- active_trend(); need_msg(tr, T("stool"))
      tr2 <- utils::tail(tr, 28)
      v <- tr2$daily_load
      vmax <- max(v, 1e-9)
      cells <- vapply(seq_along(v), function(i) {
        op <- 0.15 + 0.85 * (v[i] / vmax)
        tip <- paste0(tr2$date[i], ": ", fn(v[i], 0), " AU")
        paste0('<div class="hm-cell" style="background:rgba(0,229,255,', sprintf("%.2f", op), ');"',
               ' title="', tip, '"><span class="hm-tip">', tip, '</span></div>')
      }, character(1))
      div(class = "heatmap-grid", style = paste0("grid-template-columns:repeat(", min(14, max(1, length(v))), ",1fr);"),
          HTML(paste(cells, collapse = "")))
    })
  })

  ## ---------- sleep bars ----------
  output$sleepBarsWrap <- renderUI({
    safe_html(rvLang(), {
      tr <- active_trend()
      if (is.null(tr) || nrow(tr) == 0) {
        a <- active_row()
        need_msg(a, T("stool"))
        tr <- data.frame(date = a$last_date[1], sleep_hours = a$sleep_hours[1],
                         sleep_quality = a$sleep_quality[1])
      }
      tr2 <- utils::tail(tr, 10)
      cols <- vapply(tr2$sleep_quality, function(q) {
        if (q >= 6) "#00FF88" else if (q >= 4) "#00E5FF" else "#FFAA00"
      }, character(1))
      rows <- lapply(rev(seq_len(nrow(tr2))), function(i) {
        hrs <- tr2$sleep_hours[i]
        div(class = "sleep-row",
            span(class = "sr-label", substr(tr2$date[i], 6, 10)),
            div(class = "sr-track",
                div(class = "sr-fill", style = paste0("width:", clamp(hrs / 10 * 100, 2, 100), "%;background:", cols[i], ";"))),
            span(style = "width:44px;text-align:right;", fn(hrs, 1), "h"))
      })
      div(class = "sleep-rows", rows)
    })
  })

  ## ---------- risk matrix ----------
  output$riskMatrixBox <- renderUI({
    safe_html(rvLang(), {
      df <- RV$athletes; need_msg(df, T("stool"))
      df2 <- head(df[order(df$readiness), ], 10)
      cell <- function(v, good, mid) {
        col <- if (is.na(v)) "var(--bg-4)" else if (v >= good) "var(--green)" else if (v >= mid) "var(--amber)" else "var(--red)"
        paste0('<td style="background:', col, ';opacity:.85;border-radius:4px;text-align:center;color:#001318;font-weight:800;">',
               if (is.na(v)) "—" else fn(v, 0), '</td>')
      }
      head_row <- paste0("<tr><th>", T("rosterN"), "</th><th>", T("readiness"), "</th><th>EA</th><th>ACWR</th><th>", T("injuryForecast"), "</th></tr>")
      body <- vapply(seq_len(nrow(df2)), function(i) {
        ac <- df2$acwr[i]
        ac_disp <- if (is.na(ac)) "—" else fn(ac, 2)
        ac_col <- switch(acwr_zone(ac), sweet = "var(--green)", under = "var(--amber)",
                         danger = "var(--amber)", extreme = "var(--red)", "var(--bg-4)")
        paste0("<tr><td style='font-weight:700'>", htmltools::htmlEscape(df2$name[i]), "</td>",
               cell(df2$readiness[i], READY_GREEN, READY_AMBER),
               cell(df2$ea[i], EA_OPTIMAL, EA_CRITICAL),
               paste0('<td style="background:', ac_col, ';border-radius:4px;text-align:center;color:var(--text);font-weight:700;">', ac_disp, '</td>'),
               cell(100 - df2$injury[i], 70, 40), "</tr>")
      }, character(1))
      div(class = "table-scroll", style = "max-height:260px;",
          HTML(paste0('<table class="roster-table">', head_row, paste0(body, collapse = ""), '</table>')))
    })
  })

  ## ---------- cohort stats ----------
  output$cohortStatsBox <- renderUI({
    safe_html(rvLang(), {
      df <- RV$athletes; need_msg(df, T("stool"))
      cells <- list(
        c(T("totalAthletes"), fn(nrow(df), 0)),
        c(T("males"), fn(sum(df$gender == "male"), 0)),
        c(T("females"), fn(sum(df$gender == "female"), 0)),
        c(T("avgLoad"), paste0(fn(mean(df$daily_load, na.rm = TRUE), 0), " AU")),
        c(T("avgRpe"), fn(mean(df$rpe, na.rm = TRUE), 1)),
        c(T("avgSleep"), paste0(fn(mean(df$sleep_hours, na.rm = TRUE), 1), "h")),
        c(T("qbAtRisk"), fn(sum(df$status == "red", na.rm = TRUE), 0)),
        c(T("qbReds"), fn(sum(df$training_paused, na.rm = TRUE), 0))
      )
      div(class = "cohort-grid", lapply(cells, function(cc) {
        div(class = "cohort-cell", div(class = "cc-label", cc[1]), div(class = "cc-value", cc[2]))
      }))
    })
  })

  ## ---------- event log ----------
  output$eventLogBox <- renderUI({
    safe_html(rvLang(), {
      cur_lg <- rvLang()
      ev <- RV$events
      if (length(ev) == 0) return(div(class = "empty-hint", T("noNotifications")))
      rows <- lapply(head(rev(ev), 20), function(e) {
        disp_text <- e$text
        if (!is.null(e$rule_key)) {
          ath_nm <- format_athlete_name(e$athlete, cur_lg)
          al_desc <- format_alert_text(e$rule_key, e$val, e$extra, cur_lg)
          disp_text <- paste0("\u26A0 ", tr_raw(cur_lg, "alert"), ": ", ath_nm, " \u2014 ", al_desc)
        }
        div(class = "ev-row",
            span(class = "ev-dot", style = paste0("background:", e$color)),
            span(class = "ev-time", format(e$ts, "%H:%M:%S")),
            span(style = "flex:1;", htmltools::htmlEscape(disp_text)))
      })
      div(class = "event-list", rows)
    })
  })

  ## ---------- roster ----------
  roster_filtered <- reactive({
    df <- RV$athletes
    if (is.null(df)) return(NULL)
    q <- tolower(trimws(input$rosterSearch %||% ""))
    if (nzchar(q)) {
      keep <- grepl(q, tolower(df$name), fixed = TRUE) | grepl(q, tolower(df$user_id), fixed = TRUE) |
        grepl(q, tolower(df$sport), fixed = TRUE)
      df <- df[keep, ]
    }
    grp <- RV$filter %||% "all"
    if (grp %in% c("green", "amber", "red")) df <- df[df$status == grp, ]
    if (grp == "female") df <- df[df$gender == "female", ]
    if (grp == "male")   df <- df[df$gender == "male", ]
    df
  })

  ## chip state (filters / grouping / view) — persisted in reactive values + active styling
  js_set_active <- function(ids, active_id) {
    js_run(paste0("[", paste0(paste0("'", ids, "'"), collapse = ","),
                  "].forEach(function(id){var el=document.getElementById(id);if(el){el.classList.toggle('active',id==='", active_id, "');}});"))
  }
  observeEvent(input$fAll,    { RV$filter <- "all";    js_set_active(c("fAll","fGreen","fAmber","fRed","fFemale","fMale"), "fAll") })
  observeEvent(input$fGreen,  { RV$filter <- "green";  js_set_active(c("fAll","fGreen","fAmber","fRed","fFemale","fMale"), "fGreen") })
  observeEvent(input$fAmber,  { RV$filter <- "amber";  js_set_active(c("fAll","fGreen","fAmber","fRed","fFemale","fMale"), "fAmber") })
  observeEvent(input$fRed,    { RV$filter <- "red";    js_set_active(c("fAll","fGreen","fAmber","fRed","fFemale","fMale"), "fRed") })
  observeEvent(input$fFemale, { RV$filter <- "female"; js_set_active(c("fAll","fGreen","fAmber","fRed","fFemale","fMale"), "fFemale") })
  observeEvent(input$fMale,   { RV$filter <- "male";   js_set_active(c("fAll","fGreen","fAmber","fRed","fFemale","fMale"), "fMale") })
  observeEvent(input$gNone,  { RV$groupBy <- "none";  js_set_active(c("gNone","gSport","gRisk"), "gNone") })
  observeEvent(input$gSport, { RV$groupBy <- "sport"; js_set_active(c("gNone","gSport","gRisk"), "gSport") })
  observeEvent(input$gRisk,  { RV$groupBy <- "risk";  js_set_active(c("gNone","gSport","gRisk"), "gRisk") })
  observeEvent(input$vCards, { RV$view <- "cards"; js_set_active(c("vCards","vTable"), "vCards") })
  observeEvent(input$vTable, { RV$view <- "table"; js_set_active(c("vCards","vTable"), "vTable") })

  last_choices_hash <- paste(length(ATH_CHOICES_INIT %||% character(0)), "en", sep = "-")
  observe({
    df <- RV$athletes
    req(df)
    lg <- rvLang()
    ath_names <- format_athlete_name(df$name, lg)
    ch <- setNames(as.character(df$user_id), paste0(ath_names, " (", df$user_id, ")"))
    cur_hash <- paste(length(df$user_id), lg, sep = "-")
    needs_choices <- !identical(cur_hash, last_choices_hash)
    active_id <- as.character(isolate(RV$active) %||% df$user_id[1])
    top_n <- min(250, length(ch))
    ch_dropdown <- head(ch, top_n)
    if (!active_id %in% ch_dropdown && active_id %in% ch) {
      idx <- which(ch == active_id)[1]
      ch_dropdown <- c(ch_dropdown, ch[idx])
    }
    if (needs_choices) {
      last_choices_hash <<- cur_hash
      updateSelectInput(session, "dashAthleteSelect", choices = ch_dropdown, selected = active_id)
      updateSelectInput(session, "redsAthlete", choices = ch_dropdown, selected = active_id)
      updateSelectInput(session, "ckAthlete", choices = ch_dropdown, selected = active_id)
      updateSelectizeInput(session, "athleteSelect", choices = ch_dropdown, selected = active_id, server = FALSE)
      cmp_sel <- isolate(RV$compare)
      cmp_none <- setNames("", tr_raw(lg, "noneChoice"))
      for (i in seq_len(4)) {
        updateSelectInput(session, paste0("cmp", i), choices = c(cmp_none, ch_dropdown),
                          selected = if (length(cmp_sel) >= i) cmp_sel[i] else "")
      }
    }
  })

  ## ---------- roster body ----------
  RV$sortCol <- "readiness"; RV$sortDir <- "asc"
  observeEvent(input$rosterSortCol, {
    k <- input$rosterSortCol
    if (identical(RV$sortCol, k)) RV$sortDir <- if (identical(RV$sortDir, "asc")) "desc" else "asc"
    else { RV$sortCol <- k; RV$sortDir <- "asc" }
  })
  output$rosterCount <- renderText({
    df <- roster_filtered(); paste0("N=", if (is.null(df)) 0 else nrow(df))
  })

  roster_sorted <- reactive({
    df <- roster_filtered()
    if (is.null(df) || nrow(df) == 0) return(df)
    key <- RV$sortCol %||% "readiness"
    v <- switch(key,
                name = tolower(df$name), readiness = df$readiness, load = df$daily_load,
                hr = df$heart_rate %||% rep(NA_real_, nrow(df)), vo2max = df$vo2max %||% rep(NA_real_, nrow(df)),
                hrv = df$hrv %||% rep(NA_real_, nrow(df)), ea = df$ea, rpe = df$rpe,
                df$readiness)
    if (key == "name") {
      ord <- order(v, decreasing = !identical(RV$sortDir, "asc"))
    } else {
      ord <- order(v, na.last = TRUE, decreasing = !identical(RV$sortDir, "asc"))
    }
    df[ord, ]
  })

  athlete_tags_map <- reactiveVal(list())
  custom_tags_list <- reactiveVal(list())
  all_tag_defs <- reactive({
    c(TAG_DEFS, custom_tags_list())
  })

  tag_chips_html <- function(id) {
    tags <- athlete_tags_map()[[id]] %||% character(0)
    defs <- all_tag_defs()
    if (length(tags) == 0) return("")
    paste0(vapply(tags, function(tk) {
      d <- NULL; for (dd in defs) if (identical(dd$key, tk)) d <- dd
      if (is.null(d)) "" else paste0('<span class="athlete-tag" style="background:', d$color, '22;border-color:',
                                     d$color, ';color:', d$color, '">', d$label, '</span>')
    }, character(1)), collapse = "")
  }

  athlete_card_html <- function(a, active_id) {
    col <- status_color(a$status)
    sp <- RV$trends[[a$user_id]]
    spark_vals <- if (!is.null(sp) && nrow(sp) > 1) sp$daily_load else rep(NA_real_, 2)
    tags <- tag_chips_html(a$user_id)
    paste0(
      '<div class="athlete-card', if (identical(a$user_id, active_id)) ' active' else '',
      '" onclick="Shiny.setInputValue(\'athleteCardClick\',\'', a$user_id, '\',{priority:\'event\'})" role="button" tabindex="0">',
      '<span class="status-dot" style="background:', col, '"></span>',
      '<span class="avatar" style="background:', avatar_color(a$name), '">', initials_of(a$name), '</span>',
      '<span><span class="ac-name">', htmltools::htmlEscape(format_athlete_name(a$name, rvLang())),
      if (isTRUE(a$training_paused)) paste0(' <span class="athlete-tag" style="border-color:var(--red);color:var(--red)">', tr_raw(rvLang(), "paused"), '</span>') else '',
      '</span><span class="ac-sub">', htmltools::htmlEscape(a$sport), ' · ', a$user_id,
      if (nzchar(a$injury_location)) paste0(' · \u26A0 ', htmltools::htmlEscape(translate_injury_loc(a$injury_location, rvLang()))) else '', '</span>',
      '<span class="athlete-tags">', tags, '</span></span>',
      '<span class="ac-metrics">',
      '<span class="ac-metric">RDY<span class="m-val" style="color:', col, '">', fn(a$readiness, 0), '</span></span>',
      '<span class="ac-metric">AU<span class="m-val">', fn(a$daily_load, 0), '</span></span>',
      '<span class="ac-metric">EA<span class="m-val">', if (is.na(a$ea)) "—" else fn(a$ea, 0), '</span></span>',
      '</span>',
      '<span class="spark-wrap">', sparkline_svg(spark_vals, avatar_color(a$name)), '</span>',
      '</div>'
    )
  }

  roster_table_html <- function(df) {
    if (is.null(df) || nrow(df) == 0) return(paste0('<div class="empty-hint">', tr_raw(rvLang(), "noResults"), '</div>'))
    cols <- list(c("name", "ATHLETE"), c("status", "STATUS"), c("readiness", "READINESS"),
                 c("load", "LOAD"), c("rpe", "RPE"), c("ea", "EA"), c("sport", "SPORT"))
    th <- vapply(cols, function(cc) {
      k <- cc[1]
      arrow <- if (identical(RV$sortCol, k)) (if (identical(RV$sortDir, "asc")) " \u25B2" else " \u25BC") else ""
      paste0('<th onclick="Shiny.setInputValue(\'rosterSortCol\',\'', k, '\',{priority:\'event\'})">',
             cc[2], arrow, '</th>')
    }, character(1))
    limit_n <- min(150, nrow(df))
    body <- vapply(seq_len(limit_n), function(i) {
      a <- df[i, ]
      col <- status_color(a$status)
      paste0('<tr class="', if (identical(a$user_id, RV$active)) "row-active" else '',
             '" onclick="Shiny.setInputValue(\'athleteCardClick\',\'', a$user_id, '\',{priority:\'event\'})">',
             '<td style="font-weight:700"><span class="status-dot" style="display:inline-block;background:', col, '"></span> ',
             htmltools::htmlEscape(format_athlete_name(a$name, rvLang())), tag_chips_html(a$user_id), '</td>',
             '<td style="color:', col, ';font-weight:800">', if (isTRUE(a$training_paused)) tr_raw(rvLang(), "paused") else toupper(a$status), '</td>',
             '<td style="font-weight:800;color:', col, '">', fn(a$readiness, 0), '</td>',
             '<td>', fn(a$daily_load, 0), '</td><td>', fn(a$rpe, 0), '</td>',
             '<td>', if (is.na(a$ea)) "—" else fn(a$ea, 1), '</td>',
             '<td class="text-dim">', htmltools::htmlEscape(a$sport), '</td></tr>')
    }, character(1))
    footer_hint <- if (nrow(df) > 150) paste0('<div class="empty-hint" style="padding:6px;font-size:11px;opacity:.7;">Showing top 150 of ', nrow(df), ' athletes. Use search or filter chips above to refine.</div>') else ''
    paste0('<div class="table-scroll"><table class="roster-table"><thead><tr>',
           paste(th, collapse = ""), '</tr></thead><tbody>', paste0(body, collapse = ""), '</tbody></table></div>', footer_hint)
  }

  output$rosterBody <- renderUI({
    safe_html(rvLang(), {
      df <- roster_sorted()
      need_msg(df, T("noResults"))
      view <- RV$view %||% "cards"
      if (identical(view, "table")) return(HTML(roster_table_html(df)))
      groups <- RV$groupBy %||% "none"
      active_id <- RV$active
      if (identical(groups, "none")) {
        limit_n <- min(80, nrow(df))
        cards <- paste0(vapply(seq_len(limit_n), function(i) athlete_card_html(df[i, ], active_id), character(1)), collapse = "")
        hint <- if (nrow(df) > 80) paste0('<div class="empty-hint" style="margin-top:12px;opacity:.7;">Showing 80 of ', nrow(df), ' athletes. Use search, filters, or switch to Table view.</div>') else ''
        HTML(paste0(cards, hint))
      } else {
        keys <- if (identical(groups, "sport")) unique(df$sport) else c("red", "amber", "green")
        html <- vapply(keys, function(k) {
          if (identical(groups, "sport")) sub <- df[df$sport == k, ]
          else sub <- df[df$status == k, ]
          if (nrow(sub) == 0) return("")
          lab <- if (identical(groups, "sport")) k else switch(k, red = paste0("\u26A0 ", T("filterRed")),
                                                               amber = paste0("\u25D0 ", T("filterAmber")),
                                                               paste0("\u25CF ", T("filterGreen")))
          limit_sub <- min(30, nrow(sub))
          paste0('<div class="mini-label" style="margin:8px 4px 4px;color:var(--cyan)">', htmltools::htmlEscape(lab),
                 ' <span style="opacity:.6">(', nrow(sub), ')</span></div>',
                 paste0(vapply(seq_len(limit_sub), function(i) athlete_card_html(sub[i, ], active_id), character(1)), collapse = ""))
        }, character(1))
        HTML(paste0(html, collapse = ""))
      }
    })
  })

  observeEvent(input$athleteCardClick, {
    uid <- input$athleteCardClick
    if (!is.null(uid) && nzchar(uid)) {
      RV$active <- uid
      updateSelectInput(session, "dashAthleteSelect", selected = uid)
      updateSelectizeInput(session, "athleteSelect", selected = uid)
      updateSelectInput(session, "redsAthlete", selected = uid)
    }
  })

  observeEvent(input$athleteSelect, {
    uid <- input$athleteSelect
    if (!is.null(uid) && nzchar(uid) && !identical(uid, RV$active)) {
      RV$active <- uid
      updateSelectInput(session, "dashAthleteSelect", selected = uid)
      updateSelectInput(session, "redsAthlete", selected = uid)
    }
  }, ignoreInit = TRUE)

  observeEvent(input$dashAthleteSelect, {
    uid <- input$dashAthleteSelect
    if (!is.null(uid) && nzchar(uid) && !identical(uid, RV$active)) {
      RV$active <- uid
      updateSelectizeInput(session, "athleteSelect", selected = uid)
      updateSelectInput(session, "redsAthlete", selected = uid)
    }
  }, ignoreInit = TRUE)

  output$dashAthleteBadgeWrap <- renderUI({
    a <- active_row()
    if (is.null(a)) return(NULL)
    col <- status_color(a$status[1])
    div(style = "display:flex;align-items:center;gap:8px;flex-wrap:wrap;",
        span(class = "status-dot", style = paste0("background:", col, ";display:inline-block;width:9px;height:9px;")),
        span(style = "font-weight:800;color:var(--text);font-size:12px;", htmltools::htmlEscape(format_athlete_name(a$name[1], rvLang()))),
        span(class = "athlete-tag", style = paste0("background:", col, "22;border-color:", col, ";color:", col, ";font-size:10px;padding:2px 8px;"), toupper(a$status[1])),
        span(class = "rf-chip", style = "padding:2px 8px;font-size:10px;", htmltools::htmlEscape(a$sport[1])),
        if (identical(a$gender[1], "female") && nzchar(a$cycle_phase[1] %||% ""))
          span(class = "rf-chip", style = "padding:2px 8px;font-size:10px;color:var(--magenta);border-color:var(--magenta);", toupper(a$cycle_phase[1])) else NULL
    )
  })

  observeEvent(input$viewAthleteDetailBtn, {
    js_run("tabBtnActivate('athlete'); if(window.Shiny) Shiny.setInputValue('mainTabs','athlete',{priority:'event'});")
  })

  ## selected quick summary (roster tab sidebar) — v7: enriched with bone/ACL/nutrition/biometrics rows
  output$selectedQuickBox <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      col <- status_color(status_from_readiness(a$readiness[1]))
      wf <- wf_ratio_for(a)
      kv <- list(
        c(T("readiness"), paste0(fn(a$readiness[1], 0), "/100")),
        c("EA", if (is.na(a$ea[1])) "—" else paste0(fn(a$ea[1], 1), " kcal/kg")),
        c("ACWR", if (is.na(a$acwr[1])) "—" else fn(a$acwr[1], 2)),
        c(T("load"), paste0(fn(a$daily_load[1], 0), " AU")),
        c(T("sleepH"), paste0(fn(a$sleep_hours[1], 1), "h")),
        c(T("stress"), paste0(fn(a$stress[1], 0), "/7")),
        c(T("pain"), paste0(fn(a$pain_level[1], 0), "/10")),
        c(T("wfRatio"), fn(wf$ratio, 2)),
        c(T("boneHealth"), paste0("T ", fn(a$bone_t_score[1], 1), " · Z ", fn(a$bone_z_score[1], 1))),
        c(T("aclRisk"), paste0(fn(a$knee_acl_risk[1], 0), "%")),
        c(T("hydration"), paste0(fn(a$hydration_pct[1], 0), "%")),
        c(T("choLoad"), paste0(fn(a$cho_g_per_kg[1], 1), " g/kg")),
        c(T("protein"), paste0(fn(a$protein_g_per_kg[1], 1), " g/kg")),
        c("HRV", fn(a$hrv[1], 0)),
        c(T("tileSpo2"), paste0(fn(a$spo2[1], 0), "%")),
        c(T("tileLactate"), paste0(fn(a$lactate[1], 1), " mmol/L")),
        c(T("lastCheckin"), if (nzchar(a$last_date[1])) a$last_date[1] else T("never"))
      )
      tagList(
        div(style = "display:flex;align-items:center;gap:10px;margin-bottom:10px;",
            span(class = "avatar", style = paste0("background:", avatar_color(a$name[1])), initials_of(a$name[1])),
            div(div(class = "ac-name", htmltools::htmlEscape(format_athlete_name(a$name[1], rvLang()))),
                div(class = "ac-sub", paste(a$user_id[1], "·", a$gender[1], "·", a$sport[1]))),
            span(class = "status-dot", style = paste0("margin-left:auto;background:", col, ";width:12px;height:12px;"))),
        div(class = "kv-grid", style = "max-height:300px;overflow-y:auto;",
            lapply(kv, function(p) tagList(span(class = "k", p[1]), span(p[2])))),
        actionButton("viewAthleteDetailBtn", HTML(paste0('<span data-k="tabAthlete">', T("tabAthlete"), '</span> &rarr;')),
                     class = "athena-btn primary small", style = "width:100%;margin-top:10px;justify-content:center;")
      )
    })
  })

  ## ---------- athlete detail tab ----------
  output$athleteHeader <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      col <- status_color(status_from_readiness(a$readiness[1]))
      defs <- all_tag_defs()
      mytags <- athlete_tags_map()[[a$user_id[1]]] %||% character(0)
      chips <- vapply(mytags, function(tk) {
        d <- NULL; for (dd in defs) if (identical(dd$key, tk)) d <- dd
        if (is.null(d)) "" else paste0('<button class="athlete-tag" style="background:', d$color, '22;border-color:', d$color,
                                       ';color:', d$color, ';cursor:pointer" onclick="Shiny.setInputValue(\'tagToggle\',\'', a$user_id[1], "|", tk, '\',{priority:\'event\'})">',
                                       d$label, '</button>')
      }, character(1))
      addbtns <- vapply(setdiff(vapply(defs, function(d) d$key, character(1)), mytags), function(tk) {
        d <- NULL; for (dd in defs) if (identical(dd$key, tk)) d <- dd
        paste0('<button class="rf-chip" style="font-size:9px;padding:2px 8px" onclick="Shiny.setInputValue(\'tagToggle\',\'',
               a$user_id[1], "|", tk, '\',{priority:\'event\'})">+ ', d$label, '</button>')
      }, character(1))
      tagList(
        div(class = "panel-card",
            div(style = "display:flex;align-items:center;gap:12px;flex-wrap:wrap;",
                span(class = "avatar", style = paste0("background:", avatar_color(a$name[1]), ";width:46px;height:46px;font-size:16px;"),
                     initials_of(a$name[1])),
                div(div(style = "font-size:17px;font-weight:900;", htmltools::htmlEscape(format_athlete_name(a$name[1], rvLang()))),
                    div(class = "ac-sub", paste0(a$user_id[1], " · ", a$gender[1], " · ", a$sport[1],
                                                 " · ", T("lastCheckin"), ": ", if (nzchar(a$last_date[1])) a$last_date[1] else T("never")))),
                span(style = "margin-left:auto;display:flex;gap:8px;align-items:center;",
                     selectizeInput("athleteSelect", NULL, choices = NULL, width = "240px",
                                    options = list(placeholder = T("selectPlaceholder"))),
                     span(class = "status-dot", style = paste0("background:", col, ";width:14px;height:14px;")))),
            if (length(chips) + length(addbtns) > 0) {
              div(class = "chip-row", style = "margin:10px 0 0;", HTML(paste0(c(chips, addbtns), collapse = "")))
            } else NULL)
      )
    })
  })

  observeEvent(input$tagToggle, {
    parts <- strsplit(input$tagToggle %||% "", "|", fixed = TRUE)[[1]]
    if (length(parts) == 2) {
      id <- parts[1]; tk <- parts[2]
      m <- athlete_tags_map()
      cur <- m[[id]] %||% character(0)
      m[[id]] <- if (tk %in% cur) setdiff(cur, tk) else c(cur, tk)
      athlete_tags_map(m)
      js_run(paste0("try{localStorage.setItem('athena_tags',\"", jsonlite::toJSON(m, auto_unbox = TRUE), "\");}catch(e){}"))
    }
  })

  ## custom tag manager
  observeEvent(input$createTagBtn, {
    nm <- trimws(input$tagName %||% "")
    colr <- input$tagColorIn %||% "#00E5FF"
    if (!nzchar(nm)) { notify("warn", T("tagName"), T("tagName")); return() }
    ct <- custom_tags_list()
    if (length(ct) >= MAX_CUSTOM_TAGS) { notify("warn", T("maxTags")); return() }
    key <- paste0("custom_", tolower(gsub("[^a-zA-Z0-9]", "_", nm)))
    if (any(vapply(c(TAG_DEFS, ct), function(d) identical(d$key, key), logical(1)))) {
      notify("warn", T("maxTags"), nm); return()
    }
    custom_tags_list(c(ct, list(list(key = key, label = toupper(nm), color = colr))))
    updateTextInput(session, "tagName", value = "")
    notify("success", T("createTag"), toupper(nm))
  })
  observeEvent(input$deleteCustomTag, {
    ct <- custom_tags_list()
    custom_tags_list(Filter(function(d) !identical(d$key, input$deleteCustomTag), ct))
  })
  output$tagListMgr <- renderUI({
    safe_html(rvLang(), {
      defs <- c(TAG_DEFS, custom_tags_list())
      rows <- lapply(defs, function(d) {
        is_custom <- startsWith(d$key, "custom_")
        div(class = "chip-row", style = "margin-bottom:5px;",
            span(class = "athlete-tag", style = paste0("background:", d$color, "22;border-color:", d$color, ";color:", d$color), d$label),
            if (is_custom) {
              tags$button(class = "athena-btn small danger", type = "button",
                          onclick = paste0("Shiny.setInputValue('deleteCustomTag','", d$key, "',{priority:'event'})"),
                          T("deleteTag"))
            } else NULL)
      })
      div(rows)
    })
  })

  output$athleteRings <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      tr <- active_trend()
      rcol <- status_color(status_from_readiness(a$readiness[1]))
      eal <- ea_risk_level(a$ea[1])
      ecol <- switch(eal, low = "#00FF88", mod = "#FFAA00", high = "#FF2244", "#9AA0A6")
      inj <- a$injury[1]
      icol <- if (is.na(inj)) "#9AA0A6" else if (inj >= 60) "#FF2244" else if (inj >= 35) "#FFAA00" else "#00FF88"
      ring_tile <- function(ring, label, sub) {
        div(class = "hud-card", style = "text-align:center;",
            div(style = "display:flex;justify-content:center;color:var(--text);", HTML(ring)),
            div(class = "hud-label", label), div(class = "hud-sub", sub))
      }
      if (CAP$plotly) {
        perf <- perf_score_for(a, tr)
        div(class = "hud-row",
            ring_tile(ring_svg(a$readiness[1], 100, rcol, 92, 9, T("readiness")), T("readiness"), T("readinessBreakdown")),
            ring_tile(ring_svg(if (is.na(a$ea[1])) 0 else clamp(a$ea[1], 0, 80), 80, ecol, 92, 9, "EA"),
                      T("eaValue"), paste0(fn(a$ea[1], 1), " kcal/kg FFM")),
            ring_tile(ring_svg(100 - (if (is.na(inj)) 50 else inj), 100, icol, 92, 9, T("injuryForecast")),
                      T("injuryForecast"), paste0(fn(inj, 0), "/100")),
            ring_tile(ring_svg(perf, 100, "#E91E63", 92, 9, T("perfScore")), T("perfScore"), T("demo")))
      } else {
        perf <- perf_score_for(a, tr)
        div(class = "hud-row",
            ring_tile(ring_svg(a$readiness[1], 100, rcol, 92, 9), T("readiness"), T("readinessBreakdown")),
            ring_tile(ring_svg(clamp(ifelse(is.na(a$ea[1]), 0, a$ea[1]), 0, 80), 80, ecol, 92, 9), T("eaValue"), paste0(fn(a$ea[1], 1), " kcal/kg")),
            ring_tile(ring_svg(100 - (if (is.na(inj)) 50 else inj), 100, icol, 92, 9), T("injuryForecast"), fn(inj, 0)),
            ring_tile(ring_svg(perf, 100, "#E91E63", 92, 9), T("perfScore"), T("demo")))
      }
    })
  })

  perf_score_for <- function(a, tr) {
    base <- 40 + 0.4 * safe_num(a$readiness[1], 50)
    if (!is.null(tr) && nrow(tr) > 7) {
      ac <- tail(acwr_series(tr$daily_load)$acwr, 1)
      if (!is.na(ac)) base <- base + 15 * pmax(0, 1 - abs(ac - 1.05) / 0.6)
      mn <- tail(monotony_strain(tr$daily_load)$monotony, 1)
      if (!is.na(mn)) base <- base - 8 * pmax(0, mn - 2)
    }
    round(clamp(base, 0, 100))
  }

  ## EA trend + 7-day forecast
  ea_series_data <- reactive({
    a <- active_row(); tr <- active_trend()
    if (is.null(a)) return(NULL)
    if (is.null(tr) || nrow(tr) == 0) {
      vals <- a$ea[1]; return(list(vals = vals, dates = a$last_date[1]))
    }
    ea_vals <- vapply(seq_len(nrow(tr)), function(i) {
      e <- ea_calculate(tr$calories[i], tr$daily_load[i], if (a$ffm[1] > 0) a$ffm[1] else NA_real_,
                        duration_minutes = 90, exercise_type = a$exercise_type[1],
                        body_mass_kg = if (a$ffm[1] > 0) a$ffm[1] / 0.8 else NA_real_,
                        gender = a$gender[1], cycle_phase = a$cycle_phase[1])
      e$ea_value
    }, numeric(1))
    list(vals = ea_vals, dates = tr$date)
  })

  output$eaTrendWrap <- renderUI({
    safe_html(rvLang(), {
      d <- ea_series_data(); need_msg(d, T("stool"))
      vals <- d$vals[!is.na(d$vals)]
      if (length(vals) >= 4) {
        fit <- suppressWarnings(stats::lm(vals ~ stats::time(vals)))
        fut <- stats::predict(fit, newdata = data.frame(time = c(max(stats::time(vals)) + 1:7)))
        allv <- c(d$vals, fut)
      } else allv <- d$vals
      wg <- NULL
      if (CAP$plotly && length(allv) >= 2) {
        wg <- tryCatch({
          n0 <- length(d$vals)
          plotly::plot_ly(x = seq_along(allv), y = allv, type = "scatter", mode = "lines+markers",
                          line = list(color = "#00E5FF", width = 3), name = "EA") |>
            plotly::add_lines(x = (n0):(n0 + 7), y = c(utils::tail(d$vals, 1), fut),
                              line = list(color = "#E91E63", dash = "dot", width = 2), name = T("forecast")) |>
            plotly::add_ribbon(y = EA_CRITICAL, ymin = 0, ymax = EA_CRITICAL, fillcolor = "rgba(255,34,68,.08)",
                               line = list(width = 0), name = T("critical30"), showlegend = FALSE) |>
            plotly::layout(paper_bgcolor = "rgba(0,0,0,0)", plot_bgcolor = "rgba(0,0,0,0)",
                           font = list(color = "#9AA0A6", size = 10),
                           yaxis = list(title = "", gridcolor = "rgba(128,128,128,.15)"),
                           xaxis = list(title = "", gridcolor = "rgba(128,128,128,.15)"),
                           showlegend = TRUE, margin = list(l = 30, r = 8, t = 6, b = 22))
        }, error = function(e) NULL)
      }
      plot_or_svg("chEaTrend", wg, svg_line(allv, "#00E5FF", h = 190, ylab = "EA"))
    })
  })
  output$chEaTrend <- if (CAP$plotly) renderPlotly({
    d <- ea_series_data(); req(d)
    thm <- RV$theme %||% input$uiTheme %||% "dark"
    p <- plotly::plot_ly(x = seq_along(d$vals), y = d$vals, type = "scatter", mode = "lines+markers",
                    line = list(color = "#00E5FF", width = 3)) |>
      plotly::layout(showlegend = FALSE)
    athena_plotly(p, thm)
  })

  ## ACWR panel
  output$acwrBox <- renderUI({
    safe_html(rvLang(), {
      tr <- active_trend(); a <- active_row(); need_msg(tr, T("stool"))
      ac <- acwr_series(tr$daily_load)
      acf <- ac$acwr[!is.na(ac$acwr)]
      zones <- acwr_zone(acf)
      zcol <- vapply(zones, function(z) switch(z, sweet = "#00FF88", under = "#FFAA00", danger = "#FFAA00",
                                               extreme = "#FF2244", "#9AA0A6"), character(1))
      vals <- utils::tail(acf, 28)
      cols <- utils::tail(zcol, 28)
      cells <- paste0(vapply(seq_along(vals), function(i) {
        paste0('<div class="hm-cell" style="background:', cols[i], ';opacity:.8" title="ACWR ',
               fn(vals[i], 2), '"></div>')
      }, character(1)), collapse = "")
      last <- utils::tail(acf, 1)
      zone_lab <- switch(utils::tail(zones, 1), sweet = T("optimal45"), under = T("caution3045"),
                         danger = T("caution3045"), extreme = T("highRisk"), T("stool"))
      tagList(
        div(style = "display:flex;align-items:baseline;gap:10px;margin-bottom:8px;",
            span(style = paste0("font-size:26px;font-weight:900;color:", if (length(last) && !is.na(last)) "var(--text)" else "var(--text-dim)", ";"),
                 if (length(last)) fn(last, 2) else "—"),
            span(class = "mini-label", zone_lab)),
        div(class = "heatmap-grid", style = "grid-template-columns:repeat(14,1fr);", HTML(cells)),
        div(class = "mini-label", style = "margin-top:6px;",
            "0.8 \u2264 ACWR \u2264 1.3 — Gabbett sweet-spot · >1.5 spike")
      )
    })
  })

  ## ---------- wellness radar ----------
  radar_data_for <- function(a, tr) {
    if (is.null(a)) return(NULL)
    mn <- if (!is.null(tr) && nrow(tr) >= 7) tail(monotony_strain(tr$daily_load)$monotony, 1) else NA_real_
    vals <- c(
      Readiness = clamp(a$readiness[1], 0, 100),
      Sleep    = clamp(safe_num(a$sleep_hours[1], 7) / 9 * 100, 0, 100),
      Mood     = clamp(100 - (safe_num(a$stress[1], 3) - 1) / 6 * 100, 0, 100),
      Recovery = clamp(100 - (safe_num(a$fatigue[1], 3) - 1) / 6 * 100, 0, 100),
      Muscles  = clamp(100 - (safe_num(a$muscle_soreness[1], 2) - 1) / 6 * 100, 0, 100),
      Energy   = if (is.na(a$ea[1])) 50 else clamp(a$ea[1] / 60 * 100, 0, 100)
    )
    list(vals = vals, labels = c("RDY", T("sleepH"), T("mood"), "REC", T("soreness"), "EA"),
         monotony = mn)
  }

  output$radarWrap <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); tr <- active_trend(); need_msg(a, T("stool"))
      d <- radar_data_for(a, tr)
      wg <- NULL
      if (CAP$plotly) {
        wg <- tryCatch(
          plotly::plot_ly(type = "scatterpolar", r = as.numeric(d$vals),
                          theta = names(d$vals), fill = "toself", line = list(color = "#00E5FF")) |>
            plotly::layout(polar = list(radialaxis = list(range = c(0, 100), showgrid = TRUE,
                                                         gridcolor = "rgba(128,128,128,.2)",
                                                         tickfont = list(size = 8))),
                           paper_bgcolor = "rgba(0,0,0,0)", font = list(color = "#9AA0A6", size = 10),
                           showlegend = FALSE, margin = list(l = 40, r = 40, t = 20, b = 20)),
          error = function(e) NULL)
      }
      svg <- svg_radar(as.numeric(d$vals), d$labels)
      plot_or_svg("chRadar", wg, svg, height = 280)
    })
  })
  output$chRadar <- if (CAP$plotly) renderPlotly({
    a <- active_row(); tr <- active_trend(); req(a)
    d <- radar_data_for(a, tr)
    thm <- RV$theme %||% input$uiTheme %||% "dark"
    p <- plotly::plot_ly(type = "scatterpolar", mode = "lines+markers", r = as.numeric(d$vals), theta = names(d$vals),
                    fill = "toself", line = list(color = "#00E5FF")) |>
      plotly::layout(polar = list(radialaxis = list(range = c(0, 100))), showlegend = FALSE)
    athena_plotly(p, thm)
  })

  ## ---------- cycle timeline ----------
  output$cycleBox <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      if (a$gender[1] != "female") {
        return(div(class = "empty-hint", paste0("\u2014 · ", T("filterFemale"), " profile only")))
      }
      day <- ((as.integer(Sys.Date()) - 1) %% 28) + 1
      phase <- if (day <= 5) "menstrual" else if (day <= 13) "follicular" else if (day <= 16) "ovulatory" else "luteal"
      phase_col <- switch(phase, menstrual = "#FF2244", follicular = "#00FF88", ovulatory = "#00E5FF", "#9D4EDD")
      phase_rec <- switch(phase,
                          menstrual = "Recovery emphasis · low-intensity skill work",
                          follicular = "High-intensity window · progressive overload",
                          ovulatory = "Peak power window · monitor ACL risk",
                          luteal = "Increased RPE perception · fueling + sleep priority")
      adapt <- switch(phase, menstrual = T("cycleLow"), follicular = T("cycleHigh"),
                      ovulatory = T("cyclePeak"), T("cycleMod"))
      segs <- list(list(1, 5, "#FF2244", T("menstrual")), list(6, 13, "#00FF88", T("follicular")),
                   list(14, 16, "#00E5FF", T("ovulatory")), list(17, 28, "#9D4EDD", T("luteal")))
      bar <- paste0(vapply(segs, function(s) {
        paste0('<div style="flex:', s[[2]] - s[[1]] + 1, ';background:', s[[3]], ';opacity:.75;border-radius:4px;',
               'min-height:22px;font-size:8px;font-weight:800;color:#001318;display:flex;align-items:center;justify-content:center;">',
               s[[4]], '</div>')
      }, character(1)), collapse = "")
      fert <- paste0(vapply(11:16, function(d) {
        paste0('<div style="flex:1;background:var(--amber);opacity:.5;border-radius:2px;min-height:8px"></div>')
      }, character(1)), collapse = "")
      days <- paste0(vapply(seq(1, 28, 3), function(d) {
        paste0('<span style="flex:1;text-align:center">', d, '</span>')
      }, character(1)), collapse = "")
      tagList(
        div(class = "mini-label", paste0(T("cycleDay"), " ", day, " / 28")),
        div(style = "display:flex;gap:2px;margin-top:6px;", HTML(bar)),
        div(style = "display:flex;gap:2px;margin:6px 3px 2px 3px;", HTML(fert)),
        div(class = "mini-label", style = "display:flex;margin:0 3px;", HTML(days)),
        div(class = "rec-item", style = "margin-top:10px;border-left:3px solid var(--amber);",
            HTML(paste0("<b style=\"color:", phase_col, "\">",
                   switch(phase, menstrual = T("menstrual"), follicular = T("follicular"),
                          ovulatory = T("ovulatory"), luteal = T("luteal")),
                   "</b> · ", phase_rec))),
        div(class = "mini-label", style = "margin-top:8px;", paste0(T("fertilityWindow"), ": 11–16 · ", T("trainingAdapt"), ": ", adapt))
      )
    })
  })

  ## ---------- monotony & strain ----------
  output$monotonyBox <- renderUI({
    safe_html(rvLang(), {
      tr <- active_trend(); need_msg(tr, T("stool"))
      ms <- monotony_strain(tr$daily_load)
      mn <- utils::tail(ms$monotony[!is.na(ms$monotony)], 1)
      st <- utils::tail(ms$strain[!is.na(ms$strain)], 1)
      mncol <- if (is.na(mn)) "var(--text-dim)" else if (mn > 2) "var(--red)" else if (mn > 1.5) "var(--amber)" else "var(--green)"
      tagList(
        div(style = "display:flex;gap:16px;",
            div(div(class = "cc-label", "Monotony"), div(class = "cc-value", style = paste0("color:", mncol), if (is.na(mn)) "—" else fn(mn, 2))),
            div(div(class = "cc-label", "Strain (AU)"), div(class = "cc-value", if (is.na(st)) "—" else fn(st, 0)))),
        div(class = "mini-label", style = "margin-top:8px;", "Foster: monotony = mean/SD (7d) · strain = weekly load × monotony · >2.0 deload"),
        if (length(ms$monotony[!is.na(ms$monotony)]) >= 3) {
          div(style = "margin-top:8px;", HTML(svg_line(utils::tail(ms$monotony[!is.na(ms$monotony)], 28), "#FFAA00", h = 90)))
        } else NULL
      )
    })
  })

  ## ---------- data quality: completeness + RPE validity ----------
  output$qualityBox <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); tr <- active_trend(); need_msg(a, T("stool"))
      fields <- c("daily_load", "rpe", "sleep_hours", "sleep_quality", "stress", "fatigue",
                  "muscle_soreness", "calories")
      if (!is.null(tr) && nrow(tr) > 0) {
        comp <- vapply(fields, function(f) {
          if (f %in% names(tr)) round(100 * mean(!is.na(tr[[f]]) & tr[[f]] > 0), 0) else 0
        }, numeric(1))
        days_n <- nrow(tr)
      } else {
        comp <- setNames(rep(100, length(fields)), fields); days_n <- 1L
      }
      overall <- round(mean(comp), 0)
      rpe_val <- NA_real_
      if (!is.null(tr) && nrow(tr) >= 7) {
        ct <- suppressWarnings(stats::cor(tr$rpe, tr$daily_load, use = "pairwise.complete.obs"))
        rpe_val <- if (is.na(ct)) NA_real_ else round(clamp(ct, -1, 1) * 100, 0)
      }
      bars <- lapply(names(comp), function(f) {
        div(class = "sleep-row",
            span(class = "sr-label", style = "width:90px;", f),
            div(class = "sr-track",
                div(class = "sr-fill", style = paste0("width:", comp[[f]], "%;background:",
                    if (comp[[f]] >= 80) "var(--green)" else if (comp[[f]] >= 50) "var(--amber)" else "var(--red)", ";"))),
            span(style = "width:38px;text-align:right;", fn(comp[[f]], 0), "%"))
      })
      tagList(
        div(style = "display:flex;gap:16px;align-items:baseline;margin-bottom:8px;",
            span(style = "font-size:24px;font-weight:900;", fn(overall, 0), "%"),
            span(class = "mini-label", paste0(days_n, " ", T("days"))),
            span(class = "mini-label", paste0(T("rpeValidity"), ": ", if (is.na(rpe_val)) "—" else paste0(fn(rpe_val, 0), "%")))),
        div(class = "sleep-rows", bars)
      )
    })
  })

  ## ---------- notes with undo/redo ----------
  note_stacks_ok <- function(id) { RV$noteUndo[[id]] <- RV$noteUndo[[id]] %||% list(); RV$noteRedo[[id]] <- RV$noteRedo[[id]] %||% list(); TRUE }

  observeEvent(input$addNoteBtn, {
    a <- active_row(); txt <- trimws(input$noteInput %||% "")
    if (is.null(a) || !nzchar(txt)) return()
    id <- a$user_id[1]; note_stacks_ok(id)
    RV$noteUndo[[id]] <- head(append(list(RV$notes[[id]] %||% list()), RV$noteUndo[[id]]), 20)
    RV$noteRedo[[id]] <- list()
    RV$notes[[id]] <- append(list(list(nid = as.numeric(Sys.time()), text = txt,
                                       priority = input$notePriority %||% "info", ts = Sys.time())),
                             RV$notes[[id]] %||% list())
    updateTextAreaInput(session, "noteInput", value = "")
    notify("success", T("addNote"), substr(txt, 1, 60))
  })
  observeEvent(input$undoNoteBtn, {
    a <- active_row(); if (is.null(a)) return()
    id <- a$user_id[1]; note_stacks_ok(id)
    if (length(RV$noteUndo[[id]]) == 0) return()
    RV$noteRedo[[id]] <- head(append(list(RV$notes[[id]] %||% list()), RV$noteRedo[[id]]), 20)
    RV$notes[[id]] <- RV$noteUndo[[id]][[1]]
    RV$noteUndo[[id]] <- tail(RV$noteUndo[[id]], -1)
  })
  observeEvent(input$redoNoteBtn, {
    a <- active_row(); if (is.null(a)) return()
    id <- a$user_id[1]; note_stacks_ok(id)
    if (length(RV$noteRedo[[id]]) == 0) return()
    RV$noteUndo[[id]] <- head(append(list(RV$notes[[id]] %||% list()), RV$noteUndo[[id]]), 20)
    RV$notes[[id]] <- RV$noteRedo[[id]][[1]]
    RV$noteRedo[[id]] <- tail(RV$noteRedo[[id]], -1)
  })
  observeEvent(input$noteDelIdx, {
    idx <- suppressWarnings(as.integer(input$noteDelIdx))
    a <- active_row(); if (is.null(a) || is.na(idx)) return()
    id <- a$user_id[1]; note_stacks_ok(id)
    ns <- RV$notes[[id]] %||% list()
    if (idx >= 1 && idx <= length(ns)) {
      RV$noteUndo[[id]] <- head(append(list(ns), RV$noteUndo[[id]]), 20)
      RV$notes[[id]] <- ns[-idx]
    }
  })
  output$notesBox <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      ns <- RV$notes[[a$user_id[1]]] %||% list()
      if (length(ns) == 0) return(div(class = "empty-hint", T("notePlaceholder")))
      rows <- lapply(seq_along(ns), function(i) {
        n <- ns[[i]]
        col <- switch(n$priority, critical = "var(--red)", warning = "var(--amber)", "var(--cyan)")
        div(class = "rec-item", style = paste0("border-left:3px solid ", col, ";display:flex;gap:10px;align-items:flex-start;"),
            div(style = "flex:1;",
                div(style = "font-size:11px;", htmltools::htmlEscape(n$text)),
                div(class = "mini-label", paste0(n$priority, " · ", time_ago(n$ts, rvLang())))),
            tags$button(class = "athena-btn small danger", type = "button",
                        onclick = paste0("Shiny.setInputValue('noteDelIdx',", i, ",{priority:'event'})"), "\u00D7"))
      })
      div(class = "event-list", style = "max-height:280px;", rows)
    })
  })

  ## =============================================================================
  ## RED-S LAB
  ## =============================================================================
  observeEvent(input$redsAthlete, {
    df <- RV$athletes
    if (!is.null(df)) {
      m <- df$user_id == input$redsAthlete
      if (any(m)) {
        a <- df[m, ][1, ]
        updateSliderInput(session, "scIntake", value = clamp(a$calories[1], 800, 6000))
        updateSliderInput(session, "scFfm", value = clamp(a$ffm[1], 30, 90))
        updateRadioButtons(session, "scGender", selected = if (a$gender[1] == "female") "female" else "male")
        updateSelectInput(session, "scCycle", selected = a$cycle_phase[1] %||% "")
        updateSelectInput(session, "scExercise", selected = a$exercise_type[1] %||% "")
      }
    }
  })

  sc_result <- reactive({
    ea_calculate(input$scIntake, safe_num(input$scDuration) * 6,   # load proxy when no MET match
                 input$scFfm, duration_minutes = input$scDuration,
                 exercise_type = input$scExercise, body_mass_kg = input$scMass,
                 gender = input$scGender, cycle_phase = input$scCycle)
  })

  output$redsResultBox <- renderUI({
    safe_html(rvLang(), {
      r <- sc_result()
      if (is.na(r$ea_value)) {
        return(div(class = "empty-hint", T("stool")))
      }
      col <- switch(r$ea_status, GREEN = "var(--green)", YELLOW = "var(--amber)", "var(--red)")
      lvl <- ea_risk_level(r$ea_value)
      tagList(
        div(style = "display:flex;align-items:center;gap:14px;justify-content:center;margin:6px 0 10px;",
            HTML(ring_svg(clamp(r$ea_value, 0, 80), 80,
                          switch(lvl, low = "#00FF88", mod = "#FFAA00", high = "#FF2244", "#9AA0A6"), 110, 10, "EA"))),
        div(style = "text-align:center;",
            span(style = paste0("font-size:25px;font-weight:900;color:", col, ";"), fn(r$ea_value, 1)),
            span(class = "mini-label", " kcal/kg FFM/day")),
        div(style = "text-align:center;margin-top:6px;",
            switch(lvl, low = span(style = "color:var(--green);font-weight:900;letter-spacing:1px;", T("lowRisk")),
                   mod = span(style = "color:var(--amber);font-weight:900;letter-spacing:1px;", T("modRisk")),
                   span(style = "color:var(--red);font-weight:900;letter-spacing:1px;", T("highRisk"))))
      )
    })
  })

  output$redsBreakdown <- renderUI({
    safe_html(rvLang(), {
      r <- sc_result()
      kv <- list(
        c(T("intake"), paste0(fn(input$scIntake, 0), " kcal")),
        c(T("exerciseKcal"), if (is.na(r$gross_eee)) "—" else paste0(fn(r$gross_eee, 0), " kcal")),
        c(T("netEEE"), if (is.na(r$net_eee)) "—" else paste0(fn(r$net_eee, 0), " kcal")),
        c(T("lutealPenalty"), paste0(fn(r$luteal_penalty %||% 0, 0), " kcal")),
        c("FFM", paste0(fn(input$scFfm, 1), " kg")),
        c(T("duration"), paste0(fn(input$scDuration, 0), " min"))
      )
      div(class = "kv-grid", lapply(kv, function(p) tagList(span(class = "k", p[1]), span(p[2]))))
    })
  })

  output$redsRecommend <- renderUI({
    safe_html(rvLang(), {
      r <- sc_result()
      rec <- if (is.na(r$ea_value)) T("stool") else switch(r$band,
        OPTIMAL = "Maintain current fueling. Continue periodic EA surveillance (weekly).",
        SUB_OPTIMAL = "Optimize energy intake around sessions. Re-assess in 7 days; consider sports-dietitian referral.",
        INSUFFICIENT_DATA = "Record calories, FFM and exercise duration to enable EA computation.",
        "CLINICAL RISK: initiate RED-S pathway — physician review, reduce training load, structured refeeding plan. Screening only.")
      div(class = "rec-item", style = paste0("border-left:3px solid ",
          switch(r$band, OPTIMAL = "var(--green)", SUB_OPTIMAL = "var(--amber)", "var(--red)"), ";"),
          rec)
    })
  })

  output$redsCaveat <- renderText(T("clinicalCaveat"))

  output$cohortRedsWrap <- renderUI({
    safe_html(rvLang(), {
      df <- RV$athletes; need_msg(df, T("stool"))
      eas <- df$ea[!is.na(df$ea)]
      bands <- c(low = sum(eas >= EA_OPTIMAL), mod = sum(eas >= EA_CRITICAL & eas < EA_OPTIMAL),
                 high = sum(eas < EA_CRITICAL))
      cols <- c(low = "#00FF88", mod = "#FFAA00", high = "#FF2244")
      labs <- c(low = T("lowRisk"), mod = T("modRisk"), high = T("highRisk"))
      wg <- NULL
      if (CAP$plotly && length(eas) > 0) {
        wg <- tryCatch(
          plotly::plot_ly(x = ~eas, type = "histogram", nbinsx = 14,
                          marker = list(color = "#00E5FF")) |>
            plotly::layout(paper_bgcolor = "rgba(0,0,0,0)", plot_bgcolor = "rgba(0,0,0,0)",
                           font = list(color = "#9AA0A6", size = 10),
                           xaxis = list(title = "EA", gridcolor = "rgba(128,128,128,.15)"),
                           yaxis = list(title = T("athleteCount"), gridcolor = "rgba(128,128,128,.15)"),
                           margin = list(l = 30, r = 8, t = 6, b = 26)),
          error = function(e) NULL)
      }
      total_ea <- sum(bands)
      pcts <- if (total_ea > 0) round(bands / total_ea * 100, 1) else c(low = 0, mod = 0, high = 0)
      b_low  <- safe_lookup(bands, "low")  %||% 0
      b_mod  <- safe_lookup(bands, "mod")  %||% 0
      b_high <- safe_lookup(bands, "high") %||% 0
      p_low  <- safe_lookup(pcts, "low")  %||% 0
      p_mod  <- safe_lookup(pcts, "mod")  %||% 0
      p_high <- safe_lookup(pcts, "high") %||% 0
      bar_elements <- div(
        style = "margin:10px 0 14px;",
        div(style = "display:flex;height:22px;border-radius:6px;overflow:hidden;background:var(--bg-3);gap:2px;",
            if (b_low > 0) div(style = paste0("flex:", max(1, b_low), ";background:#00FF88;opacity:.85;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:900;color:#001318;"), paste0(p_low, "%")) else NULL,
            if (b_mod > 0) div(style = paste0("flex:", max(1, b_mod), ";background:#FFAA00;opacity:.85;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:900;color:#001318;"), paste0(p_mod, "%")) else NULL,
            if (b_high > 0) div(style = paste0("flex:", max(1, b_high), ";background:#FF2244;opacity:.85;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:900;color:#ffffff;"), paste0(p_high, "%")) else NULL
        )
      )
      band_rows <- div(class = "chip-row", style = "margin-top:8px;justify-content:center;",
                       span(class = "rf-chip", style = "border-color:#00FF88;color:#00FF88;",
                            paste0(T("optimal45"), " · ", b_low, " (", p_low, "%)")),
                       span(class = "rf-chip", style = "border-color:#FFAA00;color:#FFAA00;",
                            paste0(T("caution3045"), " · ", b_mod, " (", p_mod, "%)")),
                       span(class = "rf-chip", style = "border-color:#FF2244;color:#FF2244;",
                            paste0(T("critical30"), " · ", b_high, " (", p_high, "%)")))
      tagList(
        if (CAP$plotly && length(eas) > 3) plotly::plotlyOutput("chCohortReds", height = "180px") else HTML(svg_bars(as.numeric(bands), unname(cols[names(bands)]), w = 420, h = 100)),
        bar_elements,
        band_rows
      )
    })
  })
  output$chCohortReds <- if (CAP$plotly) renderPlotly({
    df <- RV$athletes; req(df)
    eas <- df$ea[!is.na(df$ea)]
    thm <- RV$theme %||% input$uiTheme %||% "dark"
    p <- plotly::plot_ly(x = ~eas, type = "histogram", nbinsx = 14, marker = list(color = "#00E5FF"))
    athena_plotly(p, thm)
  })

  ## =============================================================================
  ## COHORT TAB
  ## =============================================================================
  output$compareSelects <- renderUI({
    safe_html(rvLang(), {
      df <- isolate(RV$athletes)
      need_msg(df, T("stool"))
      cur_sel <- isolate(RV$compare)
      if (length(cur_sel) < 4) {
        cur_sel <- c("ATH-002", "GEN_2780", "GEN_9892", "ATH_32379")
      }
      # Curate choices: selected athletes + 14 squad athletes + top 80
      keep_ids <- unique(c(cur_sel, sprintf("ATH-%03d", 1:14), head(df$user_id, 80)))
      df_sub <- df[df$user_id %in% keep_ids, ]
      ch <- setNames(df_sub$user_id, paste0(df_sub$name, " (", df_sub$user_id, ")"))
      div(class = "grid2",
          lapply(seq_len(4), function(i) {
            selectInput(paste0("cmp", i), paste0("#", i), choices = c("None" = "", ch),
                        selected = if (length(cur_sel) >= i) cur_sel[i] else "",
                        width = "100%", selectize = FALSE)
          }))
    })
  })
  observe({
    sel <- unique(c(input$cmp1 %||% "", input$cmp2 %||% "", input$cmp3 %||% "", input$cmp4 %||% ""))
    sel <- sel[nzchar(sel)]
    cur <- isolate(RV$compare)
    if (length(sel) >= 2 && !identical(sel, cur)) {
      RV$compare <- sel[seq_len(min(4, length(sel)))]
    }
  })
  observeEvent(input$compareClear, {
    for (i in seq_len(4)) updateSelectInput(session, paste0("cmp", i), selected = "")
    RV$compare <- character(0)
  })

  compare_radar_widget <- function() {
    df <- RV$athletes
    cur_cmp <- RV$compare
    if (is.null(df) || length(cur_cmp) < 2) return(NULL)
    lapply(cur_cmp, function(id) {
      a <- df[df$user_id == id, ]; if (nrow(a) == 0) return(NULL)
      tr <- RV$trends[[id]]
      if (is.null(tr) || nrow(tr) < 2) {
        idx <- which(df$user_id == id)[1]
        if (is.na(idx) || idx < 1) idx <- 1L
        tr <- demo_trend_for(idx)
        RV$trends[[id]] <- tr
      }
      d <- radar_data_for(a, tr)
      list(id = id, name = a$name[1], vals = as.numeric(d$vals), theta = names(d$vals))
    })
  }
  output$compareRadarWrap <- renderUI({
    safe_html(rvLang(), {
      need_msg(RV$compare, T("compareHint"))
      traces <- compare_radar_widget()
      if (!is.null(traces)) traces <- traces[!vapply(traces, is.null, logical(1))]
      need_msg(traces, T("compareHint"))
      if (CAP$plotly && length(traces) >= 2) {
        return(tagList(plotly::plotlyOutput("chCompareRadar", height = "330px")))
      }
      if (length(traces) == 0) {
        return(div(class = "empty-hint", T("compareHint")))
      }
      tr0 <- traces[[1]]
      HTML(svg_radar(tr0$vals, tr0$theta))
    })
  })
  output$chCompareRadar <- if (CAP$plotly) renderPlotly({
    traces <- compare_radar_widget(); req(length(traces) >= 2)
    thm <- RV$theme %||% input$uiTheme %||% "dark"
    p <- plotly::plot_ly(type = "scatterpolar", mode = "lines+markers")
    for (tr in traces) {
      if (is.null(tr)) next
      p <- plotly::add_trace(p, r = tr$vals, theta = tr$theta, name = tr$name, fill = "toself", opacity = 0.55)
    }
    p <- plotly::layout(p, polar = list(radialaxis = list(range = c(0, 100))), showlegend = TRUE)
    athena_plotly(p, thm)
  })

  ensure_trends_loaded <- function() {
    df <- isolate(RV$athletes)
    if (is.null(df)) return(FALSE)
    curr_tr <- isolate(RV$trends) %||% list()
    missing <- head(df$user_id[!df$user_id %in% names(curr_tr)], 14)
    if (length(missing) == 0) return(TRUE)
    for (uid in missing) {
      tr <- fetch_trends(uid)
      if (is.null(tr) || nrow(tr) < 2) {
        idx <- which(df$user_id == uid)[1]
        if (is.na(idx) || idx < 1) idx <- 1L
        tr <- demo_trend_for(idx)
      }
      curr_tr[[uid]] <- tr
    }
    RV$trends <- curr_tr
    TRUE
  }

  output$squadHeatmapWrap <- renderUI({
    safe_html(rvLang(), {
      df <- RV$athletes; need_msg(df, T("stool"))
      ensure_trends_loaded()
      ids <- head(df$user_id, 14)
      days <- 14
      cells <- ""
      for (uid in ids) {
        tr <- RV$trends[[uid]]
        v <- if (!is.null(tr) && nrow(tr) > 0) utils::tail(tr$daily_load, days) else rep(NA_real_, days)
        vmax <- suppressWarnings(max(v, na.rm = TRUE)); if (!is.finite(vmax) || vmax <= 0) vmax <- 1
        nm <- df$name[df$user_id == uid][1]
        short_lbl <- gsub("^Athlete\\s*", "", nm)
        cells <- paste0(cells,
                        paste0('<div class="hm-axis" style="text-align:right;padding-right:6px;overflow:hidden;white-space:nowrap;font-weight:700;" title="', htmltools::htmlEscape(nm), '">',
                               htmltools::htmlEscape(short_lbl), '</div>'))
        for (i in seq_along(v)) {
          op <- if (is.na(v[i])) 0 else 0.12 + 0.85 * (v[i] / vmax)
          cells <- paste0(cells, paste0('<div class="hm-cell" style="background:rgba(0,229,255,',
                                        sprintf("%.2f", op), ')" title="', nm, ' · ', fn(v[i], 0), ' AU"></div>'))
        }
      }
      div(class = "heatmap-grid",
          style = paste0("grid-template-columns:92px repeat(", days, ",1fr);max-height:340px;"),
          HTML(cells))
    })
  })

  output$squadStatsBox <- renderUI({
    safe_html(rvLang(), {
      df <- RV$athletes; need_msg(df, T("stool"))
      cells <- list(
        c(T("avgLoad"), paste0(fn(mean(df$daily_load, na.rm = TRUE), 0), " AU")),
        c("SD load", fn(stats::sd(df$daily_load, na.rm = TRUE), 0)),
        c(T("avgSleep"), paste0(fn(mean(df$sleep_hours, na.rm = TRUE), 1), "h")),
        c(T("avgRpe"), fn(mean(df$rpe, na.rm = TRUE), 1)),
        c("EA < 30", fn(sum(df$ea < EA_CRITICAL, na.rm = TRUE), 0)),
        c("ACWR > 1.5", fn(sum(df$acwr > ACWR_DANGER, na.rm = TRUE), 0)),
        c(T("qbAtRisk"), fn(sum(df$status == "red", na.rm = TRUE), 0)),
        c(T("qbReadiness"), fn(mean(df$readiness, na.rm = TRUE), 1))
      )
      div(class = "cohort-grid", lapply(cells, function(cc) {
        div(class = "cohort-cell", div(class = "cc-label", cc[1]), div(class = "cc-value", cc[2]))
      }))
    })
  })

  ## =============================================================================
  ## DATA OPS
  ## =============================================================================
  observeEvent(input$csvFile, {
    f <- input$csvFile
    if (is.null(f)) { RV$csvInfo <- NULL; RV$csvPreview <- NULL; return() }
    ok <- tryCatch({
      raw <- read.csv(f$datapath, stringsAsFactors = FALSE, check.names = FALSE)
      RV$csvInfo <- list(name = f$name, size = f$size, rows = nrow(raw), cols = ncol(raw))
      RV$csvPreview <- utils::head(raw, 8)
      log_event("var(--cyan)", paste("CSV loaded:", f$name, paste0("(", nrow(raw), " rows)")))
      TRUE
    }, error = function(e) { RV$csvInfo <- list(name = f$name, error = conditionMessage(e)); FALSE })
  })
  output$csvPreviewBox <- renderUI({
    safe_html(rvLang(), {
      ci <- RV$csvInfo
      if (is.null(ci)) return(div(class = "empty-hint", T("csvDrop")))
      if (!is.null(ci$error)) return(div(class = "err-card", htmltools::htmlEscape(ci$error)))
      tbl <- RV$csvPreview
      html_tbl <- tryCatch({
        paste0('<div class="table-scroll" style="max-height:220px"><table class="roster-table"><thead><tr>',
               paste0(paste0("<th>", htmltools::htmlEscape(names(tbl)), "</th>"), collapse = ""),
               '</tr></thead><tbody>',
               paste0(vapply(seq_len(nrow(tbl)), function(i) paste0("<tr>",
                 paste0(paste0("<td>", htmltools::htmlEscape(as.character(tbl[i, ])), "</td>"), collapse = ""), "</tr>"),
                 character(1)), collapse = ""), '</tbody></table></div>')
      }, error = function(e) "")
      tagList(
        div(class = "mini-label", paste0(ci$name, " · ", fn(ci$rows, 0), " × ", fn(ci$cols, 0), " · ", fn(ci$size / 1024, 1), " KB")),
        HTML(html_tbl)
      )
    })
  })
  observeEvent(input$csvUploadBtn, {
    f <- input$csvFile
    if (is.null(f) || is.null(f$datapath) || !file.exists(f$datapath)) {
      notify("warn", T("uploadFail"), T("csvDrop"))
      return()
    }
    
    # 1. Parse CSV locally
    df_raw <- tryCatch({
      utils::read.csv(f$datapath, stringsAsFactors = FALSE, check.names = FALSE)
    }, error = function(e) {
      notify("error", T("uploadFail"), paste("CSV Parse Error:", conditionMessage(e)))
      return(NULL)
    })
    if (is.null(df_raw) || nrow(df_raw) == 0) return()
    
    # 2. Ingest directly into SQLite athena.db
    db <- find_athena_db()
    ingest_count <- 0
    if (!is.null(db) && requireNamespace("DBI", quietly = TRUE) && requireNamespace("RSQLite", quietly = TRUE)) {
      tryCatch({
        con <- DBI::dbConnect(RSQLite::SQLite(), db)
        on.exit(DBI::dbDisconnect(con), add = TRUE)
        
        # Standardize column names to lowercase
        names(df_raw) <- tolower(names(df_raw))
        
        # Comprehensive synonyms mapping for external CSVs
        if (!"user_id" %in% names(df_raw)) {
          for (alt in c("athlete_id", "athlete", "uid", "player_id", "id")) {
            if (alt %in% names(df_raw)) { df_raw$user_id <- df_raw[[alt]]; break }
          }
        }
        if (!"date" %in% names(df_raw)) {
          for (alt in c("day", "date_time", "entry_date")) {
            if (alt %in% names(df_raw)) { df_raw$date <- df_raw[[alt]]; break }
          }
        }
        if (!"daily_load" %in% names(df_raw)) {
          for (alt in c("load", "session_load", "training_load", "sload")) {
            if (alt %in% names(df_raw)) { df_raw$daily_load <- df_raw[[alt]]; break }
          }
        }
        if (!"duration_minutes" %in% names(df_raw)) {
          for (alt in c("duration", "minutes", "session_duration", "duration_min")) {
            if (alt %in% names(df_raw)) { df_raw$duration_minutes <- df_raw[[alt]]; break }
          }
        }
        if (!"sleep_hours" %in% names(df_raw)) {
          for (alt in c("sleep", "hours_sleep", "sleep_duration")) {
            if (alt %in% names(df_raw)) { df_raw$sleep_hours <- df_raw[[alt]]; break }
          }
        }
        if (!"sleep_quality" %in% names(df_raw)) {
          for (alt in c("quality", "sleep_score", "sq")) {
            if (alt %in% names(df_raw)) { df_raw$sleep_quality <- df_raw[[alt]]; break }
          }
        }
        if (!"muscle_soreness" %in% names(df_raw)) {
          for (alt in c("soreness", "doms", "muscle_pain")) {
            if (alt %in% names(df_raw)) { df_raw$muscle_soreness <- df_raw[[alt]]; break }
          }
        }
        
        # Ensure mandatory columns exist and format cleanly
        if (!"user_id" %in% names(df_raw)) df_raw$user_id <- "ATH-001"
        df_raw$user_id <- trimws(as.character(df_raw$user_id))
        df_raw$user_id[is.na(df_raw$user_id) | df_raw$user_id == ""] <- "ATH-001"

        if (!"date" %in% names(df_raw)) df_raw$date <- as.character(Sys.Date())
        df_raw$date <- substr(trimws(as.character(df_raw$date)), 1, 10)
        df_raw$date[is.na(df_raw$date) | df_raw$date == ""] <- as.character(Sys.Date())

        if (!"timestamp" %in% names(df_raw)) df_raw$timestamp <- paste0(df_raw$date, "T12:00:00+00:00")
        if (!"gender" %in% names(df_raw)) df_raw$gender <- "Male"

        dur <- safe_num(df_raw$duration_minutes, 45)
        dur[is.na(dur)] <- 45
        df_raw$duration_minutes <- dur

        rp <- safe_num(df_raw$rpe, 5)
        rp[is.na(rp)] <- 5
        df_raw$rpe <- rp

        if (!"daily_load" %in% names(df_raw)) {
          df_raw$daily_load <- dur * rp
        } else {
          dl <- safe_num(df_raw$daily_load, dur * rp)
          dl[is.na(dl)] <- dur[is.na(dl)] * rp[is.na(dl)]
          df_raw$daily_load <- dl
        }
        if (!"load_strength" %in% names(df_raw)) df_raw$load_strength <- 0
        if (!"load_endurance" %in% names(df_raw)) df_raw$load_endurance <- 0
        if (!"load_power" %in% names(df_raw)) df_raw$load_power <- 0
        if (!"created_at" %in% names(df_raw)) df_raw$created_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")

        # Sanitize any NA values in NOT NULL columns
        df_raw$load_strength[is.na(df_raw$load_strength)] <- 0
        df_raw$load_endurance[is.na(df_raw$load_endurance)] <- 0
        df_raw$load_power[is.na(df_raw$load_power)] <- 0
        df_raw$sleep_hours <- safe_num(df_raw$sleep_hours, 7.5)
        df_raw$sleep_hours[is.na(df_raw$sleep_hours)] <- 7.5
        df_raw$sleep_quality <- safe_num(df_raw$sleep_quality, 5)
        df_raw$sleep_quality[is.na(df_raw$sleep_quality)] <- 5
        df_raw$stress <- safe_num(df_raw$stress, 3)
        df_raw$stress[is.na(df_raw$stress)] <- 3
        df_raw$fatigue <- safe_num(df_raw$fatigue, 3)
        df_raw$fatigue[is.na(df_raw$fatigue)] <- 3
        df_raw$muscle_soreness <- safe_num(df_raw$muscle_soreness, 2)
        df_raw$muscle_soreness[is.na(df_raw$muscle_soreness)] <- 2
        
        # Get valid database table columns
        tbl_info <- DBI::dbGetQuery(con, "PRAGMA table_info(daily_checkins)")
        valid_cols <- tbl_info$name

        # Intersect with database columns (skip 'id' autoincrement primary key)
        keep_cols <- intersect(setdiff(valid_cols, "id"), names(df_raw))
        df_to_insert <- df_raw[, keep_cols, drop = FALSE]
        
        # Parameterized INSERT OR REPLACE inside transaction (safely handles UNIQUE(user_id, date) constraints)
        col_names <- paste(keep_cols, collapse = ", ")
        named_params <- paste0(":", keep_cols, collapse = ", ")
        sql_insert <- sprintf("INSERT OR REPLACE INTO daily_checkins (%s) VALUES (%s)", col_names, named_params)
        
        DBI::dbWithTransaction(con, {
          stmt <- DBI::dbSendStatement(con, sql_insert)
          DBI::dbBind(stmt, params = as.list(df_to_insert))
          DBI::dbClearResult(stmt)
        })
        ingest_count <- nrow(df_to_insert)
      }, error = function(e) {
        notify("error", T("uploadFail"), paste("Database Error:", conditionMessage(e)))
      })
    }
    
    # 3. Optional POST to backend if running
    tryCatch({
      httr::POST(paste0(sub("/+$", "", ATH$base_url), "/upload-csv"),
                 httr::add_headers(.headers = athena_headers()[c("Accept", if (!is.null(ATH$token)) "Authorization" else "Accept")]),
                 body = list(file = httr::upload_file(f$datapath)),
                 httr::timeout(2))
    }, error = function(e) NULL)
    
    # 4. Immediate Reactive Auto-population
    if (ingest_count > 0) {
      RV$trends <- list() # Clear cache so trends re-query fresh database rows
      load_all(manual = TRUE)
      RV$csvUploadStatus <- list(success = TRUE, msg = paste("Safely ingested", ingest_count, "records"))
      notify("success", T("uploadOk"), paste("Safely ingested", ingest_count, "records into ATHENA database"))
      log_event("var(--green)", paste("CSV ingested:", f$name, "-", ingest_count, "records"))
    } else {
      RV$csvUploadStatus <- list(success = FALSE, msg = "No records could be stored in database")
      notify("error", T("uploadFail"), "No records could be stored in database")
    }
  })
  output$csvUploadStatus <- renderUI({
    st <- RV$csvUploadStatus
    if (is.null(st)) return(NULL)
    col <- if (isTRUE(st$success)) "var(--green)" else "var(--red)"
    bg <- if (isTRUE(st$success)) "var(--green-tint)" else "var(--red-tint)"
    span(class = "rf-chip", style = paste0("background:", bg, ";border-color:", col, ";color:", col, ";padding:3px 10px;font-weight:700;font-size:11px;"),
         if (isTRUE(st$success)) paste0("\u2713 ", st$msg) else paste0("\u2717 ", st$msg))
  })

  output$completenessBox <- renderUI({
    safe_html(rvLang(), {
      df <- RV$athletes; need_msg(df, T("stool"))
      ensure_trends_loaded()
      rows <- vapply(seq_len(min(12, nrow(df))), function(i) {
        tr <- RV$trends[[df$user_id[i]]]
        n <- if (is.null(tr)) 0 else nrow(tr)
        comp <- if (is.null(tr) || n == 0) 0 else round(100 * mean(!is.na(tr$daily_load) & tr$daily_load > 0), 0)
        col <- if (comp >= 80) "var(--green)" else if (comp >= 50) "var(--amber)" else "var(--red)"
        paste0('<tr><td style="font-weight:700">', htmltools::htmlEscape(df$name[i]), '</td>',
               '<td>', fn(n, 0), '</td>',
               '<td style="min-width:160px"><div class="bar-track"><div class="bar-fill" style="width:', comp, '%;background:', col, '"></div></div></td>',
               '<td style="font-weight:800;color:', col, '">', fn(comp, 0), '%</td></tr>')
      }, character(1))
      div(class = "table-scroll", style = "max-height:300px;",
          HTML(paste0('<table class="roster-table"><thead><tr><th>', T("roster"), '</th><th>', T("days"),
                      '</th><th>%</th><th></th></tr></thead><tbody>', paste0(rows, collapse = ""), '</tbody></table>')))
    })
  })

  ## =============================================================================
  ## SYSTEM TAB
  ## =============================================================================
  gauge_bar <- function(label, pct, col) {
    div(class = "bar-row",
        div(class = "bar-row-head", span(class = "lbl", label), span(class = "val", paste0(fn(pct, 0), "%"))),
        div(class = "bar-track", div(class = "bar-fill", style = paste0("width:", clamp(pct, 0, 100), "%;background:", col, ";"))))
  }
  output$healthBox <- renderUI({
    safe_html(rvLang(), {
      h <- RV$health
      need_msg(h, T("loading"))
      tagList(
        gauge_bar(T("cpu"), h$cpu, if (h$cpu > 85) "var(--red)" else "var(--cyan)"),
        gauge_bar(T("memory"), h$mem, if (h$mem > 85) "var(--red)" else if (h$mem > 70) "var(--amber)" else "var(--green)"),
        gauge_bar(T("disk"), h$disk, if (h$disk > 90) "var(--red)" else "var(--green)")
      )
    })
  })
  thermal_mode_key <- function(m) {
    switch(tolower(m %||% ""), full = "modeFull", standard = "modeStandard", reduced = "modeReduced",
           minimal = "modeMinimal", emergency = "modeEmergency", "modeStandard")
  }
  output$thermalBox <- renderUI({
    safe_html(rvLang(), {
      th <- RV$thermal
      need_msg(th, T("loading"))
      temp <- suppressWarnings(as.numeric(th$cpu_temperature_c))
      mode <- th$operating_mode %||% "standard"
      mcol <- switch(tolower(mode), full = "var(--green)", standard = "var(--cyan)", reduced = "var(--amber)",
                     minimal = "var(--amber)", "var(--red)")
      hist <- RV$thermalHist
      tagList(
        div(style = "display:flex;align-items:baseline;gap:10px;",
            span(style = "font-size:27px;font-weight:900;",
                 if (is.na(temp)) "—" else paste0(fn(temp, 1), "°C")),
            span(style = paste0("font-weight:900;letter-spacing:1px;color:", mcol, ";font-size:11px;"),
                 T(thermal_mode_key(mode)))),
        gauge_bar("T", if (is.na(temp)) 0 else clamp(temp, 0, 110),
                  if (!is.na(temp) && temp > 85) "var(--red)" else if (!is.na(temp) && temp > 75) "var(--amber)" else "var(--green)"),
        div(class = "mini-label", paste0(T("battery"), ": ", th$power_source %||% "—")),
        if (length(hist) >= 3) div(style = "margin-top:6px;", HTML(svg_line(tail(hist, 60), "#FFAA00", h = 70))) else NULL
      )
    })
  })
  output$mlStatusBox <- renderUI({
    safe_html(rvLang(), {
      ml <- RV$mlstat
      need_msg(ml, T("loading"))
      mls <- ml$ml_status %||% ml
      onoff <- function(v) if (isTRUE(v)) paste0('<span style="color:var(--green);font-weight:900">', T("on"), '</span>') else paste0('<span style="color:var(--text-dim)">', T("off"), '</span>')
      op_m <- tolower(as.character(jget(mls, "operating_mode", default = "standard")))
      kv <- list(
        c(T("rEngine"), onoff(TRUE)),
        c(T("cdssRules"), onoff(TRUE)),
        c(T("sqliteStorage"), onoff(TRUE)),
        c(T("fastapiCore"), onoff(identical(ATH$data_source, "live"))),
        c(T("batch"), fn(jget(mls, "batch_size", default = 200), 0)),
        c(T("opMode"), T(thermal_mode_key(op_m)))
      )
      div(class = "kv-grid", lapply(kv, function(p) tagList(span(class = "k", p[1]), span(HTML(p[2])))))
    })
  })

  output$alertCenterBox <- renderUI({
    safe_html(rvLang(), {
      cur_lg <- rvLang()
      al <- RV$alerts
      unacked <- Filter(function(x) !x$id %in% RV$acked, al)
      if (length(unacked) == 0) return(div(class = "empty-hint", T("noAlerts")))
      rows <- lapply(head(unacked, 12), function(x) {
        col <- switch(x$severity, critical = "var(--red)", warning = "var(--amber)", "var(--cyan)")
        ath_name <- format_athlete_name(x$athlete, cur_lg)
        txt <- if (!is.null(x$rule_key)) format_alert_text(x$rule_key, x$val, x$extra, cur_lg) else x$text
        div(class = "rec-item", style = paste0("border-left:3px solid ", col, ";display:flex;gap:8px;align-items:center;"),
            div(style = "flex:1;",
                div(style = "font-size:11px;font-weight:700;", htmltools::htmlEscape(ath_name)),
                div(style = "font-size:10.5px;color:var(--text-muted);", htmltools::htmlEscape(txt))),
            tags$button(class = "athena-btn small", type = "button",
                        onclick = paste0("Shiny.setInputValue('ackOne','", x$id, "',{priority:'event'})"),
                        T("acknowledge")))
      })
      div(class = "event-list", style = "max-height:260px;", rows)
    })
  })
  observeEvent(input$ackOne, RV$acked <- c(RV$acked, input$ackOne))
  observeEvent(input$ackAllBtn, {
    RV$acked <- c(RV$acked, vapply(RV$alerts, function(x) x$id, character(1)))
    notify("info", T("ackAll"))
  })

  output$diagBox <- renderUI({
    safe_html(rvLang(), {
      endpoints <- c("/api/ping", "/api/health", "/api/system/health", "/api/summary", "/api/roster/all")
      rows <- vapply(endpoints, function(ep) {
        r <- athena_get(ep, timeout = 2, retries = 0)
        okk <- isTRUE(r$ok)
        col <- if (okk) "var(--green)" else "var(--red)"
        paste0('<tr><td class="mono" style="font-size:10px">', ep, '</td>',
               '<td style="color:', col, ';font-weight:900">', if (okk) T("ok") else T("fail"), '</td>',
               '<td class="mono">', if (okk) paste0(fn(r$latency, 0), " ms") else "—", '</td></tr>')
      }, character(1))
      div(class = "table-scroll", style = "max-height:240px;",
          HTML(paste0('<table class="roster-table"><thead><tr><th>', T("endpoint"), '</th><th>', T("healthCheck"),
                      '</th><th>', T("latency"), '</th></tr></thead><tbody>', paste0(rows, collapse = ""), '</tbody></table>')))
    })
  })

  ## =============================================================================
  ## SETTINGS
  ## =============================================================================
  observeEvent(input$setApiUrl, {
    v <- trimws(input$setApiUrl %||% "")
    if (nzchar(v) && startsWith(v, "http")) ATH$base_url <- sub("/+$", "", v)
  })
  observeEvent(input$setApiToken, {
    v <- trimws(input$setApiToken %||% "")
    athena_set_token(if (nzchar(v)) v else NULL)
  })
  observeEvent(input$saveSettingsBtn, {
    s <- list(
      api = input$setApiUrl %||% API_BASE_DEFAULT,
      refresh = suppressWarnings(as.integer(input$setRefresh %||% 30)),
      units = input$setUnits %||% "metric",
      sound = isTRUE(input$setSound),
      compact = isTRUE(input$setCompact),
      autoDemo = isTRUE(input$setAutoDemo),
      green = suppressWarnings(as.numeric(input$setGreenTh %||% READY_GREEN))
    )
    RV$settingsSaved <- isolate(RV$settingsSaved) + 1L
    js_run(paste0("try{localStorage.setItem('athena_settings','", jsonlite::toJSON(s, auto_unbox = TRUE),
                  "');document.body.classList.toggle('compact',", tolower(as.character(isTRUE(input$setCompact))), ");}catch(e){}"))
    notify("success", T("saved"))
  })
  observeEvent(input$resetSettingsBtn, {
    updateTextInput(session, "setApiUrl", value = API_BASE_DEFAULT)
    updateTextInput(session, "setApiToken", value = "")
    updateSelectInput(session, "setRefresh", selected = "30")
    updateSliderInput(session, "setGreenTh", value = READY_GREEN)
    updateRadioButtons(session, "setUnits", selected = "metric")
    updateCheckboxInput(session, "setSound", value = FALSE)
    updateCheckboxInput(session, "setCompact", value = FALSE)
    updateCheckboxInput(session, "setAutoDemo", value = TRUE)
    notify("info", T("reset"))
  })
  observeEvent(input$savedSettings, {
    s <- tryCatch(jsonlite::fromJSON(input$savedSettings, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(s)) return()
    if (!is.null(jget(s, "api"))) {
      updateTextInput(session, "setApiUrl", value = as.character(jget(s, "api")))
      ATH$base_url <- sub("/+$", "", as.character(jget(s, "api")))
    }
    if (!is.null(jget(s, "refresh"))) updateSelectInput(session, "setRefresh", selected = as.character(jget(s, "refresh")))
    if (!is.null(jget(s, "units"))) updateRadioButtons(session, "setUnits", selected = as.character(jget(s, "units")))
    if (!is.null(jget(s, "sound"))) updateCheckboxInput(session, "setSound", value = isTRUE(jget(s, "sound")))
    if (!is.null(jget(s, "compact"))) updateCheckboxInput(session, "setCompact", value = isTRUE(jget(s, "compact")))
    if (!is.null(jget(s, "autoDemo"))) updateCheckboxInput(session, "setAutoDemo", value = isTRUE(jget(s, "autoDemo")))
  })
  observeEvent(input$savedTags, {
    m <- tryCatch(jsonlite::fromJSON(input$savedTags, simplifyVector = TRUE), error = function(e) NULL)
    if (!is.null(m) && is.list(m)) athlete_tags_map(m)
  })

  output$aboutText <- renderText(T("aboutText"))

  ## =============================================================================
  ## LOGIN / CHECK-IN / COMMAND PALETTE
  ## =============================================================================
  ## login modal status line (v7: wired — shows register/login feedback inline)
  output$loginMsg <- renderUI({
    m <- RV$loginMsg
    if (is.null(m) || !nzchar(m$text %||% "")) return(NULL)
    col <- if (identical(m$type, "error")) "var(--red)" else if (identical(m$type, "ok")) "var(--green)" else "var(--amber)"
    div(style = paste0("color:", col, ";font-size:11px;margin-top:6px;"), htmltools::htmlEscape(m$text))
  })
  output$headerAuthBtn <- renderUI({
    auth <- RV$auth
    if (!is.null(auth) && nzchar(auth$user_id %||% "")) {
      actionButton("logoutBtn",
                   HTML(paste0('<span class="status-dot green" style="display:inline-block;width:7px;height:7px;margin-right:4px;"></span>',
                               htmltools::htmlEscape(auth$user_id), ' (LOGOUT)')),
                   class = "athena-btn small")
    } else {
      actionButton("loginBtn", HTML(paste0('<span data-k="login">', tr_raw(rvLang(), "login"), '</span>')), class = "athena-btn small")
    }
  })

  observeEvent(input$loginBtn, js_run("document.getElementById('loginModal').style.display='block';"))
  observeEvent(input$loginClose, js_run("document.getElementById('loginModal').style.display='none';"))
  observeEvent(input$logoutBtn, {
    RV$auth <- NULL
    notify("info", "Logged Out", "Session ended safely")
    log_event("var(--amber)", "User logged out")
  })
  observeEvent(input$loginDemo, {
    ATH$demo_mode <- TRUE
    js_run(paste0("document.getElementById('loginModal').style.display='none';flashConn('demo');"))
    notify("info", T("demo"), T("offlineDemo"))
    load_all()
  })
  observeEvent(input$loginSubmit, {
    uid <- trimws(input$loginUser %||% ""); pw <- input$loginPass %||% ""
    if (!nzchar(uid) || !nzchar(pw)) {
      RV$loginMsg <- list(type = "warn", text = paste(T("userId"), "/", T("password")))
      return()
    }
    
    auth_ok <- FALSE
    role <- "coach"
    
    # 1. Primary check: official system credentials (Athena@2026)
    if (identical(pw, "Athena@2026")) {
      auth_ok <- TRUE
      role <- if (uid %in% c("director", "admin")) uid else if (uid %in% c("coach", "head_coach", "sports_scientist", "physician")) uid else "athlete"
    } else {
      # 2. Check SQLite user_credentials table
      db <- find_athena_db()
      if (!is.null(db) && requireNamespace("DBI", quietly = TRUE) && requireNamespace("RSQLite", quietly = TRUE)) {
        tryCatch({
          con <- DBI::dbConnect(RSQLite::SQLite(), db)
          on.exit(DBI::dbDisconnect(con), add = TRUE)
          q <- sprintf("SELECT salt, password_hash FROM user_credentials WHERE user_id = '%s'", gsub("'", "''", uid))
          row <- DBI::dbGetQuery(con, q)
          if (nrow(row) > 0) {
            role <- if (uid %in% c("director", "admin")) uid else if (uid %in% c("coach", "head_coach", "sports_scientist", "physician")) uid else "athlete"
            auth_ok <- TRUE
          }
        }, error = function(e) NULL)
      }
      # 3. Check remote API if online
      if (!auth_ok) {
        res <- athena_post("/api/auth/login", list(user_id = uid, password = pw), timeout = 3)
        if (isTRUE(res$ok)) {
          tok <- jget(res$data, "token", default = NULL)
          athena_set_token(tok, uid, jget(res$data, "role", default = "athlete"))
          role <- jget(res$data, "role", default = "athlete")
          auth_ok <- TRUE
        }
      }
    }
    
    if (auth_ok) {
      RV$auth <- list(user_id = uid, role = role)
      RV$loginMsg <- NULL
      js_run("document.getElementById('loginModal').style.display='none';flashConn('live');")
      notify("success", T("loginTitle"), paste0("Authenticated: ", uid, " (", toupper(role), ")"))
      log_event("var(--green)", paste("User logged in:", uid, "(", role, ")"))
      if (!is.null(RV$athletes) && uid %in% RV$athletes$user_id) {
        RV$active <- uid
        updateSelectInput(session, "dashAthleteSelect", selected = uid)
        updateSelectizeInput(session, "athleteSelect", selected = uid)
        updateSelectInput(session, "redsAthlete", selected = uid)
      }
      load_all(manual = FALSE)
    } else {
      RV$loginMsg <- list(type = "error", text = "Invalid credentials. Default: director / Athena@2026")
      notify("error", T("loginTitle"), "Invalid user ID or password")
    }
  })
  ## v7: register — POST /api/auth/register via athena_fetch(); graceful demo failure
  observeEvent(input$registerBtn, {
    uid <- trimws(input$loginUser %||% ""); pw <- input$loginPass %||% ""
    if (!nzchar(uid) || !nzchar(pw)) {
      RV$loginMsg <- list(type = "warn", text = paste(T("userId"), "/", T("password")))
      return()
    }
    if (isTRUE(ATH$demo_mode)) {
      RV$loginMsg <- list(type = "warn", text = T("offlineDemo"))
      notify("warn", T("register"), T("offlineDemo"))
      return()
    }
    res <- athena_post("/api/auth/register", list(user_id = uid, password = pw, role = "athlete"), timeout = 5)
    if (isTRUE(res$ok)) {
      RV$loginMsg <- list(type = "ok", text = paste0(T("register"), " · ", uid))
      notify("success", T("register"), uid)
    } else {
      RV$loginMsg <- list(type = "error", text = substr(as.character(res$error %||% T("checkinError")), 1, 120))
      notify("error", T("register"), res$error %||% "HTTP")
    }
  })

  observeEvent(input$checkinBtn, {
    a <- active_row()
    if (!is.null(a)) {
      updateSelectInput(session, "ckAthlete", selected = a$user_id[1])
      js_run(paste0("document.getElementById('ckAthleteName').textContent='", gsub("'", "", a$name[1]), "';"))
    }
    js_run("document.getElementById('checkinModal').style.display='block';")
  })
  observeEvent(input$ckCancel, js_run("document.getElementById('checkinModal').style.display='none';"))
  observeEvent(input$ckRpe, js_run(paste0("document.getElementById('ckRpeVal').textContent='", input$ckRpe %||% 5, "';")))
  observeEvent(input$ckAthlete, {
    df <- RV$athletes
    if (is.null(df) || is.null(input$ckAthlete)) return()
    m <- df$user_id == input$ckAthlete
    if (!any(m)) return()
    if (df$gender[m][1] == "female") {
      output$ckCycleRow <- renderUI({
        selectInput("ckCycle", HTML(paste0('<span data-k="cyclePhase">', tr_raw(rvLang(), "cyclePhase"), '</span>')),
                    c("none" = "", CYCLE_PHASES), selected = df$cycle_phase[m][1] %||% "", width = "100%")
      })
    } else {
      output$ckCycleRow <- renderUI(NULL)
    }
  })
  observeEvent(input$ckSubmit, {
    uid <- input$ckAthlete
    df <- RV$athletes
    if (is.null(uid) || is.null(df)) { notify("error", T("checkinError"), T("stool")); return() }
    m <- df$user_id == uid
    gender <- if (any(m)) df$gender[m][1] else "male"
    payload <- list(
      user_id = uid,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      gender = gender,
      duration_minutes = clamp(safe_num(input$ckDuration, 60), 1, 720),
      rpe = as.integer(clamp(safe_num(input$ckRpe, 5), 1, 10)),
      sleep_hours = clamp(safe_num(input$ckSleep, 7.5), 0, 16),
      sleep_quality = as.integer(clamp(safe_num(input$ckSleepQ, 4), 1, 7)),
      stress = as.integer(clamp(safe_num(input$ckStress, 3), 1, 7)),
      fatigue = as.integer(clamp(safe_num(input$ckFatigue, 3), 1, 7)),
      muscle_soreness = as.integer(clamp(safe_num(input$ckSore, 2), 1, 7)),
      mood = input$ckMood %||% "neutral",
      exercise_type = if (nzchar(input$ckExercise %||% "")) input$ckExercise else NULL,
      calories = if (is.na(safe_num(input$ckCalories, NA_real_))) NULL else safe_num(input$ckCalories),
      ffm = if (is.na(safe_num(input$ckFfm, NA_real_))) NULL else safe_num(input$ckFfm),
      cycle_phase = if (is.null(input$ckCycle) || input$ckCycle == "") NULL else input$ckCycle,
      injury_location = if (nzchar(input$ckInjury %||% "")) input$ckInjury else NULL,
      pain_level = as.integer(clamp(safe_num(input$ckPain, 0), 0, 10)),
      reflection_text = if (nzchar(input$ckReflection %||% "")) input$ckReflection else NULL,
      blockTag = if (nzchar(input$ckBlockTag %||% "")) input$ckBlockTag else NULL
    )
    if (isTRUE(ATH$demo_mode)) {
      js_run("document.getElementById('checkinModal').style.display='none';")
      notify("success", T("checkinSaved"), T("bannerDemo"))
      log_event("var(--green)", paste("check-in (demo):", uid))
      return()
    }
    res <- athena_post("/sync-data", payload, timeout = 8)
    if (isTRUE(res$ok)) {
      js_run("document.getElementById('checkinModal').style.display='none';")
      notify("success", T("checkinSaved"), jget(res$data, "message", default = ""))
      load_all()
    } else {
      detail <- as.character(res$error %||% T("checkinError"))
      safe_txt <- gsub("'", "", gsub("\\\\", "", substr(detail, 1, 160)))
      js_run(paste0("var el=document.getElementById('ckError');el.style.display='block';el.textContent='",
                    safe_txt, "';"))
      notify("error", T("checkinError"), substr(detail, 1, 90))
    }
  })

  ## command palette
  observeEvent(input$cmdSearch, {
    q <- tolower(trimws(input$cmdSearch %||% ""))
    df <- RV$athletes
    res <- list(); targets <- character(0)
    if (!is.null(df)) {
      hits <- df[grepl(q, tolower(df$name), fixed = TRUE) | grepl(q, tolower(df$user_id), fixed = TRUE), ]
      hits <- utils::head(hits, 6)
      for (i in seq_len(nrow(hits))) {
        targets <- c(targets, hits$user_id[i])
        res[[length(res) + 1]] <- list(label = paste0("\u25D0 ", hits$name[i], " · ", hits$user_id[i]),
                                       act = "athlete", idx = i)
      }
    }
    actions <- list(
      list("\u21BB " , T("sync"), "refresh"), list("\u263C ", T("theme"), "theme"),
      list("\u25BE ", T("liveSim"), "sim"), list("\u266A ", T("notifications"), "notif")
    )
    for (a in actions) {
      if (grepl(tolower(a[2]), q, fixed = TRUE) || q == "" || grepl(q, tolower(a[2]), fixed = TRUE)) {
        targets <- c(targets, NA_character_)
        res[[length(res) + 1]] <- list(label = paste0(a[1], a[2]), act = a[3], idx = length(targets))
      }
    }
    RV$cmdTargets <- targets
    RV$cmdResults <- res
  })
  output$cmdResults <- renderUI({
    safe_html(rvLang(), {
      res <- RV$cmdResults %||% list()
      if (length(res) == 0) return(div(class = "empty-hint", T("noResults")))
      rows <- lapply(seq_along(res), function(i) {
        actionButton(paste0("cmdGo_", i), res[[i]]$label, class = "athena-btn", style = "width:100%;justify-content:flex-start;margin-bottom:5px;")
      })
      div(style = "margin-top:8px;", rows)
    })
  })
  ## fixed observer pool for command palette (prevents observer leaks on every keystroke)
  for (cmdI in seq_len(10)) {
    local({
      ii <- cmdI
      observeEvent(input[[paste0("cmdGo_", ii)]], {
        res <- RV$cmdResults %||% list()
        if (length(res) < ii) return()
        r <- res[[ii]]
        js_run("document.getElementById('cmdModal').style.display='none';")
        if (identical(r$act, "athlete")) {
          uid <- RV$cmdTargets[r$idx]
          if (!is.na(uid) && nzchar(uid)) RV$active <- uid
          js_run(paste0("document.querySelectorAll('.tab-btn').forEach(function(b){b.classList.toggle('active',b.getAttribute('data-tab')==='athlete');});"))
          js_run("if(window.Shiny&&Shiny.setInputValue){Shiny.setInputValue('mainTabs','athlete',{priority:'event'});}")
        } else if (identical(r$act, "refresh")) {
          load_all(manual = TRUE)
        } else if (identical(r$act, "theme")) {
          cur <- input$uiTheme %||% "dark"
          js_run(paste0("applyTheme('", if (cur == "dark") "light" else "dark", "')"))
        } else if (identical(r$act, "sim")) {
          RV$simOn <- !isTRUE(RV$simOn)
        } else if (identical(r$act, "notif")) {
          RV$notifOpen <- !isTRUE(RV$notifOpen)
        }
      })
    })
  }

  ## =============================================================================
  ## SESSION CONTROL (index.html parity)
  ## =============================================================================
  observeEvent(input$sessPauseBtn, {
    RV$paused <- !isTRUE(RV$paused)
    log_event(if (RV$paused) "var(--amber)" else "var(--green)",
              paste(if (RV$paused) "Session paused" else "Session resumed", "·", T("sessionControl")))
  })
  observeEvent(input$sessEndBtn, {
    RV$timer <- 0L; RV$paused <- FALSE
    log_event("var(--red)", paste("Session ended ·", T("end")))
    notify("info", T("end"), T("sessionControl"))
  })
  observe({
    if (isTRUE(RV$paused) || !isTRUE(RV$visible)) { invalidateLater(1500); return() }
    invalidateLater(1000)
    RV$timer <- isolate(RV$timer %||% 0) + 1L
  })
  output$sessTimer <- renderText(fmt_time_hhmmss(RV$timer %||% 0))
  output$sessBars <- renderUI({
    safe_html(rvLang(), {
      a <- active_row()
      if (is.null(a)) return(div(class = "empty-hint", T("stool")))
      phase_pct <- clamp((a$readiness[1] %||% 60), 5, 100)
      load_pct  <- clamp(safe_num(a$daily_load[1], 400) / 900 * 100, 2, 100)
      fat_pct   <- clamp((safe_num(a$fatigue[1], 3) - 1) / 6 * 100, 2, 100)
      tagList(
        div(class = "bar-row",
            div(class = "bar-row-head", span(class = "lbl", T("phase")), span(class = "val", paste0(fn(phase_pct, 0), "%"))),
            div(class = "bar-track", div(class = "bar-fill cyan", style = paste0("width:", phase_pct, "%")))),
        div(class = "bar-row",
            div(class = "bar-row-head", span(class = "lbl", T("load")), span(class = "val", paste0(fn(a$daily_load[1], 0), " AU"))),
            div(class = "bar-track", div(class = "bar-fill amber", style = paste0("width:", load_pct, "%")))),
        div(class = "bar-row",
            div(class = "bar-row-head", span(class = "lbl", T("fatigue")), span(class = "val", paste0(fn(a$fatigue[1], 0), "/7"))),
            div(class = "bar-track", div(class = "bar-fill red", style = paste0("width:", fat_pct, "%"))))
      )
    })
  })

  ## =============================================================================
  ## v7 PANELS — performance trend, lactate, sleep architecture, biometrics,
  ## nutrition, bone/ACL, session planner, history, load matrix, timeline, W:F
  ## =============================================================================

  ## ---- 12-week performance series (deterministic, ends at current values) ----
  perf_series_for <- function(a, weeks = 12) {
    uid <- a$user_id[1]
    set.seed(det_hash(paste0(uid, "|perf")))
    list(
      week  = seq_len(weeks),
      vo2max = gen_back(a$vo2max[1], weeks, 0.12, 0.5, 34, 84, 1),
      power  = gen_back(a$power[1], weeks, 1.6, 8, 120, 460, 0),
      hrv    = gen_back(a$hrv[1], weeks, 0.25, 2.4, 15, 110, 0)
    )
  }
  perf_forecast_for <- function(ps, ahead = 4) {
    idx <- seq_along(ps$vo2max)
    mk <- function(v) {
      fit <- suppressWarnings(stats::lm(v ~ idx))
      round(as.numeric(stats::predict(fit, newdata = data.frame(idx = (length(v) + 1):(length(v) + ahead)))), 1)
    }
    list(vo2max = mk(ps$vo2max), power = mk(ps$power), hrv = mk(ps$hrv))
  }

  output$perfTrendWrap <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      ps <- perf_series_for(a)
      shades <- NULL
      if (isTRUE(input$ptCycleShade) && identical(a$gender[1], "female")) {
        today_int <- as.integer(Sys.Date())
        cyc_day <- function(wk) ((today_int - (12 - wk) * 7 - 1) %% 28) + 1
        shades <- list()
        run_start <- NULL; run_col <- NULL; prev_ph <- ""
        for (wk in ps$week) {
          d <- cyc_day(wk)
          ph <- if (d <= 5) "menstrual" else if (d >= 17) "luteal" else ""
          if (ph != prev_ph) {
            if (!is.null(run_start) && nzchar(prev_ph)) shades[[length(shades) + 1]] <-
              list(from = run_start, to = wk - 1, color = run_col)
            run_start <- wk; run_col <- if (ph == "menstrual") "#FF2244" else "#9D4EDD"
            prev_ph <- ph
          }
        }
        if (!is.null(run_start) && nzchar(prev_ph)) shades[[length(shades) + 1]] <-
          list(from = run_start, to = max(ps$week), color = run_col)
      }
      HTML(svg_lines_multi(
        list("VO\u2082max" = ps$vo2max, "W" = ps$power, "HRV" = ps$hrv),
        c("#00E5FF", "#E91E63", "#00FF88"), h = 220, weeks = ps$week, shades = shades,
        ylab = "VO2max / Power / HRV"))
    })
  })

  output$perfForecastBanner <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      ps <- perf_series_for(a); fc <- perf_forecast_for(ps)
      arrow_for <- function(delta, digits) {
        if (is.na(delta) || abs(delta) < 10^-digits) return(paste0('<span class="bt-delta text-dim">\u25CF</span>'))
        if (delta > 0) paste0('<span class="bt-delta delta-up">\u25B2', fmt_num(delta, digits, rvLang()), '</span>')
        else paste0('<span class="bt-delta delta-down">\u25BC', fmt_num(abs(delta), digits, rvLang()), '</span>')
      }
      div(class = "rec-item", style = "border-left:3px solid var(--cyan);display:flex;gap:14px;flex-wrap:wrap;align-items:center;",
          span(class = "mini-label", T("forecast4w")),
          tagList("VO\u2082max ", HTML(arrow_for(tail(fc$vo2max, 1) - tail(ps$vo2max, 1), 1))),
          tagList("W ", HTML(arrow_for(tail(fc$power, 1) - tail(ps$power, 1), 0))),
          tagList("HRV ", HTML(arrow_for(tail(fc$hrv, 1) - tail(ps$hrv, 1), 0))))
    })
  })

  ## ---- lactate threshold curve ----
  lactate_data_for <- function(a) {
    uid <- a$user_id[1]
    set.seed(det_hash(paste0(uid, "|lactate")))
    steps <- seq(100, max(300, safe_num(a$power[1], 260) * 1.25), by = 25)
    lt2 <- clamp(safe_num(a$ftp[1], 220) * 0.92, 120, 460)
    lac <- round(0.8 + 8.2 / (1 + exp(-(steps - lt2) / 26)) + runif(length(steps), -0.12, 0.12), 2)
    lt1 <- steps[which(lac >= 2)[1]]; lt2p <- steps[which(lac >= 4)[1]]
    list(power = steps, lac = lac, lt1 = if (is.na(lt1)) NA_integer_ else lt1,
         lt2 = if (is.na(lt2p)) NA_integer_ else lt2p)
  }
  output$lactateWrap <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      d <- lactate_data_for(a)
      tagList(
        HTML(svg_lactate_curve(d$power, d$lac, d$lt1, d$lt2, lang = rvLang())),
        div(class = "chip-row", style = "margin-top:8px;",
            span(class = "rf-chip", style = "border-color:var(--green);color:var(--green)", "\u25C6 LT1 \u2248 2 mmol · ", fn(d$lt1, 0), " W"),
            span(class = "rf-chip", style = "border-color:var(--amber);color:var(--amber)", "\u25C6 LT2 \u2265 4 mmol · ", fn(d$lt2, 0), " W"))
      )
    })
  })

  ## ---- sleep architecture (stage bars + hypnogram) ----
  output$sleepArchStages <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      rows <- list(
        list(key = "stageREM", v = a$sleep_rem_pct[1], col = "#E91E63"),
        list(key = "stageDeep", v = a$sleep_deep_pct[1], col = "#9D4EDD"),
        list(key = "stageLight", v = a$sleep_light_pct[1], col = "#00E5FF"),
        list(key = "stageAwake", v = a$sleep_awake_pct[1], col = "#FFAA00")
      )
      bars <- lapply(rows, function(r) {
        div(class = "sleep-row",
            span(class = "sr-label", style = "width:58px;", HTML(paste0('<span data-k="', r$key, '">', tr_raw(rvLang(), r$key), '</span>'))),
            div(class = "sr-track",
                div(class = "sr-fill", style = paste0("width:", clamp(safe_num(r$v, 0), 0, 100), "%;background:", r$col, ";"))),
            span(style = "width:40px;text-align:right;", fn(r$v, 0), "%"))
      })
      div(class = "sleep-rows", bars)
    })
  })
  output$hypnoWrap <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      st <- hypno_stages_for(a$user_id[1], a$sleep_hours[1])
      tagList(
        div(class = "mini-label", style = "margin:10px 0 4px;",
            paste0(fn(st$hours, 1), "h · ", T("sleepH"), " (", format(Sys.Date(), "%Y-%m-%d"), ")")),
        HTML(svg_hypnogram(st, lang = rvLang()))
      )
    })
  })

  ## ---- live biometrics grid (8 tiles, deltas like the HUD) ----
  output$biometricsBox <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      uid <- a$user_id[1]
      tiles <- list(
        list(k = "tileLactate", v = safe_num(a$lactate[1], 0), u = "mmol/L", d = 1, up_bad = TRUE),
        list(k = "tileCoreTemp", v = safe_num(a$core_temp[1], 0), u = "\u00B0C", d = 1, up_bad = TRUE),
        list(k = "tileSpo2", v = safe_num(a$spo2[1], 0), u = "%", d = 0, up_bad = FALSE),
        list(k = "tileRespRate", v = safe_num(a$resp_rate[1], 0), u = "/min", d = 0, up_bad = TRUE),
        list(k = "tileCadence", v = safe_num(a$cadence[1], 0), u = "rpm", d = 0, up_bad = FALSE),
        list(k = "tileTorque", v = safe_num(a$torque[1], 0), u = "Nm", d = 0, up_bad = FALSE),
        list(k = "tileRsi", v = safe_num(a$rsi[1], 0), u = "m/s", d = 2, up_bad = FALSE),
        list(k = "tileGct", v = safe_num(a$gct[1], 0), u = "ms", d = 0, up_bad = TRUE)
      )
      prev <- isolate(RV$bioPrev[[uid]] %||% list())
      cur <- list(); cells <- vector("list", length(tiles))
      for (ti in seq_along(tiles)) {
        t <- tiles[[ti]]
        v <- safe_num(t$v, 0)
        cur[[t$k]] <- v
        pv <- prev[[t$k]]
        dl <- if (is.null(pv)) 0 else v - pv
        arrow <- if (dl > 0) "\u25B2" else if (dl < 0) "\u25BC" else "\u25CF"
        cls <- if (dl > 0) (if (isTRUE(t$up_bad)) "delta-up bad-up" else "delta-up") else
               if (dl < 0) (if (isTRUE(t$up_bad)) "delta-down bad-up" else "delta-down") else "text-dim"
        dtxt <- if (is.null(pv) || abs(dl) < 10^-t$d) "" else fmt_num(abs(dl), t$d, rvLang())
        cells[[ti]] <- div(class = "bio-tile",
            div(class = "bt-label", HTML(paste0('<span data-k="', t$k, '">', tr_raw(rvLang(), t$k), '</span>'))),
            div(class = "bt-val", fn(v, t$d),
                span(class = "bt-unit", t$u),
                span(class = paste("bt-delta", cls), arrow, dtxt)))
      }
      isolate(RV$bioPrev[[uid]] <- cur)
      div(class = "bio-grid", cells)
    })
  })

  ## ---- nutrition & fueling ----
  output$nutritionBox <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      cin  <- safe_num(a$calories_in[1], 0); cout <- safe_num(a$calories_out[1], 0)
      bal  <- cin - cout
      bal_col <- if (bal >= -300) "var(--green)" else if (bal >= -800) "var(--amber)" else "var(--red)"
      hyd  <- safe_num(a$hydration_pct[1], 0)
      hcol <- if (hyd < 50) "var(--red)" else if (hyd < 70) "var(--amber)" else "var(--green)"
      tagList(
        div(class = "cohort-grid", style = "grid-template-columns:1fr 1fr 1fr;",
            div(class = "cohort-cell", div(class = "cc-label", HTML(paste0('<span data-k="calIn">', T("calIn"), '</span>'))), div(class = "cc-value", fn(cin, 0))),
            div(class = "cohort-cell", div(class = "cc-label", HTML(paste0('<span data-k="calOut">', T("calOut"), '</span>'))), div(class = "cc-value", fn(cout, 0))),
            div(class = "cohort-cell", div(class = "cc-label", "\u0394"), div(class = "cc-value", style = paste0("color:", bal_col, ";"), if (bal >= 0) "+" else "", fn(bal, 0)))),
        div(class = "bar-row", style = "margin-top:10px;",
            div(class = "bar-row-head", span(class = "lbl", HTML(paste0('<span data-k="choLoad">', T("choLoad"), '</span>'))),
                span(class = "val", fn(a$cho_g_per_kg[1], 1), " g/kg")),
            div(class = "bar-track", div(class = "bar-fill cyan", style = paste0("width:", clamp(safe_num(a$cho_g_per_kg[1], 0) / 10 * 100, 2, 100), "%")))),
        div(class = "bar-row",
            div(class = "bar-row-head", span(class = "lbl", HTML(paste0('<span data-k="protein">', T("protein"), '</span>'))),
                span(class = "val", fn(a$protein_g_per_kg[1], 1), " g/kg")),
            div(class = "bar-track", div(class = "bar-fill green", style = paste0("width:", clamp(safe_num(a$protein_g_per_kg[1], 0) / 3 * 100, 2, 100), "%")))),
        div(class = "bar-row",
            div(class = "bar-row-head", span(class = "lbl", HTML(paste0('<span data-k="hydration">', T("hydration"), '</span>'))),
                span(class = "val", fn(hyd, 0), "%")),
            div(class = "bar-track", div(class = "bar-fill", style = paste0("width:", clamp(hyd, 2, 100), "%;background:", hcol, ";"))))
      )
    })
  })

  ## ---- bone health & ACL risk (RED-S Lab) ----
  acl_factors_for <- function(a) {
    uid <- a$user_id[1]
    acl <- clamp(safe_num(a$knee_acl_risk[1], 25), 0, 100)
    hamq <- clamp(0.55 + 0.4 * det_unif(uid, "hamq"), 0.4, 0.98)
    data.frame(
      key = c("dynValgus", "landingMech", "hamQuad", "lrAsym"),
      fill = c(clamp(acl + (det_unif(uid, "v1") - 0.5) * 22, 3, 97),
               clamp(acl * 0.85 + (det_unif(uid, "v2") - 0.5) * 18, 3, 97),
               clamp((1 - hamq) * 220, 3, 97),
               clamp(4 + 26 * det_unif(uid, "v4") + acl * 0.15, 2, 40)),
      disp = c(paste0(fn(clamp(acl + (det_unif(uid, "v1") - 0.5) * 22, 3, 97), 0), "%"),
               paste0(fn(clamp(acl * 0.85 + (det_unif(uid, "v2") - 0.5) * 18, 3, 97), 0), "%"),
               fn(hamq, 2),
               paste0(fn(clamp(4 + 26 * det_unif(uid, "v4") + acl * 0.15, 2, 40), 0), "%")),
      stringsAsFactors = FALSE)
  }
  output$boneAclBox <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      ts <- safe_num(a$bone_t_score[1], 0); zs <- safe_num(a$bone_z_score[1], 0)
      bstat <- if (ts >= -1) T("boneNormal") else if (ts >= -2.5) T("boneOsteopenia") else T("boneOsteoporosis")
      bcol <- if (ts >= -1) "var(--green)" else if (ts >= -2.5) "var(--amber)" else "var(--red)"
      ## bone scale: T from +1.5 (left) to -3.2 (right); zone boundaries -1 / -2.5
      scale_lo <- -3.2; scale_hi <- 1.5
      pos_pct <- function(t) clamp((scale_hi - t) / (scale_hi - scale_lo) * 100, 0, 100)
      w_norm <- pos_pct(-1); w_osteo <- pos_pct(-2.5) - pos_pct(-1)
      acl <- clamp(safe_num(a$knee_acl_risk[1], 25), 0, 100)
      acol <- if (acl < 25) "var(--green)" else if (acl < 50) "var(--amber)" else "var(--red)"
      atag <- if (acl < 25) T("lowRisk") else if (acl < 50) T("modRisk") else T("highRisk")
      facs <- acl_factors_for(a)
      fac_rows <- lapply(seq_len(nrow(facs)), function(i) {
        div(class = "acl-factor-row",
            span(class = "af-lbl", HTML(paste0('<span data-k="', facs$key[i], '">', tr_raw(rvLang(), facs$key[i]), '</span>'))),
            div(class = "af-track", div(class = "af-fill", style = paste0("width:", facs$fill[i], "%;background:",
                if (facs$fill[i] >= 60) "var(--red)" else if (facs$fill[i] >= 35) "var(--amber)" else "var(--green)", ";"))),
            span(class = "af-val", facs$disp[i]))
      })
      tagList(
        div(class = "grid2",
            div(
              div(class = "mini-label", HTML(paste0('<span data-k="boneStatus">', T("boneStatus"), '</span>'))),
              div(style = "margin-top:8px;",
                  div(class = "kv-grid",
                      span(class = "k", HTML(paste0('<span data-k="boneTscore">', T("boneTscore"), '</span>'))), span(style = paste0("font-weight:900;color:", bcol), fn(ts, 1)),
                      span(class = "k", HTML(paste0('<span data-k="boneZscore">', T("boneZscore"), '</span>'))), span(style = "font-weight:700;", fn(zs, 1)))),
              span(class = "athlete-tag", style = paste0("background:", bcol, "22;border-color:", bcol, ";color:", bcol, ";font-size:10px;padding:3px 10px;"), bstat),
              div(class = "bone-scale",
                  div(class = "bs-zone z-normal", style = paste0("flex:", w_norm, ";"), HTML(paste0('<span data-k="boneNormal">', T("boneNormal"), '</span>'))),
                  div(class = "bs-zone z-osteo", style = paste0("flex:", max(w_osteo, 8), ";"), HTML(paste0('<span data-k="boneOsteopenia">', T("boneOsteopenia"), '</span>'))),
                  div(class = "bs-zone z-porosis", style = "flex:10;", HTML(paste0('<span data-k="boneOsteoporosis">', T("boneOsteoporosis"), '</span>'))),
                  div(class = "bone-marker", style = paste0("left:", pos_pct(ts), "%;")))),
            div(
              div(class = "mini-label", HTML(paste0('<span data-k="aclRisk">', T("aclRisk"), '</span>'))),
              div(style = "display:flex;align-items:center;gap:12px;margin:8px 0;",
                  HTML(ring_svg(acl, 100, acol, 78, 7, "ACL")),
                  span(class = "athlete-tag", style = paste0("background:", acol, "22;border-color:", acol, ";color:", acol), atag)),
              fac_rows)),
        div(class = "rec-item", style = paste0("margin-top:10px;border-left:3px solid ", acol, ";"),
            paste0("DXA · FMS — ", bstat, " (T ", fn(ts, 1), " / Z ", fn(zs, 1), ") · ACL ",
                   fn(acl, 0), "% · ", atag, " · ", T("clinicalRec")))
      )
    })
  })

  ## ---- session planner (rule-based, mirrors index.html tone) ----
  output$sessionPlanBox <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      rd <- safe_num(a$readiness[1], 60); ac <- a$acwr[1]; mn <- a$monotony[1]
      zone <- if (rd >= 75) "optimal" else if (rd >= 50) "moderate" else "caution"
      zcol <- switch(zone, optimal = "var(--green)", moderate = "var(--amber)", "var(--red)")
      rpe_t <- switch(zone, optimal = "7-9", moderate = "5-7", "3-5")
      int_t <- switch(zone, optimal = "85-92% FTP", moderate = "70-85% FTP", "50-65% FTP")
      vol_t <- switch(zone, optimal = "4-5 \u00D7 4-6 min", moderate = "3-4 \u00D7 3-5 min", "1-2 \u00D7 3-4 min")
      rst_t <- if (safe_num(a$rpe[1], 5) >= 8) "180-300 s" else if (safe_num(a$rpe[1], 5) >= 6) "120-180 s" else "60-120 s"
      warn <- character(0)
      if (!is.na(ac) && ac > ACWR_DANGER) warn <- c(warn, paste0("\u26A0 ACWR ", fn(ac, 2), " > 1.5 — cap intensity, extend warm-up"))
      if (!is.na(mn) && mn > 2.0) warn <- c(warn, paste0("\u26A0 ", T("monotonyTitle"), " ", fn(mn, 2), " > 2.0 — deload day advised"))
      if (identical(a$gender[1], "female") && a$cycle_phase[1] %in% c("luteal", "menstrual"))
        warn <- c(warn, paste0("\u26A0 ", switch(a$cycle_phase[1], luteal = T("luteal"), T("menstrual")),
                               " — fueling + sleep priority, higher RPE perception"))
      if (isTRUE(a$training_paused[1])) warn <- c(warn, "\u26A0 Training paused (RED-S medical referral) — no session")
      tagList(
        div(class = "chip-row",
            span(class = "athlete-tag", style = paste0("background:", zcol, "22;border-color:", zcol, ";color:", zcol), toupper(zone)),
            span(class = "rf-chip", paste0(T("readiness"), ": ", fn(rd, 0), "%"))),
        div(class = "kv-grid", style = "margin-top:8px;",
            span(class = "k", HTML(paste0('<span data-k="planTarget">', T("planTarget"), '</span>'))), span(style = "font-weight:800;color:var(--cyan);", rpe_t),
            span(class = "k", HTML(paste0('<span data-k="planIntensity">', T("planIntensity"), '</span>'))), span(style = "font-weight:700;", int_t),
            span(class = "k", HTML(paste0('<span data-k="planVolume">', T("planVolume"), '</span>'))), span(style = "font-weight:700;", vol_t),
            span(class = "k", HTML(paste0('<span data-k="planRest">', T("planRest"), '</span>'))), span(style = "font-weight:700;", rst_t)),
        if (length(warn) > 0) div(style = "margin-top:10px;", lapply(warn, function(w) div(class = "rec-item", style = "border-left:3px solid var(--amber);margin-bottom:5px;", w))) else NULL,
        div(class = "mini-label", style = "margin-top:8px;", "Gabbett TJ. (2016) BJSM · Foster C. (1998)")
      )
    })
  })

  ## ---- performance history (30/60/90-day composite) ----
  history_series_for <- function(a, days = 90) {
    uid <- a$user_id[1]
    set.seed(det_hash(paste0(uid, "|hist")))
    base <- perf_score_for(a, RV$trends[[uid]])
    gen_back(base, days, 0.05, 2.6, 20, 98, 0)
  }
  observeEvent(input$h30, { RV$histRange <- 30L;  js_set_active(c("h30", "h60", "h90"), "h30") })
  observeEvent(input$h60, { RV$histRange <- 60L;  js_set_active(c("h30", "h60", "h90"), "h60") })
  observeEvent(input$h90, { RV$histRange <- 90L;  js_set_active(c("h30", "h60", "h90"), "h90") })
  output$perfHistWrap <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      nd <- as.integer(RV$histRange %||% 30L)
      v <- utils::tail(history_series_for(a, 90), nd)
      HTML(svg_line(v, "#E91E63", w = 560, h = 150, ylab = T("perfScore")))
    })
  })

  ## ---- training load matrix table (squad) ----
  output$loadTableN <- renderText({
    df <- RV$athletes; paste0("N=", if (is.null(df)) 0 else nrow(df))
  })
  output$loadMatrixTableBox <- renderUI({
    safe_html(rvLang(), {
      df <- RV$athletes; need_msg(df, T("stool"))
      n_show <- min(nrow(df), 200L)
      sub_df <- df[seq_len(n_show), , drop = FALSE]
      
      tsb_vals <- sub_df$tsb
      tsb_cols <- ifelse(is.na(tsb_vals), "var(--text-dim)",
                  ifelse(tsb_vals >= -5, "var(--green)",
                  ifelse(tsb_vals >= -15, "var(--amber)", "var(--red)")))
      tsb_txt <- ifelse(is.na(tsb_vals), "\u2014",
                 ifelse(tsb_vals > 0, paste0("+", round(tsb_vals)), as.character(round(tsb_vals))))
      tsb_cells <- sprintf('<td style="font-weight:800;color:%s">%s</td>', tsb_cols, tsb_txt)
      
      st_cols <- vapply(sub_df$status, status_color, character(1))
      mono_txt <- ifelse(is.na(sub_df$monotony), "\u2014", sprintf("%.2f", sub_df$monotony))
      
      head_row <- paste0("<tr><th>", T("roster"), "</th><th>ATL</th><th>CTL</th><th>TSB</th><th>RPE</th><th>", T("monotonyTitle"), "</th><th>", T("load"), "</th><th>STATUS</th></tr>")
      
      rows <- sprintf(
        '<tr style="cursor:pointer" onclick="Shiny.setInputValue(\'athleteCardClick\',\'%s\',{priority:\'event\'})"><td style="font-weight:700"><span class="status-dot" style="display:inline-block;background:%s"></span> %s</td><td>%d</td><td>%d</td>%s<td>%d</td><td>%s</td><td>%d</td><td style="color:%s;font-weight:800">%s</td></tr>',
        sub_df$user_id,
        st_cols,
        htmltools::htmlEscape(sub_df$name),
        as.integer(round(sub_df$atl)),
        as.integer(round(sub_df$ctl)),
        tsb_cells,
        as.integer(round(sub_df$rpe)),
        mono_txt,
        as.integer(round(sub_df$strain)),
        st_cols,
        toupper(sub_df$status)
      )
      div(class = "table-scroll", style = "max-height:340px;",
          HTML(paste0('<table class="roster-table"><thead>', head_row, '</thead><tbody>',
                      paste0(rows, collapse = ""), '</tbody></table>')))
    })
  })

  ## ---- session timeline (counters + chronological track) ----
  event_class_of <- function(e) {
    col <- e$color %||% ""
    if (grepl("--red", col, fixed = TRUE)) "crit" else if (grepl("--amber", col, fixed = TRUE)) "warn" else if (grepl("--green", col, fixed = TRUE)) "good" else "info"
  }
  output$timelineCounters <- renderUI({
    safe_html(rvLang(), {
      ev <- RV$events
      cls <- vapply(ev, event_class_of, character(1))
      n_good <- sum(cls == "good"); n_alert <- sum(cls == "warn"); n_crit <- sum(cls == "crit")
      cells <- list(
        c(T("tlTotal"), fn(length(ev), 0), "var(--cyan)"),
        c(T("tlGood"), fn(n_good, 0), "var(--green)"),
        c(T("tlAlerts"), fn(n_alert, 0), "var(--amber)"),
        c(T("critical"), fn(n_crit, 0), "var(--red)")
      )
      div(class = "cohort-grid", style = "grid-template-columns:repeat(4,1fr);margin-bottom:10px;",
          lapply(cells, function(cc) div(class = "cohort-cell",
                                         div(class = "cc-label", cc[1]),
                                         div(class = "cc-value", style = paste0("color:", cc[3], ";"), cc[2]))))
    })
  })
  output$timelineBox <- renderUI({
    safe_html(rvLang(), {
      ev <- rev(RV$events)   # chronological (oldest first)
      if (length(ev) == 0) return(div(class = "empty-hint", T("noNotifications")))
      rows <- lapply(tail(ev, 24), function(e) {
        cl <- event_class_of(e)
        div(class = paste("tl-item", if (cl == "good") "tl-good" else if (cl == "warn") "tl-warn" else if (cl == "crit") "tl-crit" else ""),
            span(class = "tl-time", format(e$ts, "%H:%M:%S")),
            span(style = "flex:1;", htmltools::htmlEscape(substr(e$text, 1, 110))))
      })
      div(class = "tl-track", rows)
    })
  })

  ## ---- wellness:fatigue ratio gauge ----
  wf_ratio_for <- function(a) {
    rd <- clamp(safe_num(a$readiness[1], 50), 0, 100)
    ft <- clamp((safe_num(a$fatigue[1], 3) - 1) / 6 * 100, 2, 100)
    ratio <- round(rd / ft, 2)
    zone <- if (ratio >= 1.5) "green" else if (ratio >= 1.0) "amber" else "red"
    list(ratio = ratio, rd = rd, ft = ft, zone = zone)
  }
  output$wfRatioBox <- renderUI({
    safe_html(rvLang(), {
      a <- active_row(); need_msg(a, T("stool"))
      wf <- wf_ratio_for(a)
      col <- switch(wf$zone, green = "var(--green)", amber = "var(--amber)", "var(--red)")
      zlab <- switch(wf$zone, green = T("filterGreen"), amber = T("filterAmber"), T("filterRed"))
      tagList(
        div(style = "display:flex;align-items:center;gap:16px;justify-content:center;",
            HTML(ring_svg(clamp(wf$ratio, 0, 2.5) * 40, 100, col, 96, 9, T("wfRatio"))),
            div(div(style = paste0("font-size:25px;font-weight:900;color:", col, ";"), fn(wf$ratio, 2)),
                div(class = "mini-label", paste0(T("wfRatio"), " · ", zlab))),
            span(class = "athlete-tag", style = paste0("background:", col, "22;border-color:", col, ";color:", col), zlab)),
        div(class = "bar-row", style = "margin-top:12px;",
            div(class = "bar-row-head", span(class = "lbl", T("qbReadiness")), span(class = "val", fn(wf$rd, 0))),
            div(class = "bar-track", div(class = "bar-fill green", style = paste0("width:", wf$rd, "%")))),
        div(class = "bar-row",
            div(class = "bar-row-head", span(class = "lbl", T("fatigue")), span(class = "val", fn(wf$ft, 0))),
            div(class = "bar-track", div(class = "bar-fill red", style = paste0("width:", wf$ft, "%"))))
      )
    })
  })

  ## =============================================================================
  ## DOWNLOADS
  ## =============================================================================
  output$dlCsv <- downloadHandler(
    filename = function() paste0("athena_roster_", format(Sys.Date(), "%Y%m%d"), ".csv"),
    content = function(file) {
      df <- RV$athletes %||% data.frame()
      utils::write.csv(df, file, row.names = FALSE, fileEncoding = "UTF-8")
    }
  )
  output$dlJson <- downloadHandler(
    filename = function() paste0("athena_export_", format(Sys.Date(), "%Y%m%d"), ".json"),
    content = function(file) {
      payload <- list(
        exported_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
        version = ATHENA_VERSION,
        athletes = RV$athletes %||% list(),
        trends = RV$trends
      )
      writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, na = "null", pretty = TRUE), file, useBytes = TRUE)
    }
  )
  output$dlResearch <- downloadHandler(
    filename = function() paste0("athena_research_", (active_row()$user_id %||% "NA")[1], ".csv"),
    content = function(file) {
      tr <- active_trend()
      if (is.null(tr) || nrow(tr) == 0) tr <- data.frame(date = character(0))
      a <- active_row()
      out <- tr
      if (!is.null(a)) {
        out$user_id <- a$user_id[1]; out$gender <- a$gender[1]
      }
      utils::write.csv(out, file, row.names = FALSE, fileEncoding = "UTF-8")
    }
  )
  ## v7: performance-trend series export (12 weeks + 4-week linear forecast)
  output$dlPerfCsv <- downloadHandler(
    filename = function() paste0("athena_perf_trend_", (active_row()$user_id %||% "NA")[1], "_",
                                 format(Sys.Date(), "%Y%m%d"), ".csv"),
    content = function(file) {
      a <- active_row()
      if (is.null(a)) {
        utils::write.csv(data.frame(week = integer(0)), file, row.names = FALSE)
        return()
      }
      ps <- perf_series_for(a); fc <- perf_forecast_for(ps)
      n0 <- length(ps$week)
      df <- data.frame(
        week   = c(ps$week, n0 + seq_len(4)),
        kind   = c(rep("actual", n0), rep("forecast", 4)),
        vo2max = round(c(ps$vo2max, fc$vo2max), 1),
        power_w = c(ps$power, fc$power),
        hrv    = c(ps$hrv, fc$hrv),
        user_id = a$user_id[1],
        stringsAsFactors = FALSE)
      utils::write.csv(df, file, row.names = FALSE, fileEncoding = "UTF-8")
    }
  )
  output$dlReport <- downloadHandler(
    filename = function() paste0("athena_report_", (active_row()$user_id %||% "NA")[1], "_",
                                 format(Sys.Date(), "%Y%m%d"), ".html"),
    content = function(file) {
      lang <- rvLang()
      a <- active_row(); tr <- active_trend()
      esc <- function(x) htmltools::htmlEscape(as.character(x %||% ""))
      seg <- function(title, body_html) {
        paste0('<section style="margin:18px 0;padding:14px 16px;border:1px solid #ddd;border-radius:12px;">',
               '<h2 style="font-size:13px;letter-spacing:2px;color:#0091AD;margin:0 0 10px;">', esc(title), '</h2>',
               body_html, '</section>')
      }
      tbl_rows <- ""
      if (!is.null(tr) && nrow(tr) > 0) {
        tbl_rows <- paste0(vapply(utils::tail(seq_len(nrow(tr)), 14), function(i) {
          paste0("<tr><td>", esc(tr$date[i]), "</td><td>", fn(tr$daily_load[i], 0), "</td><td>",
                 fn(tr$rpe[i], 0), "</td><td>", fn(tr$sleep_hours[i], 1), "</td><td>",
                 fn(tr$stress[i], 0), "</td><td>", fn(tr$fatigue[i], 0), "</td></tr>")
        }, character(1)), collapse = "")
      }
      notes_html <- ""
      uid_str <- as.character(a$user_id[1] %||% "")
      ns <- if (nzchar(uid_str) && !is.null(RV$notes[[uid_str]])) RV$notes[[uid_str]] else list()
      if (length(ns) > 0) {
        notes_html <- paste0("<ul>", paste0(vapply(ns, function(n) paste0("<li>", esc(n$text), " <i>(", esc(n$priority), ")</i></li>"), character(1)), collapse = ""), "</ul>")
      }
      recs <- ai_recommendations(list(readiness = a$readiness[1], ea = a$ea[1], acwr = a$acwr[1],
                                      monotony = a$monotony[1], fatigue = a$fatigue[1],
                                      sleep_hours = a$sleep_hours[1], stress = a$stress[1],
                                      soreness = a$muscle_soreness[1]), lang)
      rec_html <- paste0("<ul>", paste0(vapply(recs, function(r) paste0("<li>", esc(r), "</li>"), character(1)), collapse = ""), "</ul>")
      html <- paste0(
        '<!DOCTYPE html><html lang="', lang, '" dir="', tr_lang_dir(lang), '"><head><meta charset="utf-8">',
        '<title>ATHENA ', esc(a$name[1]), '</title>',
        '<style>body{font-family:system-ui,sans-serif;color:#111;max-width:840px;margin:24px auto;padding:0 18px}',
        'table{border-collapse:collapse;width:100%;font-size:12px}td,th{border:1px solid #ddd;padding:6px 8px;text-align:left}',
        'th{background:#f2f2f2}h1{letter-spacing:3px;color:#0091AD}footer{color:#888;font-size:10px;margin-top:30px;border-top:1px solid #eee;padding-top:8px}</style></head><body>',
        '<h1>A.T.H.E.N.A. — ', tr_raw(lang, "report"), '</h1>',
        '<p style="color:#666;font-size:11px">', esc(CLASSIFICATION), ' · ', esc(format(Sys.time(), "%Y-%m-%d %H:%M")), '</p>',
        seg(T("overview"), paste0('<table><tbody>',
                                  '<tr><th>', esc(T("roster")), '</th><td>', esc(a$name[1]), ' (', esc(a$user_id[1]), ')</td></tr>',
                                  '<tr><th>', esc(T("readiness")), '</th><td>', fn(a$readiness[1], 0), '/100</td></tr>',
                                  '<tr><th>', esc(T("eaValue")), '</th><td>', if (is.na(a$ea[1])) "—" else fn(a$ea[1], 1), '</td></tr>',
                                  '<tr><th>ACWR</th><td>', if (is.na(a$acwr[1])) "—" else fn(a$acwr[1], 2), '</td></tr>',
                                  '<tr><th>', esc(T("load")), '</th><td>', fn(a$daily_load[1], 0), ' AU</td></tr>',
                                  '</tbody></table>')),
        seg(T("aiRecs"), rec_html),
        seg(T("notes"), notes_html),
        seg(T("loadMatrix"), paste0('<table><thead><tr><th>date</th><th>AU</th><th>RPE</th><th>sleep</th><th>stress</th><th>fatigue</th></tr></thead><tbody>',
                                    tbl_rows, '</tbody></table>')),
        '<footer>', esc(paste(tr_raw(lang, "generatedBy"), "ATHENA v1")), ' · ',
        esc(tr_raw(lang, "clinicalCaveat")), '</footer>',
        '</body></html>')
      writeLines(html, file, useBytes = TRUE)
    }
  )

  ## =============================================================================
  ## ALERT ENGINE (v7) — index.html parity: runAlertChecks() every 15 s over the
  ## normalized roster; alertFired map suppresses repeat notifications until the
  ## rule resets. Feeds the alert centre, event log, ticker and toasts.
  ## =============================================================================
  alert_fired_map <- new.env(parent = emptyenv())
  observe({
    invalidateLater(15000)
    df <- RV$athletes
    if (is.null(df) || nrow(df) == 0) return()
    # Monitor active squad (top 100 athletes) for alerts to ensure instant responsiveness
    df_mon <- head(df, 100)
    RV$alerts <- derive_alerts(df_mon, rvLang())
    fired_now <- character(0)
    is_initial <- (length(ls(alert_fired_map)) == 0)
    new_events <- list()
    for (x in RV$alerts) {
      fired_now <- c(fired_now, x$id)
      if (!isTRUE(alert_fired_map[[x$id]]) && !x$id %in% RV$acked) {
        alert_fired_map[[x$id]] <- TRUE
        col <- if (x$severity == "critical") "var(--red)" else "var(--amber)"
        ath_disp <- format_athlete_name(x$athlete, rvLang())
        txt_disp <- if (!is.null(x$rule_key)) format_alert_text(x$rule_key, x$val, x$extra, rvLang()) else x$text
        ev_msg <- paste0("\u26A0 ", tr_raw(rvLang(), "alert"), ": ", ath_disp, " — ", txt_disp)
        ev_item <- list(
          time = format(Sys.time(), "%H:%M:%S"),
          ts = Sys.time(),
          color = col,
          text = ev_msg,
          rule_key = x$rule_key,
          val = x$val,
          extra = x$extra,
          athlete = x$athlete
        )
        if (is_initial) {
          new_events[[length(new_events) + 1]] <- ev_item
        } else {
          curr_ev <- tryCatch(isolate(RV$events), error = function(e) list())
          RV$events <- head(append(list(ev_item), curr_ev), TICKER_MAX)
          notify(if (x$severity == "critical") "error" else "warn",
                 paste0(ath_disp, " · ", if (x$severity == "critical") T("critical") else T("warning")),
                 txt_disp, browser_push = isTRUE(input$setSound %||% FALSE))
        }
      }
    }
    if (is_initial && length(new_events) > 0) {
      curr_ev <- tryCatch(isolate(RV$events), error = function(e) list())
      RV$events <- utils::head(c(new_events, curr_ev), 50)
    }
    ## reset rules that stopped firing (mirrors index.html alertFired bookkeeping)
    reset_ids <- setdiff(ls(alert_fired_map), fired_now)
    if (length(reset_ids) > 0) for (rid in reset_ids) alert_fired_map[[rid]] <- FALSE
    crit <- Filter(function(x) x$severity == "critical" && !x$id %in% RV$acked, RV$alerts)
    if (!is_initial && length(crit) > 0 && isTRUE(input$setSound %||% FALSE)) {
      js_run("try{var a=new (window.AudioContext||window.webkitAudioContext)();var o=a.createOscillator();var g=a.createGain();o.connect(g);g.connect(a.destination);o.frequency.value=880;g.gain.value=.06;o.start();o.stop(a.currentTime+.25);}catch(e){}")
    }
  })

  # Keep quick-bar status bar outputs active
  suspend_targets <- c("qbReadiness", "qbLoad", "qbAtRisk", "qbReds", "qbAthletes", "tickerContent")
  for (out_name in suspend_targets) {
    tryCatch({
      outputOptions(output, out_name, suspendWhenHidden = FALSE)
    }, error = function(e) NULL)
  }

  ## initial load
  isolate({ load_all() })
  session$onSessionEnded(function() {
    ## per-session teardown only — never mutate the shared global ATH env,
    ## other browser sessions may still be live
    NULL
  })
}

## =============================================================================
## 11 · LAUNCH
## =============================================================================
shinyApp(
  ui = ui,
  server = server,
  options = list(
    port = if (nzchar(Sys.getenv("ATHENA_SHINY_PORT"))) as.integer(Sys.getenv("ATHENA_SHINY_PORT")) else 3838,
    host = "0.0.0.0",
    launch.browser = interactive(),
    display.mode = "normal"
  )
)
