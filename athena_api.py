
import io
import json
import logging
import os
import secrets
import uuid
import os as _os
import socket
import shutil
from datetime import timedelta

def _httpx_client(timeout=2.0):
    import httpx
    return httpx.AsyncClient(timeout=timeout)

R_API_URL = os.getenv("ATHENA_R_API_URL", "http://localhost:8001")

R_ENGINE_AVAILABLE_API = None

def _check_r_engine_api():
    global R_ENGINE_AVAILABLE_API
    if R_ENGINE_AVAILABLE_API is None:
        try:
            s = socket.create_connection(('localhost', 8001), timeout=1.0)
            s.close()
            R_ENGINE_AVAILABLE_API = True
        except Exception:
            R_ENGINE_AVAILABLE_API = False
    return R_ENGINE_AVAILABLE_API

async def _call_r(endpoint, payload):
    if not _check_r_engine_api():
        return None
    try:
        async with _httpx_client(timeout=2.0) as client:
            response = await client.post(f"{R_API_URL}/{endpoint}", json=payload)
            response.raise_for_status()
            return response.json()
    except Exception:
        return None

async def get_validated_energy_availability(calories, daily_load, ffm, exercise_type=None, duration_minutes=60, body_mass_kg=None, gender="Male", cycle_phase="", measured_rmr_daily=None, last_ffm_date=None):
    from tasks import _calculate_energy_availability
    try:
        r_payload = {
            "dates": [datetime.now(timezone.utc).strftime("%Y-%m-%d")],
            "calories": calories,
            "ffm": ffm,
            "daily_load": daily_load,
            "gender": gender,
            "cycle_phase": cycle_phase,
            "body_mass_kg": body_mass_kg,
            "duration_minutes_series": [duration_minutes],
            "exercise_type": exercise_type or ""
        }
        r_result = await _call_r("analytics/energy-availability", r_payload)
        if r_result and "ea_value" in r_result and r_result["ea_value"] is not None:
            return r_result
    except Exception:
        pass
    return _calculate_energy_availability(
        calories, daily_load, ffm,
        duration_minutes=duration_minutes,
        exercise_type=exercise_type,
        body_mass_kg=body_mass_kg,
        gender=gender,
        cycle_phase=cycle_phase,
        measured_rmr_daily=measured_rmr_daily,
        last_ffm_date=last_ffm_date
    )

async def get_validated_acwr(daily_loads, gender="male", hormonal_status=""):
    from tasks import _compute_acwr_python
    try:
        dates_list = [(datetime.now(timezone.utc) - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(len(daily_loads) - 1, -1, -1)]
        r_payload = {
            "dates": dates_list,
            "daily_loads": daily_loads,
            "gender": gender,
            "cycle_phase": hormonal_status
        }
        r_result = await _call_r("analytics/acwr", r_payload)
        if r_result and "error" not in r_result:
            return r_result
    except Exception:
        pass
    return _compute_acwr_python(daily_loads, gender, hormonal_status)

import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timezone, date, timedelta
from pathlib import Path
from typing import List, Optional

import redis
from celery import Celery
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from system_probe import SystemProbe, get_system_profile
from security_middleware import SecurityHeadersMiddleware
from auth import verify_jwt, create_jwt, check_permission, hash_password, TOKEN_BLACKLIST, ROLES
from audit_middleware import audit_log_action

STAFF_ROLES = ("admin", "head_coach", "coach", "sports_scientist", "physician")

REDIS_URL = os.getenv("ATHENA_REDIS_URL", "redis://localhost:6379/0")
CELERY_BROKER_URL = REDIS_URL
CELERY_RESULT_BACKEND = REDIS_URL
UPLOAD_DIR = Path("/tmp/athena_uploads")
BASE_DIR = Path(__file__).resolve().parent
API_KEY_FILE = BASE_DIR / ".athena_api_key"

import logging as _logging
_log_level = os.getenv("ATHENA_LOG_LEVEL", "WARNING").upper()
_log_level_map = {"DEBUG": _logging.DEBUG, "INFO": _logging.INFO, "WARNING": _logging.WARNING, "ERROR": _logging.ERROR, "CRITICAL": _logging.CRITICAL}
_logging.basicConfig(
    level=_log_level_map.get(_log_level, _logging.WARNING),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = _logging.getLogger("athena-api")

import socket as _socket
_redis_available_api = None

def _check_redis_api():
    global _redis_available_api
    if _redis_available_api is None:
        try:
            s = _socket.create_connection(('localhost', 6379), timeout=1.0)
            s.close()
            _redis_available_api = True
        except Exception:
            _redis_available_api = False
    return _redis_available_api

if _check_redis_api():
    celery_app = Celery(
        "athena_tasks",
        broker=CELERY_BROKER_URL,
        backend=CELERY_RESULT_BACKEND,
    )
else:
    celery_app = None
    logger.warning("Redis not reachable. Celery disabled. All processing synchronous.")

redis_client = None
if _check_redis_api():
    try:
        redis_client = redis.Redis.from_url(REDIS_URL, decode_responses=True)
        redis_client.ping()
        logger.info("Redis connection established")
    except Exception as e:
        logger.error(f"Redis connection failed: {e}")
        redis_client = None


def get_or_create_api_key():
    if API_KEY_FILE.exists():
        return API_KEY_FILE.read_text().strip()
    key = secrets.token_urlsafe(32)
    API_KEY_FILE.write_text(key)
    os.chmod(API_KEY_FILE, 0o600)
    logger.info("New API key generated and stored")
    return key


ATHENA_API_KEY = get_or_create_api_key()


def verify_api_key(request: Request, x_api_key: str = Header(None)):
    if x_api_key == ATHENA_API_KEY:
        return True
    client_host = getattr(request.client, "host", None)
    if client_host in ("127.0.0.1", "::1", "localhost", "testclient"):
        return True
    raise HTTPException(status_code=401, detail="Invalid or missing API key")


def verify_origin(request: Request):
    origin = request.headers.get("origin", "")
    allowed = {"http://localhost:8000", "http://127.0.0.1:8000", "null"}
    if origin and origin not in allowed:
        raise HTTPException(status_code=403, detail="Origin not permitted")
    return True


class SyncPayload(BaseModel):
    user_id: str = Field(..., min_length=1, max_length=64)
    timestamp: str = Field(...)
    gender: str = Field(...)
    duration_minutes: float = Field(..., ge=1, le=720)
    rpe: int = Field(..., ge=1, le=10)
    sleep_hours: float = Field(..., ge=0, le=16)
    sleep_quality: int = Field(..., ge=1, le=7)
    stress: int = Field(..., ge=1, le=7)
    fatigue: int = Field(..., ge=1, le=7)
    muscle_soreness: int = Field(..., ge=1, le=7)
    mood: Optional[str] = Field(default=None)
    exercise_type: Optional[str] = Field(default=None)
    calories: Optional[float] = Field(default=None, ge=500, le=10000)
    ffm: Optional[float] = Field(default=None, ge=30, le=120)
    cycle_phase: Optional[str] = Field(default=None)
    contraceptive_type: Optional[str] = Field(default=None)
    cramp_severity: Optional[int] = Field(default=None, ge=0, le=10)
    bleeding_volume: Optional[str] = Field(default=None)
    mood_disturbance: Optional[int] = Field(default=None, ge=0, le=10)
    injury_location: Optional[str] = Field(default=None)
    pain_level: Optional[int] = Field(default=None, ge=0, le=10)
    injury_notes: Optional[str] = Field(default=None)
    rtp_date: Optional[str] = Field(default=None)
    sets: Optional[int] = Field(default=None)
    reps: Optional[int] = Field(default=None)
    weight_kg: Optional[float] = Field(default=None)
    distance_m: Optional[float] = Field(default=None)
    jump_count: Optional[int] = Field(default=None)
    cmj_height_cm: Optional[float] = Field(default=None, ge=0)
    sprint_20m_s: Optional[float] = Field(default=None, ge=0)
    training_block_tag: Optional[str] = Field(default=None, max_length=100)
    reflection_text: Optional[str] = Field(default=None)
    stopbang_score: Optional[int] = Field(default=None, ge=0, le=8)
    parent_consent_token: Optional[str] = Field(default=None)
    urine_color: Optional[int] = Field(default=None, ge=1, le=8)
    symptoms_today: Optional[str] = Field(default=None)
    basal_body_temp_c: Optional[float] = Field(default=None)
    travel_from_tz: Optional[str] = Field(default=None)
    travel_to_tz: Optional[str] = Field(default=None)
    flight_duration: Optional[float] = Field(default=None, ge=0)
    diet_type: Optional[str] = Field(default=None)
    respiratory_rate: Optional[float] = Field(default=None, ge=8, le=30)
    perceived_recovery: Optional[int] = Field(default=None, ge=0, le=10)
    classification: Optional[str] = Field(default=None)

    @field_validator("timestamp")
    @classmethod
    def validate_timestamp(cls, v):
        try:
            datetime.fromisoformat(v)
        except ValueError:
            raise ValueError("timestamp must be a valid ISO 8601 datetime string")
        return v

    @field_validator("gender")
    @classmethod
    def validate_gender(cls, v):
        if v not in ("Male", "Female"):
            raise ValueError('gender must be "Male" or "Female"')
        return v

    @field_validator("cycle_phase")
    @classmethod
    def validate_cycle_phase(cls, v):
        if v is not None and v != "":
            allowed = {"menstrual", "follicular", "ovulatory", "luteal", "unknown",
                       "not_tracking", "hormonal_contraceptive", "amenorrheic"}
            if v.lower() not in allowed:
                raise ValueError(f"cycle_phase must be one of: {allowed}")
            return v.lower()
        return v


class SyncDataResponse(BaseModel):
    task_id: str
    status: str
    message: str


class CsvUploadResponse(BaseModel):
    task_id: str
    status: str
    message: str
    filename: str


class StopBangPayload(BaseModel):
    user_id: str
    score: int = Field(..., ge=0, le=8)
    risk_level: str


class ParentalConsentPayload(BaseModel):
    user_id: str
    parent_name: str
    parent_relation: str
    parent_email: Optional[str] = None
    parent_phone: Optional[str] = None
    expiry_date: str


class ConsentVerificationPayload(BaseModel):
    token: str


class REDSMedicalClearancePayload(BaseModel):
    user_id: str
    physician_name: str
    clearance_date: str

@asynccontextmanager
async def lifespan(app: FastAPI):
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    try:
        if celery_app is not None:
            insp = celery_app.control.inspect()
        else:
            insp = None
        if insp is not None:
            workers = insp.ping()
            if workers:
                logger.info(f"Celery workers available: {list(workers.keys())}")
            else:
                logger.warning("No Celery workers detected")
        else:
            logger.info("Celery disabled. Running in synchronous mode.")
    except Exception as e:
        logger.warning(f"Could not inspect Celery workers: {e}")

    import asyncio

    async def scheduled_backup():
        vacuum_counter = 0
        while True:
            await asyncio.sleep(3600)
            backup_dir = BASE_DIR / "backups"
            backup_dir.mkdir(exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_path = backup_dir / f"athena_auto_backup_{timestamp}.db"
            try:
                from tasks import SQLITE_DB_PATH, get_session
                if SQLITE_DB_PATH.exists():
                    shutil.copy2(SQLITE_DB_PATH, backup_path)
                    backups = sorted(backup_dir.glob("athena_auto_backup_*.db"))
                    for old in backups[:-24]:
                        old.unlink()
                    logger.info(f"Hourly backup complete: {backup_path.name}")
                    vacuum_counter += 1
                    if vacuum_counter >= 24:
                        logger.info("Running weekly database VACUUM for space reclamation")
                        session = get_session()
                        session.execute(text("VACUUM"))
                        session.close()
                        vacuum_counter = 0
                        logger.info("VACUUM complete")
            except Exception as e:
                logger.error(f"Auto-backup failed: {e}")

    asyncio.create_task(scheduled_backup())

    from tasks import get_engine as tasks_get_engine
    try:
        from migrations import run_migrations, CURRENT_SCHEMA_VERSION
    except ImportError:
        run_migrations = lambda: None
        CURRENT_SCHEMA_VERSION = 1
        logger.warning("migrations.py not found — schema versioning disabled")
    
    try:
        run_migrations()
        engine = tasks_get_engine()
        with engine.connect() as conn:
            result = conn.execute(text("SELECT MAX(version) FROM schema_version"))
            db_version = result.scalar() or 0
            if db_version < CURRENT_SCHEMA_VERSION:
                logger.critical(f"Database schema version {db_version} is behind code version {CURRENT_SCHEMA_VERSION}. Run migrations manually.")
    except Exception as e:
        logger.warning(f"Migration check skipped: {e}")

    try:
        engine = tasks_get_engine()
        with engine.connect() as conn:
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS daily_reflections (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    date DATE NOT NULL,
                    reflection_text TEXT,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS recovery_strategies (
                    id SERIAL PRIMARY KEY,
                    category VARCHAR(50) NOT NULL,
                    strategy_text TEXT NOT NULL,
                    locale VARCHAR(10) DEFAULT 'en',
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS stopbang_records (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    assessment_date DATE NOT NULL,
                    score INTEGER NOT NULL,
                    risk_level VARCHAR(20) NOT NULL,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS parental_consents (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    parent_name VARCHAR(200) NOT NULL,
                    parent_relation VARCHAR(50) NOT NULL,
                    parent_email VARCHAR(200),
                    parent_phone VARCHAR(50),
                    consent_date DATE NOT NULL,
                    expiry_date DATE NOT NULL,
                    consent_token VARCHAR(100) NOT NULL,
                    verified INTEGER DEFAULT 0,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS reds_medical_referrals (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    referral_date DATE NOT NULL,
                    physician_name VARCHAR(200),
                    physician_cleared INTEGER DEFAULT 0,
                    clearance_date DATE,
                    training_paused INTEGER DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS recovery_compliance (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    date DATE NOT NULL,
                    breath_completed INTEGER DEFAULT 0,
                    nsdr_completed INTEGER DEFAULT 0,
                    asanas_completed INTEGER DEFAULT 0,
                    notes TEXT,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS training_programs (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    program_name VARCHAR(200) NOT NULL,
                    periodization_model VARCHAR(50) NOT NULL,
                    start_date DATE NOT NULL,
                    end_date DATE NOT NULL,
                    created_by VARCHAR(64),
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS workout_sessions (
                    id SERIAL PRIMARY KEY,
                    program_id INTEGER REFERENCES training_programs(id),
                    planned_date DATE NOT NULL,
                    session_type VARCHAR(50) NOT NULL,
                    target_adaptation VARCHAR(50) NOT NULL,
                    auto_regulate BOOLEAN DEFAULT TRUE,
                    warmup_json TEXT,
                    cooldown_json TEXT
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS exercise_prescriptions (
                    id SERIAL PRIMARY KEY,
                    session_id INTEGER REFERENCES workout_sessions(id),
                    exercise_name VARCHAR(200) NOT NULL,
                    base_sets INTEGER NOT NULL,
                    base_reps INTEGER,
                    base_intensity_pct_1rm FLOAT,
                    base_rpe_target INTEGER,
                    rest_seconds INTEGER,
                    tempo VARCHAR(20),
                    exercise_order INTEGER NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS exercise_library (
                    id SERIAL PRIMARY KEY,
                    name VARCHAR(200) NOT NULL UNIQUE,
                    category VARCHAR(50) NOT NULL,
                    subcategory VARCHAR(50),
                    primary_muscle VARCHAR(100),
                    equipment VARCHAR(100),
                    difficulty VARCHAR(20),
                    contraindications TEXT,
                    description TEXT,
                    coaching_cues TEXT
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS wut_hydration_logs (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    date DATE NOT NULL,
                    morning_weight_kg FLOAT,
                    urine_color INTEGER,
                    thirst_level INTEGER,
                    status VARCHAR(20),
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS concussion_grtp (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    incident_date DATE NOT NULL,
                    current_stage INTEGER DEFAULT 1,
                    symptom_free_days INTEGER DEFAULT 0,
                    days_at_current_stage INTEGER DEFAULT 0,
                    cleared_by_md INTEGER DEFAULT 0,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS movement_risk_flags (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    assessment_date DATE NOT NULL,
                    fms_total_score INTEGER,
                    fms_asymmetry BOOLEAN,
                    less_score INTEGER,
                    limb_symmetry_index_pct FLOAT,
                    acl_injury_risk_pct FLOAT,
                    recommended_interventions TEXT,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS blood_biomarkers (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    test_date DATE NOT NULL,
                    ferritin_ng_ml FLOAT,
                    haemoglobin_g_dl FLOAT,
                    vitamin_d_ng_ml FLOAT,
                    testosterone_ng_dl FLOAT,
                    cortisol_ug_dl FLOAT,
                    creatine_kinase_u_l FLOAT,
                    crp_mg_l FLOAT,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS environmental_logs (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    date DATE NOT NULL,
                    altitude_m INTEGER,
                    days_at_altitude INTEGER,
                    aqi INTEGER,
                    pollen_count INTEGER,
                    ozone_ppb FLOAT,
                    heat_acclimation_status VARCHAR(30),
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS psychological_assessments (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    assessment_date DATE NOT NULL,
                    restq_stress_score INTEGER,
                    restq_recovery_score INTEGER,
                    abq_burnout_score FLOAT,
                    csai_cognitive_anxiety INTEGER,
                    csai_somatic_anxiety INTEGER,
                    csai_self_confidence INTEGER,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS nutrition_periodization (
                    id SERIAL PRIMARY KEY,
                    program_id INTEGER NOT NULL,
                    mesocycle_number INTEGER NOT NULL,
                    phase_goal VARCHAR(50) NOT NULL,
                    cho_g_per_kg_target FLOAT,
                    pro_g_per_kg_target FLOAT,
                    fat_g_per_kg_target FLOAT,
                    supplement_protocol TEXT,
                    hydration_protocol TEXT,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS sleep_architecture (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    date DATE NOT NULL,
                    total_sleep_min INTEGER,
                    deep_sleep_min INTEGER,
                    rem_sleep_min INTEGER,
                    sleep_efficiency_pct FLOAT,
                    sleep_onset_latency_min INTEGER,
                    wake_after_sleep_onset_min INTEGER,
                    resting_hr_avg INTEGER,
                    hrv_rmssd FLOAT,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS para_classifications (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL UNIQUE,
                    ipc_class VARCHAR(10),
                    sport_class VARCHAR(10),
                    assistive_device VARCHAR(100),
                    safety_protocol_required BOOLEAN DEFAULT FALSE,
                    updated_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS health_metrics (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    date DATE NOT NULL,
                    systolic_bp INTEGER,
                    diastolic_bp INTEGER,
                    resting_hr INTEGER,
                    waist_circumference_cm FLOAT,
                    body_mass_kg FLOAT,
                    height_cm FLOAT,
                    bmi FLOAT,
                    physical_activity_min_week INTEGER,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS dexa_scans (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    scan_date DATE NOT NULL,
                    total_body_mass_kg FLOAT,
                    ffm_kg FLOAT,
                    fm_kg FLOAT,
                    body_fat_pct FLOAT,
                    bmd_total_body_g_cm2 FLOAT,
                    bmd_lumbar_spine_g_cm2 FLOAT,
                    bmd_hip_g_cm2 FLOAT,
                    vat_kg FLOAT,
                    created_at TEXT NOT NULL
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS clinical_notes (
                    id SERIAL PRIMARY KEY,
                    user_id VARCHAR(64) NOT NULL,
                    note_date DATE NOT NULL,
                    author VARCHAR(100),
                    note_type VARCHAR(50),
                    content TEXT,
                    created_at TEXT NOT NULL
                )
            """))
            conn.commit()
            logger.info("Additional tables and indexes verified")
    except Exception as e:
        logger.warning(f"Could not verify additional database tables: {e}")
    yield
    # Graceful shutdown sequence
    logger.info("ATHENA API: Initiating graceful database shutdown...")
    try:
        from tasks import get_engine as tasks_get_engine
        engine = tasks_get_engine()
        with engine.connect() as conn:
            try:
                conn.execute(text("PRAGMA wal_checkpoint(TRUNCATE)"))
                conn.commit()
                logger.info("ATHENA API: SQLite WAL checkpointed and truncated.")
            except Exception as e:
                logger.warning(f"ATHENA API: WAL checkpoint notification: {e}")
        engine.dispose()
        logger.info("ATHENA API: Database connection pool cleanly disposed.")
    except Exception as e:
        logger.error(f"ATHENA API: Database shutdown cleanup error: {e}")

from collections import defaultdict
import time as time_module

rate_limit_store = defaultdict(list)

app = FastAPI(
    title="A.T.H.E.N.A. API",
    description="Athlete Telemetry and Health Analytics",
    lifespan=lifespan,
    docs_url="/api/docs",
    redoc_url="/api/redoc",
    openapi_url="/api/openapi.json",
    contact={
        "name": "ATHENA Research Protocol",
        "url": "http://localhost:8000",
    },
    license_info={
        "name": "MIT",
        "url": "https://opensource.org/licenses/MIT",
    },
)

app.add_middleware(SecurityHeadersMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("ATHENA_CORS_ORIGINS", "http://localhost:8000,http://127.0.0.1:8000").split(","),
    allow_credentials=True,
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["*"],
)

static_dir = Path(__file__).parent / "static"
if static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")

@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    client_ip = request.client.host if request.client else "unknown"
    current_time = time_module.time()
    window_start = current_time - 60
    rate_limit_store[client_ip] = [t for t in rate_limit_store[client_ip] if t > window_start]
    if len(rate_limit_store[client_ip]) > 300:
        return JSONResponse(
            status_code=429,
            content={"detail": "Too many requests. Please wait before making additional requests."}
        )
    rate_limit_store[client_ip].append(current_time)
    if len(rate_limit_store) > 50000 or (len(rate_limit_store) > 100 and current_time - getattr(rate_limit_store, '_last_cleanup', 0) > 3600):
        oldest_threshold = current_time - 3600
        stale_keys = [k for k, v in rate_limit_store.items() if not v or v[-1] < oldest_threshold]
        for key in stale_keys[:1000]:
            del rate_limit_store[key]
        rate_limit_store._last_cleanup = current_time
    response = await call_next(request)
    return response

@app.get("/api/system/profile")
async def get_system_profile_endpoint():
    profile = get_system_profile()
    if profile is None:
        probe = SystemProbe()
        profile = probe.run()
        probe.save()
    profile["ui_preferences"] = {
        "scanline_enabled": os.getenv("ATHENA_UI_SCANLINE", "true").lower() == "true",
        "theme": os.getenv("ATHENA_UI_THEME", "tactical"),
        "font_size_scale": float(os.getenv("ATHENA_UI_FONT_SCALE", "1.0"))
    }
    return profile

@app.get("/api/system/ml-status")
async def get_ml_status():
    ml_control_path = Path("/tmp/athena_ml_control.json")
    thermal_status_path = Path("/tmp/athena_thermal_status.json")
    ml_status = {
        "r_engine_enabled": True,
        "cdss_rules_enabled": True,
        "sqlite_storage": True,
        "fastapi_core": True,
        "batch_size": 500,
        "max_concurrent_users": 50,
        "operating_mode": "standard",
        "architecture": "Clinical Decision Support System (CDSS) & Deterministic Sports Science"
    }
    if ml_control_path.exists():
        try:
            with open(ml_control_path, "r") as f:
                ml_status = json.load(f)
        except Exception:
            pass
    thermal_status = {"cpu_temperature_c": 0, "operating_mode": "unknown"}
    if thermal_status_path.exists():
        try:
            with open(thermal_status_path, "r") as f:
                thermal_status = json.load(f)
        except Exception:
            pass
    return {
        "ml_status": ml_status,
        "thermal_status": thermal_status,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }
@app.post("/api/demo/seed")
async def seed_demo_data():
    from tasks import get_session
    import random
    session = get_session()
    try:
        demo_ids = ["ATH-DEMO-01", "ATH-DEMO-02", "ATH-DEMO-03", "ATH-DEMO-04", "ATH-DEMO-05"]
        genders = ["Male", "Male", "Female", "Female", "Male"]
        sports = ["run", "cycle", "swim", "sprint", "row"]
        created = 0
        for uid, gender, sport in zip(demo_ids, genders, sports):
            existing = session.execute(
                text("SELECT COUNT(*) FROM daily_checkins WHERE user_id = :uid"),
                {"uid": uid}
            ).scalar()
            if existing > 0:
                continue
            base_date = date.today() - timedelta(days=42)
            for day_offset in range(42):
                current_date = base_date + timedelta(days=day_offset)
                phase = random.choice(["follicular", "luteal", "menstrual", "ovulatory"]) if gender == "Female" else ""
                rpe = random.randint(3, 9)
                duration = random.randint(30, 90)
                daily_load = round(rpe * duration, 2)
                sleep_hours = round(random.uniform(5.5, 9.0), 1)
                sleep_quality = random.randint(2, 7)
                stress_val = random.randint(1, 6)
                fatigue_val = random.randint(1, 6)
                soreness = random.randint(1, 5)
                calories = random.randint(1800, 3500) if gender == "Male" else random.randint(1500, 2800)
                ffm = round(random.uniform(55, 75), 1) if gender == "Male" else round(random.uniform(40, 55), 1)
                now_iso = datetime.now(timezone.utc).isoformat()
                session.execute(text("""
                    INSERT INTO daily_checkins
                        (user_id, date, timestamp, gender, duration_minutes, rpe, sleep_hours,
                         sleep_quality, stress, fatigue, muscle_soreness, cycle_phase,
                         calories, ffm, daily_load, load_strength, load_endurance, load_power,
                         exercise_type, created_at)
                    VALUES
                        (:uid, :date, :ts, :gender, :dur, :rpe, :sh, :sq, :st, :fa, :ms, :cp,
                         :cal, :ffm, :load, :ls, :le, :lp, :ex, :now)
                    ON CONFLICT (user_id, date) DO NOTHING
                """), {
                    "uid": uid, "date": current_date.isoformat(), "ts": now_iso,
                    "gender": gender, "dur": duration, "rpe": rpe,
                    "sh": sleep_hours, "sq": sleep_quality, "st": stress_val,
                    "fa": fatigue_val, "ms": soreness, "cp": phase,
                    "cal": calories, "ffm": ffm, "load": daily_load,
                    "ls": 0, "le": 0, "lp": 0, "ex": sport, "now": now_iso
                })
                if gender == "Female" and phase:
                    session.execute(text("""
                        INSERT INTO female_athlete_data
                            (user_id, current_phase, contraceptive_type, cramp_severity,
                             bleeding_volume, mood_disturbance, created_at, updated_at)
                        VALUES (:uid, :cp, 'none', 0, 'moderate', 0, :now, :now)
                        ON CONFLICT (user_id) DO UPDATE SET current_phase = EXCLUDED.current_phase
                    """), {"uid": uid, "cp": phase, "now": now_iso})
                created += 1
                if created % 100 == 0:
                    session.commit()
        session.commit()
        return {"status": "seeded", "athletes": len(demo_ids), "days_per_athlete": 42, "total_records": created}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.get("/api/system/health")
async def get_system_health():
    try:
        import psutil
        import asyncio as _asyncio
        cpu_percent = await _asyncio.to_thread(psutil.cpu_percent, interval=0.5)
        return {
            "cpu_percent": cpu_percent,
            "memory_percent": psutil.virtual_memory().percent,
            "disk_percent": psutil.disk_usage("/").percent,
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
    except ImportError:
        return {
            "cpu_percent": 0,
            "memory_percent": 0,
            "disk_percent": 0,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "error": "psutil not installed"
        }

import signal as _signal
_shutting_down_api = False

def _handle_sigterm(signum, frame):
    global _shutting_down_api
    _shutting_down_api = True
    logger.warning("ATHENA API: Received SIGTERM. Graceful shutdown initiated.")
    raise KeyboardInterrupt

_signal.signal(_signal.SIGTERM, _handle_sigterm)

@app.middleware("http")
async def shutdown_middleware(request: Request, call_next):
    if _shutting_down_api:
        return JSONResponse(status_code=503, content={"detail": "Server shutting down. Try again shortly."})
    return await call_next(request)

@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    logger.error(f"HTTP {exc.status_code}: {exc.detail} — URL: {request.url}")
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})


@app.get("/")
async def serve_root():
    return {
        "status": "online",
        "service": "A.T.H.E.N.A. — Clinical Telemetry & Biomechanical Intelligence Platform",
        "version": "1.0.0",
        "classification": "RESTRICTED",
        "documentation": "/api/docs",
        "health": "/api/health",
        "clinical_hub": "http://127.0.0.1:3838"
    }

@app.get("/index.html")
async def serve_root_alt():
    from fastapi.responses import RedirectResponse
    return RedirectResponse(url="/")


@app.get("/api/admin/audit-report")
async def get_audit_report(
    user_id: str = Query(None),
    start_date: str = Query(None),
    end_date: str = Query(None),
    authorization: str = Header(None)
):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload or token_payload.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Admin access required")
    from tasks import get_session
    session = get_session()
    try:
        query = "SELECT user_hash, action, resource, outcome, created_at FROM audit_logs WHERE 1=1"
        params = {}
        if user_id:
            query += " AND user_hash = :uid"
            params["uid"] = user_id[:16]
        if start_date:
            query += " AND created_at >= :start"
            params["start"] = start_date
        if end_date:
            query += " AND created_at <= :end"
            params["end"] = end_date
        query += " ORDER BY created_at DESC LIMIT 1000"
        result = session.execute(text(query), params)
        rows = result.fetchall()
        entries = [{"user_hash": r[0], "action": r[1], "resource": r[2], "outcome": r[3], "timestamp": r[4]} for r in rows]
        actions_summary = {}
        for r in rows:
            actions_summary[r[1]] = actions_summary.get(r[1], 0) + 1
        return {
            "total_entries": len(entries),
            "actions_summary": actions_summary,
            "entries": entries,
            "generated_at": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()

@app.get("/api/admin/failed-tasks")
async def get_failed_tasks(authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload or token_payload.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Admin access required")
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("SELECT id, task_name, error_message, attempts, created_at FROM failed_tasks ORDER BY created_at DESC LIMIT 50"))
        tasks = [{"id": r[0], "task_name": r[1], "error": r[2], "attempts": r[3], "created_at": r[4]} for r in result.fetchall()]
        return {"failed_tasks": tasks, "count": len(tasks)}
    finally:
        session.close()

@app.get("/api/verify/{user_id}")
async def verify_data_integrity(user_id: str):
    from tasks import get_session
    import hashlib
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT id, user_id, date, gender, duration_minutes, rpe, sleep_hours, sleep_quality,
                   stress, fatigue, muscle_soreness, daily_load, COALESCE(data_hash, 'MISSING')
            FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC
        """), {"uid": user_id})
        rows = result.fetchall()
        if not rows:
            raise HTTPException(status_code=404, detail="No data found")
        verified = 0
        missing = 0
        tampered = 0
        for row in rows:
            stored_hash = row[12]
            if stored_hash == 'MISSING':
                missing += 1
                continue
            raw = f"{row[1]}|{row[2]}|{row[3]}|{row[4]}|{row[5]}|{row[6]}|{row[7]}|{row[8]}|{row[9]}|{row[10]}|{row[11]}"
            computed_hash = hashlib.sha256(raw.encode()).hexdigest()[:16]
            if computed_hash == stored_hash:
                verified += 1
            else:
                tampered += 1
        total = len(rows)
        return {
            "user_id": user_id,
            "total_records": total,
            "verified": verified,
            "missing_hash": missing,
            "tampered": tampered,
            "integrity_ok": tampered == 0,
            "reference": "SHA-256 hash verification of all field values."
        }
    finally:
        session.close()

@app.get("/api/admin/metrics")
async def get_admin_metrics(authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload or token_payload.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Admin access required")
    from tasks import get_session
    session = get_session()
    try:
        total_checkins = session.execute(text("SELECT COUNT(*) FROM daily_checkins")).scalar()
        unique_athletes = session.execute(text("SELECT COUNT(DISTINCT user_id) FROM daily_checkins")).scalar()
        avg_load = session.execute(text("SELECT AVG(daily_load) FROM daily_checkins")).scalar()
        avg_readiness = session.execute(text("SELECT AVG((sleep_quality/7.0 + MIN(sleep_hours/8.0,1) + (8.0-stress)/7.0 + (8.0-fatigue)/7.0 + (8.0-muscle_soreness)/7.0)/5.0*100) FROM daily_checkins")).scalar()
        today_checkins = session.execute(text("SELECT COUNT(*) FROM daily_checkins WHERE date = date('now')")).scalar()
        failed_count = session.execute(text("SELECT COUNT(*) FROM failed_tasks")).scalar()
        db_size = os.path.getsize(os.path.join(os.path.dirname(os.path.abspath(__file__)), "athena.db")) / (1024*1024)
        return {
            "total_checkins": total_checkins or 0,
            "unique_athletes": unique_athletes or 0,
            "average_daily_load": round(float(avg_load or 0), 1),
            "average_readiness": round(float(avg_readiness or 0), 1),
            "today_checkins": today_checkins or 0,
            "failed_tasks": failed_count or 0,
            "database_size_mb": round(db_size, 1),
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()

@app.post("/api/adverse-event")
async def report_adverse_event(payload: dict, authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload:
        raise HTTPException(status_code=401, detail="Invalid token")
    user_id = payload.get("user_id")
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id is required")
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            CREATE TABLE IF NOT EXISTS adverse_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id VARCHAR(64) NOT NULL,
                event_date TEXT NOT NULL,
                event_type VARCHAR(50) NOT NULL,
                severity VARCHAR(20) NOT NULL CHECK(severity IN ('mild','moderate','severe','life-threatening')),
                description TEXT,
                related_to_training VARCHAR(10) DEFAULT 'unknown' CHECK(related_to_training IN ('yes','no','unknown')),
                actions_taken TEXT,
                outcome VARCHAR(30) DEFAULT 'ongoing',
                reported_by VARCHAR(64) NOT NULL,
                created_at TEXT NOT NULL
            )
        """))
        session.execute(text("""
            INSERT INTO adverse_events (user_id, event_date, event_type, severity, description, related_to_training, actions_taken, outcome, reported_by, created_at)
            VALUES (:uid, :edate, :etype, :sev, :desc, :rel, :actions, :outcome, :reporter, :now)
        """), {
            "uid": user_id,
            "edate": payload.get("event_date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "etype": payload.get("event_type", "unspecified"),
            "sev": payload.get("severity", "moderate"),
            "desc": payload.get("description", "")[:2000],
            "rel": payload.get("related_to_training", "unknown"),
            "actions": payload.get("actions_taken", "")[:1000],
            "outcome": payload.get("outcome", "ongoing"),
            "reporter": token_payload.get("sub", "unknown"),
            "now": datetime.now(timezone.utc).isoformat()
        })
        session.commit()
        audit_log_action(user_id, "ADVERSE_EVENT_REPORTED", "adverse_event", "success")
        return {"status": "recorded", "user_id": user_id, "severity": payload.get("severity")}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.get("/api/adverse-events/{user_id}")
async def get_adverse_events(user_id: str, authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload:
        raise HTTPException(status_code=401, detail="Invalid token")
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT id, event_date, event_type, severity, description, related_to_training, actions_taken, outcome, created_at
            FROM adverse_events WHERE user_id = :uid ORDER BY event_date DESC LIMIT 50
        """), {"uid": user_id})
        events = [{"id": r[0], "event_date": r[1], "event_type": r[2], "severity": r[3], "description": r[4], "related_to_training": r[5], "actions_taken": r[6], "outcome": r[7], "created_at": r[8]} for r in result.fetchall()]
        return {"user_id": user_id, "adverse_events": events, "count": len(events)}
    finally:
        session.close()

@app.post("/api/recommendation-feedback")
async def submit_recommendation_feedback(payload: dict, authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload:
        raise HTTPException(status_code=401, detail="Invalid token")
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            CREATE TABLE IF NOT EXISTS recommendation_feedback (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id VARCHAR(64) NOT NULL,
                recommendation_type VARCHAR(50) NOT NULL,
                recommendation_text TEXT,
                was_helpful VARCHAR(10) CHECK(was_helpful IN ('yes','no','partially')),
                was_followed VARCHAR(10) CHECK(was_followed IN ('yes','no','partially')),
                outcome_notes TEXT,
                submitted_by VARCHAR(64) NOT NULL,
                created_at TEXT NOT NULL
            )
        """))
        session.execute(text("""
            INSERT INTO recommendation_feedback (user_id, recommendation_type, recommendation_text, was_helpful, was_followed, outcome_notes, submitted_by, created_at)
            VALUES (:uid, :rtype, :rtext, :helpful, :followed, :notes, :submitter, :now)
        """), {
            "uid": payload.get("user_id"),
            "rtype": payload.get("recommendation_type", "session_plan"),
            "rtext": payload.get("recommendation_text", "")[:500],
            "helpful": payload.get("was_helpful", "yes"),
            "followed": payload.get("was_followed", "yes"),
            "notes": payload.get("outcome_notes", "")[:500],
            "submitter": token_payload.get("sub", "unknown"),
            "now": datetime.now(timezone.utc).isoformat()
        })
        session.commit()
        return {"status": "recorded"}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.get("/api/recommendation-feedback-summary")
async def get_recommendation_feedback_summary(authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload or token_payload.get("role") not in STAFF_ROLES:
        raise HTTPException(status_code=403, detail="Insufficient permissions")
    from tasks import get_session
    session = get_session()
    try:
        total = session.execute(text("SELECT COUNT(*) FROM recommendation_feedback")).scalar() or 0
        helpful = session.execute(text("SELECT COUNT(*) FROM recommendation_feedback WHERE was_helpful = 'yes'")).scalar() or 0
        followed = session.execute(text("SELECT COUNT(*) FROM recommendation_feedback WHERE was_followed = 'yes'")).scalar() or 0
        return {
            "total_feedback": total,
            "helpful_pct": round((helpful / total) * 100, 1) if total > 0 else 0,
            "followed_pct": round((followed / total) * 100, 1) if total > 0 else 0,
            "generated_at": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()

@app.get("/api/health/full")
async def health_check_full():
    from tasks import get_session, get_engine
    import psutil as psutil_module
    results = {"database": "fail", "redis": "fail", "r_engine": "fail", "disk": "fail", "memory": "fail"}
    try:
        s = get_session()
        s.execute(text("SELECT 1"))
        s.close()
        results["database"] = "pass"
    except Exception:
        pass
    try:
        if redis_client:
            redis_client.ping()
            results["redis"] = "pass"
        else:
            results["redis"] = "disabled"
    except Exception:
        pass
    try:
        s = socket.create_connection(('localhost', 8001), timeout=1.0)
        s.close()
        results["r_engine"] = "pass"
    except Exception:
        results["r_engine"] = "unavailable"
    try:
        usage = shutil.disk_usage(BASE_DIR)
        free_gb = round(usage.free / (1024**3), 1)
        results["disk"] = f"pass ({free_gb}GB free)"
    except Exception:
        pass
    try:
        mem = psutil_module.virtual_memory()
        results["memory"] = f"pass ({mem.percent}% used)"
    except Exception:
        pass
    try:
        athlete_count = get_session().execute(text("SELECT COUNT(DISTINCT user_id) FROM daily_checkins")).scalar()
        results["athletes"] = athlete_count or 0
    except Exception:
        results["athletes"] = 0
    overall = all(v.startswith("pass") or v == "disabled" or v == "unavailable" for v in results.values() if isinstance(v, str))
    return {"status": "healthy" if overall else "degraded", "components": results, "timestamp": datetime.now(timezone.utc).isoformat()}

LOGIN_ATTEMPTS = {}

@app.post("/api/auth/login")
async def login(payload: dict, request: Request):
    user_id = payload.get("user_id", "")
    password = payload.get("password", "")
    if not user_id or not password:
        raise HTTPException(status_code=400, detail="user_id and password required")
    client_ip = request.client.host if request.client else "unknown"
    attempt_key = f"{user_id}:{client_ip}"
    now = datetime.now(timezone.utc)
    if attempt_key in LOGIN_ATTEMPTS:
        attempts, lock_until = LOGIN_ATTEMPTS[attempt_key]
        if lock_until and now < lock_until:
            raise HTTPException(status_code=429, detail="Account temporarily locked. Try again later.")
        if now > (lock_until or now):
            LOGIN_ATTEMPTS[attempt_key] = (0, None)
    role = "athlete"
    if user_id.startswith("COACH-"):
        role = "coach"
    elif user_id.startswith("ADMIN-"):
        role = "admin"
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("SELECT salt, password_hash FROM user_credentials WHERE user_id = :uid"), {"uid": user_id})
        row = result.fetchone()
        if row:
            stored_salt = row[0]
            stored_hash = row[1]
            _, computed_hash = hash_password(password, stored_salt)
            if computed_hash != stored_hash:
                attempts, _ = LOGIN_ATTEMPTS.get(attempt_key, (0, None))
                attempts += 1
                lock_until = now + timedelta(minutes=15) if attempts >= 10 else None
                LOGIN_ATTEMPTS[attempt_key] = (attempts, lock_until)
                audit_log_action(user_id, "LOGIN_FAILED", "auth", "invalid_password")
                raise HTTPException(status_code=401, detail="Invalid credentials")
        else:
            attempts, _ = LOGIN_ATTEMPTS.get(attempt_key, (0, None))
            attempts += 1
            lock_until = now + timedelta(minutes=15) if attempts >= 10 else None
            LOGIN_ATTEMPTS[attempt_key] = (attempts, lock_until)
            audit_log_action(user_id, "LOGIN_FAILED", "auth", "user_not_found")
            raise HTTPException(status_code=401, detail="Invalid credentials")
    finally:
        session.close()
    LOGIN_ATTEMPTS[attempt_key] = (0, None)
    token = create_jwt(user_id, role, expiry_hours=1)
    audit_log_action(user_id, "LOGIN", "auth", "success")
    return {"token": token, "user_id": user_id, "role": role, "expires_in": "1h"}

TOKEN_BLACKLIST = set()

@app.post("/api/auth/logout")
async def logout(authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    payload = verify_jwt(token)
    if payload:
        jti = payload.get("jti", token[-20:])
        TOKEN_BLACKLIST.add(jti)
        audit_log_action(payload.get("sub", "unknown"), "LOGOUT", "auth", "success")
    return {"status": "logged_out"}

@app.get("/api/auth/me")
async def get_current_user(authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid token")
    token = authorization.replace("Bearer ", "")
    payload = verify_jwt(token)
    if not payload:
        raise HTTPException(status_code=401, detail="Invalid or expired token")
    return {"user_id": payload.get("sub"), "role": payload.get("role")}

@app.post("/api/auth/register")
async def register_athlete(payload: dict):
    user_id = payload.get("user_id", "")
    password = payload.get("password", "")
    consent_training = payload.get("consent_training", False)
    consent_research = payload.get("consent_research", False)
    if not user_id or not password or len(password) < 6:
        raise HTTPException(status_code=400, detail="user_id and password (min 6 chars) required")
    if not consent_training:
        raise HTTPException(status_code=400, detail="Training data consent is required to use this system")
    from tasks import get_session
    session = get_session()
    try:
        existing = session.execute(text("SELECT id FROM daily_checkins WHERE user_id = :uid LIMIT 1"), {"uid": user_id}).fetchone()
        if existing:
            raise HTTPException(status_code=409, detail="Athlete ID already registered")
        salt, pw_hash = hash_password(password)
        session.execute(text("""
            CREATE TABLE IF NOT EXISTS user_credentials (
                user_id VARCHAR(64) PRIMARY KEY,
                salt TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """))
        session.execute(text("""
            INSERT INTO user_credentials (user_id, salt, password_hash, created_at, updated_at)
            VALUES (:uid, :salt, :hash, :now, :now)
            ON CONFLICT (user_id) DO UPDATE SET salt=:salt, password_hash=:hash, updated_at=:now
        """), {"uid": user_id, "salt": salt, "hash": pw_hash, "now": datetime.now(timezone.utc).isoformat()})
        session.execute(text("""
            CREATE TABLE IF NOT EXISTS athlete_consents (
                user_id VARCHAR(64) PRIMARY KEY,
                consent_training INTEGER DEFAULT 0,
                consent_research INTEGER DEFAULT 0,
                consent_training_date TEXT,
                consent_research_date TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """))
        session.execute(text("""
            INSERT INTO athlete_consents (user_id, consent_training, consent_research, consent_training_date, consent_research_date, created_at, updated_at)
            VALUES (:uid, :ct, :cr, :now, :now, :now, :now)
        """), {"uid": user_id, "ct": 1 if consent_training else 0, "cr": 1 if consent_research else 0, "now": datetime.now(timezone.utc).isoformat()})
        session.execute(text("""
            INSERT INTO daily_checkins (user_id, date, timestamp, gender, duration_minutes, rpe, sleep_hours, sleep_quality, stress, fatigue, muscle_soreness, daily_load, load_strength, load_endurance, load_power, created_at)
            VALUES (:uid, date('now'), :ts, 'Male', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, :now)
        """), {"uid": user_id, "ts": datetime.now(timezone.utc).isoformat(), "now": datetime.now(timezone.utc).isoformat()})
        session.commit()
        token = create_jwt(user_id, "athlete")
        audit_log_action(user_id, "REGISTER", "auth", "success")
        return {"token": token, "user_id": user_id, "role": "athlete"}
    except HTTPException:
        raise
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.post("/api/auth/reset-password")
async def reset_athlete_password(payload: dict, authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload or token_payload.get("role") not in STAFF_ROLES:
        raise HTTPException(status_code=403, detail="Staff access required (admin, coach, sports_scientist, physician)")
    target_user_id = payload.get("user_id", "")
    new_password = payload.get("new_password", "")
    if not target_user_id or not new_password or len(new_password) < 6:
        raise HTTPException(status_code=400, detail="user_id and new_password (min 6 chars) required")
    from tasks import get_session
    from auth import hash_password
    session = get_session()
    try:
        existing = session.execute(
            text("SELECT user_id FROM user_credentials WHERE user_id = :uid"),
            {"uid": target_user_id}
        ).fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Athlete not found")
        salt, pw_hash = hash_password(new_password)
        session.execute(text("""
            UPDATE user_credentials SET salt = :salt, password_hash = :hash, updated_at = :now
            WHERE user_id = :uid
        """), {"uid": target_user_id, "salt": salt, "hash": pw_hash, "now": datetime.now(timezone.utc).isoformat()})
        session.commit()
        audit_log_action(target_user_id, "PASSWORD_RESET", "auth", "success")
        return {"status": "reset", "user_id": target_user_id, "reset_by": token_payload.get("sub")}
    except HTTPException:
        raise
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.post("/api/auth/register-bulk")
async def register_athletes_bulk(payload: dict, authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload or token_payload.get("role") not in STAFF_ROLES:
        raise HTTPException(status_code=403, detail="Staff access required (admin, coach, sports_scientist, physician)")
    athletes_list = payload.get("athletes", [])
    if not athletes_list or len(athletes_list) > 200:
        raise HTTPException(status_code=400, detail="Provide 1-200 athletes in array")
    from tasks import get_session
    from auth import hash_password
    session = get_session()
    results = {"registered": [], "skipped": [], "errors": []}
    for athlete in athletes_list:
        uid = athlete.get("user_id", "").strip()
        pw = athlete.get("password", "").strip()
        if not uid or not pw or len(pw) < 6:
            results["errors"].append({"user_id": uid or "empty", "reason": "Invalid user_id or password (min 6 chars)"})
            continue
        try:
            existing = session.execute(
                text("SELECT id FROM daily_checkins WHERE user_id = :uid LIMIT 1"),
                {"uid": uid}
            ).fetchone()
            if existing:
                results["skipped"].append(uid)
                continue
            salt, pw_hash = hash_password(pw)
            session.execute(text("""
                INSERT INTO user_credentials (user_id, salt, password_hash, created_at, updated_at)
                VALUES (:uid, :salt, :hash, :now, :now)
                ON CONFLICT (user_id) DO UPDATE SET salt=:salt, password_hash=:hash, updated_at=:now
            """), {"uid": uid, "salt": salt, "hash": pw_hash, "now": datetime.now(timezone.utc).isoformat()})
            session.execute(text("""
                INSERT INTO daily_checkins (user_id, date, timestamp, gender, duration_minutes, rpe, sleep_hours, sleep_quality, stress, fatigue, muscle_soreness, daily_load, load_strength, load_endurance, load_power, created_at)
                VALUES (:uid, date('now'), :ts, 'Male', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, :now)
            """), {"uid": uid, "ts": datetime.now(timezone.utc).isoformat(), "now": datetime.now(timezone.utc).isoformat()})
            results["registered"].append(uid)
        except Exception as e:
            results["errors"].append({"user_id": uid, "reason": str(e)[:100]})
    session.commit()
    session.close()
    return {"status": "completed", "total": len(athletes_list), "results": results}

@app.get("/api/ping")
async def ping():
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}

@app.get("/api/health")
async def health_check():
    from tasks import get_capability
    cap = get_capability()
    mode = cap.get_mode()
    redis_status = "disconnected"
    if redis_client:
        try:
            redis_client.ping()
            redis_status = "connected"
        except Exception:
            pass
    available_features = ["api", "database", "dashboard"]
    unavailable_features = []
    if cap.can_use_r_engine():
        available_features.append("r_analytics_engine")
    else:
        unavailable_features.append("r_analytics_engine")
    if cap.can_use_celery():
        available_features.append("celery_async_processing")
    else:
        unavailable_features.append("celery_async_processing")
    if cap.can_use_redis():
        available_features.append("redis_queue")
    if cap.can_compute_numerical():
        available_features.append("numerical_computation")
    else:
        unavailable_features.append("numerical_computation")
    if cap.get_memory_mb() > 4000:
        available_features.extend(["local_ml_pipeline", "prophet_forecasting"])
    return {
        "status": "degraded" if unavailable_features else "healthy",
        "operating_mode": mode,
        "service": "A.T.H.E.N.A. API",
        "version": "5.0.0",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "redis": redis_status,
        "memory_available_mb": round(cap.get_memory_mb(), 0),
        "available_features": available_features,
        "unavailable_features": unavailable_features,
        "unavailable_features_note": "Features unavailable due to system resource constraints. Upgrade hardware to unlock." if unavailable_features else None
    }


@app.get("/api/health/db")
async def health_db():
    from tasks import get_engine, get_session
    try:
        s = get_session()
        s.execute(text("SELECT 1"))
        s.close()
        engine = get_engine()
        db_type = "PostgreSQL" if "postgresql" in str(engine.url) else "SQLite"
        return {
            "status": "healthy",
            "database": "connected",
            "type": db_type,
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
    except Exception as e:
        return JSONResponse(status_code=503, content={"status": "unhealthy", "error": str(e)})


def _get_org_timezone(user_id: str) -> str:
    try:
        from tasks import get_session
        session = get_session()
        result = session.execute(text("SELECT COALESCE(settings_json, '{}') FROM organizations WHERE id = (SELECT organization_id FROM daily_checkins WHERE user_id = :uid LIMIT 1)"), {"uid": user_id})
        row = result.fetchone()
        session.close()
        if row:
            settings = json.loads(row[0])
            return settings.get("timezone", "UTC")
    except Exception:
        pass
    return "UTC"

@app.post("/sync-data", response_model=SyncDataResponse)
async def sync_data(payload: SyncPayload, request: Request):
    from tasks import check_reds_training_pause, check_parq_status

    # RED-S pause check: Only trigger for IOC REDs CAT2 Orange/Red categories, not calculated EA.
    # The 2023 IOC consensus states EA cannot be accurately measured in field settings.
    reds_paused = check_reds_training_pause(payload.user_id)
    if reds_paused:
        raise HTTPException(
            status_code=403,
            detail="Training paused due to RED-S. Medical clearance required before data entry. "
                   "Please complete the IOC REDs CAT2 assessment with your medical team."
        )

    parq_cleared = check_parq_status(payload.user_id)
    if not parq_cleared:
        raise HTTPException(
            status_code=403,
            detail="PAR-Q+ screening required before data entry. Please complete the pre-participation screening."
        )

    task_data = payload.model_dump()
    task_data["_received_at"] = datetime.now(timezone.utc).isoformat()
    task_data["_batch_id"] = str(uuid.uuid4())

    if payload.stopbang_score is not None:
        from tasks import record_stopbang_assessment
        risk_level = "HIGH" if payload.stopbang_score >= 5 else "INTERMEDIATE" if payload.stopbang_score >= 3 else "LOW"
        record_stopbang_assessment(payload.user_id, payload.stopbang_score, risk_level)

    from tasks import get_capability
    cap = get_capability()
    celery_available = cap.can_use_celery()

    if not celery_available or celery_app is None:
        try:
            direct_result = await sync_data_direct(payload)
            return SyncDataResponse(
                task_id="sync-" + str(uuid.uuid4())[:8],
                status="processed",
                message="Data processed synchronously (Celery/Redis unavailable on this system)"
            )
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Synchronous processing failed: {str(e)}")

    try:
        task = celery_app.send_task(
            "tasks.process_athlete_checkin",
            args=[json.dumps(task_data)],
            queue="athena_checkins"
        )
        from tasks import audit_log
        audit_log(payload.user_id, "DATA_SYNC", "daily_checkin", "queued")
        return SyncDataResponse(
            task_id=task.id,
            status="queued",
            message="Data received and queued for processing"
        )
    except redis.exceptions.ConnectionError as e:
        logger.error(f"Redis connection error: {e}, attempting synchronous fallback")
        try:
            direct_result = await sync_data_direct(payload)
            return SyncDataResponse(
                task_id="sync-fallback-" + str(uuid.uuid4())[:8],
                status="processed",
                message="Data processed synchronously (Redis unavailable)"
            )
        except Exception as fallback_error:
            raise HTTPException(status_code=503, detail="Message queue unavailable and synchronous fallback failed")
    except Exception as e:
        logger.error(f"Unexpected error queueing task: {e}")
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")


@app.post("/sync-data/bulk")
async def sync_data_bulk(payloads: List[SyncPayload]):
    from tasks import check_reds_training_pause
    if len(payloads) > 200:
        raise HTTPException(status_code=400, detail="Maximum 200 records per bulk request. Split into smaller batches.")

    results = []
    errors = []
    for i, payload in enumerate(payloads):
        reds_paused = check_reds_training_pause(payload.user_id)
        if reds_paused:
            errors.append({
                "user_id": payload.user_id,
                "error": "RED-S medical clearance required"
            })
            continue

        try:
            task_data = payload.model_dump()
            task_data["_received_at"] = datetime.now(timezone.utc).isoformat()
            task_data["_batch_id"] = str(uuid.uuid4())
            task = celery_app.send_task(
                "tasks.process_athlete_checkin",
                args=[json.dumps(task_data)],
                queue="athena_checkins"
            )
            results.append({"user_id": payload.user_id, "task_id": task.id, "status": "queued"})
        except Exception as e:
            errors.append({"user_id": payload.user_id if hasattr(payload, 'user_id') else f"index_{i}", "error": str(e)})
    return {
        "total": len(payloads),
        "success": len(results),
        "errors": len(errors),
        "results": results,
        "error_details": errors if errors else None
    }


@app.post("/sync-data/direct")
async def sync_data_direct(payload: SyncPayload):
    from tasks import get_session, _calculate_modality_loads, check_reds_training_pause

    reds_paused = check_reds_training_pause(payload.user_id)
    if reds_paused:
        raise HTTPException(
            status_code=403,
            detail="Training paused due to RED-S. Medical clearance required before data entry."
        )

    session = get_session()
    try:
        timestamp_dt = datetime.fromisoformat(payload.timestamp)
        date_str = timestamp_dt.strftime("%Y-%m-%d")
        daily_load = round(payload.rpe * payload.duration_minutes, 2)

        modality_loads = _calculate_modality_loads(
            payload.exercise_type or "", payload.rpe, payload.duration_minutes,
            payload.sets, payload.reps, payload.weight_kg,
            payload.distance_m, payload.jump_count
        )

        session.execute(text("""
            INSERT INTO daily_checkins
                (user_id, date, timestamp, gender, duration_minutes, rpe,
                 sleep_hours, sleep_quality, stress, fatigue, muscle_soreness,
                 mood, cycle_phase, calories, ffm, daily_load,
                 load_strength, load_endurance, load_power,
                 exercise_type, injury_location, pain_level, injury_notes, rtp_date,
                 cmj_height_cm, sprint_20m_s, training_block_tag, created_at)
            VALUES
                (:uid, :date, :ts, :gender, :dur, :rpe,
                 :sh, :sq, :st, :fa, :ms,
                 :mood, :cp, :cal, :ffm, :load,
                 :ls, :le, :lp,
                 :ex, :il, :pl, :inotes, :rtp,
                 :cmj, :sprint, :block_tag, :now)
            ON CONFLICT (user_id, date) DO UPDATE SET
                timestamp = EXCLUDED.timestamp,
                gender = EXCLUDED.gender,
                duration_minutes = EXCLUDED.duration_minutes,
                rpe = EXCLUDED.rpe,
                sleep_hours = EXCLUDED.sleep_hours,
                sleep_quality = EXCLUDED.sleep_quality,
                stress = EXCLUDED.stress,
                fatigue = EXCLUDED.fatigue,
                muscle_soreness = EXCLUDED.muscle_soreness,
                mood = EXCLUDED.mood,
                cycle_phase = COALESCE(EXCLUDED.cycle_phase, daily_checkins.cycle_phase),
                calories = COALESCE(EXCLUDED.calories, daily_checkins.calories),
                ffm = COALESCE(EXCLUDED.ffm, daily_checkins.ffm),
                daily_load = EXCLUDED.daily_load,
                load_strength = EXCLUDED.load_strength,
                load_endurance = EXCLUDED.load_endurance,
                load_power = EXCLUDED.load_power,
                exercise_type = COALESCE(EXCLUDED.exercise_type, daily_checkins.exercise_type),
                injury_location = COALESCE(EXCLUDED.injury_location, daily_checkins.injury_location),
                pain_level = COALESCE(EXCLUDED.pain_level, daily_checkins.pain_level),
                injury_notes = COALESCE(EXCLUDED.injury_notes, daily_checkins.injury_notes),
                rtp_date = COALESCE(EXCLUDED.rtp_date, daily_checkins.rtp_date),
                cmj_height_cm = COALESCE(EXCLUDED.cmj_height_cm, daily_checkins.cmj_height_cm),
                sprint_20m_s = COALESCE(EXCLUDED.sprint_20m_s, daily_checkins.sprint_20m_s),
                training_block_tag = COALESCE(EXCLUDED.training_block_tag, daily_checkins.training_block_tag)
        """), {
            "uid": payload.user_id,
            "date": date_str,
            "ts": payload.timestamp,
            "gender": payload.gender,
            "dur": payload.duration_minutes,
            "rpe": payload.rpe,
            "sh": payload.sleep_hours,
            "sq": payload.sleep_quality,
            "st": payload.stress,
            "fa": payload.fatigue,
            "ms": payload.muscle_soreness,
            "mood": payload.mood or "neutral",
            "cp": payload.cycle_phase or "",
            "cal": payload.calories or 0,
            "ffm": payload.ffm or 0,
            "load": daily_load,
            "ls": modality_loads["strength"],
            "le": modality_loads["endurance"],
            "lp": modality_loads["power"],
            "ex": payload.exercise_type or "",
            "il": payload.injury_location or "",
            "pl": payload.pain_level or 0,
            "inotes": payload.injury_notes or "",
            "rtp": payload.rtp_date if payload.rtp_date else None,
            "cmj": payload.cmj_height_cm,
            "sprint": payload.sprint_20m_s,
            "block_tag": payload.training_block_tag or "",
            "now": datetime.now(timezone.utc).isoformat(),
        })

        if payload.gender == "Female":
            session.execute(text("""
                INSERT INTO female_athlete_data
                    (user_id, current_phase, contraceptive_type,
                     cramp_severity, bleeding_volume, mood_disturbance,
                     created_at, updated_at)
                VALUES
                    (:uid, :cp, :ct, :cr, :bl, :md, :now, :now)
                ON CONFLICT (user_id) DO UPDATE SET
                    current_phase = COALESCE(EXCLUDED.current_phase, female_athlete_data.current_phase),
                    contraceptive_type = COALESCE(EXCLUDED.contraceptive_type, female_athlete_data.contraceptive_type),
                    cramp_severity = COALESCE(EXCLUDED.cramp_severity, female_athlete_data.cramp_severity),
                    bleeding_volume = COALESCE(EXCLUDED.bleeding_volume, female_athlete_data.bleeding_volume),
                    mood_disturbance = COALESCE(EXCLUDED.mood_disturbance, female_athlete_data.mood_disturbance),
                    updated_at = EXCLUDED.updated_at
            """), {
                "uid": payload.user_id,
                "cp": payload.cycle_phase or "",
                "ct": payload.contraceptive_type or "",
                "cr": payload.cramp_severity or 0,
                "bl": payload.bleeding_volume or "none",
                "md": payload.mood_disturbance or 0,
                "now": datetime.now(timezone.utc).isoformat(),
            })

        if payload.reflection_text and payload.reflection_text.strip():
            session.execute(text("""
                INSERT INTO daily_reflections
                    (user_id, date, reflection_text, created_at)
                VALUES
                    (:uid, :date, :text, :now)
            """), {
                "uid": payload.user_id,
                "date": date_str,
                "text": payload.reflection_text.strip(),
                "now": datetime.now(timezone.utc).isoformat(),
            })

        if payload.stopbang_score is not None:
            risk_level = "HIGH" if payload.stopbang_score >= 5 else "INTERMEDIATE" if payload.stopbang_score >= 3 else "LOW"
            session.execute(text("""
                INSERT INTO stopbang_records
                    (user_id, assessment_date, score, risk_level, created_at)
                VALUES
                    (:uid, :adate, :score, :risk, :now)
            """), {
                "uid": payload.user_id,
                "adate": date.today().isoformat(),
                "score": payload.stopbang_score,
                "risk": risk_level,
                "now": datetime.now(timezone.utc).isoformat(),
            })

        session.commit()
        audit_log_action(payload.user_id, "SYNC_DIRECT", "daily_checkin", "success")
        return {
            "status": "synced",
            "user_id": payload.user_id,
            "date": date_str,
            "daily_load": daily_load
        }
    except Exception as e:
        session.rollback()
        logger.error(f"Direct sync failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.post("/api/stopbang")
async def record_stopbang(payload: StopBangPayload):
    from tasks import record_stopbang_assessment
    try:
        record_stopbang_assessment(payload.user_id, payload.score, payload.risk_level)
        return {"status": "recorded", "user_id": payload.user_id, "score": payload.score}
    except Exception as e:
        logger.error(f"STOP-BANG recording failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/parq")
async def submit_parq(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        user_id = payload.get("user_id")
        responses = payload.get("responses", {})
        chest_pain_during = responses.get("q2", False)
        chest_pain_at_rest = responses.get("q3", False)
        dizziness = responses.get("q4", False)
        known_heart = responses.get("q1", False)
        heart_medication = responses.get("q6", False)
        if chest_pain_during or chest_pain_at_rest or dizziness:
            cleared = 0
        elif known_heart or heart_medication:
            cleared = 1
        else:
            cleared = 1
        session.execute(text("""
            INSERT INTO parq_records
                (user_id, assessment_date, responses_json, cleared, created_at)
            VALUES
                (:uid, :adate, :resp, :cleared, :now)
            ON CONFLICT (user_id) DO UPDATE SET
                assessment_date = EXCLUDED.assessment_date,
                responses_json = EXCLUDED.responses_json,
                cleared = EXCLUDED.cleared,
                created_at = EXCLUDED.created_at
        """), {
            "uid": user_id,
            "adate": date.today().isoformat(),
            "resp": json.dumps(responses),
            "cleared": cleared,
            "now": datetime.now(timezone.utc).isoformat(),
        })
        session.commit()
        audit_log_action(user_id, "PARQ_SUBMIT", "parq_record", "success")
        return {"status": "recorded", "user_id": user_id, "cleared": bool(cleared)}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.post("/api/parental-consent")
async def create_parental_consent(payload: ParentalConsentPayload):
    from tasks import record_parental_consent
    import secrets
    token = secrets.token_urlsafe(32)
    try:
        success = record_parental_consent(
            payload.user_id,
            payload.parent_name,
            payload.parent_relation,
            payload.parent_email,
            payload.parent_phone,
            payload.expiry_date,
            token
        )
        if not success:
            raise HTTPException(status_code=500, detail="Failed to record consent")
        return {
            "status": "created",
            "user_id": payload.user_id,
            "consent_token": token,
            "consent_link": f"/consent.html?token={token}&athlete={payload.user_id}"
        }
    except Exception as e:
        logger.error(f"Parental consent failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/verify-consent")
async def verify_consent(payload: ConsentVerificationPayload):
    from tasks import verify_parental_consent
    try:
        success = verify_parental_consent(payload.token)
        if not success:
            raise HTTPException(status_code=404, detail="Invalid or expired token")
        return {"status": "verified", "token": payload.token}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Consent verification failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/reds-clearance")
async def submit_reds_clearance(payload: REDSMedicalClearancePayload, api_key: str = Depends(verify_api_key)):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            UPDATE reds_medical_referrals
            SET physician_name = :pname,
                physician_cleared = 1,
                clearance_date = :cdate,
                training_paused = 0,
                updated_at = :now
            WHERE user_id = :uid AND physician_cleared = 0
            ORDER BY referral_date DESC
            LIMIT 1
        """), {
            "uid": payload.user_id,
            "pname": payload.physician_name,
            "cdate": payload.clearance_date,
            "now": datetime.now(timezone.utc).isoformat(),
        })
        session.commit()
        audit_log_action(payload.user_id, "REDS_CLEARANCE", "reds_referral", "success")
        return {
            "status": "cleared",
            "user_id": payload.user_id,
            "message": "Training clearance granted. Athlete may resume data entry."
        }
    except Exception as e:
        session.rollback()
        logger.error(f"RED-S clearance failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.post("/api/medication-log")
async def record_medication(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        substance = payload.get("substance_name", "")
        if not substance or not substance.strip():
            raise HTTPException(status_code=400, detail="Substance name is required")
        session.execute(text("""
            INSERT INTO medication_logs
                (user_id, substance_name, dosage, frequency, prescribed_by,
                 start_date, end_date, wada_status, created_at)
            VALUES
                (:uid, :substance, :dosage, :freq, :prescribed,
                 :sdate, :edate, :wada, :now)
        """), {
            "uid": payload.get("user_id"),
            "substance": substance.strip(),
            "dosage": payload.get("dosage", ""),
            "freq": payload.get("frequency", ""),
            "prescribed": payload.get("prescribed_by", ""),
            "sdate": payload.get("start_date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "edate": payload.get("end_date") if payload.get("end_date") else None,
            "wada": "VERIFICATION REQUIRED",
            "now": datetime.now(timezone.utc).isoformat(),
        })
        session.commit()
        audit_log_action(payload.get("user_id", "unknown"), "MEDICATION_LOG", "medication", "success")
        return {
            "status": "recorded",
            "substance": substance.strip(),
            "wada_status": "VERIFICATION REQUIRED",
            "warning": "The athlete and coach MUST verify this substance against the current WADA Prohibited List before competition. A Therapeutic Use Exemption (TUE) may be required for prescribed prohibited substances.",
            "reference": "WADA Prohibited List 2026. Always consult the official WADA list."
        }
    except HTTPException:
        raise
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/reds-pause-status/{user_id}")
async def get_reds_pause_status(user_id: str):
    from tasks import check_reds_training_pause
    try:
        paused = check_reds_training_pause(user_id)
        return {"user_id": user_id, "training_paused": paused}
    except Exception as e:
        logger.error(f"RED-S status check failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/upload-csv", response_model=CsvUploadResponse)
async def upload_csv(file: UploadFile = File(...)):
    if not file.filename or not file.filename.lower().endswith(".csv"):
        raise HTTPException(status_code=400, detail="Only CSV files with .csv extension are accepted")
    MAX_CSV_SIZE_MB = 50
    content = await file.read()
    upload_count = len(list(UPLOAD_DIR.glob("*.csv"))) if UPLOAD_DIR.exists() else 0
    if upload_count > 50:
        import shutil as _shutil
        for old_file in sorted(UPLOAD_DIR.glob("*.csv"), key=lambda p: p.stat().st_mtime)[:10]:
            try:
                old_file.unlink()
            except Exception:
                pass
    if len(content) > MAX_CSV_SIZE_MB * 1024 * 1024:
        raise HTTPException(status_code=400, detail=f"CSV file exceeds {MAX_CSV_SIZE_MB}MB limit")
    safe_filename = f"{uuid.uuid4().hex}_{Path(file.filename).name}"
    file_path = UPLOAD_DIR / safe_filename
    try:
        with open(file_path, "wb") as buffer:
            buffer.write(content)
    except Exception as e:
        logger.error(f"Failed to save uploaded file: {e}")
        raise HTTPException(status_code=500, detail="Failed to save uploaded file")
    try:
        if celery_app is None:
            from tasks import process_csv_upload
            result = process_csv_upload(str(file_path), safe_filename, True)
            return CsvUploadResponse(
                task_id="csv-sync-" + str(uuid.uuid4())[:8],
                status="processed",
                message="CSV processed synchronously.",
                filename=safe_filename
            )
        task = celery_app.send_task(
            "tasks.process_csv_upload",
            args=[str(file_path), safe_filename, True],
            queue="athena_csv_processing"
        )
        return CsvUploadResponse(
            task_id=task.id,
            status="queued",
            message="CSV received. Processing and saving to database.",
            filename=safe_filename
        )
    except redis.exceptions.ConnectionError as e:
        logger.error(f"Redis connection error: {e}")
        if file_path.exists():
            file_path.unlink()
        raise HTTPException(status_code=503, detail="Message queue unavailable")
    except Exception as e:
        logger.error(f"Unexpected error queueing CSV task: {e}")
        if file_path.exists():
            file_path.unlink()
        raise HTTPException(status_code=500, detail=f"Internal server error: {str(e)}")


@app.get("/task-status/{task_id}")
async def get_task_status(task_id: str):
    if celery_app is None:
        return {"task_id": task_id, "status": "completed", "result": "Processed synchronously"}
    try:
        task = celery_app.AsyncResult(task_id)
        if task.state == "PENDING":
            return {"task_id": task_id, "status": "pending", "result": None}
        elif task.state == "FAILURE":
            return {"task_id": task_id, "status": "failed", "error": str(task.info) if task.info else "Unknown error"}
        elif task.state == "SUCCESS":
            return {"task_id": task_id, "status": "completed", "result": task.result}
        else:
            return {"task_id": task_id, "status": task.state, "result": task.info}
    except Exception as e:
        return {"task_id": task_id, "status": "error", "error": str(e)}


@app.get("/api/csv-results/{task_id}")
async def get_csv_results(task_id: str):
    if celery_app is None:
        return {"status": "completed", "results": {"status": "processed"}}
    task = celery_app.AsyncResult(task_id)
    if task.state == "SUCCESS":
        return {"status": "completed", "results": task.result}
    elif task.state == "FAILURE":
        return {"status": "failed", "error": str(task.info)}
    else:
        return {"status": task.state}


@app.get("/api/roster/all")
async def get_all_roster():
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT
                dc.user_id, dc.gender, dc.date, dc.daily_load, dc.rpe,
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
            ORDER BY dc.user_id
        """))
        athletes = []
        for row in result:
            athletes.append({
                "user_id": row[0],
                "gender": row[1] or "male",
                "last_date": str(row[2]) if row[2] else "",
                "daily_load": float(row[3]) if row[3] else 0,
                "rpe": row[4] or 0,
                "sleep_hours": float(row[5]) if row[5] else 0,
                "sleep_quality": row[6] or 0,
                "stress": row[7] or 0,
                "fatigue": row[8] or 0,
                "muscle_soreness": row[9] or 0,
                "cycle_phase": row[10] or "",
                "calories": float(row[11]) if row[11] else 0,
                "ffm": float(row[12]) if row[12] else 0,
                "mood": row[13] or "neutral",
                "exercise_type": row[14] or "",
                "injury_location": row[15] or "",
                "pain_level": row[16] or 0,
                "contraceptive_type": row[17] or "",
                "cramp_severity": row[18] or 0,
                "bleeding_volume": row[19] or "none",
                "mood_disturbance": row[20] or 0,
                "training_paused": bool(row[21]) if row[21] is not None else False,
            })
        return {"athletes": athletes, "count": len(athletes)}
    finally:
        session.close()


@app.get("/api/roster/page")
async def get_roster_paginated(
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    gender: str = Query("all"),
    search: str = Query(""),
    status: str = Query("all"),
    sort_by: str = Query("user_id"),
    sort_dir: str = Query("asc")
):
    from tasks import get_session
    session = get_session()
    try:
        offset = (page - 1) * per_page
        params = {"limit": per_page, "offset": offset}
        
        # Build WHERE clauses safely
        where_clauses = []
        if gender != "all":
            where_clauses.append("LOWER(dc.gender) = :gender")
            params["gender"] = gender.lower()
        if status == "paused":
            where_clauses.append("COALESCE(reds.training_paused, 0) = 1")
        elif status == "active":
            where_clauses.append("COALESCE(reds.training_paused, 0) = 0")
        if search:
            where_clauses.append("(LOWER(CAST(dc.user_id AS TEXT)) LIKE :search_pattern)")
            params["search_pattern"] = f"%{search.lower().replace('%', '\\%').replace('_', '\\_')}%"
        
        where = "WHERE " + " AND ".join(where_clauses) if where_clauses else ""
        
        # Validate sort column
        allowed_sorts = {"user_id", "date", "daily_load", "rpe", "sleep_hours", "stress", "fatigue"}
        if sort_by not in allowed_sorts:
            sort_by = "user_id"
        if sort_dir.lower() not in ("asc", "desc"):
            sort_dir = "asc"
        sort_col = sort_by
        sort_direction = "DESC" if sort_dir.lower() == "desc" else "ASC"

        count_result = session.execute(text(f"""
            SELECT COUNT(DISTINCT dc.user_id)
            FROM daily_checkins dc
            LEFT JOIN female_athlete_data fd ON dc.user_id = fd.user_id
            LEFT JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id AND reds.physician_cleared = 0
            {where}
        """), params)
        total = count_result.scalar()

        params["sort_col"] = sort_by
        params["sort_dir"] = sort_dir.upper()
        
        result = session.execute(text(f"""
            SELECT
                dc.user_id, dc.gender, dc.date, dc.daily_load, dc.rpe,
                dc.sleep_hours, dc.sleep_quality, dc.stress, dc.fatigue,
                dc.muscle_soreness, dc.cycle_phase, dc.calories, dc.ffm,
                COALESCE(fd.contraceptive_type, '') as contraceptive_type,
                COALESCE(fd.cramp_severity, 0) as cramp_severity,
                COALESCE(fd.bleeding_volume, 'none') as bleeding_volume,
                COALESCE(fd.mood_disturbance, 0) as mood_disturbance,
                COALESCE(reds.training_paused, 0) as training_paused
            FROM daily_checkins dc
            LEFT JOIN female_athlete_data fd ON dc.user_id = fd.user_id
            LEFT JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id AND reds.physician_cleared = 0
            {where}
            ORDER BY dc.{sort_by} {sort_dir.upper()}
            LIMIT :limit OFFSET :offset
        """), params)
        
        athletes = []
        for row in result:
            athletes.append({
                "user_id": row[0],
                "gender": row[1] or "male",
                "last_date": str(row[2]) if row[2] else "",
                "daily_load": float(row[3]) if row[3] else 0,
                "rpe": row[4] or 0,
                "sleep_hours": float(row[5]) if row[5] else 0,
                "sleep_quality": row[6] or 0,
                "stress": row[7] or 0,
                "fatigue": row[8] or 0,
                "muscle_soreness": row[9] or 0,
                "cycle_phase": row[10] or "",
                "calories": float(row[11]) if row[11] else 0,
                "ffm": float(row[12]) if row[12] else 0,
                "contraceptive_type": row[13] or "",
                "cramp_severity": row[14] or 0,
                "bleeding_volume": row[15] or "none",
                "mood_disturbance": row[16] or 0,
                "training_paused": bool(row[17]) if row[17] is not None else False,
            })
        return {
            "athletes": athletes,
            "total": total,
            "page": page,
            "per_page": per_page,
            "total_pages": max(1, (total + per_page - 1) // per_page)
        }
    finally:
        session.close()


@app.get("/api/athlete/{user_id}")
async def get_athlete_detail(user_id: str):
    from tasks import get_session, audit_log
    audit_log(user_id, "VIEW_ATHLETE", f"athlete/{user_id}", "accessed")
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT
                dc.user_id, dc.gender, dc.date, dc.daily_load, dc.rpe,
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
            WHERE dc.user_id = :uid
            ORDER BY dc.date DESC
            LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if row:
            return {
                "user_id": row[0],
                "gender": row[1],
                "last_date": str(row[2]),
                "daily_load": float(row[3]) if row[3] else 0,
                "rpe": row[4],
                "sleep_hours": float(row[5]) if row[5] else 0,
                "sleep_quality": row[6],
                "stress": row[7],
                "fatigue": row[8],
                "muscle_soreness": row[9],
                "cycle_phase": row[10],
                "calories": float(row[11]) if row[11] else 0,
                "ffm": float(row[12]) if row[12] else 0,
                "mood": row[13] or "neutral",
                "exercise_type": row[14] or "",
                "injury_location": row[15] or "",
                "pain_level": row[16] or 0,
                "contraceptive_type": row[17] or "",
                "cramp_severity": row[18] or 0,
                "bleeding_volume": row[19] or "none",
                "mood_disturbance": row[20] or 0,
                "training_paused": bool(row[21]) if row[21] is not None else False,
            }
        return JSONResponse(status_code=404, content={"detail": "Athlete not found"})
    finally:
        session.close()


@app.get("/api/db-stats")
async def get_db_stats():
    from tasks import get_session
    session = get_session()
    try:
        total = session.execute(text("SELECT COUNT(*) FROM daily_checkins")).scalar()
        users = session.execute(text("SELECT COUNT(DISTINCT user_id) FROM daily_checkins")).scalar()
        latest = session.execute(text("SELECT MAX(date) FROM daily_checkins")).scalar()
        female_count = session.execute(text("SELECT COUNT(DISTINCT user_id) FROM female_athlete_data")).scalar()
        reds_paused = session.execute(text("SELECT COUNT(DISTINCT user_id) FROM reds_medical_referrals WHERE training_paused = 1")).scalar()
        return {
            "total_records": total,
            "unique_athletes": users,
            "female_athletes": female_count or 0,
            "latest_date": str(latest) if latest else None,
            "reds_paused_athletes": reds_paused or 0
        }
    finally:
        session.close()


@app.get("/api/summary")
async def get_summary():
    from tasks import get_session
    session = get_session()
    try:
        total_users = session.execute(text("SELECT COUNT(DISTINCT user_id) FROM daily_checkins")).scalar()
        total_records = session.execute(text("SELECT COUNT(*) FROM daily_checkins")).scalar()
        male_count = session.execute(text("SELECT COUNT(DISTINCT user_id) FROM daily_checkins WHERE LOWER(gender) = 'male'")).scalar()
        female_count = session.execute(text("SELECT COUNT(DISTINCT user_id) FROM daily_checkins WHERE LOWER(gender) = 'female'")).scalar()
        avg_load = session.execute(text("SELECT AVG(daily_load) FROM daily_checkins")).scalar()
        avg_rpe = session.execute(text("SELECT AVG(rpe) FROM daily_checkins")).scalar()
        avg_sleep = session.execute(text("SELECT AVG(sleep_hours) FROM daily_checkins")).scalar()
        avg_stress = session.execute(text("SELECT AVG(stress) FROM daily_checkins")).scalar()
        latest_date = session.execute(text("SELECT MAX(date) FROM daily_checkins")).scalar()
        reds_paused = session.execute(text("SELECT COUNT(DISTINCT user_id) FROM reds_medical_referrals WHERE training_paused = 1")).scalar()
        return {
            "total_athletes": total_users,
            "total_records": total_records,
            "male_athletes": male_count,
            "female_athletes": female_count,
            "average_daily_load": round(float(avg_load) if avg_load else 0, 2),
            "average_rpe": round(float(avg_rpe) if avg_rpe else 0, 2),
            "average_sleep_hours": round(float(avg_sleep) if avg_sleep else 0, 2),
            "average_stress": round(float(avg_stress) if avg_stress else 0, 2),
            "latest_data_date": str(latest_date) if latest_date else None,
            "reds_training_paused": reds_paused or 0
        }
    finally:
        session.close()


@app.get("/api/trends/{user_id}")
async def get_trends(user_id: str, days: int = Query(28, ge=1, le=365)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, daily_load, rpe, sleep_hours, sleep_quality,
                   stress, fatigue, muscle_soreness
            FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date DESC
            LIMIT :days
        """), {"uid": user_id, "days": days})
        rows = result.fetchall()
        trends = []
        for row in reversed(rows):
            trends.append({
                "date": str(row[0]),
                "daily_load": float(row[1]) if row[1] else 0,
                "rpe": row[2],
                "sleep_hours": float(row[3]) if row[3] else 0,
                "sleep_quality": row[4],
                "stress": row[5],
                "fatigue": row[6],
                "muscle_soreness": row[7]
            })
        return {"user_id": user_id, "days": len(trends), "data": trends}
    finally:
        session.close()


@app.get("/api/female/{user_id}", dependencies=[Depends(verify_api_key)])
async def get_female_data(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT user_id, current_phase, contraceptive_type,
                   cramp_severity, bleeding_volume, mood_disturbance
            FROM female_athlete_data
            WHERE user_id = :uid
        """), {"uid": user_id})
        row = result.fetchone()
        if row:
            return {
                "user_id": row[0],
                "current_phase": row[1] or "",
                "contraceptive_type": row[2] or "",
                "cramp_severity": row[3] or 0,
                "bleeding_volume": row[4] or "none",
                "mood_disturbance": row[5] or 0
            }
        return JSONResponse(status_code=404, content={"detail": "Female data not found"})
    finally:
        session.close()


def _calculate_data_completeness(user_id: str, days: int = 28) -> dict:
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT COUNT(*) as total,
                   SUM(CASE WHEN daily_load > 0 THEN 1 ELSE 0 END) as with_load,
                   SUM(CASE WHEN sleep_hours > 0 THEN 1 ELSE 0 END) as with_sleep,
                   SUM(CASE WHEN rpe > 0 THEN 1 ELSE 0 END) as with_rpe
            FROM daily_checkins
            WHERE user_id = :uid AND date >= date('now', :days || ' days')
        """), {"uid": user_id, "days": str(-days)})
        row = result.fetchone()
        if row and row[0] > 0:
            total = row[0]
            return {
                "expected_days": days,
                "actual_days": total,
                "completeness_pct": round((total / days) * 100, 1),
                "with_load_pct": round((row[1] / total) * 100, 1) if total > 0 else 0,
                "with_sleep_pct": round((row[2] / total) * 100, 1) if total > 0 else 0,
                "with_rpe_pct": round((row[3] / total) * 100, 1) if total > 0 else 0,
                "warning": "Data completeness below 70%. Results may be unreliable." if (total / days) < 0.7 else None
            }
        return {"expected_days": days, "actual_days": 0, "completeness_pct": 0, "warning": "Insufficient data for reliable analysis."}
    finally:
        session.close()

@app.get("/api/session-plan/{user_id}")
async def get_session_plan(user_id: str):
    from tasks import get_session, _compute_acwr_python, _compute_coupled_acwr, _compute_monotony_strain, check_reds_training_pause, get_hormonal_status, _calculate_readiness
    session = get_session()
    try:
        reds_paused = check_reds_training_pause(user_id)
        if reds_paused:
            return {
                "user_id": user_id,
                "status": "TRAINING PAUSED",
                "reason": "RED-S medical referral required. Training cannot resume until physician clearance.",
                "action": "Contact medical team. Complete RED-S CAT assessment and obtain physician clearance."
            }

        result = session.execute(
            text("""
                SELECT user_id, gender, rpe, sleep_hours, sleep_quality, stress, fatigue,
                       muscle_soreness, daily_load, cycle_phase, calories, ffm,
                       exercise_type, injury_location, pain_level, mood
                FROM daily_checkins
                WHERE user_id = :uid
                ORDER BY date DESC
                LIMIT 1
            """),
            {"uid": user_id},
        )
        row = result.fetchone()
        if not row:
            return {"error": "No data found for athlete"}

        gender = row[1] or "Male"
        rpe = row[2] or 5
        sleep_hours = float(row[3]) if row[3] else 7.0
        sleep_quality = row[4] or 4
        stress_val = row[5] or 3
        fatigue_val = row[6] or 3
        soreness_val = row[7] or 2
        daily_load = float(row[8]) if row[8] else 0.0
        cycle_phase = row[9] or ""
        injury_location = row[13] or ""
        pain_level = row[14] or 0
        mood = row[15] or "neutral"

        readiness = _calculate_readiness(sleep_quality, stress_val, fatigue_val, soreness_val, sleep_hours)

        history_result = session.execute(
            text("SELECT date, daily_load FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC"),
            {"uid": user_id},
        )
        history_rows = history_result.fetchall()
        daily_loads = [float(r[1]) if r[1] else 0.0 for r in history_rows]

        acwr = 1.0
        risk_zone = "optimal"
        coupled_acwr = None
        monotony_strain = None

        hormonal_status = get_hormonal_status(user_id)
        if hormonal_status in ("NOT_FEMALE", "UNKNOWN_PHASE"):
            hormonal_status = cycle_phase if cycle_phase else ""

        if len(daily_loads) >= 28:
            acwr_data = await get_validated_acwr(daily_loads, gender, hormonal_status)
            if "acwr" in acwr_data:
                acwr = acwr_data["acwr"]
                risk_zone = acwr_data.get("risk_zone", "optimal")
        if len(daily_loads) >= 42:
            coupled_acwr = _compute_coupled_acwr(daily_loads)
        monotony_strain = _compute_monotony_strain(daily_loads)

        clinical_evidence = {}
        if readiness >= 70 and acwr <= 1.2:
            strength_rpe = "7-9"
            strength_volume = "3-5 sets, 2-5 reps"
            strength_intensity = "85-90% 1RM"
            clinical_evidence["strength"] = "High readiness + ACWR 0.8-1.2 optimal for strength development. Evidence: NSCA Guidelines (Haff & Triplett, 2016). Recommendation strength: STRONG."
        elif readiness >= 50 and acwr <= 1.4:
            strength_rpe = "6-8"
            strength_volume = "3-4 sets, 8-12 reps"
            strength_intensity = "70-80% 1RM"
            clinical_evidence["strength"] = "Moderate readiness + ACWR 1.2-1.4. Hypertrophy range appropriate. Evidence: Schoenfeld et al. (2017) JSCR. Recommendation strength: MODERATE."
        elif readiness >= 30:
            strength_rpe = "5-6"
            strength_volume = "2-3 sets, 12-15 reps"
            strength_intensity = "60-65% 1RM"
            clinical_evidence["strength"] = "Low readiness. Reduced volume to prevent overreaching. Evidence: Gabbett (2016) BJSM. ACWR >1.5 = 2.4x injury risk. Recommendation strength: STRONG."
        else:
            strength_rpe = "3-4"
            strength_volume = "2 sets, 8-10 reps"
            strength_intensity = "<50% 1RM"
            clinical_evidence["strength"] = "Critically low readiness. Active recovery only. Evidence: Meeusen et al. (2013) MSSE. Overtraining syndrome prevention. Recommendation strength: STRONG."

        # Cycle-phase based training modifications removed.
        # Evidence: UEFA consensus (2025) states "current evidence linking menstrual cycle phases
        # to performance or injury risk remains inconclusive." A 2023 umbrella review found no
        # support for phase-based periodization of strength training. Monitor symptoms, not phase.
        if gender.lower() == "female" and hormonal_status and hormonal_status not in ("", "N/A"):
            strength_volume += f" (monitor {hormonal_status} symptoms; adjust based on athlete-reported tolerance)"

        if readiness >= 60 and acwr <= 1.3:
            endurance_zone = "Zone 2-3 (RPE 4-6)"
            endurance_duration = "40-60 min"
        elif readiness >= 40:
            endurance_zone = "Zone 1-2 (RPE 2-4)"
            endurance_duration = "30-40 min"
        else:
            endurance_zone = "Zone 1 only (RPE 1-2)"
            endurance_duration = "20-30 min"

        if readiness >= 70 and acwr <= 1.2 and hormonal_status != "luteal":
            power_recommendation = "Cleared for plyometrics and explosive work"
        elif readiness >= 50 and acwr <= 1.4:
            power_recommendation = "Moderate volume, avoid maximal efforts"
        else:
            power_recommendation = "No power work, recovery priority"

        warnings = []
        if pain_level >= 5:
            warnings.append(f"Pain {pain_level}/10 in {injury_location}")
        if acwr >= 1.50:
            warnings.append("ACWR critical, high injury risk")
        elif acwr >= 1.35:
            warnings.append("ACWR elevated, do not increase load")
        if sleep_hours < 6:
            warnings.append(f"Sleep deficit ({sleep_hours}h)")
        if readiness < 40:
            warnings.append("Readiness critically low")
        if monotony_strain and monotony_strain.get("risk"):
            warnings.append(f"Training monotony high ({monotony_strain['monotony']}). Increase variation.")
        if coupled_acwr and coupled_acwr.get("risk"):
            warnings.append("Coupled ACWR indicates elevated injury risk window.")

        nutrition_note = "Maintain normal nutrition protocol."
        if gender.lower() == "female":
            if hormonal_status == "luteal":
                nutrition_note = "Luteal Phase: Increase protein intake to 1.8-2.0g/kg. Consider magnesium-rich foods."
            elif hormonal_status == "menstrual":
                nutrition_note = "Menstrual Phase: Increase iron-rich foods. Maintain hydration. Pair vitamin C with iron sources."
            elif hormonal_status == "follicular":
                nutrition_note = "Follicular Phase: Normal intake. Emphasize carbohydrate timing for high-intensity sessions."
            elif hormonal_status == "HORMONALLY_SUPPRESSED":
                nutrition_note = "Hormonally Suppressed (Contraceptive): Standard nutrition protocol. No cycle-based metabolic shifts required."
            elif hormonal_status == "ovulatory":
                nutrition_note = "Ovulatory Phase: Normal intake. Monitor for increased energy and performance potential."

        recovery_strategies = []
        if readiness < 50:
            recovery_strategies.append("Active recovery: 20 min Zone 1 walking or cycling")
            recovery_strategies.append("Contrast shower: 1 min hot, 30 sec cold, repeat 3 times")
        if stress_val >= 5:
            recovery_strategies.append("Box breathing: 4 sec inhale, 4 sec hold, 4 sec exhale, 4 sec hold, 5 min")
        if sleep_hours < 7:
            recovery_strategies.append("No caffeine after 14:00. Consistent wake time. Cool room 18-20C.")
        if gender.lower() == "female" and hormonal_status == "menstrual":
            recovery_strategies.append("Heat pack on lower abdomen. Gentle yoga: child's pose, cat-cow.")

        completeness = _calculate_data_completeness(user_id, 28)
        return {
            "user_id": user_id,
            "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "data_completeness": completeness,
            "clinical_evidence": clinical_evidence,
            "readiness": readiness,
            "acwr": round(acwr, 4),
            "risk_zone": risk_zone,
            "cycle_phase": cycle_phase or "N/A",
            "strength": {"rpe_range": strength_rpe, "volume": strength_volume, "intensity": strength_intensity},
            "endurance": {"zone": endurance_zone, "duration": endurance_duration},
            "power": power_recommendation,
            "warnings": warnings if warnings else ["No warnings"],
            "nutrition_note": nutrition_note,
            "recovery_strategies": recovery_strategies if recovery_strategies else ["Maintain normal recovery routine."],
            "coupled_acwr": coupled_acwr,
            "monotony_strain": monotony_strain,
            "reds_training_paused": reds_paused,
        }
    finally:
        session.close()


@app.get("/api/nutrition-plan/{user_id}")
async def get_nutrition_plan(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT dc.gender, dc.daily_load, dc.rpe, dc.cycle_phase, dc.calories,
                   dc.ffm, dc.sleep_hours, dc.fatigue, dc.muscle_soreness,
                   dc.exercise_type, dc.duration_minutes,
                   COALESCE(fd.bleeding_volume, 'none') as bleeding_volume
            FROM daily_checkins dc
            LEFT JOIN female_athlete_data fd ON dc.user_id = fd.user_id
            WHERE dc.user_id = :uid
            ORDER BY dc.date DESC
            LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="No data for athlete")

        gender = row[0] or "Male"
        daily_load = float(row[1]) if row[1] else 0
        rpe = row[2] or 5
        cycle_phase = row[3] or ""
        calories = float(row[4]) if row[4] else 0
        ffm = float(row[5]) if row[5] else 55
        sleep_hours = float(row[6]) if row[6] else 7
        fatigue = row[7] or 3
        soreness = row[8] or 2
        exercise_type = row[9] or ""
        duration_minutes = float(row[10]) if row[10] else 60
        bleeding = row[11] or "none"

        ea_result = await get_validated_energy_availability(
            calories, daily_load, ffm,
            exercise_type=exercise_type if exercise_type else None,
            duration_minutes=duration_minutes,
            body_mass_kg=None,
            gender=gender,
            cycle_phase=cycle_phase
        )
        if ea_result:
            ea = ea_result["ea_value"]
            ea_status = ea_result["ea_status"]
        else:
            ea = 45
            ea_status = "GREEN"

        if ea < 30:
            calorie_target = "INCREASE intake by 500-750 kcal/day immediately."
        elif ea < 45:
            calorie_target = "INCREASE intake by 300-500 kcal/day."
        else:
            calorie_target = "Maintain current intake. Fuel matches demand."

        if gender == "Female" and cycle_phase == "follicular":
            macros = "CARBOHYDRATE: 6-8 g/kg on training days. PROTEIN: 1.6-1.8 g/kg. FAT: 1.0-1.2 g/kg."
            timing = "Pre-training (2h before): 1.5 g/kg carbohydrate. Post-training (within 30 min): 0.4 g/kg protein + 1.0 g/kg carbohydrate."
        elif gender == "Female" and cycle_phase == "luteal":
            macros = "CARBOHYDRATE: 5-7 g/kg. PROTEIN: 1.6-2.0 g/kg. FAT: 1.0-1.2 g/kg."
            timing = "Normal meal timing. Monitor individual tolerance; some athletes report increased appetite in late luteal phase."
        elif gender == "Female" and cycle_phase == "menstrual":
            macros = "CARBOHYDRATE: 5-7 g/kg. PROTEIN: 1.6-1.8 g/kg. IRON-RICH foods: spinach, lentils, lean red meat."
            timing = "Pair iron sources with vitamin C (citrus, bell peppers). Avoid tea/coffee within 1 hour of iron-rich meals."
        elif gender == "Female" and cycle_phase == "ovulatory":
            macros = "CARBOHYDRATE: 6-7 g/kg. PROTEIN: 1.6-1.8 g/kg. FAT: 1.0-1.2 g/kg."
            timing = "Normal meal timing. Hydrate well for potential bloating."
        elif gender == "Male" and daily_load > 500:
            macros = "CARBOHYDRATE: 7-9 g/kg. PROTEIN: 1.6-2.0 g/kg. FAT: 1.0-1.5 g/kg."
            timing = "High-intensity days: carbohydrate loading 24h before. Post-training: 0.4 g/kg protein within 30 min."
        elif gender == "Male":
            macros = "CARBOHYDRATE: 5-7 g/kg. PROTEIN: 1.4-1.7 g/kg. FAT: 1.0-1.2 g/kg."
            timing = "Pre-training (2h): light carbohydrate snack. Post-training: protein + carbohydrate within 60 min."
        else:
            macros = "CARBOHYDRATE: 5-7 g/kg. PROTEIN: 1.4-1.8 g/kg. FAT: 1.0-1.2 g/kg."
            timing = "Balanced meals every 3-4 hours. Pre and post-training nutrition recommended."

        if bleeding == "heavy" and gender == "Female":
            supplements = "IRON: Consider 30-60mg elemental iron daily (consult physician). VITAMIN C: 500mg with iron. MAGNESIUM: 300-400mg glycinate before bed."
        elif fatigue >= 5:
            supplements = "MAGNESIUM: 300-400mg glycinate before bed. VITAMIN D: 2000-4000 IU daily if limited sun exposure. OMEGA-3: 2-3g EPA+DHA."
        elif soreness >= 5:
            supplements = "OMEGA-3: 2-3g EPA+DHA for inflammation. TART CHERRY JUICE: 30ml concentrate twice daily. MAGNESIUM: 300mg."
        else:
            supplements = "VITAMIN D: 2000 IU daily (ACSM recommendation). Consider food-first approach before supplementation."

        if daily_load > 400:
            hydration = "3-4 L total water daily. During training: 500-750ml per hour. Add electrolytes (sodium 500-700mg/L) for sessions over 90 min."
        else:
            hydration = "2.5-3 L total water daily. During training: 400-600ml per hour. Monitor urine color (pale straw = hydrated)."

        if sleep_hours < 7:
            hydration += " No caffeine after 14:00. Herbal tea (chamomile) before bed."

        return {
            "user_id": user_id,
            "calorie_target": calorie_target,
            "ea_status": ea_status,
            "energy_availability": ea,
            "macros": macros,
            "timing": timing,
            "supplements": supplements,
            "hydration": hydration,
            "reference": "IOC REDs Consensus 2023 (Mountjoy et al., BJSM). ACSM Position Stand on Nutrition and Athletic Performance (Thomas et al., 2016)."
        }
    finally:
        session.close()


@app.get("/api/iron-risk/{user_id}")
async def get_iron_risk(user_id: str):
    from tasks import get_session, _calculate_iron_risk
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT dc.gender, dc.exercise_type,
                   COALESCE(fd.bleeding_volume, 'none') as bleeding_volume
            FROM daily_checkins dc
            LEFT JOIN female_athlete_data fd ON dc.user_id = fd.user_id
            WHERE dc.user_id = :uid
            ORDER BY dc.date DESC
            LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="No data for athlete")
        gender = row[0] or "Male"
        exercise_type = row[1] or ""
        bleeding_volume = row[2] or "none"
        ferritin = None
        haemoglobin = None
        diet_type = "mixed"
        result = _calculate_iron_risk(gender, bleeding_volume, diet_type, ferritin, haemoglobin, exercise_type)
        result["user_id"] = user_id
        result["reference"] = "Peeling et al. (2008) Sports Med. Sim et al. (2019) BJSM."
        return result
    finally:
        session.close()


@app.get("/api/reds-assessment/{user_id}", dependencies=[Depends(verify_api_key)])
async def get_reds_assessment(user_id: str):
    from tasks import reds_cat_assessment
    try:
        result = reds_cat_assessment(user_id)
        if "error" in result:
            raise HTTPException(status_code=404, detail=result["error"])
        return result
    except HTTPException as e:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/phq4-record")
async def record_phq4_score(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            INSERT INTO phq4_records
                (user_id, assessment_date, total_score, anxiety_score, depression_score, created_at)
            VALUES
                (:uid, :adate, :total, :anxiety, :depression, :now)
        """), {
            "uid": payload.get("user_id"),
            "adate": payload.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "total": payload.get("total_score", 0),
            "anxiety": payload.get("anxiety_score", 0),
            "depression": payload.get("depression_score", 0),
            "now": datetime.now(timezone.utc).isoformat(),
        })
        session.commit()
        return {"status": "recorded", "user_id": payload.get("user_id")}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/phq4-history/{user_id}")
async def get_phq4_history(user_id: str, limit: int = Query(10, ge=1, le=50)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT assessment_date, total_score, anxiety_score, depression_score
            FROM phq4_records
            WHERE user_id = :uid
            ORDER BY assessment_date DESC
            LIMIT :limit
        """), {"uid": user_id, "limit": limit})
        rows = result.fetchall()
        history = []
        for row in reversed(rows):
            history.append({
                "date": str(row[0]),
                "total": row[1],
                "anxiety": row[2],
                "depression": row[3]
            })
        return {"user_id": user_id, "history": history, "current_total": history[-1]["total"] if history else None}
    finally:
        session.close()


@app.post("/api/leafq-record")
async def record_leafq_score(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            INSERT INTO leafq_records
                (user_id, assessment_date, total_score, created_at)
            VALUES
                (:uid, :adate, :score, :now)
        """), {
            "uid": payload.get("user_id"),
            "adate": payload.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "score": payload.get("total_score", 0),
            "now": datetime.now(timezone.utc).isoformat(),
        })
        session.commit()
        return {"status": "recorded", "user_id": payload.get("user_id"), "score": payload.get("total_score")}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.post("/api/brums-record")
async def record_brums_score(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            INSERT INTO brums_records
                (user_id, assessment_date, tmd_score, created_at)
            VALUES
                (:uid, :adate, :tmd, :now)
        """), {
            "uid": payload.get("user_id"),
            "adate": payload.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "tmd": payload.get("tmd_score", 0),
            "now": datetime.now(timezone.utc).isoformat(),
        })
        session.commit()
        return {"status": "recorded", "user_id": payload.get("user_id"), "tmd_score": payload.get("tmd_score")}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/brums-history/{user_id}")
async def get_brums_history(user_id: str, days: int = Query(28, ge=7, le=90)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT assessment_date, tmd_score FROM brums_records
            WHERE user_id = :uid
            ORDER BY assessment_date DESC
            LIMIT :days
        """), {"uid": user_id, "days": days})
        rows = result.fetchall()
        history = [{"date": str(r[0]), "tmd_score": r[1]} for r in reversed(rows)]
        current = history[-1]["tmd_score"] if history else None
        risk = "HIGH" if current and current > 20 else "MODERATE" if current and current > 12 else "LOW"
        return {
            "user_id": user_id,
            "history": history,
            "current_tmd": current,
            "risk_level": risk,
            "reference": "Terry PC, Lane AM, Fogarty GJ. (2003). Construct validity of the Profile of Mood States — Adolescents for use with adults. Psychology of Sport and Exercise, 4(2), 125-139. BRUMS developed from POMS-A."
        }
    finally:
        session.close()


@app.post("/api/leafq-assessment")
async def leafq_assessment(payload: dict):
    responses = payload.get("responses", {})
    injury_score = sum(int(r.get("score", 0)) for r in responses.get("injury", []))
    gi_score = sum(int(r.get("score", 0)) for r in responses.get("gi", []))
    menstrual_score = sum(int(r.get("score", 0)) for r in responses.get("menstrual", []))
    total = injury_score + gi_score + menstrual_score
    risk = total >= 8
    return {
        "total_score": total,
        "injury_score": injury_score,
        "gi_score": gi_score,
        "menstrual_score": menstrual_score,
        "risk": "HIGH" if risk else "LOW",
        "cutoff": 8,
        "recommendation": (
            "LEAF-Q score >= 8 indicates elevated risk of LEA. "
            "Conduct full RED-S CAT assessment. Consider sports dietitian referral."
            if risk
            else "LEAF-Q score within normal range. Continue regular monitoring."
        ),
        "sensitivity": "78%",
        "specificity": "90%",
        "reference": "Melin et al. (2014) BJSM; doi:10.1136/bjsports-2013-093240"
    }


@app.get("/api/fitt-vp/{user_id}")
async def get_fitt_vp_report(user_id: str, weeks: int = Query(4, ge=1, le=12)):
    from tasks import generate_fitt_vp_report
    try:
        report = generate_fitt_vp_report(user_id, weeks)
        if "error" in report:
            raise HTTPException(status_code=404, detail=report["error"])
        return report
    except HTTPException as e:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/acsm-screening")
async def acsm_screening(payload: dict):
    from tasks import acsm_screening_algorithm
    try:
        result = acsm_screening_algorithm(payload.get("responses", {}))
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/personalised-phase/{user_id}", dependencies=[Depends(verify_api_key)])
async def get_personalised_phase(user_id: str):
    from tasks import get_session, personalised_phase_recommendation
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT cycle_phase FROM daily_checkins
            WHERE user_id = :uid AND cycle_phase IS NOT NULL AND cycle_phase != ''
            ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="No cycle data found")
        phase = row[0]
        recommendation = personalised_phase_recommendation(user_id, phase)
        recommendation["user_id"] = user_id
        recommendation["current_phase"] = phase
        return recommendation
    finally:
        session.close()


@app.get("/api/cycle-prediction/{user_id}", dependencies=[Depends(verify_api_key)])
async def get_cycle_prediction(
    user_id: str,
    cycle_length: int = Query(28, ge=21, le=35),
    period_length: int = Query(5, ge=2, le=8)
):
    from tasks import predict_cycle_phases
    try:
        result = predict_cycle_phases(user_id, cycle_length, period_length)
        if "error" in result:
            raise HTTPException(status_code=404, detail=result["error"])
        return result
    except HTTPException as e:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/squad/cycle-anonymous")
async def get_anonymous_cycle_report():
    from tasks import get_session
    session = get_session()
    try:
        total_female = session.execute(
            text("SELECT COUNT(DISTINCT user_id) FROM daily_checkins WHERE LOWER(gender) = 'female'")
        ).scalar()

        phase_result = session.execute(text("""
            SELECT dc.cycle_phase, COUNT(DISTINCT dc.user_id)
            FROM daily_checkins dc
            WHERE LOWER(dc.gender) = 'female'
              AND dc.cycle_phase IS NOT NULL
              AND dc.cycle_phase != ''
              AND (dc.user_id, dc.date) IN (
                  SELECT user_id, MAX(date) FROM daily_checkins GROUP BY user_id
              )
            GROUP BY dc.cycle_phase
        """))
        phase_distribution = {row[0]: row[1] for row in phase_result}

        coach_guidance_parts = []
        for phase, count in phase_distribution.items():
            if phase == "follicular" and count >= 3:
                coach_guidance_parts.append(f"{count} in follicular phase - optimal for high-intensity work")
            elif phase == "luteal" and count >= 3:
                coach_guidance_parts.append(f"{count} in luteal phase - monitor recovery closely")
        if not coach_guidance_parts:
            coach_guidance_parts.append("No specific phase-based recommendations for current squad distribution")

        return {
            "total_female_athletes": total_female,
            "phase_distribution": phase_distribution,
            "coach_guidance": coach_guidance_parts,
            "privacy_note": "Individual athlete cycle data is anonymised.",
            "reference": "IOC Consensus Statement on RED-S (Mountjoy et al., 2023, BJSM)"
        }
    finally:
        session.close()


@app.get("/api/ramp-rate/{user_id}")
async def get_weekly_ramp_rate(user_id: str, weeks: int = Query(8, ge=4, le=24)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, daily_load FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date ASC
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 14:
            return {"error": "Need at least 14 days of data"}

        from collections import defaultdict
        import datetime as dt
        weekly_loads = defaultdict(float)
        for row in rows:
            d = dt.date.fromisoformat(str(row[0]))
            week_start = d - dt.timedelta(days=d.weekday())
            weekly_loads[week_start] += float(row[1]) if row[1] else 0

        sorted_weeks = sorted(weekly_loads.items())
        ramp_rates = []
        alerts = []

        for i in range(1, len(sorted_weeks)):
            prev_week_load = sorted_weeks[i-1][1]
            curr_week_load = sorted_weeks[i][1]
            if prev_week_load > 0:
                ramp_pct = round(((curr_week_load - prev_week_load) / prev_week_load) * 100, 1)
            else:
                ramp_pct = 0
            ramp_rates.append({
                "week_start": str(sorted_weeks[i][0]),
                "weekly_load": round(curr_week_load, 1),
                "previous_week_load": round(prev_week_load, 1),
                "ramp_rate_percent": ramp_pct
            })
            if ramp_pct > 15:
                alerts.append(f"Week {str(sorted_weeks[i][0])}: {ramp_pct}% increase EXCEEDS safe threshold.")

        recent_ramps = ramp_rates[-weeks:] if len(ramp_rates) > weeks else ramp_rates
        max_ramp = max(r["ramp_rate_percent"] for r in recent_ramps) if recent_ramps else 0

        return {
            "user_id": user_id,
            "weeks_analyzed": len(sorted_weeks),
            "ramp_rates": recent_ramps,
            "max_ramp_rate_percent": max_ramp,
            "alerts": alerts[-5:] if alerts else ["Ramp rates within safe limits."],
            "threshold_10_percent": max_ramp > 10,
            "threshold_15_percent": max_ramp > 15,
            "reference": "Gabbett TJ. (2016) BJSM. ACSM Guidelines 2024."
        }
    finally:
        session.close()


def _get_individual_baseline(user_id: str, metric: str, days: int = 28) -> dict:
    from tasks import get_session
    import math
    session = get_session()
    try:
        if metric == "readiness":
            result = session.execute(text("""
                SELECT (sleep_quality/7.0 + MIN(sleep_hours/8.0,1) + (8.0-stress)/7.0 + (8.0-fatigue)/7.0 + (8.0-muscle_soreness)/7.0)/5.0*100
                FROM daily_checkins WHERE user_id = :uid
                ORDER BY date DESC LIMIT :limit
            """), {"uid": user_id, "limit": days})
        elif metric == "daily_load":
            result = session.execute(text("""
                SELECT daily_load
                FROM daily_checkins WHERE user_id = :uid AND daily_load > 0
                ORDER BY date DESC LIMIT :limit
            """), {"uid": user_id, "limit": days})
        elif metric == "sleep_hours":
            result = session.execute(text("""
                SELECT sleep_hours
                FROM daily_checkins WHERE user_id = :uid AND sleep_hours > 0
                ORDER BY date DESC LIMIT :limit
            """), {"uid": user_id, "limit": days})
        else:
            return {"error": "Unknown metric"}
        
        rows = [float(r[0]) for r in result.fetchall() if r[0] is not None]
        if rows:
            mean_val = sum(rows) / len(rows)
            if len(rows) > 1:
                variance = sum((x - mean_val) ** 2 for x in rows) / (len(rows) - 1)
                sd_val = math.sqrt(variance)
            else:
                sd_val = 0.0
            return {
                "metric": metric,
                "baseline_mean": round(mean_val, 1),
                "baseline_sd": round(sd_val, 1),
                "baseline_period_days": days,
                "sample_size": len(rows),
                "lower_bound_1sd": round(mean_val - sd_val, 1),
                "upper_bound_1sd": round(mean_val + sd_val, 1),
                "lower_bound_2sd": round(mean_val - 2 * sd_val, 1),
                "upper_bound_2sd": round(mean_val + 2 * sd_val, 1),
            }
        return {"error": "Insufficient data for baseline"}
    finally:
        session.close()

@app.get("/api/baseline/{user_id}")
async def get_athlete_baselines(user_id: str):
    return {
        "user_id": user_id,
        "readiness": _get_individual_baseline(user_id, "readiness"),
        "daily_load": _get_individual_baseline(user_id, "daily_load"),
        "sleep_hours": _get_individual_baseline(user_id, "sleep_hours"),
        "generated_at": datetime.now(timezone.utc).isoformat()
    }

@app.get("/api/readiness-trend/{user_id}")
async def get_readiness_trend(user_id: str, days: int = Query(28, ge=7, le=90)):
    from tasks import get_session, _calculate_readiness
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, sleep_quality, stress, fatigue, muscle_soreness,
                   sleep_hours, mood
            FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date ASC
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 7:
            return {"error": "Need at least 7 days of data"}

        readiness_values = []
        dates_list = []
        for row in rows:
            r = _calculate_readiness(
                row[1] or 4, row[2] or 3, row[3] or 3,
                row[4] or 2, float(row[5]) if row[5] else 7
            )
            readiness_values.append(r)
            dates_list.append(str(row[0]))

        recent = readiness_values[-days:]
        recent_dates = dates_list[-days:]
        rolling_avg = []
        for i in range(6, len(recent)):
            rolling_avg.append(round(sum(recent[i-6:i+1]) / 7, 1))

        mean_readiness = sum(recent) / len(recent)
        variance = sum((v - mean_readiness) ** 2 for v in recent) / len(recent)
        sd_readiness = variance ** 0.5
        swc = round(0.5 * sd_readiness, 1) if sd_readiness > 0 else 5

        current_7day_avg = sum(recent[-7:]) / 7 if len(recent) >= 7 else recent[-1]
        previous_7day_avg = sum(recent[-14:-7]) / 7 if len(recent) >= 14 else current_7day_avg
        change = round(current_7day_avg - previous_7day_avg, 1)

        if change < -swc * 2:
            status = "SIGNIFICANT_DECLINE"
            action = "Readiness has significantly declined. Consider rest day and investigate causes."
        elif change < -swc:
            status = "MODERATE_DECLINE"
            action = "Readiness declining. Monitor closely. Reduce non-essential stressors."
        elif change > swc * 2:
            status = "SIGNIFICANT_IMPROVEMENT"
            action = "Readiness significantly improved. Optimal for progressive overload."
        elif change > swc:
            status = "MODERATE_IMPROVEMENT"
            action = "Readiness improving. Continue current program."
        else:
            status = "STABLE"
            action = "Readiness stable. Maintain current training plan."

        return {
            "user_id": user_id,
            "current_readiness": readiness_values[-1],
            "rolling_7day_avg": rolling_avg,
            "dates": recent_dates[6:] if len(recent_dates) >= 7 else recent_dates,
            "change_from_previous_7days": change,
            "swc": swc,
            "status": status,
            "action": action,
            "reference": "Buchheit M. (2014) Front Physiol. Thorpe et al. (2017) IJSPP."
        }
    finally:
        session.close()


@app.get("/api/rpe-validity/{user_id}")
async def check_rpe_validity(user_id: str, min_sessions: int = Query(10, ge=5, le=50)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT rpe, daily_load, duration_minutes
            FROM daily_checkins
            WHERE user_id = :uid AND daily_load > 0 AND rpe > 0
            ORDER BY date DESC
            LIMIT :limit
        """), {"uid": user_id, "limit": min_sessions + 20})
        rows = result.fetchall()
        if len(rows) < min_sessions:
            return {"error": f"Need at least {min_sessions} sessions", "available": len(rows)}

        rpe_values = [float(r[0]) for r in rows]
        load_values = [float(r[1]) for r in rows]

        n = len(rpe_values)
        sum_rpe = sum(rpe_values)
        sum_load = sum(load_values)
        sum_rpe_load = sum(r * l for r, l in zip(rpe_values, load_values))
        sum_rpe_sq = sum(r ** 2 for r in rpe_values)
        sum_load_sq = sum(l ** 2 for l in load_values)

        numerator = n * sum_rpe_load - sum_rpe * sum_load
        denominator = ((n * sum_rpe_sq - sum_rpe ** 2) * (n * sum_load_sq - sum_load ** 2)) ** 0.5

        correlation = round(numerator / denominator, 3) if denominator > 0 else 0

        if correlation >= 0.85:
            validity = "EXCELLENT"
            action = "RPE reporting highly consistent with training load. Continue current monitoring."
        elif correlation >= 0.70:
            validity = "GOOD"
            action = "RPE reporting adequately reflects training load."
        elif correlation >= 0.50:
            validity = "MODERATE"
            action = "RPE-load relationship is moderate. Consider RPE education session with athlete."
        else:
            validity = "POOR"
            action = "RPE reporting is inconsistent with training load. RPE education required. Consider alternative load monitoring."

        mean_rpe = round(sum_rpe / n, 1)
        mean_load = round(sum_load / n, 1)

        return {
            "user_id": user_id,
            "sessions_analyzed": n,
            "rpe_load_correlation": correlation,
            "validity": validity,
            "action": action,
            "mean_rpe": mean_rpe,
            "mean_load": mean_load,
            "interpretation": f"Athlete reports RPE of {mean_rpe} for average load of {mean_load} AU. Correlation r={correlation} indicates {validity.lower()} validity.",
            "reference": "Foster et al. (2001) JSCR. Scott et al. (2013) IJSPP."
        }
    finally:
        session.close()


@app.get("/api/sleep-debt/{user_id}")
async def get_sleep_debt(user_id: str, days: int = Query(14, ge=7, le=30)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, sleep_hours FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date DESC
            LIMIT :days
        """), {"uid": user_id, "days": days})
        rows = result.fetchall()
        if len(rows) < 7:
            return {"error": "Need at least 7 days of sleep data"}

        daily_deficit = []
        target_sleep = 8.0
        cumulative_debt = 0

        for row in reversed(rows):
            sleep = float(row[1]) if row[1] else 7
            deficit = target_sleep - sleep
            if deficit > 0:
                cumulative_debt += deficit
            else:
                cumulative_debt = max(0, cumulative_debt + deficit)
            daily_deficit.append({
                "date": str(row[0]),
                "sleep_hours": sleep,
                "deficit": round(deficit, 1),
                "cumulative_debt": round(cumulative_debt, 1)
            })

        current_7day_avg = round(sum(d["sleep_hours"] for d in daily_deficit[-7:]) / 7, 1) if len(daily_deficit) >= 7 else daily_deficit[-1]["sleep_hours"]
        total_debt = daily_deficit[-1]["cumulative_debt"]

        if total_debt > 8:
            status = "SEVERE_DEBT"
            action = "Cumulative sleep debt exceeds 8 hours. Significant performance and injury risk. Prioritize sleep extension immediately."
        elif total_debt > 4:
            status = "MODERATE_DEBT"
            action = "Sleep debt accumulating. Schedule nap opportunities. Extend sleep by 1-2 hours for next 3-4 days."
        elif total_debt > 2:
            status = "MILD_DEBT"
            action = "Mild sleep debt. Maintain consistent sleep schedule. No caffeine after 14:00."
        else:
            status = "ADEQUATE"
            action = "Sleep is adequate. Maintain current sleep hygiene practices."

        return {
            "user_id": user_id,
            "current_7day_avg_sleep": current_7day_avg,
            "target_sleep_hours": target_sleep,
            "cumulative_debt": total_debt,
            "status": status,
            "action": action,
            "daily_details": daily_deficit[-7:],
            "reference": "Milewski et al. (2014) JPO. Watson et al. (2017) Sleep Health."
        }
    finally:
        session.close()


@app.get("/api/squad/load-distribution")
async def get_squad_load_distribution():
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT dc.user_id, dc.gender, dc.daily_load, dc.rpe, dc.cycle_phase,
                   COALESCE(reds.training_paused, 0) as paused
            FROM daily_checkins dc
            LEFT JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id AND reds.physician_cleared = 0
            WHERE (dc.user_id, dc.date) IN (
                SELECT user_id, MAX(date) FROM daily_checkins GROUP BY user_id
            )
        """))
        rows = result.fetchall()
        if not rows:
            return {"error": "No data"}

        loads = []
        female_loads = []
        male_loads = []
        high_load = []
        low_load = []

        for row in rows:
            load_val = float(row[2]) if row[2] else 0
            rpe_val = row[3] or 0
            paused = bool(row[5])

            entry = {
                "user_id": row[0],
                "gender": row[1],
                "daily_load": load_val,
                "rpe": rpe_val,
                "paused": paused
            }
            loads.append(entry)

            if row[1] == "Female":
                female_loads.append(load_val)
            else:
                male_loads.append(load_val)

            if load_val > 500 and not paused:
                high_load.append(entry)
            if load_val < 200 and not paused:
                low_load.append(entry)

        avg_load = round(sum(l["daily_load"] for l in loads) / len(loads), 1) if loads else 0
        avg_female = round(sum(female_loads) / len(female_loads), 1) if female_loads else 0
        avg_male = round(sum(male_loads) / len(male_loads), 1) if male_loads else 0

        return {
            "total_athletes": len(loads),
            "average_load": avg_load,
            "female_average_load": avg_female,
            "male_average_load": avg_male,
            "high_load_athletes": len(high_load),
            "low_load_athletes": len(low_load),
            "high_load_list": high_load[:10],
            "recommendation": "Load distribution appears balanced." if abs(avg_female - avg_male) < 100 else "Consider reviewing load distribution between male and female squads.",
            "generated_at": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()


@app.get("/api/squad/illness-surveillance")
async def get_illness_surveillance():
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT dc.user_id, dc.symptoms_today, dc.date
            FROM daily_checkins dc
            WHERE (dc.user_id, dc.date) IN (
                SELECT user_id, MAX(date) FROM daily_checkins GROUP BY user_id
            )
            AND dc.symptoms_today IS NOT NULL AND dc.symptoms_today != ''
        """))
        rows = result.fetchall()
        total_athletes = session.execute(text("SELECT COUNT(DISTINCT user_id) FROM daily_checkins")).scalar()
        symptomatic = []
        for row in rows:
            symptomatic.append({
                "user_id": row[0],
                "symptoms": row[1],
                "date": str(row[2])
            })
        pct_symptomatic = round(len(symptomatic) / total_athletes * 100, 1) if total_athletes > 0 else 0
        alert = pct_symptomatic > 15
        return {
            "total_athletes": total_athletes,
            "symptomatic_count": len(symptomatic),
            "percentage": pct_symptomatic,
            "cluster_alert": alert,
            "action": "Consider enhanced hygiene, mask use, and training load reduction for affected athletes." if alert else "No illness cluster detected.",
            "symptomatic_athletes": symptomatic if len(symptomatic) <= 20 else symptomatic[:20],
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "reference": "Schwellnus et al. (2016) BJSM. IOC Consensus on Illness in Elite Sport."
        }
    finally:
        session.close()


@app.get("/api/squad/heatmap")
async def get_squad_heatmap():
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT dc.user_id, dc.gender, dc.daily_load, dc.rpe,
                   dc.sleep_hours, dc.sleep_quality, dc.stress, dc.fatigue,
                   dc.muscle_soreness, dc.cycle_phase, dc.calories, dc.ffm,
                   dc.mood, dc.injury_location, dc.pain_level,
                   COALESCE(reds.training_paused, 0) as training_paused
            FROM daily_checkins dc
            LEFT JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id AND reds.physician_cleared = 0
            WHERE (dc.user_id, dc.date) IN (
                SELECT user_id, MAX(date) FROM daily_checkins GROUP BY user_id
            )
            ORDER BY dc.user_id
        """))
        rows = result.fetchall()
        athletes_risk = []
        for row in rows:
            user_id = row[0]
            gender = row[1] or "male"
            load = float(row[2]) if row[2] else 0
            rpe = row[3] or 0
            sleep_hours = float(row[4]) if row[4] else 0
            sleep_quality = row[5] or 0
            stress = row[6] or 0
            fatigue = row[7] or 0
            soreness = row[8] or 0
            cycle_phase = row[9] or ""
            calories = float(row[10]) if row[10] else 0
            ffm = float(row[11]) if row[11] else 0
            mood = row[12] or "neutral"
            injury = row[13] or ""
            pain = row[14] or 0
            paused = bool(row[15]) if row[15] is not None else False

            readiness_score = round(((sleep_quality/7)*100 + min((sleep_hours/8)*100, 100) + ((8-stress)/7)*100 + ((8-fatigue)/7)*100 + ((8-soreness)/7)*100) / 5)

            ea = None
            if calories > 0 and ffm > 0 and load > 0:
                ea_result = await get_validated_energy_availability(
                    calories, load, ffm,
                    exercise_type=None,
                    duration_minutes=60,
                    body_mass_kg=None
                )
                if ea_result:
                    ea = ea_result["ea_value"]

            risk_score = 0
            flags = []
            if readiness_score < 40:
                risk_score += 30
                flags.append("LOW_READINESS")
            elif readiness_score < 60:
                risk_score += 15
                flags.append("MOD_READINESS")
            if load > 500:
                risk_score += 20
                flags.append("HIGH_LOAD")
            if sleep_hours < 6:
                risk_score += 15
                flags.append("SLEEP_DEFICIT")
            if stress >= 6:
                risk_score += 15
                flags.append("HIGH_STRESS")
            if fatigue >= 6:
                risk_score += 15
                flags.append("HIGH_FATIGUE")
            if pain >= 5:
                risk_score += 20
                flags.append("PAIN")
            if ea is not None and ea < 30:
                risk_score += 25
                flags.append("RED_S")
            if paused:
                risk_score = 100
                flags = ["TRAINING_PAUSED"]

            if risk_score >= 50:
                color = "#ff2244"
                zone = "RED"
            elif risk_score >= 25:
                color = "#ffaa00"
                zone = "AMBER"
            else:
                color = "#00ff88"
                zone = "GREEN"

            athletes_risk.append({
                "user_id": user_id,
                "gender": gender,
                "risk_score": risk_score,
                "zone": zone,
                "color": color,
                "readiness": readiness_score,
                "daily_load": load,
                "sleep_hours": sleep_hours,
                "flags": flags,
                "cycle_phase": cycle_phase,
                "energy_availability": ea,
                "training_paused": paused
            })

        athletes_risk.sort(key=lambda x: x["risk_score"], reverse=True)
        red_count = sum(1 for a in athletes_risk if a["zone"] == "RED")
        amber_count = sum(1 for a in athletes_risk if a["zone"] == "AMBER")
        green_count = sum(1 for a in athletes_risk if a["zone"] == "GREEN")
        return {
            "athletes": athletes_risk,
            "total": len(athletes_risk),
            "summary": {
                "red": red_count,
                "amber": amber_count,
                "green": green_count
            },
            "generated_at": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()


@app.delete("/api/athlete/{user_id}")
async def delete_athlete_data(user_id: str, authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload or token_payload.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Admin access required")
    from tasks import get_session
    session = get_session()
    try:
        tables = [
            "daily_checkins", "female_athlete_data", "alert_log",
            "cycle_response_history", "movement_screenings", "daily_reflections",
            "stopbang_records", "parental_consents", "reds_medical_referrals",
            "phq4_records", "leafq_records", "brums_records",
            "coach_athlete_checkins", "recovery_compliance", "sleep_architecture",
            "blood_biomarkers", "environmental_logs", "psychological_assessments",
            "medication_logs", "movement_risk_flags", "dexa_scans",
            "health_metrics", "clinical_notes", "wut_hydration_logs",
            "concussion_grtp", "rtp_clearances", "reds_return_to_play",
            "adverse_events", "recommendation_feedback", "parq_records",
            "athlete_consents", "user_credentials", "para_classifications",
            "training_programs", "nutrition_periodization"
        ]
        deleted = {}
        for table in tables:
            result = session.execute(
                text(f"DELETE FROM {table} WHERE user_id = :uid"),
                {"uid": user_id}
            )
            deleted[table] = result.rowcount
        session.commit()
        total = sum(deleted.values())
        if total == 0:
            return JSONResponse(status_code=404, content={"detail": "No data found for athlete"})
        return {
            "status": "deleted",
            "user_id": user_id,
            "records_removed": total,
            "breakdown": deleted,
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.post("/api/movement-screening", dependencies=[Depends(verify_api_key)])
async def record_movement_screening(
    user_id: str = Form(...),
    screen_type: str = Form(...),
    overhead_squat_score: int = Form(None),
    single_leg_squat_score: int = Form(None),
    push_up_test_reps: int = Form(None),
    compensations_json: str = Form(None)
):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            INSERT INTO movement_screenings
                (user_id, screen_date, screen_type, overhead_squat_score,
                 single_leg_squat_score, push_up_test_reps, compensations_json, created_at)
            VALUES
                (:uid, :sdate, :stype, :ohsa, :sls, :pu, :comp, :now)
        """), {
            "uid": user_id,
            "sdate": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "stype": screen_type,
            "ohsa": overhead_squat_score,
            "sls": single_leg_squat_score,
            "pu": push_up_test_reps,
            "comp": compensations_json,
            "now": datetime.now(timezone.utc).isoformat(),
        })
        session.commit()
        return {"status": "recorded", "user_id": user_id, "screen_type": screen_type}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.post("/api/alerts", dependencies=[Depends(verify_api_key)])
async def create_alert(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            INSERT INTO alert_log
                (user_id, alert_type, severity, title, body, created_at)
            VALUES
                (:uid, :type, :severity, :title, :body, :now)
        """), {
            "uid": payload.get("user_id"),
            "type": payload.get("alert_type", "general"),
            "severity": payload.get("severity", "info"),
            "title": payload.get("title", ""),
            "body": payload.get("body", ""),
            "now": datetime.now(timezone.utc).isoformat()
        })
        session.commit()
        return {"status": "created"}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/export/csv")
async def export_csv(user_id: str = Query(None), training_block_tag: str = Query(None), api_key: str = Depends(verify_api_key)):
    from tasks import get_session, get_capability
    cap = get_capability()
    max_rows = 5000 if cap.get_mode() in ("embedded", "minimal") else 50000
    session = get_session()
    try:
        if user_id:
            result = session.execute(
                text(f"SELECT * FROM daily_checkins WHERE user_id = :uid ORDER BY date LIMIT {max_rows}"),
                {"uid": user_id}
            )
        elif training_block_tag:
            result = session.execute(
                text(f"SELECT * FROM daily_checkins WHERE training_block_tag = :tag ORDER BY user_id, date LIMIT {max_rows}"),
                {"tag": training_block_tag}
            )
        else:
            result = session.execute(
                text(f"SELECT * FROM daily_checkins ORDER BY user_id, date LIMIT {max_rows}")
            )
        rows = result.fetchall()
        if not rows:
            return JSONResponse(status_code=404, content={"detail": "No data found"})
        output = io.StringIO()
        headers = "user_id,date,gender,duration_minutes,rpe,sleep_hours,sleep_quality,stress,fatigue,muscle_soreness,cycle_phase,mood,exercise_type,injury_location,pain_level,calories,ffm,daily_load,load_strength,load_endurance,load_power,cmj_height_cm,sprint_20m_s,training_block_tag\n"
        output.write(headers)
        for row in rows:
            output.write(
                f"{row.user_id},{row.date},{row.gender},{row.duration_minutes},"
                f"{row.rpe},{row.sleep_hours},{row.sleep_quality},{row.stress},"
                f"{row.fatigue},{row.muscle_soreness},{row.cycle_phase or ''},"
                f"{getattr(row, 'mood', '') or ''},{getattr(row, 'exercise_type', '') or ''},"
                f"{getattr(row, 'injury_location', '') or ''},{getattr(row, 'pain_level', '') or ''},"
                f"{row.calories or ''},{row.ffm or ''},{row.daily_load},"
                f"{getattr(row, 'load_strength', 0)},{getattr(row, 'load_endurance', 0)},{getattr(row, 'load_power', 0)},"
                f"{getattr(row, 'cmj_height_cm', '') or ''},{getattr(row, 'sprint_20m_s', '') or ''},"
                f"{getattr(row, 'training_block_tag', '') or ''}\n"
            )
        output.seek(0)
        filename = f"athena_export_{user_id or training_block_tag or 'all'}.csv"
        return StreamingResponse(
            output,
            media_type="text/csv",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
    finally:
        session.close()


@app.get("/api/export/research", dependencies=[Depends(verify_api_key)])
async def export_research_data(training_block_tag: str = Query(...)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(
            text("SELECT * FROM daily_checkins WHERE training_block_tag = :tag ORDER BY user_id, date"),
            {"tag": training_block_tag}
        )
        rows = result.fetchall()
        if not rows:
            return JSONResponse(status_code=404, content={"detail": "No data found for block tag"})

        output = io.StringIO()
        headers = "user_id,date,gender,duration_minutes,rpe,sleep_hours,sleep_quality,stress,fatigue,muscle_soreness,cycle_phase,mood,exercise_type,daily_load,load_strength,load_endurance,load_power,cmj_height_cm,sprint_20m_s,calories,ffm,injury_location,pain_level,training_block_tag\n"
        output.write(headers)
        for row in rows:
            output.write(
                f"{row.user_id},{row.date},{row.gender},{row.duration_minutes},"
                f"{row.rpe},{row.sleep_hours},{row.sleep_quality},{row.stress},"
                f"{row.fatigue},{row.muscle_soreness},{row.cycle_phase or ''},"
                f"{getattr(row, 'mood', '') or ''},{getattr(row, 'exercise_type', '') or ''},"
                f"{row.daily_load},{getattr(row, 'load_strength', 0)},{getattr(row, 'load_endurance', 0)},"
                f"{getattr(row, 'load_power', 0)},{getattr(row, 'cmj_height_cm', '') or ''},"
                f"{getattr(row, 'sprint_20m_s', '') or ''},{row.calories or ''},{row.ffm or ''},"
                f"{getattr(row, 'injury_location', '') or ''},{getattr(row, 'pain_level', '') or ''},"
                f"{getattr(row, 'training_block_tag', '') or ''}\n"
            )
        output.seek(0)
        filename = f"athena_research_{training_block_tag}.csv"
        return StreamingResponse(
            output,
            media_type="text/csv",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
    finally:
        session.close()

@app.get("/api/my-data/export")
async def export_my_data(authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload:
        raise HTTPException(status_code=401, detail="Invalid token")
    user_id = token_payload.get("sub")
    return await export_research_ready_data(user_id, anonymize=False)

@app.get("/api/my-data/delete")
async def delete_my_data(authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload:
        raise HTTPException(status_code=401, detail="Invalid token")
    user_id = token_payload.get("sub")
    return await delete_athlete_data(user_id, authorization=authorization)

@app.get("/api/export/research-ready/{user_id}")
async def export_research_ready_data(user_id: str, anonymize: bool = True):
    from tasks import get_session
    import csv
    import io
    session = get_session()
    try:
        consent_check = session.execute(text("SELECT consent_research FROM athlete_consents WHERE user_id = :uid"), {"uid": user_id})
        consent_row = consent_check.fetchone()
        if not consent_row or not consent_row[0]:
            raise HTTPException(status_code=403, detail="Athlete has not consented to research use of their data.")
        result = session.execute(text("""
            SELECT date, daily_load, rpe, duration_minutes, sleep_hours, sleep_quality,
                   stress, fatigue, muscle_soreness, mood, cycle_phase, calories, ffm,
                   exercise_type, injury_location, pain_level, cmj_height_cm, sprint_20m_s,
                   training_block_tag, respiratory_rate, perceived_recovery, urine_color,
                   basal_body_temp_c, travel_from_tz, travel_to_tz, flight_duration
            FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC
        """), {"uid": user_id})
        rows = result.fetchall()
        if not rows:
            raise HTTPException(status_code=404, detail="No data found")

        output = io.StringIO()
        writer = csv.writer(output)
        headers = ["date", "daily_load_au", "rpe", "duration_min", "sleep_hours", "sleep_quality_1_7",
                   "stress_1_7", "fatigue_1_7", "muscle_soreness_1_7", "mood", "cycle_phase",
                   "calories_kcal", "ffm_kg", "exercise_type", "injury_location", "pain_0_10",
                   "cmj_height_cm", "sprint_20m_s", "training_block_tag", "respiratory_rate",
                   "perceived_recovery_0_10", "urine_color_1_8", "basal_body_temp_c",
                   "travel_from_tz", "travel_to_tz", "flight_duration_h"]
        writer.writerow(headers)

        for row in rows:
            writer.writerow([
                row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8],
                row[9] if row[9] else "", row[10] if row[10] else "", row[11] if row[11] else "",
                row[12] if row[12] else "", row[13] if row[13] else "", row[14] if row[14] else "",
                row[15] if row[15] is not None else "", row[16] if row[16] else "",
                row[17] if row[17] else "", row[18] if row[18] else "", row[19] if row[19] else "",
                row[20] if row[20] else "", row[21] if row[21] else "", row[22] if row[22] else "",
                row[23] if row[23] else "", row[24] if row[24] else "", row[25] if row[25] else ""
            ])

        output.seek(0)
        filename = f"research_data_{'anon' if anonymize else user_id}.csv"

        codebook = {
            "daily_load_au": "Session-RPE load (RPE x duration_min). Foster et al. (2001).",
            "rpe": "Borg CR-10 Rating of Perceived Exertion. 1-10 scale.",
            "sleep_quality_1_7": "Self-reported sleep quality. 1=very poor, 7=excellent.",
            "stress_1_7": "Self-reported stress. 1=no stress, 7=extreme stress.",
            "fatigue_1_7": "Self-reported fatigue. 1=no fatigue, 7=extreme fatigue.",
            "muscle_soreness_1_7": "Self-reported muscle soreness. 1=no soreness, 7=extreme soreness.",
            "cycle_phase": "menstrual/follicular/ovulatory/luteal. Self-reported or calendar-predicted.",
            "cmj_height_cm": "Counter-movement jump height in centimeters.",
            "sprint_20m_s": "20-meter sprint time in seconds.",
            "respiratory_rate": "Resting respiratory rate in breaths per minute.",
            "urine_color_1_8": "Armstrong urine color scale. 1=pale straw, 8=dark brown.",
            "basal_body_temp_c": "Basal body temperature in Celsius."
        }

        return StreamingResponse(
            output,
            media_type="text/csv",
            headers={
                "Content-Disposition": f"attachment; filename={filename}",
                "X-Codebook": str(codebook)
            }
        )
    finally:
        session.close()


@app.get("/api/fhir/observation/{user_id}")
async def export_fhir_observations(user_id: str, authorization: str = Header(None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")
    token = authorization.replace("Bearer ", "")
    token_payload = verify_jwt(token)
    if not token_payload or token_payload.get("role") not in STAFF_ROLES:
        raise HTTPException(status_code=403, detail="Insufficient permissions")
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, daily_load, rpe, sleep_hours, sleep_quality, stress, fatigue,
                   muscle_soreness, mood, cycle_phase, calories, ffm, cmj_height_cm, sprint_20m_s
            FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC
        """), {"uid": user_id})
        rows = result.fetchall()
        observations = []
        for row in rows:
            date_str = str(row[0])
            observations.append({
                "resourceType": "Observation",
                "subject": {"reference": f"Patient/{user_id}"},
                "effectiveDateTime": date_str,
                "component": [
                    {"code": {"text": "Training Load"}, "valueQuantity": {"value": float(row[1] or 0), "unit": "AU"}},
                    {"code": {"text": "RPE"}, "valueQuantity": {"value": row[2] or 0, "unit": "/10"}},
                    {"code": {"text": "Sleep Hours"}, "valueQuantity": {"value": float(row[3] or 0), "unit": "h"}},
                    {"code": {"text": "Readiness"}, "valueQuantity": {"value": round(((row[5] or 4)/7.0 + min((float(row[3] or 7))/8.0, 1) + (8.0-(row[6] or 3))/7.0 + (8.0-(row[7] or 3))/7.0 + (8.0-(row[8] or 2))/7.0)/5.0*100), "unit": "%"}},
                ]
            })
        return {"resourceType": "Bundle", "type": "collection", "entry": observations, "total": len(observations)}
    finally:
        session.close()

@app.get("/api/export/squad-research-data")
async def export_squad_research_data(
    gender_filter: str = Query("all"),
    min_days: int = Query(28),
    training_block_tag: str = Query(None)
):
    from tasks import get_session
    import csv
    import io
    session = get_session()
    try:
        where_clauses = []
        if gender_filter != "all":
            where_clauses.append(f"LOWER(gender) = '{gender_filter.lower()}'")
        if training_block_tag:
            where_clauses.append(f"training_block_tag = '{training_block_tag}'")

        subquery_where = " AND ".join(where_clauses) if where_clauses else "1=1"

        result = session.execute(text(f"""
            SELECT user_id, date, daily_load, rpe, duration_minutes, sleep_hours, sleep_quality,
                   stress, fatigue, muscle_soreness, cycle_phase, calories, ffm, exercise_type,
                   injury_location, pain_level, cmj_height_cm, sprint_20m_s, training_block_tag
            FROM daily_checkins
            WHERE user_id IN (
                SELECT user_id FROM daily_checkins
                WHERE {subquery_where}
                GROUP BY user_id HAVING COUNT(*) >= :min_days
            )
            ORDER BY user_id, date ASC
        """), {"min_days": min_days})

        rows = result.fetchall()
        if not rows:
            raise HTTPException(status_code=404, detail="No data matching criteria")

        output = io.StringIO()
        writer = csv.writer(output)
        headers = ["athlete_id", "date", "daily_load_au", "rpe", "duration_min", "sleep_hours",
                   "sleep_quality_1_7", "stress_1_7", "fatigue_1_7", "muscle_soreness_1_7",
                   "cycle_phase", "calories_kcal", "ffm_kg", "exercise_type", "injury_location",
                   "pain_0_10", "cmj_height_cm", "sprint_20m_s", "training_block_tag"]
        writer.writerow(headers)

        for row in rows:
            writer.writerow([
                f"ATH_{hash(row[0]) % 10000:04d}" if True else row[0],  # Anonymized: one-way hash with research ID
                row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9],
                row[10] if row[10] else "", row[11] if row[11] else "", row[12] if row[12] else "",
                row[13] if row[13] else "", row[14] if row[14] else "", row[15] if row[15] is not None else "",
                row[16] if row[16] else "", row[17] if row[17] else "", row[18] if row[18] else ""
            ])

        output.seek(0)
        filename = f"squad_research_data_n{len(rows)}.csv"

        return StreamingResponse(
            output,
            media_type="text/csv",
            headers={
                "Content-Disposition": f"attachment; filename={filename}",
                "X-Sample-Size": str(len(rows)),
                "X-Unique-Athletes": str(len(set(r[0] for r in rows)))
            }
        )
    finally:
        session.close()

@app.post("/api/coach-checkin")
async def record_coach_checkin(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            INSERT INTO coach_athlete_checkins
                (user_id, coach_id, checkin_date, topic, athlete_concern,
                 coach_response, agreed_action, follow_up_date, created_at)
            VALUES
                (:uid, :cid, :cdate, :topic, :concern,
                 :response, :action, :followup, :now)
        """), {
            "uid": payload.get("user_id"),
            "cid": payload.get("coach_id", "coach_default"),
            "cdate": payload.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "topic": payload.get("topic", "general"),
            "concern": payload.get("athlete_concern", ""),
            "response": payload.get("coach_response", ""),
            "action": payload.get("agreed_action", ""),
            "followup": payload.get("follow_up_date") if payload.get("follow_up_date") else None,
            "now": datetime.now(timezone.utc).isoformat(),
        })
        session.commit()
        return {"status": "recorded"}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/coach-checkins/{user_id}")
async def get_coach_checkins(user_id: str, limit: int = Query(5, ge=1, le=20)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT checkin_date, topic, athlete_concern, coach_response,
                   agreed_action, follow_up_date
            FROM coach_athlete_checkins
            WHERE user_id = :uid
            ORDER BY checkin_date DESC
            LIMIT :limit
        """), {"uid": user_id, "limit": limit})
        rows = result.fetchall()
        checkins = []
        for row in rows:
            checkins.append({
                "date": str(row[0]),
                "topic": row[1],
                "athlete_concern": row[2] or "",
                "coach_response": row[3] or "",
                "agreed_action": row[4] or "",
                "follow_up_date": str(row[5]) if row[5] else None
            })
        return {"user_id": user_id, "checkins": checkins, "count": len(checkins)}
    finally:
        session.close()


@app.post("/api/reflection", dependencies=[Depends(verify_api_key)])
async def save_reflection(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(
            text("""
                INSERT INTO daily_reflections
                    (user_id, date, reflection_text, created_at)
                VALUES
                    (:uid, :date, :text, :now)
            """),
            {
                "uid": payload.get("user_id"),
                "date": payload.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
                "text": payload.get("reflection_text", ""),
                "now": datetime.now(timezone.utc).isoformat(),
            },
        )
        session.commit()
        return {"status": "saved"}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/reflections/{user_id}", dependencies=[Depends(verify_api_key)])
async def get_reflections(user_id: str, limit: int = Query(7, ge=1, le=90)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(
            text("""
                SELECT date, reflection_text FROM daily_reflections
                WHERE user_id = :uid
                ORDER BY date DESC
                LIMIT :limit
            """),
            {"uid": user_id, "limit": limit},
        )
        rows = result.fetchall()
        reflections = [{"date": str(r[0]), "text": r[1]} for r in rows]
        return {"user_id": user_id, "reflections": reflections}
    finally:
        session.close()


@app.get("/api/monotony/{user_id}")
async def get_monotony_strain(user_id: str):
    from tasks import get_session, _compute_monotony_strain
    session = get_session()
    try:
        result = session.execute(
            text("SELECT daily_load FROM daily_checkins WHERE user_id = :uid ORDER BY date DESC LIMIT 42"),
            {"uid": user_id},
        )
        rows = result.fetchall()
        loads = [float(r[0]) if r[0] else 0.0 for r in rows]
        if len(loads) < 7:
            return {"error": "Insufficient data"}
        return _compute_monotony_strain(loads)
    finally:
        session.close()


@app.post("/api/orthostatic-assessment")
async def assess_orthostatic(payload: dict):
    hr_supine = payload.get("hr_supine")
    hr_stand_1 = payload.get("hr_stand_1")
    hr_stand_5 = payload.get("hr_stand_5")
    symptoms = payload.get("symptoms", "")
    age = payload.get("age_years", 25)

    if not hr_supine or not hr_stand_1:
        return {"error": "HR supine and HR standing 1 min required"}

    delta_hr = hr_stand_1 - hr_supine
    recovery_hr = hr_stand_1 - hr_stand_5 if hr_stand_5 else None

    if age <= 19:
        threshold = 40
    else:
        threshold = 30

    if delta_hr > threshold:
        result = "ABNORMAL"
        interpretation = f"HR increase of {delta_hr} bpm exceeds threshold of {threshold} bpm. Suggests possible autonomic dysfunction. Consider medical evaluation."
        severity = "HIGH"
    elif delta_hr > 20:
        result = "BORDERLINE"
        interpretation = f"HR increase of {delta_hr} bpm is borderline. Monitor trends over consecutive days."
        severity = "MODERATE"
    else:
        result = "NORMAL"
        interpretation = f"HR increase of {delta_hr} bpm is within normal limits."
        severity = "LOW"

    if symptoms and symptoms != "none":
        interpretation += f" Reported {symptoms} on standing, which supports orthostatic intolerance."
        if severity == "LOW":
            severity = "MODERATE"

    if recovery_hr and recovery_hr > 10:
        interpretation += f" Poor recovery: HR remained elevated by {recovery_hr} bpm after 5 minutes."
        if severity == "LOW":
            severity = "MODERATE"

    return {
        "delta_hr_bpm": delta_hr,
        "threshold": threshold,
        "result": result,
        "severity": severity,
        "interpretation": interpretation,
        "recommendations": [
            "Increase fluid and sodium intake" if severity != "LOW" else "Maintain current hydration",
            "Avoid rapid postural changes",
            "Supine or seated recovery after training",
            "Medical referral recommended" if severity == "HIGH" else "Repeat test weekly to monitor"
        ],
        "reference": "Meeusen et al. (2013) MSSE. Mountjoy et al. (2023) BJSM."
    }


@app.get("/api/body-composition/{user_id}")
async def get_body_composition_trend(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, ffm, calories, daily_load, gender, sleep_hours
            FROM daily_checkins
            WHERE user_id = :uid AND ffm IS NOT NULL AND ffm > 0
            ORDER BY date DESC
            LIMIT 30
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 2:
            return {"error": "Need at least 2 FFM measurements", "available": len(rows)}

        ffm_values = []
        dates_list = []
        ea_values = []
        for row in reversed(rows):
            dates_list.append(str(row[0]))
            ffm_val = float(row[1])
            ffm_values.append(ffm_val)
            cal = float(row[2]) if row[2] else 0
            load = float(row[3]) if row[3] else 0
            if ffm_val > 0 and cal > 0:
                ea_values.append(round((cal - (load * 0.10 * ffm_val)) / ffm_val, 1))
            else:
                ea_values.append(None)

        current_ffm = ffm_values[-1]
        first_ffm = ffm_values[0]
        ffm_change = round(current_ffm - first_ffm, 1)
        ffm_change_pct = round((ffm_change / first_ffm) * 100, 1) if first_ffm > 0 else 0

        if ffm_change < -1.0:
            warning = "FFM declining. Possible muscle loss. Review energy availability and protein intake."
        elif ffm_change > 2.0 and len(rows) >= 14:
            warning = "FFM increasing. Monitor whether gain is functional for sport."
        else:
            warning = "FFM stable."

        return {
            "user_id": user_id,
            "current_ffm_kg": current_ffm,
            "ffm_change_kg": ffm_change,
            "ffm_change_percent": ffm_change_pct,
            "trend": ffm_values,
            "dates": dates_list,
            "energy_availability_trend": ea_values,
            "warning": warning,
            "reference": "Boer P. (1984) Am J Physiol. Santos et al. (2014) EJAP."
        }
    finally:
        session.close()


@app.get("/api/reporting-quality/{user_id}")
async def get_reporting_quality(user_id: str, days: int = Query(28, ge=14, le=90)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT rpe, sleep_hours, sleep_quality, stress, fatigue, muscle_soreness, mood
            FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date DESC
            LIMIT :days
        """), {"uid": user_id, "days": days})
        rows = result.fetchall()
        if len(rows) < 14:
            return {"error": "Need at least 14 days of data", "available": len(rows)}
        rpe_vals = [r[0] for r in rows if r[0] is not None]
        stress_vals = [r[3] for r in rows if r[3] is not None]
        fatigue_vals = [r[4] for r in rows if r[4] is not None]
        soreness_vals = [r[5] for r in rows if r[5] is not None]

        def cv_calc(values):
            if len(values) < 5:
                return None
            mean_val = sum(values) / len(values)
            variance = sum((v - mean_val) ** 2 for v in values) / len(values)
            sd_val = variance ** 0.5
            return round((sd_val / mean_val) * 100, 1) if mean_val > 0 else 0

        rpe_cv = cv_calc(rpe_vals)
        stress_cv = cv_calc(stress_vals)
        fatigue_cv = cv_calc(fatigue_vals)
        soreness_cv = cv_calc(soreness_vals)
        flags = []
        quality_score = 100
        if rpe_cv is not None and rpe_cv < 10:
            flags.append("Low RPE variance: possible stereotyped reporting.")
            quality_score -= 20
        if rpe_cv is not None and rpe_cv > 60:
            flags.append("Very high RPE variance: possible inconsistent reporting.")
            quality_score -= 15
        if stress_cv is not None and stress_cv < 8:
            flags.append("Low stress variance: check for flatlining responses.")
            quality_score -= 20
        if fatigue_cv is not None and fatigue_cv < 8:
            flags.append("Low fatigue variance: possible inattentive reporting.")
            quality_score -= 20
        if soreness_cv is not None and soreness_cv < 8:
            flags.append("Low soreness variance: possible stereotyped responses.")
            quality_score -= 20
        quality_score = max(0, quality_score)
        if quality_score >= 80:
            rating = "EXCELLENT"
        elif quality_score >= 60:
            rating = "GOOD"
        elif quality_score >= 40:
            rating = "FAIR"
        else:
            rating = "POOR"
        return {
            "user_id": user_id,
            "days_analyzed": len(rows),
            "quality_score": quality_score,
            "rating": rating,
            "coefficients_of_variation": {
                "rpe_cv_pct": rpe_cv,
                "stress_cv_pct": stress_cv,
                "fatigue_cv_pct": fatigue_cv,
                "soreness_cv_pct": soreness_cv
            },
            "flags": flags if flags else ["Data quality acceptable."],
            "recommendation": "Provide reporting education to athlete." if quality_score < 60 else "Reporting quality sufficient for decision-making.",
            "reference": "Saw AE et al. (2017) Br J Sports Med. 51:1451-1452."
        }
    finally:
        session.close()


@app.get("/api/wellness-fatigue-ratio/{user_id}")
async def get_wellness_fatigue_ratio(user_id: str, days: int = Query(14, ge=7, le=30)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, sleep_quality, sleep_hours, stress, fatigue, muscle_soreness
            FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date DESC
            LIMIT :days
        """), {"uid": user_id, "days": days})
        rows = result.fetchall()
        if len(rows) < 7:
            return {"error": "Need at least 7 days", "available": len(rows)}
        ratios = []
        for row in reversed(rows):
            sleep_score = ((row[1] or 4) / 7.0) * 100
            sleep_hours_score = min(((row[2] or 7) / 9.0) * 100, 100)
            stress_score = ((7 - (row[3] or 3) + 1) / 7.0) * 100
            soreness_score = ((7 - (row[5] or 2) + 1) / 7.0) * 100
            wellness = (sleep_score * 0.3 + sleep_hours_score * 0.2 + stress_score * 0.3 + soreness_score * 0.2)
            fatigue_score = (row[4] or 3) / 7.0 * 100
            ratio = round(wellness / max(1, fatigue_score), 1)
            ratios.append({
                "date": str(row[0]),
                "wellness_score": round(wellness, 1),
                "fatigue_score": round(fatigue_score, 1),
                "ratio": ratio
            })
        current_ratio = ratios[-1]["ratio"]
        recent_ratios = [r["ratio"] for r in ratios[-7:]]
        avg_ratio = round(sum(recent_ratios) / len(recent_ratios), 1)
        if current_ratio < 1.0:
            status = "NEGATIVE"
            interpretation = "Fatigue exceeding wellness. Training load should be reduced."
        elif current_ratio < 1.5:
            status = "MARGINAL"
            interpretation = "Wellness marginally exceeding fatigue. Caution with load progression."
        elif current_ratio < 2.5:
            status = "POSITIVE"
            interpretation = "Wellness adequately exceeding fatigue. Appropriate training load."
        else:
            status = "OPTIMAL"
            interpretation = "Wellness significantly exceeding fatigue. Optimal for high-intensity training."
        return {
            "user_id": user_id,
            "current_ratio": current_ratio,
            "7_day_average_ratio": avg_ratio,
            "status": status,
            "interpretation": interpretation,
            "trend": ratios[-7:],
            "reference": "Hooper SL & Mackinnon LT. (1995) Sports Med. 20:321-330."
        }
    finally:
        session.close()


@app.get("/api/dynamic-risk-score/{user_id}")
async def get_dynamic_risk_score(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT dc.daily_load, dc.rpe, dc.sleep_hours, dc.sleep_quality, dc.stress,
                   dc.fatigue, dc.muscle_soreness, dc.mood, dc.cycle_phase, dc.gender,
                   dc.calories, dc.ffm, dc.injury_location, dc.pain_level,
                   COALESCE(reds.training_paused, 0) as paused
            FROM daily_checkins dc
            LEFT JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id AND reds.physician_cleared = 0
            WHERE dc.user_id = :uid
            ORDER BY dc.date DESC
            LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="No data")
        total_risk = 0
        components = []
        daily_load = float(row[0]) if row[0] else 0
        sleep_hours = float(row[2]) if row[2] else 7
        sleep_quality = row[3] or 4
        stress = row[4] or 3
        fatigue = row[5] or 3
        soreness = row[6] or 2
        mood = row[7] or "neutral"
        cycle_phase = row[8] or ""
        gender = row[9] or "male"
        calories = float(row[10]) if row[10] else 0
        ffm = float(row[11]) if row[11] else 0
        injury = row[12] or ""
        pain = row[13] or 0
        paused = bool(row[14])
        if paused:
            return {
                "user_id": user_id,
                "total_risk_score": 100,
                "risk_level": "CRITICAL",
                "components": [{"factor": "TRAINING_PAUSED", "score": 100, "reason": "RED-S medical pause active."}],
                "action": "Training paused. Medical clearance required.",
                "reference": "Mountjoy et al. (2023) BJSM IOC REDs Consensus."
            }
        if sleep_hours < 5:
            total_risk += 20
            components.append({"factor": "SLEEP_SEVERE", "score": 20, "reason": f"Sleep {sleep_hours}h."})
        elif sleep_hours < 6:
            total_risk += 12
            components.append({"factor": "SLEEP_MODERATE", "score": 12, "reason": f"Sleep {sleep_hours}h."})
        elif sleep_hours < 7:
            total_risk += 5
            components.append({"factor": "SLEEP_MILD", "score": 5, "reason": f"Sleep {sleep_hours}h."})
        if sleep_quality <= 2:
            total_risk += 10
            components.append({"factor": "SLEEP_QUALITY_POOR", "score": 10, "reason": f"Sleep quality {sleep_quality}/7."})
        if stress >= 6:
            total_risk += 15
            components.append({"factor": "HIGH_STRESS", "score": 15, "reason": f"Stress {stress}/7."})
        if fatigue >= 6:
            total_risk += 12
            components.append({"factor": "HIGH_FATIGUE", "score": 12, "reason": f"Fatigue {fatigue}/7."})
        if soreness >= 6:
            total_risk += 10
            components.append({"factor": "HIGH_SORENESS", "score": 10, "reason": f"Soreness {soreness}/7."})
        if mood and mood.lower() in ("depressed", "anxious", "conflict"):
            total_risk += 10
            components.append({"factor": "MOOD_DISTURBANCE", "score": 10, "reason": f"Mood: {mood}."})
        if pain >= 5:
            total_risk += 15
            components.append({"factor": "PAIN", "score": 15, "reason": f"Pain {pain}/10 in {injury}."})
        elif pain >= 3:
            total_risk += 8
            components.append({"factor": "MILD_PAIN", "score": 8, "reason": f"Pain {pain}/10."})
        if ffm > 0 and calories > 0 and daily_load > 0:
            ea_result = await get_validated_energy_availability(
                calories, daily_load, ffm,
                exercise_type=None,
                duration_minutes=60,
                body_mass_kg=None
            )
            if ea_result:
                ea = ea_result["ea_value"]
                # IOC 2023: Calculated EA is a screening signal, not a diagnosis.
                # RED-S flag should be triggered by CAT2 assessment, not EA alone.
                if ea < 30:
                    total_risk += 15  # Reduced weight; requires CAT2 confirmation
                    components.append({
                        "factor": "EA_LOW_SCREENING_SIGNAL",
                        "score": 15,
                        "reason": f"EA {ea:.1f} kcal/kg FFM. Screening signal only. Confirm via IOC REDs CAT2."
                    })
                elif ea < 45:
                    total_risk += 8
                    components.append({
                        "factor": "EA_SUBOPTIMAL_SCREENING",
                        "score": 8,
                        "reason": f"EA {ea:.1f} kcal/kg FFM. Monitor for additional RED-S indicators."
                    })
        if gender == "female" and cycle_phase == "luteal" and fatigue >= 5:
            total_risk += 8
            components.append({"factor": "LUTEAL_FATIGUE", "score": 8, "reason": "Luteal phase with elevated fatigue."})
        if daily_load > 600:
            total_risk += 10
            components.append({"factor": "HIGH_LOAD", "score": 10, "reason": f"Load {daily_load} AU."})
        total_risk = min(total_risk, 100)
        if total_risk >= 50:
            level = "HIGH"
            action = "Significant risk factors present. Reduce training load."
        elif total_risk >= 25:
            level = "MODERATE"
            action = "Monitor closely."
        elif total_risk >= 10:
            level = "LOW"
            action = "Minor risk factors."
        else:
            level = "MINIMAL"
            action = "No significant risk factors."
        return {
            "user_id": user_id,
            "total_risk_score": total_risk,
            "risk_level": level,
            "components": components,
            "action": action,
            "reference": "Gabbett TJ. (2016) BJSM. Bittencourt et al. (2016) BJSM."
        }
    finally:
        session.close()


@app.post("/api/squad/notify", dependencies=[Depends(verify_api_key)])
async def send_squad_notification(payload: dict):
    """Send bulk notification to all athletes or filtered subset. Coach tool. Requires API key."""
    from tasks import get_session
    session = get_session()
    try:
        message = payload.get("message", "")
        if not message.strip():
            raise HTTPException(status_code=400, detail="Message cannot be empty")
        
        target = payload.get("target", "all")
        severity = payload.get("severity", "info")
        coach_id = payload.get("coach_id", "system")
        
        # Build recipient query
        if target == "paused":
            result = session.execute(text("""
                SELECT DISTINCT dc.user_id FROM daily_checkins dc
                JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id
                WHERE reds.training_paused = 1
            """))
        elif target == "high_risk":
            result = session.execute(text("""
                SELECT dc.user_id FROM daily_checkins dc
                LEFT JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id AND reds.physician_cleared = 0
                WHERE (dc.user_id, dc.date) IN (SELECT user_id, MAX(date) FROM daily_checkins GROUP BY user_id)
                AND (dc.stress >= 6 OR dc.fatigue >= 6 OR dc.sleep_hours < 6 OR dc.muscle_soreness >= 6)
            """))
        elif target == "female":
            result = session.execute(text("""
                SELECT DISTINCT user_id FROM daily_checkins WHERE LOWER(gender) = 'female'
            """))
        else:
            result = session.execute(text("""
                SELECT DISTINCT user_id FROM daily_checkins
            """))
        
        recipients = [row[0] for row in result.fetchall()]
        
        now_iso = datetime.now(timezone.utc).isoformat()
        notified = 0
        for uid in recipients:
            session.execute(text("""
                INSERT INTO alert_log (user_id, alert_type, severity, title, body, created_at)
                VALUES (:uid, 'coach_broadcast', :sev, :title, :body, :now)
            """), {
                "uid": uid,
                "sev": severity,
                "title": f"Message from {coach_id}",
                "body": message.strip(),
                "now": now_iso
            })
            notified += 1
            if notified % 100 == 0:
                session.commit()
        session.commit()
        
        return {
            "status": "sent",
            "recipients": notified,
            "target": target,
            "severity": severity,
            "timestamp": now_iso
        }
    except HTTPException:
        raise
    except Exception as e:
        session.rollback()
        logger.error(f"Bulk notification failed: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.get("/api/communication-reminder/{user_id}")
async def get_communication_reminder(user_id: str):
    from tasks import get_session
    from datetime import date as dt_date
    session = get_session()
    try:
        risk_result = session.execute(text("""
            SELECT dc.mood, dc.stress, dc.sleep_hours, dc.fatigue,
                   COALESCE(reds.training_paused, 0) as paused
            FROM daily_checkins dc
            LEFT JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id AND reds.physician_cleared = 0
            WHERE dc.user_id = :uid
            ORDER BY dc.date DESC
            LIMIT 1
        """), {"uid": user_id})
        risk_row = risk_result.fetchone()
        if not risk_row:
            raise HTTPException(status_code=404, detail="No data")
        mood = risk_row[0] or "neutral"
        stress = risk_row[1] or 3
        sleep = float(risk_row[2]) if risk_row[2] else 7
        fatigue = risk_row[3] or 3
        paused = bool(risk_row[4])
        checkin_result = session.execute(text("""
            SELECT checkin_date FROM coach_athlete_checkins
            WHERE user_id = :uid
            ORDER BY checkin_date DESC
            LIMIT 1
        """), {"uid": user_id})
        last_checkin = checkin_result.fetchone()
        today = dt_date.today()
        days_since_checkin = None
        if last_checkin:
            last_date = dt_date.fromisoformat(str(last_checkin[0]))
            days_since_checkin = (today - last_date).days
        reminders = []
        if mood.lower() in ("depressed", "anxious", "irritable", "conflict") and (days_since_checkin is None or days_since_checkin > 7):
            reminders.append({"priority": "HIGH", "reason": f"Mood: {mood}.", "action": "Schedule a confidential conversation with the athlete."})
        if stress >= 6 and (days_since_checkin is None or days_since_checkin > 14):
            reminders.append({"priority": "MODERATE", "reason": f"Stress: {stress}/7.", "action": "Check in with athlete about life stressors."})
        if fatigue >= 6 and (days_since_checkin is None or days_since_checkin > 10):
            reminders.append({"priority": "MODERATE", "reason": f"Fatigue: {fatigue}/7.", "action": "Discuss training load and recovery."})
        if paused and (days_since_checkin is None or days_since_checkin > 3):
            reminders.append({"priority": "URGENT", "reason": "Training paused due to RED-S.", "action": "Verify athlete is receiving medical care."})
        return {
            "user_id": user_id,
            "days_since_last_checkin": days_since_checkin,
            "reminders": reminders if reminders else [{"priority": "LOW", "reason": "No reminders.", "action": "Routine communication adequate."}],
            "reminder_count": len(reminders)
        }
    finally:
        session.close()


@app.get("/api/block-comparison/{user_id}")
async def get_block_comparison(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT training_block_tag, AVG(daily_load), AVG(rpe), AVG(sleep_hours),
                   AVG(stress), AVG(fatigue), COUNT(*), MIN(date), MAX(date)
            FROM daily_checkins
            WHERE user_id = :uid AND training_block_tag IS NOT NULL AND training_block_tag != ''
            GROUP BY training_block_tag
            ORDER BY MAX(date) DESC
            LIMIT 5
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 2:
            return {"error": "Need at least 2 training blocks", "blocks_found": len(rows)}
        blocks = []
        for row in rows:
            blocks.append({
                "block_tag": row[0],
                "avg_daily_load": round(float(row[1]) if row[1] else 0, 1),
                "avg_rpe": round(float(row[2]) if row[2] else 0, 1),
                "avg_sleep_hours": round(float(row[3]) if row[3] else 0, 1),
                "avg_stress": round(float(row[4]) if row[4] else 0, 1),
                "avg_fatigue": round(float(row[5]) if row[5] else 0, 1),
                "total_sessions": row[6],
                "start_date": str(row[7]),
                "end_date": str(row[8])
            })
        current = blocks[0]
        previous = blocks[1]
        load_change_pct = round(((current["avg_daily_load"] - previous["avg_daily_load"]) / previous["avg_daily_load"]) * 100, 1) if previous["avg_daily_load"] > 0 else 0
        return {
            "user_id": user_id,
            "current_block": current,
            "previous_block": previous,
            "comparison": {
                "load_change_percent": load_change_pct,
                "rpe_change": round(current["avg_rpe"] - previous["avg_rpe"], 1),
                "fatigue_change": round(current["avg_fatigue"] - previous["avg_fatigue"], 1)
            },
            "all_blocks": blocks,
            "reference": "NSCA Essentials of Strength Training (4th Ed)."
        }
    finally:
        session.close()


@app.get("/api/weekly-report/{user_id}")
async def get_weekly_report(user_id: str):
    from tasks import get_session, _calculate_readiness
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, daily_load, rpe, sleep_hours, sleep_quality, stress,
                   fatigue, muscle_soreness, mood, cycle_phase, calories, ffm, gender
            FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date DESC
            LIMIT 7
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 3:
            return JSONResponse(status_code=404, content={"error": "Need at least 3 days"})
        daily_data = []
        for row in reversed(rows):
            daily_data.append({
                "date": str(row[0]),
                "daily_load": float(row[1]) if row[1] else 0,
                "rpe": row[2] or 0,
                "sleep_hours": float(row[3]) if row[3] else 0,
                "sleep_quality": row[4] or 0,
                "stress": row[5] or 0,
                "fatigue": row[6] or 0,
                "soreness": row[7] or 0,
                "mood": row[8] or "neutral"
            })
        loads = [d["daily_load"] for d in daily_data]
        avg_load = round(sum(loads) / len(loads), 1)
        avg_sleep = round(sum(d["sleep_hours"] for d in daily_data) / len(daily_data), 1)
        avg_readiness = round(sum(_calculate_readiness(d["sleep_quality"], d["stress"], d["fatigue"], d["soreness"], d["sleep_hours"]) for d in daily_data) / len(daily_data))
        acwr_val = 1.0
        all_loads_result = session.execute(text("SELECT daily_load FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC"), {"uid": user_id})
        all_loads = [float(r[0]) if r[0] else 0 for r in all_loads_result.fetchall()]
        if len(all_loads) >= 28:
            acute = sum(all_loads[-7:]) / 7
            chronic = sum(all_loads) / len(all_loads)
            acwr_val = round(acute / chronic, 2) if chronic > 0 else 1.0
        reds_risk = False
        if rows[0][10] and rows[0][11] and rows[0][1]:
            cal = float(rows[0][10])
            ffm = float(rows[0][11])
            load = float(rows[0][1])
            if ffm > 0:
                ea_result = await get_validated_energy_availability(
                    cal, load, ffm,
                    exercise_type=None,
                    duration_minutes=60,
                    body_mass_kg=None,
                    gender=rows[0][12] if len(rows[0]) > 12 else "Male",
                    cycle_phase=rows[0][9] if rows[0][9] else ""
                )
                if ea_result and ea_result.get("ea_value") is not None:
                    reds_risk = ea_result["ea_value"] < 30
        return {
            "user_id": user_id,
            "week_start": daily_data[0]["date"],
            "week_end": daily_data[-1]["date"],
            "avg_readiness": avg_readiness,
            "avg_daily_load": avg_load,
            "avg_sleep": avg_sleep,
            "acwr": acwr_val,
            "reds_risk": reds_risk,
            "daily_data": daily_data
        }
    finally:
        session.close()


@app.get("/api/data-completeness/{user_id}")
async def get_data_completeness(user_id: str):
    from tasks import get_session
    from datetime import date as dt_date
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT COUNT(*) as total_days,
                   MIN(date) as first_date,
                   MAX(date) as last_date,
                   AVG(CASE WHEN sleep_hours > 0 THEN 1 ELSE 0 END) as sleep_fill,
                   AVG(CASE WHEN rpe > 0 THEN 1 ELSE 0 END) as rpe_fill,
                   AVG(CASE WHEN stress > 0 THEN 1 ELSE 0 END) as stress_fill,
                   AVG(CASE WHEN calories > 0 THEN 1 ELSE 0 END) as calories_fill,
                   AVG(CASE WHEN ffm > 0 THEN 1 ELSE 0 END) as ffm_fill,
                   AVG(CASE WHEN cmj_height_cm > 0 THEN 1 ELSE 0 END) as cmj_fill
            FROM daily_checkins
            WHERE user_id = :uid
        """), {"uid": user_id})
        row = result.fetchone()
        if not row or row[0] == 0:
            return {"error": "No data for athlete"}
        total_days = row[0]
        first_date = str(row[1]) if row[1] else None
        last_date = str(row[2]) if row[2] else None
        days_in_range = (dt_date.today() - dt_date.fromisoformat(first_date)).days + 1 if first_date else 0
        completion_pct = round((total_days / max(1, days_in_range)) * 100, 1)
        analyses_available = []
        analyses_missing = []
        if total_days >= 28:
            analyses_available.append("ACWR (28+ days)")
        else:
            analyses_missing.append({"analysis": "ACWR", "days_needed": 28, "days_available": total_days, "remaining": 28 - total_days})
        if total_days >= 7:
            analyses_available.append("Weekly Trends (7+ days)")
        else:
            analyses_missing.append({"analysis": "Weekly Trends", "days_needed": 7, "days_available": total_days, "remaining": 7 - total_days})
        if total_days >= 14:
            analyses_available.append("Readiness Trend (14+ days)")
        else:
            analyses_missing.append({"analysis": "Readiness Trend", "days_needed": 14, "days_available": total_days, "remaining": 14 - total_days})
        return {
            "user_id": user_id,
            "total_days_logged": total_days,
            "date_range": f"{first_date} to {last_date}",
            "overall_completion_percent": completion_pct,
            "analyses_available": analyses_available,
            "analyses_unavailable": analyses_missing,
            "recommendation": "Continue daily logging to unlock all analyses." if analyses_missing else "All analyses available."
        }
    finally:
        session.close()


@app.get("/api/training-adherence/{user_id}")
async def get_training_adherence(user_id: str, days: int = Query(28, ge=7, le=90)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, daily_load, rpe, duration_minutes, sleep_hours
            FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date DESC
            LIMIT :days
        """), {"uid": user_id, "days": days})
        rows = result.fetchall()
        if len(rows) < 7:
            return {"error": "Need at least 7 days of data"}

        total_days = len(rows)
        training_days = sum(1 for r in rows if float(r[1]) > 50)
        rest_days = total_days - training_days
        adherence_pct = round((training_days / total_days) * 100, 1) if total_days > 0 else 0

        expected_sessions = round(total_days * 0.7)

        if adherence_pct < 50:
            status = "POOR"
            action = "Significant non-adherence. Investigate barriers: motivation, injury, life stress."
        elif adherence_pct < 70:
            status = "BELOW_TARGET"
            action = "Adherence below 70% target. Consider program modification."
        elif adherence_pct <= 90:
            status = "GOOD"
            action = "Good adherence. Continue current program."
        else:
            status = "EXCELLENT"
            action = "Excellent adherence. Monitor for overtraining signs."

        avg_load_training_days = round(sum(float(r[1]) for r in rows if float(r[1]) > 50) / max(1, training_days), 1)

        return {
            "user_id": user_id,
            "period_days": total_days,
            "training_days": training_days,
            "rest_days": rest_days,
            "adherence_percent": adherence_pct,
            "expected_sessions_per_week": expected_sessions,
            "average_load_training_days": avg_load_training_days,
            "status": status,
            "action": action,
            "reference": "NSCA Essentials of Strength Training (4th Ed). ACSM Guidelines 2024."
        }
    finally:
        session.close()


@app.get("/api/recovery-stress-balance/{user_id}")
async def get_recovery_stress_balance(user_id: str):
    from tasks import get_session, _calculate_recovery_stress_balance
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT sleep_quality, sleep_hours, stress, fatigue, muscle_soreness, mood
            FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date DESC
            LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="No data for athlete")
        rsb = _calculate_recovery_stress_balance(
            row[0] or 4, float(row[1]) if row[1] else 7,
            row[2] or 3, row[3] or 3, row[4] or 2, row[5] or "neutral"
        )
        rsb["user_id"] = user_id
        return rsb
    finally:
        session.close()


@app.get("/api/phase-performance/{user_id}")
async def get_phase_performance_summary(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT cycle_phase, AVG(daily_load), AVG(rpe), AVG(sleep_quality),
                   AVG(muscle_soreness), AVG(fatigue), COUNT(*)
            FROM daily_checkins
            WHERE user_id = :uid AND cycle_phase IS NOT NULL AND cycle_phase != ''
            GROUP BY cycle_phase
            ORDER BY CASE cycle_phase
                WHEN 'menstrual' THEN 1
                WHEN 'follicular' THEN 2
                WHEN 'ovulatory' THEN 3
                WHEN 'luteal' THEN 4
                ELSE 5 END
        """), {"uid": user_id})
        rows = result.fetchall()
        if not rows:
            return {"error": "No cycle-phase data available"}

        phases = {}
        best_phase = None
        best_load = 0
        worst_phase = None
        worst_soreness = 0

        for row in rows:
            phase = row[0]
            avg_load = round(float(row[1]) if row[1] else 0, 1)
            avg_rpe = round(float(row[2]) if row[2] else 0, 1)
            avg_sleep = round(float(row[3]) if row[3] else 0, 1)
            avg_soreness = round(float(row[4]) if row[4] else 0, 1)
            avg_fatigue = round(float(row[5]) if row[5] else 0, 1)
            count = row[6]

            phases[phase] = {
                "sessions": count,
                "avg_load": avg_load,
                "avg_rpe": avg_rpe,
                "avg_sleep_quality": avg_sleep,
                "avg_soreness": avg_soreness,
                "avg_fatigue": avg_fatigue
            }

            if avg_load > best_load:
                best_load = avg_load
                best_phase = phase
            if avg_soreness > worst_soreness:
                worst_soreness = avg_soreness
                worst_phase = phase

        return {
            "user_id": user_id,
            "phases": phases,
            "best_performance_phase": best_phase,
            "highest_load_phase": best_phase,
            "highest_soreness_phase": worst_phase,
            "recommendation": f"Highest training tolerance observed in {best_phase} phase. Schedule high-intensity sessions accordingly." if best_phase else "Insufficient data for phase-specific recommendations.",
            "reference": "McNulty et al. (2020) Sports Med. Elliott-Sale et al. (2021) Sports Med."
        }
    finally:
        session.close()


@app.get("/api/athlete-profile/{user_id}")
async def get_athlete_profile(user_id: str):
    from tasks import get_session, _calculate_readiness, _calculate_recovery_stress_balance
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT dc.gender, dc.daily_load, dc.rpe, dc.sleep_hours, dc.sleep_quality,
                   dc.stress, dc.fatigue, dc.muscle_soreness, dc.mood, dc.cycle_phase,
                   dc.calories, dc.ffm, dc.injury_location, dc.pain_level,
                   dc.cmj_height_cm, dc.sprint_20m_s, dc.training_block_tag,
                   COALESCE(reds.training_paused, 0) as training_paused,
                   COALESCE(rtp.current_phase, 0) as rtp_phase
            FROM daily_checkins dc
            LEFT JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id AND reds.physician_cleared = 0
            LEFT JOIN rtp_clearances rtp ON dc.user_id = rtp.user_id AND rtp.full_clearance_date IS NULL
            WHERE dc.user_id = :uid
            ORDER BY dc.date DESC
            LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Athlete not found")

        readiness = _calculate_readiness(row[4] or 4, row[6] or 3, row[7] or 3, row[8] or 2, float(row[3]) if row[3] else 7)
        rsb = _calculate_recovery_stress_balance(row[4] or 4, float(row[3]) if row[3] else 7, row[6] or 3, row[7] or 3, row[8] or 2, row[9])
        ea = None
        if row[10] and row[11] and row[1]:
            calories = float(row[10])
            ffm = float(row[11])
            daily_load = float(row[1])
            if ffm > 0:
                ea_result = await get_validated_energy_availability(
                    calories, daily_load, ffm,
                    exercise_type=None,
                    duration_minutes=60,
                    body_mass_kg=None
                )
                if ea_result:
                    ea = ea_result["ea_value"]

        return {
            "user_id": user_id,
            "gender": row[0],
            "training_block": row[16] or "Unspecified",
            "performance": {
                "daily_load": float(row[1]) if row[1] else 0,
                "rpe": row[2] or 0,
                "cmj_height_cm": float(row[14]) if row[14] else None,
                "sprint_20m_s": float(row[15]) if row[15] else None
            },
            "wellness": {
                "readiness_pct": readiness,
                "sleep_hours": float(row[3]) if row[3] else 0,
                "sleep_quality": row[4] or 0,
                "stress": row[6] or 0,
                "fatigue": row[7] or 0,
                "soreness": row[8] or 0,
                "mood": row[9] or "neutral"
            },
            "recovery_stress_balance": rsb,
            "female_specific": {
                "cycle_phase": row[10] if row[0] == "Female" else "N/A",
                "energy_availability": ea,
                "ea_risk": "RED" if ea and ea < 30 else "YELLOW" if ea and ea < 45 else "GREEN" if ea else "UNKNOWN"
            } if row[0] == "Female" else None,
            "medical": {
                "injury_location": row[12] or None,
                "pain_level": row[13] or 0,
                "training_paused": bool(row[17]),
                "rtp_phase": row[18] or 0
            },
            "generated_at": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()


@app.get("/api/validation/injury-prediction")
async def validate_injury_prediction(days_window: int = Query(7, ge=3, le=14)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT dc1.user_id, dc1.date, dc1.daily_load, dc1.injury_location,
                   dc2.date as next_date, dc2.injury_location as next_injury
            FROM daily_checkins dc1
            LEFT JOIN daily_checkins dc2 ON dc1.user_id = dc2.user_id
                AND dc2.date > dc1.date
                AND dc2.date <= date(dc1.date, '+""" + str(days_window) + """ days')
            WHERE dc1.daily_load > 0
            ORDER BY dc1.user_id, dc1.date
        """))
        rows = result.fetchall()
        athlete_data = {}
        for row in rows:
            uid = row[0]
            if uid not in athlete_data:
                athlete_data[uid] = {"loads": [], "dates": [], "injuries": set()}
            athlete_data[uid]["loads"].append(float(row[2]) if row[2] else 0)
            athlete_data[uid]["dates"].append(str(row[1]))
            if row[3] and row[3].strip():
                athlete_data[uid]["injuries"].add(str(row[1]))
        true_positive = 0
        false_positive = 0
        true_negative = 0
        false_negative = 0
        for uid, data in athlete_data.items():
            loads = data["loads"]
            if len(loads) < 35:
                continue
            for i in range(27, len(loads) - days_window):
                window = loads[i-27:i+1]
                acute = sum(window[-7:]) / 7
                chronic = sum(window) / 28
                acwr = acute / chronic if chronic > 0 else 1.0
                high_risk = acwr > 1.5
                future_window_dates = data["dates"][i+1:i+1+days_window]
                injury_occurred = any(d in data["injuries"] for d in future_window_dates)
                if high_risk and injury_occurred:
                    true_positive += 1
                elif high_risk and not injury_occurred:
                    false_positive += 1
                elif not high_risk and injury_occurred:
                    false_negative += 1
                else:
                    true_negative += 1
        total = true_positive + false_positive + true_negative + false_negative
        if total < 10:
            return {"error": "Insufficient data for validation", "total_observations": total}
        sensitivity = round(true_positive / (true_positive + false_negative), 3) if (true_positive + false_negative) > 0 else 0
        specificity = round(true_negative / (true_negative + false_positive), 3) if (true_negative + false_positive) > 0 else 0
        ppv = round(true_positive / (true_positive + false_positive), 3) if (true_positive + false_positive) > 0 else 0
        npv = round(true_negative / (true_negative + false_negative), 3) if (true_negative + false_negative) > 0 else 0
        relative_risk_numerator = true_positive / (true_positive + false_positive) if (true_positive + false_positive) > 0 else 0
        relative_risk_denominator = false_negative / (false_negative + true_negative) if (false_negative + true_negative) > 0 else 0.001
        relative_risk = round(relative_risk_numerator / relative_risk_denominator, 2) if relative_risk_denominator > 0 else 0
        accuracy = round((true_positive + true_negative) / total, 3)
        return {
            "model": "ACWR > 1.5 predicts injury within " + str(days_window) + " days",
            "total_observations": total,
            "athletes_analyzed": len(athlete_data),
            "confusion_matrix": {
                "true_positive": true_positive,
                "false_positive": false_positive,
                "true_negative": true_negative,
                "false_negative": false_negative
            },
            "metrics": {
                "sensitivity": sensitivity,
                "specificity": specificity,
                "positive_predictive_value": ppv,
                "negative_predictive_value": npv,
                "relative_risk": relative_risk,
                "accuracy": accuracy
            },
            "interpretation": "ACWR >1.5 predicts injury with RR=" + str(relative_risk) + "." if relative_risk > 2 else "Insufficient predictive power in current dataset. Accumulate more injury data.",
            "reference": "Gabbett TJ. Br J Sports Med. 2016;50:273-280.",
            "generated_at": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()

@app.get("/api/validation/predictive-performance/{user_id}")
async def get_predictive_performance(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, daily_load, injury_location, readiness_score FROM daily_checkins
            WHERE user_id = :uid ORDER BY date ASC
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 42:
            return {"error": "Need at least 42 days for predictive validation."}

        loads = [float(r[1] or 0) for r in rows]
        injuries = [bool(r[2] and str(r[2]).strip()) for r in rows]

        tp_acwr = fp_acwr = tn_acwr = fn_acwr = 0
        tp_readiness = fp_readiness = tn_readiness = fn_readiness = 0

        for i in range(28, len(loads) - 7):
            acute = sum(loads[i-6:i+1]) / 7
            chronic = sum(loads[i-27:i+1]) / 28
            acwr = acute / chronic if chronic > 0 else 1.0
            acwr_high = acwr > 1.5
            future_injury = any(injuries[i+1:i+8])

            if acwr_high and future_injury:
                tp_acwr += 1
            elif acwr_high and not future_injury:
                fp_acwr += 1
            elif not acwr_high and not future_injury:
                tn_acwr += 1
            else:
                fn_acwr += 1

        total = tp_acwr + fp_acwr + tn_acwr + fn_acwr
        if total < 10:
            return {"error": "Insufficient data for validation."}

        sensitivity_acwr = round(tp_acwr / (tp_acwr + fn_acwr), 3) if (tp_acwr + fn_acwr) > 0 else 0
        specificity_acwr = round(tn_acwr / (tn_acwr + fp_acwr), 3) if (tn_acwr + fp_acwr) > 0 else 0
        ppv_acwr = round(tp_acwr / (tp_acwr + fp_acwr), 3) if (tp_acwr + fp_acwr) > 0 else 0
        npv_acwr = round(tn_acwr / (tn_acwr + fn_acwr), 3) if (tn_acwr + fn_acwr) > 0 else 0
        accuracy_acwr = round((tp_acwr + tn_acwr) / total, 3)
        youden_acwr = round(sensitivity_acwr + specificity_acwr - 1, 3)

        return {
            "user_id": user_id,
            "observations": total,
            "acwr_validation": {
                "sensitivity": sensitivity_acwr,
                "specificity": specificity_acwr,
                "ppv": ppv_acwr,
                "npv": npv_acwr,
                "accuracy": accuracy_acwr,
                "youden_index": youden_acwr,
                "threshold_tested": "ACWR > 1.5"
            },
            "methodology": "Prospective rolling window. 7-day forecast horizon. ACWR threshold 1.5.",
            "reference": "Bahr & Holme (2003) Br J Sports Med. Crowcroft et al. (2020) J Sci Med Sport."
        }
    finally:
        session.close()

@app.post("/api/field-tests/rockport")
async def calculate_rockport_vo2max(payload: dict):
    gender = payload.get("gender", "male").lower()
    weight_kg = float(payload.get("weight_kg", 70))
    age_years = int(payload.get("age_years", 25))
    walk_time_min = float(payload.get("walk_time_min", 15))
    heart_rate_bpm = int(payload.get("heart_rate_bpm", 130))

    vo2max = 132.853 - (0.0769 * weight_kg * 2.20462) - (0.3877 * age_years)
    if gender == "male":
        vo2max += 6.315
    else:
        vo2max += 0
    vo2max -= (3.2649 * walk_time_min) + (0.1565 * heart_rate_bpm)
    vo2max = round(vo2max, 1)

    if gender == "male":
        norms = {"excellent": 52, "good": 46, "above_average": 42, "average": 38, "below_average": 34}
    else:
        norms = {"excellent": 45, "good": 39, "above_average": 35, "average": 31, "below_average": 27}

    if vo2max >= norms["excellent"]: category = "EXCELLENT"
    elif vo2max >= norms["good"]: category = "GOOD"
    elif vo2max >= norms["above_average"]: category = "ABOVE_AVERAGE"
    elif vo2max >= norms["average"]: category = "AVERAGE"
    elif vo2max >= norms["below_average"]: category = "BELOW_AVERAGE"
    else: category = "POOR"

    return {
        "user_id": payload.get("user_id"),
        "test": "Rockport 1-Mile Walk Test",
        "estimated_vo2max_ml_kg_min": vo2max,
        "category": category,
        "norms_used": "ACSM Guidelines 11th Ed (2024)",
        "reference": "Kline et al. (1987) Med Sci Sports Exerc."
    }


@app.post("/api/field-tests/cooper")
async def calculate_cooper_vo2max(payload: dict):
    distance_m = float(payload.get("distance_m", 2400))
    vo2max = round((distance_m - 504.9) / 44.73, 1)
    vo2max = max(20, min(vo2max, 85))

    if vo2max >= 60: category = "EXCELLENT"
    elif vo2max >= 50: category = "GOOD"
    elif vo2max >= 40: category = "AVERAGE"
    elif vo2max >= 30: category = "BELOW_AVERAGE"
    else: category = "POOR"

    return {
        "user_id": payload.get("user_id"),
        "test": "Cooper 12-Minute Run Test",
        "distance_covered_m": distance_m,
        "estimated_vo2max_ml_kg_min": vo2max,
        "category": category,
        "reference": "Cooper KH. (1968) JAMA. ACSM Guidelines 11th Ed (2024)."
    }


@app.post("/api/field-tests/ymca-step")
async def calculate_ymca_step_test(payload: dict):
    gender = payload.get("gender", "male").lower()
    recovery_hr_bpm = int(payload.get("recovery_hr_bpm", 100))

    if gender == "male":
        norms = {"excellent": 84, "good": 95, "above_average": 105, "average": 115, "below_average": 125}
    else:
        norms = {"excellent": 92, "good": 103, "above_average": 113, "average": 123, "below_average": 133}

    if recovery_hr_bpm <= norms["excellent"]: category = "EXCELLENT"
    elif recovery_hr_bpm <= norms["good"]: category = "GOOD"
    elif recovery_hr_bpm <= norms["above_average"]: category = "ABOVE_AVERAGE"
    elif recovery_hr_bpm <= norms["average"]: category = "AVERAGE"
    elif recovery_hr_bpm <= norms["below_average"]: category = "BELOW_AVERAGE"
    else: category = "POOR"

    return {
        "user_id": payload.get("user_id"),
        "test": "YMCA 3-Minute Step Test",
        "recovery_hr_bpm": recovery_hr_bpm,
        "category": category,
        "protocol": "96 bpm metronome, 3 minutes stepping, 60-second recovery HR counted",
        "reference": "Golding et al. (1989) YMCA Fitness Testing. ACSM Guidelines 11th Ed (2024)."
    }


@app.post("/api/field-tests/queens-college-step")
async def calculate_queens_college_step(payload: dict):
    gender = payload.get("gender", "male").lower()
    recovery_hr_bpm = int(payload.get("recovery_hr_bpm", 120))

    if gender == "male":
        vo2max = round(111.33 - (0.42 * recovery_hr_bpm), 1)
    else:
        vo2max = round(65.81 - (0.1847 * recovery_hr_bpm), 1)
    vo2max = max(20, min(vo2max, 80))

    if gender == "male":
        norms = {"excellent": 52, "good": 46, "average": 40}
    else:
        norms = {"excellent": 45, "good": 39, "average": 33}

    if vo2max >= norms["excellent"]: category = "EXCELLENT"
    elif vo2max >= norms["good"]: category = "GOOD"
    elif vo2max >= norms["average"]: category = "AVERAGE"
    else: category = "BELOW_AVERAGE"

    return {
        "user_id": payload.get("user_id"),
        "test": "Queens College Step Test",
        "recovery_hr_bpm": recovery_hr_bpm,
        "estimated_vo2max_ml_kg_min": vo2max,
        "category": category,
        "protocol": "Women: 88 bpm, Men: 96 bpm. 3 minutes stepping. 15-second recovery HR x 4.",
        "reference": "McArdle et al. (1972) Med Sci Sports. ACSM Guidelines 11th Ed (2024)."
    }      

@app.post("/api/statistics/effect-size")
async def calculate_effect_size(payload: dict):
    mean_pre = float(payload.get("mean_pre"))
    mean_post = float(payload.get("mean_post"))
    sd_pre = float(payload.get("sd_pre"))
    n = int(payload.get("sample_size", 10))

    mean_diff = mean_post - mean_pre
    cohens_d = round(mean_diff / sd_pre, 3) if sd_pre > 0 else 0

    pooled_sd = sd_pre
    hedges_g = round(cohens_d * (1 - (3 / (4 * n - 9))), 3) if n > 2 else cohens_d

    if abs(cohens_d) >= 0.8: magnitude = "LARGE"
    elif abs(cohens_d) >= 0.5: magnitude = "MEDIUM"
    elif abs(cohens_d) >= 0.2: magnitude = "SMALL"
    else: magnitude = "TRIVIAL"

    return {
        "mean_difference": round(mean_diff, 2),
        "cohens_d": cohens_d,
        "hedges_g": hedges_g,
        "magnitude": magnitude,
        "interpretation": f"A {magnitude.lower()} effect was observed (d={cohens_d}).",
        "reference": "Cohen J. (1988) Statistical Power Analysis. Hopkins et al. (2009) Med Sci Sports Exerc."
    }


@app.post("/api/statistics/reliability")
async def calculate_reliability_metrics(payload: dict):
    trial_1 = [float(x) for x in payload.get("trial_1", [])]
    trial_2 = [float(x) for x in payload.get("trial_2", [])]

    if len(trial_1) != len(trial_2) or len(trial_1) < 5:
        return {"error": "Need equal-length arrays with at least 5 observations."}

    diffs = [t1 - t2 for t1, t2 in zip(trial_1, trial_2)]
    mean_diff = sum(diffs) / len(diffs)
    sd_diff = (sum((d - mean_diff) ** 2 for d in diffs) / (len(diffs) - 1)) ** 0.5
    tem = round(sd_diff / (2 ** 0.5), 2)

    grand_mean = (sum(trial_1) + sum(trial_2)) / (2 * len(trial_1))
    cv_pct = round((tem / grand_mean) * 100, 1) if grand_mean > 0 else 0

    swc = round(0.2 * (((sum((x - grand_mean) ** 2 for x in trial_1)) / (len(trial_1) - 1)) ** 0.5), 2)

    return {
        "typical_error_of_measurement": tem,
        "coefficient_of_variation_pct": cv_pct,
        "smallest_worthwhile_change": swc,
        "reliability_rating": "GOOD" if cv_pct < 5 else "ACCEPTABLE" if cv_pct < 10 else "POOR",
        "sample_size": len(trial_1),
        "reference": "Hopkins WG. (2000) Sports Med. Hopkins et al. (2009) Med Sci Sports Exerc."
    }


@app.post("/api/statistics/battery-comparison")
async def compare_test_battery(payload: dict):
    group_a = [float(x) for x in payload.get("group_a", [])]
    group_b = [float(x) for x in payload.get("group_b", [])]

    if len(group_a) < 3 or len(group_b) < 3:
        return {"error": "Need at least 3 observations per group."}

    mean_a = sum(group_a) / len(group_a)
    mean_b = sum(group_b) / len(group_b)
    var_a = sum((x - mean_a) ** 2 for x in group_a) / (len(group_a) - 1)
    var_b = sum((x - mean_b) ** 2 for x in group_b) / (len(group_b) - 1)
    pooled_sd = (((len(group_a) - 1) * var_a + (len(group_b) - 1) * var_b) / (len(group_a) + len(group_b) - 2)) ** 0.5
    cohens_d = round((mean_b - mean_a) / pooled_sd, 3) if pooled_sd > 0 else 0

    return {
        "group_a_mean": round(mean_a, 2),
        "group_b_mean": round(mean_b, 2),
        "mean_difference": round(mean_b - mean_a, 2),
        "pooled_sd": round(pooled_sd, 2),
        "cohens_d": cohens_d,
        "magnitude": "LARGE" if abs(cohens_d) >= 0.8 else "MEDIUM" if abs(cohens_d) >= 0.5 else "SMALL" if abs(cohens_d) >= 0.2 else "TRIVIAL",
        "reference": "Cohen J. (1988). Hopkins et al. (2009)."
    }

@app.get("/api/performance-trend/{user_id}")
async def get_performance_trend(user_id: str, metric: str = Query("cmj", pattern="^(cmj|sprint)$")):
    from tasks import get_session
    session = get_session()
    try:
        if metric == "cmj":
            result = session.execute(text("""
                SELECT date, cmj_height_cm FROM daily_checkins
                WHERE user_id = :uid AND cmj_height_cm IS NOT NULL
                ORDER BY date DESC
                LIMIT 42
            """), {"uid": user_id})
        else:
            result = session.execute(text("""
                SELECT date, sprint_20m_s FROM daily_checkins
                WHERE user_id = :uid AND sprint_20m_s IS NOT NULL
                ORDER BY date DESC
                LIMIT 42
            """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 7:
            return {"error": "Need at least 7 measurements", "available": len(rows)}
        values = []
        for row in reversed(rows):
            values.append(float(row[1]) if row[1] else None)
        values = [v for v in values if v is not None]
        if len(values) < 7:
            return {"error": "Need at least 7 valid measurements"}
        mean_val = sum(values) / len(values)
        variance = sum((v - mean_val) ** 2 for v in values) / len(values)
        sd_val = variance ** 0.5
        swc = round(0.2 * sd_val, 2)
        recent_avg = sum(values[-7:]) / 7
        previous_avg = sum(values[-14:-7]) / max(1, len(values[-14:-7]))
        change = round(recent_avg - previous_avg, 2)
        if metric == "cmj":
            decline = change < -swc
            alert = change < -2 * swc
        else:
            decline = change > swc
            alert = change > 2 * swc
        return {
            "user_id": user_id,
            "metric": "CMJ Height (cm)" if metric == "cmj" else "20m Sprint (s)",
            "values": values,
            "recent_average": round(recent_avg, 2),
            "previous_average": round(previous_avg, 2),
            "change": change,
            "swc": swc,
            "meaningful_decline": decline,
            "significant_alert": alert,
            "recommendation": "Neuromuscular fatigue detected. Reduce high-intensity volume." if alert else "Within normal range." if not decline else "Monitor closely.",
            "reference": "Claudino et al. (2017) Sports Med. SWC = 0.2 x between-subject SD."
        }
    finally:
        session.close()


@app.get("/api/travel-recovery")
async def calculate_travel_recovery(from_tz: float = Query(...), to_tz: float = Query(...)):
    zones_crossed = abs(from_tz - to_tz)
    recovery_days = zones_crossed
    if to_tz < from_tz:
        direction = "WESTWARD"
        recovery_days = zones_crossed * 0.6
        advice = "Westward travel: easier adaptation. Evening light exposure recommended."
    else:
        direction = "EASTWARD"
        recovery_days = zones_crossed * 1.0
        advice = "Eastward travel: harder adaptation. Morning light exposure recommended."
    recovery_days = max(1, round(recovery_days))
    return {
        "zones_crossed": zones_crossed,
        "direction": direction,
        "estimated_recovery_days": recovery_days,
        "advice": advice,
        "strategies": [
            "Melatonin 1-3mg at target bedtime for first 3-4 days",
            "Avoid caffeine after 14:00 local time",
            "Light exposure: morning for eastward, evening for westward",
            f"Reduce training load by 30-50% for first {recovery_days} days",
            "Prioritize sleep: 8-9 hours per night"
        ],
        "reference": "Janse van Rensburg et al. (2023) BJSM. IOC Consensus on Athlete Travel."
    }


@app.get("/api/acwr/{user_id}")
async def get_acwr_full(user_id: str):
    from tasks import get_session, _compute_acwr_python, _compute_coupled_acwr, _compute_monotony_strain
    session = get_session()
    try:
        result = session.execute(
            text("SELECT date, daily_load, cycle_phase, gender FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC"),
            {"uid": user_id},
        )
        rows = result.fetchall()
        daily_loads = [float(r[1]) if r[1] else 0.0 for r in rows]

        if len(daily_loads) < 28:
            return {"error": "Minimum 28 days required", "days_available": len(daily_loads)}

        gender = rows[-1][3] if rows[-1][3] else "male"
        cycle_phase = rows[-1][2] if rows[-1][2] else ""

        r_payload = {
            "daily_loads": daily_loads,
            "gender": gender,
            "cycle_phase": cycle_phase
        }

        r_result = await _call_r("analytics/acwr", r_payload)

        injury_result = session.execute(text("""
            SELECT date, daily_load FROM daily_checkins
            WHERE user_id = :uid AND injury_location IS NOT NULL AND injury_location != ''
            ORDER BY date ASC
        """), {"uid": user_id})
        injury_rows = injury_result.fetchall()
        personalized_threshold = None
        if injury_rows:
            injury_acwr_values = []
            for inj_row in injury_rows:
                inj_date = inj_row[0]
                inj_loads_result = session.execute(text("""
                    SELECT daily_load FROM daily_checkins
                    WHERE user_id = :uid AND date < :idate
                    ORDER BY date ASC
                """), {"uid": user_id, "idate": str(inj_date)})
                inj_loads = [float(r[0]) if r[0] else 0 for r in inj_loads_result.fetchall()]
                if len(inj_loads) >= 28:
                    inj_acwr = _compute_acwr_python(inj_loads, gender, cycle_phase)
                    if "acwr" in inj_acwr:
                        injury_acwr_values.append(inj_acwr["acwr"])
            if injury_acwr_values:
                min_injury_acwr = min(injury_acwr_values)
                personalized_threshold = round(min_injury_acwr * 0.95, 2)

        if r_result and "error" not in r_result:
            acwr_result = r_result
        else:
            acwr_result = _compute_acwr_python(daily_loads, gender, cycle_phase)

        acwr_result["user_id"] = user_id
        if personalized_threshold:
            acwr_result["personalized_threshold"] = personalized_threshold
            acwr_result["personalized_danger_zone"] = acwr_result["acwr"] >= personalized_threshold
            acwr_result["threshold_note"] = "Personalized based on historical injury data."
        if len(daily_loads) >= 42:
            coupled = _compute_coupled_acwr(daily_loads)
            if coupled:
                acwr_result["coupled_acwr"] = coupled
        acwr_result["monotony_strain"] = _compute_monotony_strain(daily_loads)
        return acwr_result
    finally:
        session.close()


@app.post("/api/plan-session")
async def plan_session(user_id: str = Query(...), planned_rpe: int = Query(..., ge=1, le=10), planned_duration: int = Query(..., ge=1, le=480)):
    from tasks import get_session, _compute_acwr_python, _compute_coupled_acwr, _compute_monotony_strain, _calculate_daily_load, get_hormonal_status
    session = get_session()
    try:
        result = session.execute(
            text("SELECT date, daily_load, gender, cycle_phase FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC"),
            {"uid": user_id}
        )
        rows = result.fetchall()
        daily_loads = [float(r[1]) if r[1] else 0.0 for r in rows]
        if len(daily_loads) < 27:
            return {"error": "Need at least 27 days of historical data", "days_available": len(daily_loads)}
        planned_load = _calculate_daily_load(planned_rpe, planned_duration)
        projected_loads = daily_loads[-27:] + [planned_load]
        gender = rows[-1][2] if rows[-1][2] else "male"
        cycle_phase = rows[-1][3] if rows[-1][3] else ""

        hormonal_status = get_hormonal_status(user_id)
        if hormonal_status in ("NOT_FEMALE", "UNKNOWN_PHASE"):
            hormonal_status = cycle_phase

        current_acwr = await get_validated_acwr(daily_loads, gender, hormonal_status)
        projected_acwr = await get_validated_acwr(projected_loads, gender, hormonal_status)
        result = {
            "user_id": user_id,
            "planned_session": {"rpe": planned_rpe, "duration_min": planned_duration, "load": planned_load},
            "current_acwr": current_acwr.get("acwr"),
            "current_risk_zone": current_acwr.get("risk_zone"),
            "projected_acwr": projected_acwr.get("acwr"),
            "projected_risk_zone": projected_acwr.get("risk_zone"),
            "recommendation": "Proceed with planned session" if projected_acwr.get("risk_zone") in ("optimal", "moderate") else "Reduce planned load by 20-30%" if projected_acwr.get("risk_zone") == "high" else "DO NOT proceed. Risk of injury is extreme."
        }
        if len(daily_loads) >= 42:
            projected_42 = daily_loads[-41:] + [planned_load]
            coupled = _compute_coupled_acwr(projected_42)
            if coupled:
                result["projected_coupled_acwr"] = coupled
        return result
    finally:
        session.close()


@app.get("/api/cycle-response/{user_id}", dependencies=[Depends(verify_api_key)])
async def get_cycle_response_data(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(
            text("""
                SELECT phase, AVG(training_load_completed), AVG(rpe_session),
                       AVG(soreness_next_day), COUNT(*)
                FROM cycle_response_history
                WHERE user_id = :uid
                GROUP BY phase
                ORDER BY phase
            """),
            {"uid": user_id},
        )
        rows = result.fetchall()
        response = {}
        for row in rows:
            response[row[0]] = {
                "avg_load": round(float(row[1]) if row[1] else 0, 2),
                "avg_rpe": round(float(row[2]) if row[2] else 0, 1),
                "avg_soreness": round(float(row[3]) if row[3] else 0, 1),
                "session_count": row[4],
            }
        return {"user_id": user_id, "cycle_response": response}
    finally:
        session.close()


@app.get("/api/recovery-strategies")
async def get_recovery_strategies(category: str = Query(None), locale: str = Query("en")):
    return {
        "low_readiness": [
            "10-minute box breathing: 4 sec inhale, 4 sec hold, 4 sec exhale, 4 sec hold",
            "Active recovery walk: 20 min at Zone 1 intensity",
            "Contrast shower: 1 min hot water, 30 sec cold water, repeat 3 times"
        ],
        "high_stress": [
            "Progressive muscle relaxation: tense and release each muscle group for 5 seconds",
            "Journaling: write down three things that went well today",
            "Reduce screen time for 1 hour before bed"
        ],
        "poor_sleep": [
            "No caffeine after 14:00",
            "Maintain consistent wake time, even on rest days",
            "Keep bedroom cool at 18-20 degrees Celsius"
        ],
        "menstrual_cramps": [
            "Magnesium-rich foods: spinach, almonds, dark chocolate",
            "Gentle yoga poses: child's pose, cat-cow stretch",
            "Apply heat pack to lower abdomen for 15-20 minutes"
        ],
        "luteal_fatigue": [
            "Increase carbohydrate intake by 20-30g in post-training meal",
            "Reduce high-intensity training volume by 15 percent",
            "Prioritise sleep extension by 30 minutes"
        ],
        "general": [
            "Hydrate with water and electrolytes after training",
            "Consume protein within 30-60 minutes post-exercise",
            "Take at least one full rest day per week"
        ],
        "locale": locale,
        "reference": "ACSM Recovery Guidelines (2024) and IOC Consensus on RED-S (Mountjoy et al., 2023)"
    }


@app.get("/api/v1/recovery/protocol/{user_id}")
async def get_recovery_protocol(user_id: str):
    from tasks import generate_athlete_recovery_protocol
    try:
        protocol = generate_athlete_recovery_protocol(user_id)
        if "error" in protocol:
            raise HTTPException(status_code=404, detail=protocol["error"])
        return protocol
    except HTTPException as e:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/recovery/squad-summary")
async def get_squad_recovery_summary():
    from tasks import get_session, generate_athlete_recovery_protocol
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT DISTINCT user_id FROM daily_checkins ORDER BY user_id
        """))
        rows = result.fetchall()
        summary = []
        for row in rows:
            uid = row[0]
            protocol = generate_athlete_recovery_protocol(uid)
            if "error" not in protocol:
                summary.append({
                    "user_id": uid,
                    "needs_breath_work": len(protocol.get("breath_work", [])) > 0,
                    "needs_nsdr": len(protocol.get("nsdr", [])) > 0,
                    "needs_asanas": len(protocol.get("restorative_asanas", [])) > 0,
                    "has_menstrual_guidance": protocol.get("menstrual_considerations") is not None,
                    "warning_count": len(protocol.get("warnings", []))
                })
        return {"squad_summary": summary, "total": len(summary), "generated_at": datetime.now(timezone.utc).isoformat()}
    finally:
        session.close()


@app.get("/api/v1/compare/{user_id_1}/{user_id_2}")
async def compare_athletes(user_id_1: str, user_id_2: str):
    from tasks import get_session, _calculate_readiness, generate_athlete_recovery_protocol, _compute_acwr_python, get_hormonal_status
    session = get_session()
    try:
        result1 = session.execute(text("""
            SELECT dc.gender, dc.daily_load, dc.rpe, dc.sleep_hours, dc.sleep_quality, dc.stress,
                   dc.fatigue, dc.muscle_soreness, dc.mood, dc.cycle_phase, dc.calories, dc.ffm,
                   dc.injury_location, dc.pain_level
            FROM daily_checkins dc WHERE dc.user_id = :uid ORDER BY dc.date DESC LIMIT 1
        """), {"uid": user_id_1})
        result2 = session.execute(text("""
            SELECT dc.gender, dc.daily_load, dc.rpe, dc.sleep_hours, dc.sleep_quality, dc.stress,
                   dc.fatigue, dc.muscle_soreness, dc.mood, dc.cycle_phase, dc.calories, dc.ffm,
                   dc.injury_location, dc.pain_level
            FROM daily_checkins dc WHERE dc.user_id = :uid ORDER BY dc.date DESC LIMIT 1
        """), {"uid": user_id_2})
        r1 = result1.fetchone()
        r2 = result2.fetchone()
        if not r1 or not r2:
            return {"error": "One or both athletes not found"}
        
        def build_profile(row, uid):
            gender = row[0] or "Male"
            daily_load = float(row[1] or 0)
            sleep_hours = float(row[3] or 7)
            sleep_quality = row[4] or 4
            stress_val = row[5] or 3
            fatigue_val = row[6] or 3
            soreness = row[7] or 2
            readiness = _calculate_readiness(sleep_quality, stress_val, fatigue_val, soreness, sleep_hours)
            
            # Get ACWR
            loads_result = session.execute(text("""
                SELECT daily_load FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC LIMIT 42
            """), {"uid": uid})
            loads = [float(r[0] or 0) for r in loads_result.fetchall()]
            acwr = 1.0
            risk_zone = "unknown"
            if len(loads) >= 28:
                hormonal = get_hormonal_status(uid)
                if hormonal in ("NOT_FEMALE", "UNKNOWN_PHASE"):
                    hormonal = row[9] or ""
                acwr_data = _compute_acwr_python(loads, gender, hormonal)
                acwr = acwr_data.get("acwr", 1.0)
                risk_zone = acwr_data.get("risk_zone", "unknown")
            
            # EA calculation
            ea = None
            calories = float(row[10] or 0)
            ffm = float(row[11] or 0)
            if ffm > 0 and calories > 0:
                ea = round((calories - (daily_load * 0.10 * ffm)) / ffm, 1)
            
            return {
                "user_id": uid, "gender": gender,
                "daily_load": daily_load, "rpe": row[2] or 0,
                "sleep_hours": sleep_hours, "sleep_quality": sleep_quality,
                "stress": stress_val, "fatigue": fatigue_val, "soreness": soreness,
                "readiness": readiness, "acwr": round(acwr, 2), "risk_zone": risk_zone,
                "energy_availability": ea,
                "mood": row[8] or "neutral",
                "cycle_phase": row[9] or "",
                "injury_location": row[12] or "",
                "pain_level": row[13] or 0,
                "recovery_protocol": generate_athlete_recovery_protocol(uid)
            }
        
        a1 = build_profile(r1, user_id_1)
        a2 = build_profile(r2, user_id_2)
        
        # Comparative insights
        insights = []
        if a1["readiness"] > a2["readiness"] + 15:
            insights.append(f"{user_id_1} has significantly higher readiness (+{a1['readiness'] - a2['readiness']}%)")
        elif a2["readiness"] > a1["readiness"] + 15:
            insights.append(f"{user_id_2} has significantly higher readiness (+{a2['readiness'] - a1['readiness']}%)")
        
        if a1["acwr"] > 1.5:
            insights.append(f"⚠ {user_id_1} ACWR critical at {a1['acwr']}")
        if a2["acwr"] > 1.5:
            insights.append(f"⚠ {user_id_2} ACWR critical at {a2['acwr']}")
        
        if a1["energy_availability"] and a1["energy_availability"] < 30:
            insights.append(f"⚠ {user_id_1} Energy Availability critically low ({a1['energy_availability']} kcal/kg FFM)")
        if a2["energy_availability"] and a2["energy_availability"] < 30:
            insights.append(f"⚠ {user_id_2} Energy Availability critically low ({a2['energy_availability']} kcal/kg FFM)")
        
        return {
            "athlete_1": a1,
            "athlete_2": a2,
            "comparison": {
                "load_difference": round(abs(a1["daily_load"] - a2["daily_load"]), 1),
                "readiness_difference": abs(a1["readiness"] - a2["readiness"]),
                "sleep_difference": round(abs(a1["sleep_hours"] - a2["sleep_hours"]), 1),
                "stress_difference": abs(a1["stress"] - a2["stress"]),
                "fatigue_difference": abs(a1["fatigue"] - a2["fatigue"])
            },
            "insights": insights if insights else ["Both athletes within acceptable ranges."],
            "generated_at": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()


@app.get("/api/v1/squad-weekly-summary")
async def get_squad_weekly_summary():
    from tasks import get_session, _calculate_readiness
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT user_id, gender, daily_load, rpe, sleep_hours, sleep_quality,
                   stress, fatigue, muscle_soreness, mood, cycle_phase, calories, ffm
            FROM daily_checkins WHERE (user_id, date) IN (SELECT user_id, MAX(date) FROM daily_checkins GROUP BY user_id)
        """))
        rows = result.fetchall()
        athletes = []
        for row in rows:
            athletes.append({
                "user_id": row[0], "gender": row[1], "daily_load": float(row[2] or 0),
                "sleep_hours": float(row[4] or 0), "stress": row[6], "fatigue": row[7],
                "readiness": _calculate_readiness(row[5] or 4, row[6] or 3, row[7] or 3, row[8] or 2, float(row[4] or 7)),
                "cycle_phase": row[10] or ""
            })
        high_risk = [a for a in athletes if a["readiness"] < 50 or a["stress"] >= 6 or a["fatigue"] >= 6]
        return {
            "week_of": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "total_athletes": len(athletes),
            "high_risk_count": len(high_risk),
            "high_risk_athletes": high_risk,
            "all_athletes": athletes
        }
    finally:
        session.close()


@app.get("/api/v1/recovery-adherence/{user_id}")
async def get_recovery_adherence(user_id: str, days: int = Query(30, ge=7, le=90)):
    """Track recovery protocol adherence and correlate with readiness."""
    from tasks import get_session, _calculate_readiness
    session = get_session()
    try:
        # Get recovery compliance
        recovery_result = session.execute(text("""
            SELECT date, breath_completed, nsdr_completed, asanas_completed
            FROM recovery_compliance
            WHERE user_id = :uid
            ORDER BY date DESC
            LIMIT :days
        """), {"uid": user_id, "days": days})
        recovery_rows = recovery_result.fetchall()
        
        # Get readiness data
        readiness_result = session.execute(text("""
            SELECT date, sleep_quality, stress, fatigue, muscle_soreness, sleep_hours
            FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date DESC
            LIMIT :days
        """), {"uid": user_id, "days": days})
        readiness_rows = readiness_result.fetchall()
        
        # Build date-indexed maps
        recovery_map = {}
        for row in recovery_rows:
            date_str = str(row[0])
            recovery_map[date_str] = {
                "breath": bool(row[1]),
                "nsdr": bool(row[2]),
                "asanas": bool(row[3]),
                "total": sum(1 for v in [row[1], row[2], row[3]] if v)
            }
        
        readiness_map = {}
        for row in readiness_rows:
            date_str = str(row[0])
            readiness_map[date_str] = _calculate_readiness(
                row[1] or 4, row[2] or 3, row[3] or 3,
                row[4] or 2, float(row[5] or 7)
            )
        
        # Correlate
        correlation_data = []
        compliant_days = 0
        total_matched_days = 0
        
        for date_str in sorted(set(list(recovery_map.keys()) + list(readiness_map.keys()))):
            rec = recovery_map.get(date_str, {"total": 0})
            readiness = readiness_map.get(date_str)
            if readiness is not None:
                total_matched_days += 1
                if rec["total"] >= 2:
                    compliant_days += 1
                correlation_data.append({
                    "date": date_str,
                    "recovery_completed": rec["total"],
                    "readiness": readiness
                })
        
        adherence_pct = round((compliant_days / total_matched_days) * 100, 1) if total_matched_days > 0 else 0
        
        # Calculate readiness difference
        compliant_readiness = [d["readiness"] for d in correlation_data if d["recovery_completed"] >= 2]
        non_compliant_readiness = [d["readiness"] for d in correlation_data if d["recovery_completed"] < 2]
        
        avg_compliant = round(sum(compliant_readiness) / len(compliant_readiness), 1) if compliant_readiness else 0
        avg_non_compliant = round(sum(non_compliant_readiness) / len(non_compliant_readiness), 1) if non_compliant_readiness else 0
        readiness_boost = round(avg_compliant - avg_non_compliant, 1)
        
        return {
            "user_id": user_id,
            "adherence_percent": adherence_pct,
            "compliant_days": compliant_days,
            "total_days_analyzed": total_matched_days,
            "average_readiness_compliant": avg_compliant,
            "average_readiness_non_compliant": avg_non_compliant,
            "recovery_boost": readiness_boost,
            "interpretation": f"Recovery protocol adherence provides +{readiness_boost}% readiness boost." if readiness_boost > 0 else "No significant correlation yet. Continue tracking.",
            "correlation_data": correlation_data[-14:],
            "reference": "Kellmann & Kallus (2001). Venter (2014) Sports Med.",
            "generated_at": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()

@app.get("/api/v1/recovery-streak/{user_id}")
async def get_recovery_streak(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, breath_completed, nsdr_completed, asanas_completed 
            FROM recovery_compliance 
            WHERE user_id = :uid 
            ORDER BY date DESC 
            LIMIT 30
        """), {"uid": user_id})
        rows = result.fetchall()
        streak = 0
        for row in rows:
            if row[1] or row[2] or row[3]:
                streak += 1
            else:
                break
        return {
            "user_id": user_id,
            "current_streak_days": streak,
            "total_compliant_days": sum(1 for r in rows if r[1] or r[2] or r[3]),
            "total_days_tracked": len(rows)
        }
    finally:
        session.close()


@app.get("/api/v1/taper-status/{user_id}")
async def get_taper_status(user_id: str):
    from tasks import detect_taper_status
    result = detect_taper_status(user_id)
    if result is None:
        return {"error": "Need at least 14 days of data"}
    return result


@app.get("/api/v1/jet-lag/{user_id}")
async def get_jet_lag_status(user_id: str):
    from tasks import get_session, calculate_travel_impact
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT travel_from_tz, travel_to_tz, date, sleep_hours, fatigue, 
                   COALESCE(flight_duration, 0) 
            FROM daily_checkins
            WHERE user_id = :uid AND travel_from_tz IS NOT NULL AND travel_from_tz != ''
            ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            return {"status": "NO_TRAVEL_DETECTED", "message": "No travel data recorded."}
        travel_impact = calculate_travel_impact(row[0], row[1], str(row[2]), date.today().isoformat(), row[5])
        if not travel_impact:
            return {"status": "MINIMAL", "message": "No significant travel impact detected."}
        if travel_impact.get("severity") == "RESOLVED":
            return {"status": "RESOLVED", "message": "Travel impact has resolved.", "travel_impact": travel_impact}
        return {
            "user_id": user_id,
            "travel_impact": travel_impact,
            "current_sleep_hours": float(row[3]) if row[3] else None,
            "current_fatigue": row[4] if row[4] else None
        }
    finally:
        session.close()


@app.get("/api/v1/pap-readiness/{user_id}")
async def get_pap_readiness(user_id: str):
    from tasks import get_session, _calculate_readiness
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT cmj_height_cm, daily_load, sleep_hours, sleep_quality, stress, fatigue, muscle_soreness, mood
            FROM daily_checkins WHERE user_id = :uid AND cmj_height_cm IS NOT NULL
            ORDER BY date DESC LIMIT 7
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 2:
            return {"status": "INSUFFICIENT_DATA", "message": "Need at least 2 CMJ measurements. Log CMJ height in Performance Tests."}
        cmj_values = [float(r[0]) for r in rows if r[0] is not None]
        if len(cmj_values) < 2:
            return {"status": "INSUFFICIENT_DATA", "message": "Need valid CMJ measurements."}
        current_cmj = cmj_values[0]
        best_cmj = max(cmj_values)
        pct_of_best = round((current_cmj / best_cmj) * 100, 1) if best_cmj > 0 else 100
        latest = rows[0]
        readiness = _calculate_readiness(
            latest[3] or 4, latest[4] or 3, latest[5] or 3,
            latest[6] or 2, float(latest[2] or 7)
        )
        if pct_of_best >= 95 and readiness >= 70:
            status = "PRIMED"
            recommendation = "Neuromuscular system ready for maximal effort. Proceed with planned high-intensity or power session."
        elif pct_of_best >= 90:
            status = "ADEQUATE"
            recommendation = "Proceed with moderate intensity. Additional warm-up sets may improve readiness."
        else:
            status = "NOT_PRIMED"
            recommendation = "Postpone maximal effort work. Focus on technique or submaximal loads."
        return {
            "user_id": user_id,
            "status": status,
            "current_cmj_cm": current_cmj,
            "best_cmj_cm": best_cmj,
            "percent_of_best": pct_of_best,
            "readiness": readiness,
            "recommendation": recommendation,
            "reference": "Wilson JM et al. (2013) J Strength Cond Res. 27(3):854-859."
        }
    finally:
        session.close()


@app.get("/api/v1/respiratory-trend/{user_id}")
async def get_respiratory_trend(user_id: str, days: int = 7):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, respiratory_rate FROM daily_checkins
            WHERE user_id = :uid AND respiratory_rate IS NOT NULL
            ORDER BY date DESC LIMIT :days
        """), {"uid": user_id, "days": days})
        rows = result.fetchall()
        if len(rows) < 3:
            return {"error": "Need at least 3 respiratory rate measurements"}
        rates = [float(r[1]) for r in reversed(rows) if r[1] is not None]
        dates = [str(r[0]) for r in reversed(rows) if r[1] is not None]
        if len(rates) < 3:
            return {"error": "Need at least 3 valid measurements"}
        avg_rate = sum(rates) / len(rates)
        trend = rates[-1] - rates[0]
        elevated = avg_rate > 16
        alert = trend > 2 and avg_rate > 16
        return {
            "user_id": user_id,
            "current_rate": rates[-1],
            "average_rate": round(avg_rate, 1),
            "trend_change": round(trend, 1),
            "elevated": elevated,
            "overtraining_alert": alert,
            "recommendation": "Resting respiratory rate is elevated. Consider reduced training load and enhanced recovery." if alert else "Respiratory rate within normal range.",
            "reference": "Buchheit M. (2014) Front Physiol. 5:73."
        }
    finally:
        session.close()


@app.get("/api/v1/load-readiness-ratio/{user_id}")
async def get_load_readiness_ratio(user_id: str):
    from tasks import get_session, _calculate_readiness
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT daily_load, sleep_quality, stress, fatigue, muscle_soreness, sleep_hours, mood
            FROM daily_checkins WHERE user_id = :uid ORDER BY date DESC LIMIT 7
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 5:
            return {"error": "Need at least 5 days of data"}
        avg_load = sum(float(r[0] or 0) for r in rows) / len(rows)
        avg_readiness = sum(
            _calculate_readiness(r[1] or 4, r[2] or 3, r[3] or 3, r[4] or 2, float(r[5] or 7))
            for r in rows
        ) / len(rows)
        ratio = round(avg_load / max(1, avg_readiness), 2) if avg_readiness > 0 else avg_load
        if ratio > 8:
            status = "OVERREACHING"
            action = "Load significantly exceeds readiness. Immediate load reduction of 30-40% required."
        elif ratio > 5:
            status = "BORDERLINE"
            action = "Load exceeds readiness. Monitor closely. Reduce non-essential training volume."
        elif ratio > 2:
            status = "OPTIMAL"
            action = "Load and readiness are balanced. Continue current program."
        else:
            status = "UNDERLOAD"
            action = "Readiness exceeds load. Consider progressive overload."
        return {
            "user_id": user_id,
            "ratio": ratio,
            "avg_load_7d": round(avg_load, 1),
            "avg_readiness_7d": round(avg_readiness, 1),
            "status": status,
            "action": action,
            "reference": "Gabbett TJ. (2016) Br J Sports Med. 50(5):273-280."
        }
    finally:
        session.close()


@app.get("/api/v1/cycle-symptom-trend/{user_id}")
async def get_cycle_symptom_trend(user_id: str, cycles: int = 3):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT cycle_phase, cramp_severity, mood_disturbance, bleeding_volume, daily_load, date
            FROM daily_checkins WHERE user_id = :uid AND cycle_phase IS NOT NULL AND cycle_phase != ''
            ORDER BY date DESC LIMIT :limit
        """), {"uid": user_id, "limit": cycles * 28})
        rows = result.fetchall()
        if len(rows) < 7:
            return {"error": "Need at least 7 days of cycle data"}
        phase_data = {"menstrual": [], "follicular": [], "ovulatory": [], "luteal": []}
        for row in rows:
            phase = row[0] if row[0] else ""
            if phase in phase_data:
                phase_data[phase].append({
                    "date": str(row[5]),
                    "cramps": row[1] or 0,
                    "mood_disturbance": row[2] or 0,
                    "bleeding": row[3] or "none",
                    "daily_load": float(row[4] or 0)
                })
        summary = {}
        for phase, entries in phase_data.items():
            if entries:
                summary[phase] = {
                    "sessions": len(entries),
                    "avg_cramps": round(sum(e["cramps"] for e in entries) / len(entries), 1),
                    "avg_mood_disturbance": round(sum(e["mood_disturbance"] for e in entries) / len(entries), 1),
                    "avg_load": round(sum(e["daily_load"] for e in entries) / len(entries), 1)
                }
        best_phase = max(summary, key=lambda p: summary[p]["avg_load"]) if summary else None
        worst_phase = max(summary, key=lambda p: summary[p]["avg_cramps"] + summary[p]["avg_mood_disturbance"]) if summary else None
        return {
            "user_id": user_id,
            "phase_summary": summary,
            "best_performance_phase": best_phase,
            "highest_symptom_phase": worst_phase,
            "recommendation": f"Schedule high-intensity sessions in {best_phase} phase. Increase recovery support during {worst_phase} phase." if best_phase and worst_phase else "Insufficient data for recommendations.",
            "reference": "McNulty KL et al. (2020) Sports Med. 50(10):1813-1827."
        }
    finally:
        session.close()


@app.get("/api/v1/coach-alert-digest")
async def get_coach_alert_digest():
    from tasks import get_session, _calculate_readiness, generate_athlete_recovery_protocol
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT user_id, gender, daily_load, rpe, sleep_hours, sleep_quality,
                   stress, fatigue, muscle_soreness, mood, cycle_phase, calories, ffm
            FROM daily_checkins WHERE (user_id, date) IN (SELECT user_id, MAX(date) FROM daily_checkins GROUP BY user_id)
        """))
        rows = result.fetchall()
        alerts = []
        for row in rows:
            uid, gender = row[0], row[1]
            load, sh, sq = float(row[2] or 0), float(row[4] or 0), row[5] or 4
            stress, fatigue, soreness = row[6] or 3, row[7] or 3, row[8] or 2
            mood, cp, cal, ffm = row[9] or "neutral", row[10] or "", row[11] or 0, row[12] or 0
            readiness = _calculate_readiness(sq, stress, fatigue, soreness, sh)
            athlete_alerts = []
            if readiness < 40:
                athlete_alerts.append({"severity": "HIGH", "type": "LOW_READINESS", "value": f"{readiness}%"})
            if stress >= 6:
                athlete_alerts.append({"severity": "HIGH", "type": "HIGH_STRESS", "value": f"{stress}/7"})
            if fatigue >= 6:
                athlete_alerts.append({"severity": "MEDIUM", "type": "HIGH_FATIGUE", "value": f"{fatigue}/7"})
            if sh < 6:
                athlete_alerts.append({"severity": "HIGH", "type": "SLEEP_DEFICIT", "value": f"{sh}h"})
            if cal > 0 and ffm > 0 and load > 0:
                ea_result = await get_validated_energy_availability(
                    cal, load, ffm,
                    exercise_type=None,
                    duration_minutes=60,
                    body_mass_kg=None
                )
                if ea_result:
                    ea = ea_result["ea_value"]
                    if ea < 30:
                        athlete_alerts.append({"severity": "CRITICAL", "type": "RED_S", "value": f"EA {ea} kcal/kg"})
            if athlete_alerts:
                protocol = generate_athlete_recovery_protocol(uid)
                alerts.append({
                    "user_id": uid,
                    "gender": gender,
                    "readiness": readiness,
                    "daily_load": load,
                    "cycle_phase": cp,
                    "alerts": athlete_alerts,
                    "needs_breath_work": len(protocol.get("breath_work", [])) > 0,
                    "needs_nsdr": len(protocol.get("nsdr", [])) > 0,
                    "needs_asanas": len(protocol.get("restorative_asanas", [])) > 0
                })
        return {
            "total_alerts": len(alerts),
            "alerts": sorted(alerts, key=lambda x: sum(1 for a in x["alerts"] if a["severity"] in ("CRITICAL", "HIGH")), reverse=True),
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "reference": "Gabbett TJ et al. (2017) Br J Sports Med. 51(20):1451-1452."
        }
    finally:
        session.close()


@app.get("/api/v1/nutrition-timing/{user_id}")
async def get_nutrition_timing(user_id: str):
    from tasks import get_session, NUTRITION_TIMING_PROTOCOLS
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT dc.daily_load, dc.rpe, dc.duration_minutes, dc.gender, dc.cycle_phase
            FROM daily_checkins dc
            WHERE dc.user_id = :uid
            ORDER BY dc.date DESC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="No data for athlete")
        cycle_phase = row[4] or ""
        pre = dict(NUTRITION_TIMING_PROTOCOLS["pre_training"])
        during = dict(NUTRITION_TIMING_PROTOCOLS["during_training"])
        post = dict(NUTRITION_TIMING_PROTOCOLS["post_training"])
        if row[3] == "Female" and cycle_phase == "luteal":
            post["protein"] = "0.5 g/kg body mass (increased for luteal phase)"
        return {
            "user_id": user_id,
            "pre_training": pre,
            "during_training": during,
            "post_training": post,
            "reference": "Kerksick CM et al. (2017) J Int Soc Sports Nutr. 14:33."
        }
    finally:
        session.close()


@app.get("/api/v1/sleep-hygiene/{user_id}")
async def get_sleep_hygiene(user_id: str):
    from tasks import get_session, calculate_sleep_hygiene_score
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT sleep_hours, sleep_quality FROM daily_checkins
            WHERE user_id = :uid ORDER BY date DESC LIMIT 7
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 3:
            raise HTTPException(status_code=404, detail="Need at least 3 days of data")
        avg_sh = sum(float(r[0] or 7) for r in rows) / len(rows)
        avg_sq = sum(r[1] or 4 for r in rows) / len(rows)
        consistency = len(set(str(r[0])[:10] for r in rows)) >= 5
        score = calculate_sleep_hygiene_score(avg_sh, avg_sq, consistency, False, False, None)
        return {
            "user_id": user_id,
            "average_sleep_hours": round(avg_sh, 1),
            "average_sleep_quality": round(avg_sq, 1),
            "hygiene_score": score,
            "recommendations": [
                "Maintain consistent wake time, even on rest days",
                "No caffeine after 14:00",
                "Dark, quiet, cool bedroom (18-20C)",
                "No screens 60 minutes before bed",
                "If unable to fall asleep in 20 minutes, get up and do something relaxing in dim light"
            ],
            "reference": "Milewski MD et al. (2014) J Pediatr Orthop. 34(2):129-133."
        }
    finally:
        session.close()

@app.post("/api/v1/wut-hydration", dependencies=[Depends(verify_api_key)])
async def record_wut_hydration(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        uid = payload.get("user_id")
        date_str = payload.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d"))
        weight = float(payload.get("morning_weight_kg", 0))
        urine = int(payload.get("urine_color", 1))
        thirst = int(payload.get("thirst_level", 1))
        hist = session.execute(text("""
            SELECT AVG(morning_weight_kg) FROM wut_hydration_logs
            WHERE user_id = :uid AND date >= date(:date, '-7 days')
        """), {"uid": uid, "date": date_str}).scalar()
        baseline_weight = float(hist) if hist else weight
        weight_drop_pct = ((baseline_weight - weight) / baseline_weight) * 100 if baseline_weight > 0 else 0
        w_flag = 1 if weight_drop_pct > 1.0 else 0
        u_flag = 1 if urine >= 5 else 0
        t_flag = 1 if thirst >= 5 else 0
        score = w_flag + u_flag + t_flag
        if score == 3:
            status = "SEVERELY_HYPOHYDRATED"
            action = f"DO NOT CLEAR FOR TRAINING. Immediate fluid replacement: approximately {round(weight_drop_pct * 10, 1)}L fluid deficit. Replace 150% of losses with sodium-containing fluids."
        elif score == 2:
            status = "HYPOHYDRATED"
            action = "Mandatory pre-training hydration protocol. Consume 500-1000mL fluid with 500-700mg sodium within 60 minutes before training."
        else:
            status = "EUHYDRATED"
            action = "Cleared for training. Maintain standard intra-session hydration."
        session.execute(text("""
            INSERT INTO wut_hydration_logs (user_id, date, morning_weight_kg, urine_color, thirst_level, status, created_at)
            VALUES (:uid, :date, :w, :u, :t, :status, :now)
        """), {
            "uid": uid, "date": date_str, "w": weight, "u": urine, "t": thirst,
            "status": status, "now": datetime.now(timezone.utc).isoformat()
        })
        session.commit()
        return {
            "user_id": uid, "status": status, "weight_drop_percent": round(weight_drop_pct, 2),
            "action": action, "reference": "Cheuvront & Sawka (2005). WUT Protocol. ACSM Position Stand on Exertional Heat Illness."
        }
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.post("/api/v1/concussion/grtp-update", dependencies=[Depends(verify_api_key)])
async def update_concussion_grtp(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        uid = payload.get("user_id")
        symptoms_present = payload.get("symptoms_present", True)
        md_cleared = payload.get("md_cleared", False)
        record = session.execute(text("""
            SELECT id, current_stage, symptom_free_days, days_at_current_stage FROM concussion_grtp
            WHERE user_id = :uid ORDER BY incident_date DESC LIMIT 1
        """), {"uid": uid}).fetchone()
        if not record:
            return {"error": "No active concussion protocol found."}
        record_id, stage, sym_free, days_at_stage = record
        if symptoms_present:
            new_stage = 1
            new_sym_free = 0
            new_days_at_stage = 0
            action = "Symptoms present. Regress to Stage 1: Symptom-limited activity. Complete physical and cognitive rest."
        else:
            new_sym_free = sym_free + 1
            new_days_at_stage = days_at_stage + 1
            if stage == 1 and new_days_at_stage >= 1:
                new_stage = 2
                new_days_at_stage = 0
                action = "Stage 2: Light aerobic exercise up to 70% max HR. No resistance training. Duration: 20-30 min."
            elif stage == 2 and new_days_at_stage >= 1:
                new_stage = 3
                new_days_at_stage = 0
                action = "Stage 3: Sport-specific exercise (running/skating). No head impact. Light resistance cleared."
            elif stage == 3 and new_days_at_stage >= 1:
                new_stage = 4
                new_days_at_stage = 0
                action = "Stage 4: Non-contact training drills. Full resistance training cleared."
            elif stage == 4 and md_cleared and new_days_at_stage >= 1:
                new_stage = 5
                new_days_at_stage = 0
                action = "Stage 5: Full contact practice following medical clearance."
            elif stage == 4 and not md_cleared:
                new_stage = 4
                action = "Cannot progress to Stage 5 without explicit Medical Doctor (MD) clearance."
            elif stage == 5 and new_days_at_stage >= 1:
                new_stage = 6
                new_days_at_stage = 0
                action = "Stage 6: Return to Play. Fully cleared for unrestricted competition."
            else:
                new_stage = stage
                action = f"Remain at Stage {stage}. Minimum 24 hours required at each stage before progression."
        session.execute(text("""
            UPDATE concussion_grtp SET current_stage = :st, symptom_free_days = :sf,
            days_at_current_stage = :ds, cleared_by_md = :md
            WHERE id = :rid
        """), {"st": new_stage, "sf": new_sym_free, "ds": new_days_at_stage, "md": int(md_cleared), "rid": record_id})
        session.commit()
        return {
            "user_id": uid, "current_stage": new_stage, "symptom_free_days": new_sym_free,
            "days_at_current_stage": new_days_at_stage, "clinical_directive": action,
            "reference": "6th International Consensus on Concussion in Sport (Amsterdam 2022)."
        }
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()



@app.post("/api/v1/recovery-compliance")
async def log_recovery_compliance(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            INSERT INTO recovery_compliance (user_id, date, breath_completed, nsdr_completed, asanas_completed, notes, created_at)
            VALUES (:uid, :date, :breath, :nsdr, :asanas, :notes, :now)
        """), {
            "uid": payload.get("user_id"),
            "date": payload.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "breath": payload.get("breath_completed", False),
            "nsdr": payload.get("nsdr_completed", False),
            "asanas": payload.get("asanas_completed", False),
            "notes": payload.get("notes", ""),
            "now": datetime.now(timezone.utc).isoformat()
        })
        session.commit()
        return {"status": "logged"}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/v2/decision-support/{user_id}")
async def get_decision_support(user_id: str):
    from tasks import (
        get_session, _calculate_readiness,
        _compute_acwr_python, _compute_monotony_strain,
        generate_athlete_recovery_protocol
    )
    import httpx

    session = get_session()
    try:
        result = session.execute(text("""
            SELECT gender, daily_load, rpe, sleep_hours, sleep_quality,
                   stress, fatigue, muscle_soreness, mood, cycle_phase,
                   calories, ffm, exercise_type, duration_minutes,
                   respiratory_rate, injury_location, pain_level
            FROM daily_checkins
            WHERE user_id = :uid
            ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="No data for athlete")

        gender = row[0] or "male"
        sleep_hours_val = float(row[3]) if row[3] else 7.0
        sleep_quality = row[4] or 4
        stress_val = row[5] or 3
        fatigue_val = row[6] or 3
        soreness_val = row[7] or 2
        mood_val = row[8] or "neutral"
        cycle_phase = row[9] or ""
        calories_val = float(row[10]) if row[10] else 0
        ffm_val = float(row[11]) if row[11] else 0
        exercise_type = row[12] or ""
        duration_minutes = float(row[13]) if row[13] else 60
        respiratory_rate = float(row[14]) if row[14] else None
        daily_load_val = float(row[1]) if row[1] else 0

        hist = session.execute(text("""
            SELECT daily_load FROM daily_checkins
            WHERE user_id = :uid ORDER BY date ASC
        """), {"uid": user_id})
        daily_loads = [float(r[0]) if r[0] else 0.0 for r in hist.fetchall()]

        r_available = False
        acwr_val = 1.0
        acwr_zone = "unknown"
        ea_val = None
        ea_status = "UNKNOWN"

        if len(daily_loads) >= 28:
            try:
                r_payload = {
                    "daily_loads": daily_loads,
                    "gender": gender,
                    "cycle_phase": cycle_phase,
                    "calories": calories_val,
                    "ffm": ffm_val,
                    "exercise_type": exercise_type,
                    "duration_minutes": duration_minutes
                }
                async with httpx.AsyncClient(timeout=3.0) as client:
                    r_resp = await client.post(
                        "http://localhost:8001/analytics/full-assessment",
                        json=r_payload
                    )
                    if r_resp.status_code == 200:
                        r_data = r_resp.json()
                        if "error" not in r_data:
                            acwr_val = r_data.get("acwr", 1.0)
                            acwr_zone = r_data.get("risk_zone", "unknown")
                            if r_data.get("energy_availability"):
                                ea_val = r_data["energy_availability"].get("ea_value")
                                ea_status = r_data["energy_availability"].get("ea_status", "UNKNOWN")
                            r_available = True
            except Exception:
                pass

        if not r_available and len(daily_loads) >= 28:
            acwr_data = _compute_acwr_python(daily_loads, gender, cycle_phase)
            acwr_val = acwr_data.get("acwr", 1.0)
            acwr_zone = acwr_data.get("risk_zone", "unknown")

        readiness_val = _calculate_readiness(
            sleep_quality, stress_val, fatigue_val,
            soreness_val, sleep_hours_val
        )

        mono_data = _compute_monotony_strain(daily_loads) if len(daily_loads) >= 7 else {"monotony": 0, "strain": 0, "risk": False}

        wellness = readiness_val

        recovery = generate_athlete_recovery_protocol(user_id)

        alerts = []
        if acwr_val >= 1.5:
            alerts.append("ACWR CRITICAL: " + str(acwr_val))
        elif acwr_val >= 1.35:
            alerts.append("ACWR ELEVATED: " + str(acwr_val))
        if ea_status == "RED":
            alerts.append("RED-S RISK: Energy Availability critically low")
        elif ea_status == "YELLOW":
            alerts.append("Energy Availability suboptimal - monitor")
        if readiness_val < 40:
            alerts.append("READINESS CRITICAL: " + str(readiness_val) + "%")
        if mono_data.get("risk"):
            alerts.append("TRAINING MONOTONY HIGH: " + str(round(mono_data.get("monotony", 0), 1)))
        if sleep_hours_val < 6:
            alerts.append("SLEEP DEFICIT: " + str(sleep_hours_val) + "h")

        recovery_strategies = []
        for r_item in recovery.get("restorative_asanas", [])[:3]:
            recovery_strategies.append(r_item.get("name", ""))
        for w in recovery.get("warnings", [])[:2]:
            recovery_strategies.append(w)

        return {
            "user_id": user_id,
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "readiness": readiness_val,
            "acwr": round(acwr_val, 4),
            "acwr_risk_zone": acwr_zone,
            "energy_availability": ea_val,
            "ea_status": ea_status,
            "monotony": round(mono_data.get("monotony", 0), 2),
            "strain": round(mono_data.get("strain", 0), 2),
            "sleep_hours": sleep_hours_val,
            "wellness_index": wellness,
            "alerts": alerts,
            "recovery_strategies": recovery_strategies,
            "r_engine_available": r_available,
            "disclaimer": "Screening tool only. Not medical advice. Consult qualified professionals."
        }
    except Exception as e:
        logger.error(f"Decision support failed for {user_id}: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.post("/api/emergency/eap")
async def generate_emergency_action_plan(payload: dict):
    """Generate venue-specific Emergency Action Plan based on ACSM/NSCA guidelines."""
    venue_name = payload.get("venue_name", "Training Facility")
    venue_address = payload.get("venue_address", "")
    nearest_hospital = payload.get("nearest_hospital", "")
    hospital_address = payload.get("hospital_address", "")
    emergency_phone = payload.get("emergency_phone", "112/911")
    venue_phone = payload.get("venue_phone", "")
    
    eap = {
        "venue": venue_name,
        "address": venue_address,
        "emergency_numbers": {
            "ambulance": emergency_phone,
            "fire": emergency_phone,
            "police": emergency_phone,
            "venue_contact": venue_phone or "N/A"
        },
        "nearest_medical_facility": {
            "name": nearest_hospital or "DESIGNATE NEAREST HOSPITAL",
            "address": hospital_address or "ADD HOSPITAL ADDRESS",
            "estimated_response_time_min": "___ minutes"
        },
        "roles_and_responsibilities": [
            {"role": "Incident Commander", "responsibility": "Assess scene safety, activate EAP, direct EMS to victim"},
            {"role": "Primary Responder", "responsibility": "Provide first aid/CPR within scope of training. Use AED if indicated."},
            {"role": "Communications Officer", "responsibility": f"Call {emergency_phone}. Provide: venue address, victim condition, access points."},
            {"role": "Equipment Manager", "responsibility": "Retrieve AED, first aid kit, spine board if available. Meet EMS at entrance."}
        ],
        "equipment_locations": {
            "aed": "PRIMARY: [location]. SECONDARY: [location]",
            "first_aid_kit": "[location]",
            "spine_board": "[location if applicable]",
            "epinephrine_autoinjector": "[location if prescribed]"
        },
        "venue_access": {
            "main_entrance": "[description]",
            "emergency_entrance": "[description]",
            "gps_coordinates": "[latitude, longitude]"
        },
        "emergency_procedures": {
            "cardiac_arrest": "1. Activate EAP. 2. Start CPR immediately (30:2 ratio). 3. Retrieve AED. 4. Call EMS. 5. Continue until EMS arrives.",
            "heat_stroke": "1. Remove from heat. 2. Cold water immersion (ice bath 35-59°F). 3. Call EMS. 4. Monitor vitals. DO NOT DELAY COOLING.",
            "spinal_injury": "1. DO NOT MOVE athlete. 2. Stabilize head/neck. 3. Call EMS. 4. Monitor ABCs.",
            "anaphylaxis": "1. Administer epinephrine autoinjector. 2. Call EMS. 3. Monitor breathing. 4. Second dose after 5 min if no improvement.",
            "concussion": "1. Remove from play. 2. Evaluate with SCAT6. 3. NO same-day return. 4. Medical referral. 5. Follow GRTP protocol."
        },
        "review_schedule": "This EAP shall be reviewed and rehearsed quarterly. Next review date: ____",
        "references": [
            "ACSM Guidelines for Exercise Testing and Prescription, 11th Ed (2024)",
            "NSCA Essentials of Strength Training, 4th Ed",
            "6th International Consensus on Concussion in Sport (Amsterdam 2022)",
            "Korey Stringer Institute — Heat Illness Prevention"
        ],
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "disclaimer": "This is a template. Customize all [bracketed] fields for your specific venue."
    }
    
    return eap

@app.get("/api/methods")
async def get_methods():
    return {
        "system": "A.T.H.E.N.A.",
        "version": "5.0.0",
        "last_updated": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "algorithms": {
            "acwr_uncoupled": {
                "method": "Uncoupled 7:21-day rolling average",
                "formula": "ACWR = Acute_7day_RA / Uncoupled_Chronic_21day_RA",
                "threshold": 1.5,
                "threshold_note": "Population-level guideline. No validated sex-specific or cycle-specific ACWR thresholds exist in Q1 literature.",
                "confidence_interval": "AR(1) autocorrelation-corrected standard error with contiguous-block adjustment",
                "minimum_days": 42,
                "reference": "Impellizzeri FM et al. (2019) Int J Sports Physiol Perform. 14(1):2-8. Lolli L et al. (2019) J Sci Med Sport. 22(1):117-122."
            },
            "monotony_strain": {
                "monotony": "mean_7day_load / std_dev_7day_load",
                "strain": "sum_7day_load x monotony",
                "high_risk": "monotony > 2.0",
                "reference": "Foster C. (1998) Med Sci Sports Exerc. 30(7):1164-1168."
            },
            "energy_availability": {
                "method": "Thermodynamically corrected Net EEE",
                "formula": "EA = (Calories - Luteal_Penalty - Net_EEE) / FFM",
                "net_eee": "Gross EEE - (RMR/min x duration).",
                "luteal_penalty": "150 kcal/day deducted from 24-hour energy balance during natural luteal phase",
                "green": ">= 45 kcal/kg FFM/day",
                "yellow": "30-45 kcal/kg FFM/day",
                "red": "< 30 kcal/kg FFM/day",
                "sRPE_disclaimer": "sRPE-to-kcal conversion is scientifically invalid. EA calculation requires measured or MET-estimated EEE.",
                "reference": "Mountjoy M et al. (2018) Br J Sports Med. 52(11):687-697. Oosthuyse T & Bosch AN. (2010) Sports Med. 40(3):207-227."
            },
            "readiness": {
                "method": "Unweighted Hooper Index summation",
                "formula": "Mean of (sleep_quality/7, sleep_hours/8, inverted_stress, inverted_fatigue, inverted_soreness) x 100",
                "reference": "Hooper SL & Mackinnon LT. (1995) Sports Med. 20(5):321-330."
            },
            "cycle_phase_prediction": {
                "method": "Calendar-based retrograde luteal anchoring",
                "accuracy": "~70%. Confirm with urinary LH testing for critical competition periods.",
                "reference": "Lenton EA et al. (1984) Fertil Steril. 41(5):685-691. Bull JR et al. (2019) npj Digital Medicine. 2:83."
            }
        },
        "conference_readiness": {
            "acsm_guidelines": "ACSM Guidelines for Exercise Testing and Prescription, 11th Ed (2024)",
            "nsca": "Essentials of Strength Training and Conditioning, 4th Ed",
            "ioc_reds": "IOC RED-S Consensus (Mountjoy et al., 2018/2023)",
            "disclaimer": "All thresholds are screening tools only. Clinical diagnosis requires comprehensive medical evaluation."
        }
    }


@app.post("/sms-webhook")
async def sms_webhook(Body: str = Form(...), From: str = Form(...), x_api_key: str = Header(None)):
    if x_api_key != ATHENA_API_KEY:
        logger.warning(f"SMS webhook rejected: Invalid or missing API key from {From}")
        raise HTTPException(status_code=401, detail="Invalid or missing API key")
    parts = Body.strip().split()
    if len(parts) < 6:
        return {"status": "error", "message": "Format: ID sleep RPE stress fatigue soreness [cycle_phase]"}

    try:
        user_id = parts[0].upper()
        sleep_hours = float(parts[1])
        rpe = int(parts[2])
        stress = int(parts[3])
        fatigue = int(parts[4])
        soreness = int(parts[5])
        cycle_phase = parts[6] if len(parts) > 6 else ""
    except ValueError:
        return {"status": "error", "message": "Invalid numeric values"}

    payload = {
        "user_id": user_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "gender": "Female" if cycle_phase else "Male",
        "duration_minutes": 60,
        "rpe": rpe,
        "sleep_hours": sleep_hours,
        "sleep_quality": 4,
        "stress": stress,
        "fatigue": fatigue,
        "muscle_soreness": soreness,
        "cycle_phase": cycle_phase,
    }

    try:
        if celery_app is None:
            from tasks import get_session
            session = get_session()
            try:
                timestamp_dt = datetime.fromisoformat(payload["timestamp"])
                date_str = timestamp_dt.strftime("%Y-%m-%d")
                daily_load = round(payload["rpe"] * payload["duration_minutes"], 2)
                session.execute(text("""
                    INSERT INTO daily_checkins (user_id, date, timestamp, gender, duration_minutes, rpe, sleep_hours, sleep_quality, stress, fatigue, muscle_soreness, cycle_phase, daily_load, load_strength, load_endurance, load_power, created_at)
                    VALUES (:uid, :date, :ts, :gender, :dur, :rpe, :sh, :sq, :st, :fa, :ms, :cp, :load, 0, 0, 0, :now)
                    ON CONFLICT (user_id, date) DO UPDATE SET
                        timestamp=EXCLUDED.timestamp, gender=EXCLUDED.gender, duration_minutes=EXCLUDED.duration_minutes,
                        rpe=EXCLUDED.rpe, sleep_hours=EXCLUDED.sleep_hours, sleep_quality=EXCLUDED.sleep_quality,
                        stress=EXCLUDED.stress, fatigue=EXCLUDED.fatigue, muscle_soreness=EXCLUDED.muscle_soreness,
                        cycle_phase=COALESCE(EXCLUDED.cycle_phase, daily_checkins.cycle_phase), daily_load=EXCLUDED.daily_load
                """), {
                    "uid": user_id, "date": date_str, "ts": payload["timestamp"], "gender": payload["gender"],
                    "dur": payload["duration_minutes"], "rpe": payload["rpe"],
                    "sh": payload["sleep_hours"], "sq": payload["sleep_quality"],
                    "st": payload["stress"], "fa": payload["fatigue"],
                    "ms": payload["muscle_soreness"], "cp": payload.get("cycle_phase", ""),
                    "load": daily_load, "now": datetime.now(timezone.utc).isoformat()
                })
                session.commit()
            finally:
                session.close()
            return {"status": "received", "task_id": "sms-sync-" + str(uuid.uuid4())[:8], "user_id": user_id}
        task = celery_app.send_task(
            "tasks.process_athlete_checkin",
            args=[json.dumps(payload)],
            queue="athena_checkins"
        )
        return {"status": "received", "task_id": task.id, "user_id": user_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/reds-trajectory/{user_id}")
async def get_reds_trajectory(user_id: str):
    import asyncio
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(
            text("SELECT date, calories, ffm, daily_load, exercise_type, duration_minutes, gender, cycle_phase FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC"),
            {"uid": user_id}
        )
        rows = result.fetchall()

        if len(rows) < 21:
            return {"error": "Need at least 21 days of data", "days_available": len(rows)}

        dates_list = [str(r[0]) for r in rows]
        calories_series = [float(r[1]) if r[1] else 0.0 for r in rows]
        ffm_series = [float(r[2]) if r[2] else 0.0 for r in rows]
        daily_loads = [float(r[3]) if r[3] else 0.0 for r in rows]
        duration_series = [float(r[5]) if r[5] else 60.0 for r in rows]
        gender = rows[-1][6] if rows[-1][6] else "Male"
        cycle_phase = rows[-1][7] if rows[-1][7] else ""

        r_payload = {
            "dates": dates_list,
            "calories_series": calories_series,
            "ffm_series": ffm_series,
            "duration_minutes_series": duration_series,
            "daily_loads": daily_loads,
            "gender": gender,
            "cycle_phase": cycle_phase
        }

        r_result = None
        try:
            r_result = await asyncio.wait_for(_call_r("analytics/ea-assessment", r_payload), timeout=25.0)
        except (asyncio.TimeoutError, Exception):
            logger.warning(f"R engine timeout for RED-S trajectory {user_id}. Using Python fallback.")

        if r_result and "error" not in r_result:
            r_result["user_id"] = user_id
            r_result["analytics_engine"] = "r_engine"
            return r_result

        from tasks import _calculate_energy_availability
        ea_results = []
        for i in range(len(dates_list)):
            ea = _calculate_energy_availability(
                calories_series[i], daily_loads[i], ffm_series[i],
                duration_minutes=duration_series[i] if i < len(duration_series) else 60,
                gender=gender, cycle_phase=cycle_phase
            )
            if ea:
                ea_results.append(ea["ea_value"])
        if ea_results:
            avg_ea = sum(ea_results) / len(ea_results)
            return {
                "user_id": user_id,
                "ea_value": round(avg_ea, 2),
                "ea_status": "GREEN" if avg_ea >= 45 else ("YELLOW" if avg_ea >= 30 else "RED"),
                "analytics_engine": "python_fallback",
                "note": "R engine unavailable. Python-native calculation used."
            }
        return {"error": "Unable to calculate energy availability.", "user_id": user_id}
    finally:
        session.close()


@app.get("/api/full-assessment/{user_id}")
async def get_full_assessment(user_id: str):
    import asyncio
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(
            text("SELECT date, daily_load, cycle_phase, gender, calories, ffm, duration_minutes FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC"),
            {"uid": user_id}
        )
        rows = result.fetchall()

        if len(rows) < 28:
            return {"error": "Minimum 28 days required", "days_available": len(rows)}

        dates_list = [str(r[0]) for r in rows]
        daily_loads = [float(r[1]) if r[1] else 0.0 for r in rows]
        cycle_phase = rows[-1][2] if rows[-1][2] else ""
        gender = rows[-1][3] if rows[-1][3] else "Male"
        calories_series = [float(r[4]) if r[4] else 0.0 for r in rows]
        ffm_series = [float(r[5]) if r[5] else 0.0 for r in rows]
        duration_series = [float(r[6]) if r[6] else 60.0 for r in rows]
        exercise_ee_series = [float(r[1]) * 1.5 if r[1] else 0.0 for r in rows]

        r_payload = {
            "dates": dates_list,
            "daily_loads": daily_loads,
            "calories_series": calories_series,
            "exercise_ee_series": exercise_ee_series,
            "ffm_series": ffm_series,
            "duration_minutes_series": duration_series,
            "gender": gender,
            "cycle_phase": cycle_phase
        }

        r_result = None
        try:
            r_result = await asyncio.wait_for(_call_r("analytics/full-assessment", r_payload), timeout=25.0)
        except (asyncio.TimeoutError, Exception):
            logger.warning(f"R engine timeout for full assessment {user_id}. Using Python fallback.")

        if r_result and "error" not in r_result:
            r_result["user_id"] = user_id
            r_result["analytics_engine"] = "r_engine"
            return r_result

        from tasks import _compute_acwr_python, _compute_monotony_strain, _calculate_energy_availability
        acwr_data = _compute_acwr_python(daily_loads, gender, cycle_phase)
        ea_results = []
        for i in range(len(dates_list)):
            ea = _calculate_energy_availability(
                calories_series[i], daily_loads[i], ffm_series[i],
                duration_minutes=duration_series[i] if i < len(duration_series) else 60,
                gender=gender, cycle_phase=cycle_phase
            )
            if ea:
                ea_results.append(ea["ea_value"])
        avg_ea = sum(ea_results) / len(ea_results) if ea_results else None
        return {
            "user_id": user_id,
            "acwr": acwr_data.get("acwr", 1.0),
            "risk_zone": acwr_data.get("risk_zone", "unknown"),
            "energy_availability": {"ea_value": round(avg_ea, 2) if avg_ea else None, "ea_status": "GREEN" if (avg_ea and avg_ea >= 45) else ("YELLOW" if (avg_ea and avg_ea >= 30) else "RED") if avg_ea else "UNKNOWN"},
            "analytics_engine": "python_fallback",
            "note": "R engine unavailable. Python-native calculation used."
        }
    finally:
        session.close()

@app.post("/api/program/auto-periodize")
async def auto_periodize_training(payload: dict):
    """Auto-generate periodized training blocks based on competition date and sport type."""
    from datetime import date as dt_date, timedelta
    
    competition_date = dt_date.fromisoformat(payload.get("competition_date"))
    sport_type = payload.get("sport_type", "endurance").lower()
    user_id = payload.get("user_id")
    today = dt_date.today()
    
    days_to_competition = (competition_date - today).days
    if days_to_competition < 21:
        return {"error": "Need at least 21 days to competition for effective periodization.", "days_available": days_to_competition}
    
    # Define mesocycles based on sport type
    mesocycles = []
    if sport_type in ("endurance", "triathlon", "cycling", "running", "swimming"):
        mesocycles = [
            {"name": "Base Building", "weeks": max(4, days_to_competition // 6), "focus": "aerobic_capacity", "load_pct": 60},
            {"name": "Strength Endurance", "weeks": max(3, days_to_competition // 8), "focus": "strength_endurance", "load_pct": 75},
            {"name": "Power Development", "weeks": max(3, days_to_competition // 8), "focus": "power", "load_pct": 85},
            {"name": "Race Specific", "weeks": max(3, days_to_competition // 8), "focus": "sport_specific", "load_pct": 90},
            {"name": "Taper", "weeks": max(2, days_to_competition // 10), "focus": "peaking", "load_pct": 50},
        ]
    elif sport_type in ("strength", "powerlifting", "weightlifting"):
        mesocycles = [
            {"name": "Hypertrophy", "weeks": max(4, days_to_competition // 6), "focus": "hypertrophy", "load_pct": 70},
            {"name": "Strength", "weeks": max(4, days_to_competition // 7), "focus": "strength_development", "load_pct": 80},
            {"name": "Power", "weeks": max(3, days_to_competition // 8), "focus": "power", "load_pct": 88},
            {"name": "Peaking", "weeks": max(2, days_to_competition // 10), "focus": "strength_peaking", "load_pct": 60},
        ]
    elif sport_type in ("team_sport", "soccer", "basketball", "rugby", "hockey"):
        mesocycles = [
            {"name": "General Preparation", "weeks": max(4, days_to_competition // 6), "focus": "general_prep", "load_pct": 65},
            {"name": "Specific Preparation", "weeks": max(3, days_to_competition // 7), "focus": "sport_specific", "load_pct": 80},
            {"name": "Pre-Competition", "weeks": max(3, days_to_competition // 7), "focus": "tactical", "load_pct": 90},
            {"name": "Competition", "weeks": max(2, days_to_competition // 8), "focus": "maintenance", "load_pct": 75},
        ]
    else:
        mesocycles = [
            {"name": "Preparation", "weeks": max(4, days_to_competition // 5), "focus": "general", "load_pct": 70},
            {"name": "Specific", "weeks": max(3, days_to_competition // 6), "focus": "sport_specific", "load_pct": 85},
            {"name": "Taper", "weeks": max(2, days_to_competition // 8), "focus": "peaking", "load_pct": 55},
        ]
    
    # Calculate actual dates
    block_start = today
    schedule = []
    total_weeks_planned = sum(m["weeks"] for m in mesocycles)
    scaling_factor = min(1.0, days_to_competition / max(1, total_weeks_planned))
    
    for meso in mesocycles:
        adjusted_weeks = max(1, round(meso["weeks"] * scaling_factor))
        block_end = block_start + timedelta(weeks=adjusted_weeks)
        schedule.append({
            "mesocycle": meso["name"],
            "focus": meso["focus"],
            "weeks": adjusted_weeks,
            "start_date": block_start.isoformat(),
            "end_date": block_end.isoformat(),
            "target_load_percent": meso["load_pct"]
        })
        block_start = block_end
    
    # Generate nutrition targets for each mesocycle
    nutrition_plan = []
    for meso in mesocycles:
        focus = meso["focus"]
        if focus in ("hypertrophy", "strength_development", "strength_endurance"):
            nutrition_plan.append({
                "mesocycle": meso["name"],
                "pro_g_per_kg": 1.8,
                "cho_g_per_kg": 5.0,
                "fat_g_per_kg": 1.2,
                "supplements": "Creatine 5g/day. Whey protein as needed."
            })
        elif focus in ("aerobic_capacity", "endurance_base"):
            nutrition_plan.append({
                "mesocycle": meso["name"],
                "pro_g_per_kg": 1.4,
                "cho_g_per_kg": 7.0,
                "fat_g_per_kg": 1.0,
                "supplements": "Electrolytes for sessions >90 min."
            })
        elif focus in ("peaking", "strength_peaking"):
            nutrition_plan.append({
                "mesocycle": meso["name"],
                "pro_g_per_kg": 2.0,
                "cho_g_per_kg": 4.0,
                "fat_g_per_kg": 1.0,
                "supplements": "Caffeine 3-6 mg/kg pre-competition. Maintain creatine if loaded."
            })
        else:
            nutrition_plan.append({
                "mesocycle": meso["name"],
                "pro_g_per_kg": 1.6,
                "cho_g_per_kg": 5.5,
                "fat_g_per_kg": 1.1,
                "supplements": "Vitamin D 2000 IU. Food-first approach."
            })
    
    return {
        "user_id": user_id,
        "sport_type": sport_type,
        "competition_date": competition_date.isoformat(),
        "days_to_competition": days_to_competition,
        "schedule": schedule,
        "nutrition_plan": nutrition_plan,
        "reference": "NSCA Essentials 4th Ed. Bompa & Haff (2009) Periodization. ACSM Guidelines 2024.",
        "generated_at": datetime.now(timezone.utc).isoformat()
    }

@app.post("/api/program/create")
async def create_training_program(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            INSERT INTO training_programs (user_id, program_name, periodization_model, start_date, end_date, created_by, created_at)
            VALUES (:uid, :name, :model, :sdate, :edate, :coach, :now)
        """), {
            "uid": payload.get("user_id"),
            "name": payload.get("program_name"),
            "model": payload.get("periodization_model", "linear"),
            "sdate": payload.get("start_date"),
            "edate": payload.get("end_date"),
            "coach": payload.get("created_by", "coach_default"),
            "now": datetime.now(timezone.utc).isoformat()
        })
        session.commit()
        return {"status": "created", "message": "Program scaffolding initialized."}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/program/todays-workout/{user_id}")
async def get_todays_workout(user_id: str):
    from tasks import get_session, _calculate_readiness, _compute_acwr_python, get_hormonal_status
    session = get_session()
    try:
        today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        workout_query = session.execute(text("""
            SELECT ws.id, ws.session_type, ws.target_adaptation, ws.auto_regulate
            FROM workout_sessions ws
            JOIN training_programs tp ON ws.program_id = tp.id
            WHERE tp.user_id = :uid AND ws.planned_date = :today
        """), {"uid": user_id, "today": today_str})
        workout = workout_query.fetchone()
        if not workout:
            return {"status": "REST_DAY", "message": "No programmed sessions today."}
        status_query = session.execute(text("""
            SELECT sleep_quality, stress, fatigue, muscle_soreness, sleep_hours, mood, daily_load, gender, cycle_phase
            FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC LIMIT 42
        """), {"uid": user_id})
        rows = status_query.fetchall()
        readiness = 100
        acwr = 1.0
        if rows:
            latest = rows[-1]
            readiness = _calculate_readiness(
                latest[0] or 4, latest[1] or 3, latest[2] or 3,
                latest[3] or 2, float(latest[4] or 7), mood=latest[5]
            )
            loads = [float(r[6] or 0) for r in rows]
            gender = latest[7] or "Male"
            raw_cycle = latest[8] or ""
            if len(loads) >= 42:
                hormonal_status = get_hormonal_status(user_id)
                if hormonal_status in ("NOT_FEMALE", "UNKNOWN_PHASE"):
                    hormonal_status = raw_cycle
                acwr_data = _compute_acwr_python(loads, gender, hormonal_status)
                acwr = acwr_data.get("acwr", 1.0)
        volume_modifier = 1.0
        intensity_modifier = 1.0
        adjustment_note = "Standard prescription. Athlete is biologically primed."
        if workout[3]:
            if acwr >= 1.5 or readiness < 40:
                volume_modifier = 0.5
                intensity_modifier = 0.8
                adjustment_note = "CRITICAL STATE: High Injury Risk. Volume reduced 50%, Intensity reduced 20%."
            elif acwr >= 1.35 or readiness < 60:
                volume_modifier = 0.8
                intensity_modifier = 0.9
                adjustment_note = "SUBOPTIMAL STATE: Fatigue accumulating. Volume reduced 20%, Intensity reduced 10%."
        ex_query = session.execute(text("""
            SELECT exercise_name, base_sets, base_reps, base_intensity_pct_1rm, base_rpe_target, rest_seconds, tempo
            FROM exercise_prescriptions WHERE session_id = :sid ORDER BY exercise_order
        """), {"sid": workout[0]})
        exercises = []
        for ex in ex_query.fetchall():
            adjusted_sets = max(1, round(ex[1] * volume_modifier))
            adjusted_pct = round((ex[3] or 0) * intensity_modifier, 1) if ex[3] else None
            exercises.append({
                "exercise": ex[0],
                "sets": adjusted_sets,
                "reps": ex[2],
                "intensity_pct": adjusted_pct,
                "rpe": ex[4],
                "rest": ex[5],
                "tempo": ex[6],
                "original_sets": ex[1],
                "original_intensity": ex[3]
            })
        return {
            "user_id": user_id,
            "date": today_str,
            "session_type": workout[1],
            "target_adaptation": workout[2],
            "readiness_score": readiness,
            "acwr": round(acwr, 2),
            "adjustment_applied": adjustment_note,
            "exercises": exercises
        }
    finally:
        session.close()


@app.get("/api/program/athlete/{user_id}")
async def get_athlete_programs(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(
            text("SELECT * FROM training_programs WHERE user_id = :uid ORDER BY start_date DESC"),
            {"uid": user_id}
        )
        rows = result.fetchall()
        programs = []
        for row in rows:
            programs.append({
                "id": row[0], "user_id": row[1], "program_name": row[2],
                "periodization_model": row[3], "start_date": str(row[4]),
                "end_date": str(row[5]), "created_by": row[6]
            })
        return {"programs": programs, "count": len(programs)}
    finally:
        session.close()

@app.get("/api/program/exercise-library")
async def get_exercise_library(category: str = Query(None)):
    from tasks import get_session
    session = get_session()
    try:
        if category:
            result = session.execute(
                text("SELECT * FROM exercise_library WHERE category = :cat ORDER BY name"),
                {"cat": category}
            )
        else:
            result = session.execute(
                text("SELECT * FROM exercise_library ORDER BY category, name")
            )
        rows = result.fetchall()
        exercises = []
        for row in rows:
            exercises.append({
                "id": row[0], "name": row[1], "category": row[2],
                "subcategory": row[3], "primary_muscle": row[4],
                "equipment": row[5], "difficulty": row[6],
                "contraindications": row[7], "description": row[8],
                "coaching_cues": row[9]
            })
        return {"exercises": exercises, "count": len(exercises)}
    finally:
        session.close()   

@app.post("/api/biomarkers/record")
async def record_blood_biomarkers(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        now_iso = datetime.now(timezone.utc).isoformat()
        session.execute(text("""
            INSERT INTO blood_biomarkers
            (user_id, test_date, ferritin_ng_ml, haemoglobin_g_dl, vitamin_d_ng_ml, testosterone_ng_dl, cortisol_ug_dl, creatine_kinase_u_l, crp_mg_l, created_at)
            VALUES (:uid, :date, :ferritin, :hb, :vitd, :testo, :cortisol, :ck, :crp, :now)
        """), {
            "uid": payload.get("user_id"),
            "date": payload.get("test_date"),
            "ferritin": payload.get("ferritin_ng_ml"),
            "hb": payload.get("haemoglobin_g_dl"),
            "vitd": payload.get("vitamin_d_ng_ml"),
            "testo": payload.get("testosterone_ng_dl"),
            "cortisol": payload.get("cortisol_ug_dl"),
            "ck": payload.get("creatine_kinase_u_l"),
            "crp": payload.get("crp_mg_l"),
            "now": now_iso
        })
        session.commit()
        return {"status": "success", "message": "Biomarker panel logged securely."}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/biomarkers/clinical-panel/{user_id}")
async def get_clinical_biomarker_panel(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT test_date, ferritin_ng_ml, haemoglobin_g_dl, vitamin_d_ng_ml,
                   testosterone_ng_dl, cortisol_ug_dl, creatine_kinase_u_l, crp_mg_l
            FROM blood_biomarkers WHERE user_id = :uid ORDER BY test_date DESC LIMIT 2
        """), {"uid": user_id})
        rows = result.fetchall()
        if not rows:
            return {"status": "NO_DATA", "message": "No biomarker data on file."}
        latest = rows[0]
        flags = []
        ferritin = latest[1]
        hb = latest[2]
        if ferritin is not None and ferritin < 30:
            if hb is not None and hb < 12.0:
                flags.append("CRITICAL: Iron Deficiency Anemia. Immediate medical referral for supplementation.")
            else:
                flags.append("WARNING: Depleted Iron Stores (Ferritin < 30). Non-anemic iron deficiency. Increase dietary intake.")
        vit_d = latest[3]
        if vit_d is not None and vit_d < 30:
            flags.append("WARNING: Vitamin D Insufficiency. Increases bone stress injury risk. Supplementation recommended.")
        testo = latest[4]
        cortisol = latest[5]
        if testo is not None and cortisol is not None and cortisol > 0:
            tc_ratio = testo / cortisol
            if len(rows) > 1:
                prev_tc = rows[1][4] / rows[1][5] if (rows[1][4] and rows[1][5] and rows[1][5] > 0) else None
                if prev_tc and tc_ratio < (prev_tc * 0.70):
                    flags.append("CRITICAL: T/C Ratio dropped >30%. Biochemical confirmation of Non-Functional Overreaching (NFOR).")
        ck = latest[6]
        if ck is not None:
            if ck > 10000:
                flags.append("MEDICAL EMERGENCY: CK > 10,000 U/L. Exertional Rhabdomyolysis suspected. Send to ER.")
            elif ck > 2500:
                flags.append("WARNING: Severe muscular damage (CK > 2500). Impaired clearance. 48-72h passive recovery mandated.")
        return {
            "user_id": user_id,
            "latest_test_date": str(latest[0]),
            "clinical_flags": flags if flags else ["All markers within athletic normal limits."],
            "reference": "ACSM Nutrition Position Stand (2016); NSCA Essentials of Strength Training (4th Ed)"
        }
    finally:
        session.close()


@app.post("/api/biomechanics/risk-assessment")
async def record_movement_risk(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        lsi = payload.get("limb_symmetry_index_pct")
        less = payload.get("less_score")
        interventions = []
        if lsi is not None and lsi < 90.0:
            interventions.append("LSI < 90%. Return to sport CONTRAINDICATED. Prioritize unilateral eccentric loading.")
        if less is not None and less >= 5:
            interventions.append("LESS Score >= 5 indicates poor jump-landing mechanics. High ACL injury risk. Implement neuromuscular control protocols (FIFA 11+).")
        session.execute(text("""
            INSERT INTO movement_risk_flags
            (user_id, assessment_date, fms_total_score, fms_asymmetry, less_score, limb_symmetry_index_pct, recommended_interventions, created_at)
            VALUES (:uid, :date, :fms, :fms_asym, :less, :lsi, :interventions, :now)
        """), {
            "uid": payload.get("user_id"),
            "date": payload.get("assessment_date"),
            "fms": payload.get("fms_total_score"),
            "fms_asym": 1 if payload.get("fms_asymmetry") else 0,
            "less": less,
            "lsi": lsi,
            "interventions": " | ".join(interventions) if interventions else None,
            "now": datetime.now(timezone.utc).isoformat()
        })
        session.commit()
        return {"status": "success", "interventions": interventions}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.post("/api/environmental/log")
async def log_environmental_data(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        now_iso = datetime.now(timezone.utc).isoformat()
        session.execute(text("""
            INSERT INTO environmental_logs
            (user_id, date, altitude_m, days_at_altitude, aqi, pollen_count, ozone_ppb, heat_acclimation_status, created_at)
            VALUES (:uid, :date, :alt, :days, :aqi, :pollen, :ozone, :heat, :now)
        """), {
            "uid": payload.get("user_id"),
            "date": payload.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "alt": payload.get("altitude_m"),
            "days": payload.get("days_at_altitude"),
            "aqi": payload.get("aqi"),
            "pollen": payload.get("pollen_count"),
            "ozone": payload.get("ozone_ppb"),
            "heat": payload.get("heat_acclimation_status"),
            "now": now_iso
        })
        session.commit()
        return {"status": "success", "message": "Environmental data logged."}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/environmental/altitude-status/{user_id}")
async def get_altitude_acclimatization(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT altitude_m, days_at_altitude FROM environmental_logs
            WHERE user_id = :uid AND altitude_m IS NOT NULL
            ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            return {"status": "NO_DATA", "message": "No altitude data recorded."}
        altitude = row[0]
        days = row[1] or 0
        if altitude < 1500:
            phase = "SEA_LEVEL"
            load_reduction_pct = 0
        elif days < 5:
            phase = "ACUTE_HYPOXIC"
            load_reduction_pct = 30
        elif days < 14:
            phase = "EARLY_ACCLIMATIZATION"
            load_reduction_pct = 20
        elif days < 21:
            phase = "MID_ACCLIMATIZATION"
            load_reduction_pct = 10
        else:
            phase = "FULLY_ACCLIMATED"
            load_reduction_pct = 0
        return {
            "user_id": user_id,
            "altitude_m": altitude,
            "days_at_altitude": days,
            "phase": phase,
            "load_reduction_pct": load_reduction_pct,
            "reference": "Chapman et al. (2014) Altitude Training. ACSM Position Stand."
        }
    finally:
        session.close()


@app.get("/api/environmental/training-modifiers/{user_id}")
async def get_environmental_training_modifiers(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT altitude_m, days_at_altitude, aqi, pollen_count, ozone_ppb, heat_acclimation_status
            FROM environmental_logs
            WHERE user_id = :uid
            ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            return {"status": "NO_DATA", "message": "No environmental data."}
        modifiers = []
        if row[2] and row[2] > 150:
            modifiers.append("HIGH_AQI: Outdoor endurance sessions limited to 30 min. Indoor alternatives recommended.")
        if row[3] and row[3] > 100:
            modifiers.append("HIGH_POLLEN: Respiratory risk elevated. Monitor asthma symptoms. Consider antihistamine pre-training.")
        if row[4] and row[4] > 70:
            modifiers.append("HIGH_OZONE: Lung function may be impaired. Reduce prolonged outdoor aerobic work.")
        if row[5] and row[5] == "NOT_ACCLIMATED":
            modifiers.append("HEAT_STRESS_RISK: Athlete not heat acclimated. Limit intensity in WBGT > 25C.")
        return {
            "user_id": user_id,
            "modifiers": modifiers if modifiers else ["No environmental restrictions. Train as planned."],
            "reference": "Rundell (2012) Sports Med. ACSM Environmental Exercise Physiology."
        }
    finally:
        session.close()

@app.post("/api/psychology/assess")
async def record_psychological_assessment(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        now_iso = datetime.now(timezone.utc).isoformat()
        session.execute(text("""
            INSERT INTO psychological_assessments
            (user_id, assessment_date, restq_stress_score, restq_recovery_score, abq_burnout_score,
             csai_cognitive_anxiety, csai_somatic_anxiety, csai_self_confidence, created_at)
            VALUES (:uid, :date, :restq_stress, :restq_rec, :abq, :csai_cog, :csai_som, :csai_conf, :now)
        """), {
            "uid": payload.get("user_id"),
            "date": payload.get("assessment_date"),
            "restq_stress": payload.get("restq_stress_score"),
            "restq_rec": payload.get("restq_recovery_score"),
            "abq": payload.get("abq_burnout_score"),
            "csai_cog": payload.get("csai_cognitive_anxiety"),
            "csai_som": payload.get("csai_somatic_anxiety"),
            "csai_conf": payload.get("csai_self_confidence"),
            "now": now_iso
        })
        session.commit()
        return {"status": "success", "message": "Psychological assessment logged."}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/psychology/clinical-panel/{user_id}")
async def get_psychological_panel(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT assessment_date, restq_stress_score, restq_recovery_score, abq_burnout_score,
                   csai_cognitive_anxiety, csai_somatic_anxiety, csai_self_confidence
            FROM psychological_assessments
            WHERE user_id = :uid ORDER BY assessment_date DESC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            return {"status": "NO_DATA", "message": "No psychological assessment on file."}
        flags = []
        restq_stress = row[1]
        restq_rec = row[2]
        abq = row[3]
        csai_cog = row[4]
        csai_som = row[5]
        csai_conf = row[6]
        if restq_stress is not None and restq_rec is not None:
            balance = restq_rec - restq_stress
            if balance < -10:
                flags.append("CRITICAL: Recovery-Stress balance severely negative. Overtraining syndrome risk elevated. Mandatory rest protocol.")
            elif balance < 0:
                flags.append("WARNING: Recovery-Stress balance negative. Reduce non-training stressors. Prioritize sleep.")
        if abq is not None:
            if abq > 3.0:
                flags.append("CRITICAL: Athlete Burnout Questionnaire score > 3.0. Significant burnout risk. Coach-athlete communication mandatory.")
            elif abq > 2.0:
                flags.append("WARNING: ABQ score > 2.0. Early burnout indicators present. Monitor weekly.")
        if csai_cog is not None and csai_som is not None and csai_conf is not None:
            if csai_cog > 25 or csai_som > 20:
                flags.append("WARNING: Elevated competitive anxiety. Consider sport psychology referral.")
            if csai_conf < 15:
                flags.append("WARNING: Low self-confidence. Pre-competition mental skills intervention recommended.")
        return {
            "user_id": user_id,
            "assessment_date": str(row[0]),
            "clinical_flags": flags if flags else ["Psychological markers within normal range."],
            "reference": "Kellmann & Kallus (2001) RESTQ-Sport. Raedeke & Smith (2001) ABQ. Martens et al. (1990) CSAI-2."
        }
    finally:
        session.close()


@app.get("/api/psychology/trend/{user_id}")
async def get_psychological_trend(user_id: str, months: int = 6):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT assessment_date, restq_stress_score, restq_recovery_score, abq_burnout_score
            FROM psychological_assessments
            WHERE user_id = :uid AND assessment_date >= date('now', '-{} months')
            ORDER BY assessment_date ASC
        """.format(months)), {"uid": user_id})
        rows = result.fetchall()
        if not rows:
            return {"status": "NO_DATA", "message": "No psychological trend data."}
        trend_data = []
        for row in rows:
            trend_data.append({
                "date": str(row[0]),
                "restq_stress": row[1],
                "restq_recovery": row[2],
                "abq_burnout": row[3]
            })
        return {
            "user_id": user_id,
            "assessments": len(rows),
            "trend": trend_data,
            "reference": "Kellmann & Kallus (2001) RESTQ-Sport. Raedeke & Smith (2001) ABQ."
        }
    finally:
        session.close()

@app.post("/api/nutrition/periodize")
async def create_nutrition_periodization(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        now_iso = datetime.now(timezone.utc).isoformat()
        session.execute(text("""
            INSERT INTO nutrition_periodization
            (program_id, mesocycle_number, phase_goal, cho_g_per_kg_target, pro_g_per_kg_target, fat_g_per_kg_target, supplement_protocol, hydration_protocol, created_at)
            VALUES (:pid, :meso, :goal, :cho, :pro, :fat, :supp, :hyd, :now)
        """), {
            "pid": payload.get("program_id"),
            "meso": payload.get("mesocycle_number"),
            "goal": payload.get("phase_goal"),
            "cho": payload.get("cho_g_per_kg_target"),
            "pro": payload.get("pro_g_per_kg_target"),
            "fat": payload.get("fat_g_per_kg_target"),
            "supp": payload.get("supplement_protocol"),
            "hyd": payload.get("hydration_protocol"),
            "now": now_iso
        })
        session.commit()
        return {"status": "success", "message": "Nutrition periodization logged."}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/nutrition/current-targets/{user_id}")
async def get_current_nutrition_targets(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT tp.program_name, np.mesocycle_number, np.phase_goal,
                   np.cho_g_per_kg_target, np.pro_g_per_kg_target, np.fat_g_per_kg_target,
                   np.supplement_protocol, np.hydration_protocol
            FROM nutrition_periodization np
            JOIN training_programs tp ON np.program_id = tp.id
            WHERE tp.user_id = :uid AND tp.start_date <= date('now') AND tp.end_date >= date('now')
            ORDER BY np.mesocycle_number ASC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            return {"status": "NO_DATA", "message": "No active nutrition periodization found."}
        return {
            "user_id": user_id,
            "program": row[0],
            "mesocycle": row[1],
            "phase_goal": row[2],
            "cho_g_per_kg": row[3],
            "pro_g_per_kg": row[4],
            "fat_g_per_kg": row[5],
            "supplement_protocol": row[6],
            "hydration_protocol": row[7],
            "reference": "Jeukendrup (2017) Periodized Nutrition. Impey et al. (2018) Carbohydrate Periodization. Schoenfeld et al. (2013) Protein Timing."
        }
    finally:
        session.close()


@app.post("/api/nutrition/auto-generate-targets")
async def auto_generate_nutrition_targets(payload: dict):
    program_id = payload.get("program_id")
    phase_goal = payload.get("phase_goal", "").lower()
    body_mass_kg = float(payload.get("body_mass_kg", 70))

    targets = {"cho_g_per_kg": 5.0, "pro_g_per_kg": 1.6, "fat_g_per_kg": 1.0,
               "supplement_protocol": "Vitamin D 2000 IU daily. Consider food-first approach.",
               "hydration_protocol": "2.5-3.0 L total water daily. 400-600 mL per hour during training."}

    if phase_goal in ("hypertrophy", "strength_development", "max_strength"):
        targets["pro_g_per_kg"] = 1.8
        targets["fat_g_per_kg"] = 1.2
        targets["supplement_protocol"] = "Creatine monohydrate 5g daily. Vitamin D 2000 IU. Whey protein as needed to meet protein target."
    elif phase_goal in ("endurance_base", "aerobic_capacity", "vo2max"):
        targets["cho_g_per_kg"] = 7.0
        targets["pro_g_per_kg"] = 1.4
        targets["hydration_protocol"] = "3.0-4.0 L total water daily. 500-750 mL per hour during training. Add electrolytes for sessions >90 min."
    elif phase_goal == "endurance_peaking":
        targets["cho_g_per_kg"] = 8.0
        targets["pro_g_per_kg"] = 1.6
        targets["fat_g_per_kg"] = 0.8
        targets["supplement_protocol"] = "Caffeine 3-6 mg/kg pre-competition. Beetroot juice/Nitrates. Taper fiber intake 24h prior."
    elif phase_goal == "strength_peaking":
        targets["cho_g_per_kg"] = 4.0
        targets["pro_g_per_kg"] = 2.0
        targets["fat_g_per_kg"] = 1.0
        targets["supplement_protocol"] = "Caffeine 3-6 mg/kg pre-competition. Maintain creatine if previously loaded."
    elif phase_goal in ("weight_cut", "calorie_deficit", "fat_loss"):
        targets["cho_g_per_kg"] = 3.0
        targets["pro_g_per_kg"] = 2.2
        targets["fat_g_per_kg"] = 0.8
        targets["supplement_protocol"] = "Whey protein isolate to preserve FFM. Omega-3 3g EPA+DHA. Monitor iron status."
        targets["hydration_protocol"] = "2.5-3.0 L total water daily. Avoid dehydration during active weight cut."

    return {
        "program_id": program_id,
        "phase_goal": phase_goal,
        "body_mass_kg": body_mass_kg,
        "targets": targets,
        "reference": "Jeukendrup (2017) Sports Med. ACSM Position Stand (2016). Schoenfeld et al. (2013) JISSN."
    }


@app.post("/api/sleep/architecture")
async def record_sleep_architecture(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        now_iso = datetime.now(timezone.utc).isoformat()
        session.execute(text("""
            INSERT INTO sleep_architecture
            (user_id, date, total_sleep_min, deep_sleep_min, rem_sleep_min, sleep_efficiency_pct,
             sleep_onset_latency_min, wake_after_sleep_onset_min, resting_hr_avg, hrv_rmssd, created_at)
            VALUES (:uid, :date, :total, :deep, :rem, :eff, :lat, :waso, :hr, :hrv, :now)
        """), {
            "uid": payload.get("user_id"),
            "date": payload.get("date"),
            "total": payload.get("total_sleep_min"),
            "deep": payload.get("deep_sleep_min"),
            "rem": payload.get("rem_sleep_min"),
            "eff": payload.get("sleep_efficiency_pct"),
            "lat": payload.get("sleep_onset_latency_min"),
            "waso": payload.get("wake_after_sleep_onset_min"),
            "hr": payload.get("resting_hr_avg"),
            "hrv": payload.get("hrv_rmssd"),
            "now": now_iso
        })
        session.commit()
        return {"status": "success", "message": "Sleep architecture logged."}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/sleep/recovery-index/{user_id}")
async def get_sleep_recovery_index(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, total_sleep_min, deep_sleep_min, rem_sleep_min, sleep_efficiency_pct,
                   sleep_onset_latency_min, wake_after_sleep_onset_min, resting_hr_avg, hrv_rmssd
            FROM sleep_architecture
            WHERE user_id = :uid ORDER BY date DESC LIMIT 7
        """), {"uid": user_id})
        rows = result.fetchall()
        if not rows:
            return {"status": "NO_DATA", "message": "No sleep architecture data."}
        latest = rows[0]
        flags = []
        total_sleep = latest[1]
        hrv = latest[8]
        resting_hr = latest[7]
        sleep_eff = latest[4]
        if total_sleep is not None and total_sleep < 360:
            flags.append(f"WARNING: Total sleep < 6 hours ({total_sleep} min). Cognitive and physical recovery severely compromised. Prioritize sleep extension.")
        if hrv is not None:
            recent_hrv = [r[8] for r in rows[:7] if r[8] is not None]
            if len(recent_hrv) >= 5:
                baseline_hrv = sum(recent_hrv) / len(recent_hrv)
                if hrv < (baseline_hrv * 0.80):
                    flags.append("CRITICAL: HRV RMSSD dropped >20% from 7-day baseline. Autonomic recovery severely compromised. Mandatory rest/low-intensity day.")
        if resting_hr is not None:
            recent_hr = [r[7] for r in rows[:7] if r[7] is not None]
            if len(recent_hr) >= 5:
                baseline_hr = sum(recent_hr) / len(recent_hr)
                if resting_hr > (baseline_hr * 1.10):
                    flags.append("WARNING: Resting HR elevated >10% above baseline. Sympathetic overactivation. Reduce training intensity.")
        if sleep_eff is not None and sleep_eff < 85:
            flags.append("WARNING: Sleep efficiency < 85%. Fragmented sleep reduces recovery quality. Evaluate sleep hygiene and pre-bed routine.")
        return {
            "user_id": user_id,
            "latest_date": str(latest[0]),
            "total_sleep_min": total_sleep,
            "hrv_rmssd": hrv,
            "resting_hr": resting_hr,
            "sleep_efficiency_pct": sleep_eff,
            "clinical_flags": flags if flags else ["Sleep metrics within recovery norms."],
            "reference": "Watson et al. (2017) Sleep Health. NSCA Essentials of Sport Science."
        }
    finally:
        session.close()


@app.get("/api/sleep/trend/{user_id}")
async def get_sleep_trend(user_id: str, days: int = 30):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, total_sleep_min, deep_sleep_min, rem_sleep_min, sleep_efficiency_pct, hrv_rmssd
            FROM sleep_architecture
            WHERE user_id = :uid ORDER BY date DESC LIMIT :days
        """), {"uid": user_id, "days": days})
        rows = result.fetchall()
        if not rows:
            return {"status": "NO_DATA", "message": "No sleep trend data."}
        trend_data = []
        for row in reversed(rows):
            trend_data.append({
                "date": str(row[0]),
                "total_sleep_min": row[1],
                "deep_sleep_min": row[2],
                "rem_sleep_min": row[3],
                "sleep_efficiency_pct": row[4],
                "hrv_rmssd": row[5]
            })
        return {"user_id": user_id, "assessments": len(rows), "trend": trend_data}
    finally:
        session.close()

@app.post("/api/para/classification")
async def set_para_classification(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            INSERT INTO para_classifications (user_id, ipc_class, sport_class, assistive_device, safety_protocol_required, updated_at)
            VALUES (:uid, :ipc, :sport, :device, :safety, :now)
            ON CONFLICT (user_id) DO UPDATE SET
                ipc_class = EXCLUDED.ipc_class,
                sport_class = EXCLUDED.sport_class,
                assistive_device = EXCLUDED.assistive_device,
                safety_protocol_required = EXCLUDED.safety_protocol_required,
                updated_at = EXCLUDED.updated_at
        """), {
            "uid": payload.get("user_id"),
            "ipc": payload.get("ipc_class"),
            "sport": payload.get("sport_class"),
            "device": payload.get("assistive_device"),
            "safety": payload.get("safety_protocol_required", False),
            "now": datetime.now(timezone.utc).isoformat()
        })
        session.commit()
        return {"status": "updated", "user_id": payload.get("user_id")}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.get("/api/para/classification/{user_id}")
async def get_para_classification(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT ipc_class, sport_class, assistive_device, safety_protocol_required
            FROM para_classifications WHERE user_id = :uid
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            return {"status": "NOT_CLASSIFIED", "message": "No para classification on file."}
        return {
            "user_id": user_id,
            "ipc_class": row[0],
            "sport_class": row[1],
            "assistive_device": row[2],
            "safety_protocol_required": bool(row[3]),
            "reference": "IPC Athlete Classification Code (2024). Tweedy et al. (2024) IPC Classification."
        }
    finally:
        session.close()

@app.post("/api/health/metrics")
async def record_health_metrics(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        now_iso = datetime.now(timezone.utc).isoformat()
        session.execute(text("""
            INSERT INTO health_metrics
            (user_id, date, systolic_bp, diastolic_bp, resting_hr, waist_circumference_cm, body_mass_kg, height_cm, bmi, physical_activity_min_week, created_at)
            VALUES (:uid, :date, :sbp, :dbp, :hr, :waist, :bm, :ht, :bmi, :pa, :now)
        """), {
            "uid": payload.get("user_id"),
            "date": payload.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "sbp": payload.get("systolic_bp"),
            "dbp": payload.get("diastolic_bp"),
            "hr": payload.get("resting_hr"),
            "waist": payload.get("waist_circumference_cm"),
            "bm": payload.get("body_mass_kg"),
            "ht": payload.get("height_cm"),
            "bmi": round(float(payload.get("body_mass_kg", 0)) / ((float(payload.get("height_cm", 170)) / 100) ** 2), 1) if payload.get("body_mass_kg") and payload.get("height_cm") else None,
            "pa": payload.get("physical_activity_min_week"),
            "now": now_iso
        })
        session.commit()
        return {"status": "success", "message": "Health metrics logged."}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/health/metrics/{user_id}")
async def get_health_metrics(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, systolic_bp, diastolic_bp, resting_hr, waist_circumference_cm, body_mass_kg, height_cm, bmi, physical_activity_min_week
            FROM health_metrics WHERE user_id = :uid ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            return {"status": "NO_DATA", "message": "No health metrics on file."}
        flags = []
        sbp = row[1]
        dbp = row[2]
        bmi = row[6]
        pa = row[7]
        if sbp and sbp >= 140:
            flags.append("WARNING: Systolic BP >= 140 mmHg. Hypertension Stage 2. Medical referral recommended.")
        elif sbp and sbp >= 130:
            flags.append("CAUTION: Systolic BP >= 130 mmHg. Hypertension Stage 1. Monitor regularly.")
        if dbp and dbp >= 90:
            flags.append("WARNING: Diastolic BP >= 90 mmHg. Hypertension. Medical referral recommended.")
        if bmi and bmi >= 30:
            flags.append("BMI >= 30 kg/m2. Obesity Class I. Weight management support recommended.")
        if pa and pa < 150:
            flags.append(f"Physical activity ({pa} min/week) below ACSM minimum of 150 min/week.")
        return {
            "user_id": user_id,
            "latest_date": str(row[0]),
            "systolic_bp": sbp,
            "diastolic_bp": dbp,
            "resting_hr": row[2],
            "waist_cm": row[3],
            "body_mass_kg": row[4],
            "height_cm": row[5],
            "bmi": bmi,
            "physical_activity_min_week": pa,
            "clinical_flags": flags if flags else ["All health metrics within normal limits."],
            "reference": "ACSM Guidelines for Exercise Testing and Prescription, 11th Ed (2024)."
        }
    finally:
        session.close()

@app.post("/api/dexa/record")
async def record_dexa_scan(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        now_iso = datetime.now(timezone.utc).isoformat()
        session.execute(text("""
            INSERT INTO dexa_scans
            (user_id, scan_date, total_body_mass_kg, ffm_kg, fm_kg, body_fat_pct, bmd_total_body_g_cm2, bmd_lumbar_spine_g_cm2, bmd_hip_g_cm2, vat_kg, created_at)
            VALUES (:uid, :date, :tbm, :ffm, :fm, :bfp, :bmd_total, :bmd_ls, :bmd_hip, :vat, :now)
        """), {
            "uid": payload.get("user_id"),
            "date": payload.get("scan_date"),
            "tbm": payload.get("total_body_mass_kg"),
            "ffm": payload.get("ffm_kg"),
            "fm": payload.get("fm_kg"),
            "bfp": payload.get("body_fat_pct"),
            "bmd_total": payload.get("bmd_total_body_g_cm2"),
            "bmd_ls": payload.get("bmd_lumbar_spine_g_cm2"),
            "bmd_hip": payload.get("bmd_hip_g_cm2"),
            "vat": payload.get("vat_kg"),
            "now": now_iso
        })
        session.commit()
        return {"status": "success", "message": "DEXA scan logged."}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/dexa/latest/{user_id}")
async def get_latest_dexa(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT scan_date, total_body_mass_kg, ffm_kg, fm_kg, body_fat_pct, bmd_total_body_g_cm2, bmd_lumbar_spine_g_cm2, bmd_hip_g_cm2, vat_kg
            FROM dexa_scans WHERE user_id = :uid ORDER BY scan_date DESC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        if not row:
            return {"status": "NO_DATA", "message": "No DEXA scan on file."}
        flags = []
        bmd_total = row[5]
        bmd_ls = row[6]
        bmd_hip = row[7]
        if bmd_total and bmd_total < 1.0:
            flags.append("WARNING: Total body BMD below 1.0 g/cm2. Osteopenia suspected. Clinical correlation required.")
        if bmd_ls and bmd_ls < 0.9:
            flags.append("WARNING: Lumbar spine BMD below 0.9 g/cm2. Vertebral fracture risk elevated.")
        if bmd_hip and bmd_hip < 0.8:
            flags.append("WARNING: Hip BMD below 0.8 g/cm2. Hip fracture risk elevated.")
        return {
            "user_id": user_id,
            "scan_date": str(row[0]),
            "total_body_mass_kg": row[1],
            "ffm_kg": row[2],
            "fm_kg": row[3],
            "body_fat_pct": row[4],
            "bmd_total_body_g_cm2": bmd_total,
            "bmd_lumbar_spine_g_cm2": bmd_ls,
            "bmd_hip_g_cm2": bmd_hip,
            "vat_kg": row[8],
            "clinical_flags": flags if flags else ["Bone mineral density within normal limits."],
            "reference": "ISCD Official Positions (2019). ACSM Bone Health Position Stand."
        }
    finally:
        session.close()

@app.post("/api/clinical/notes")
async def record_clinical_note(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        now_iso = datetime.now(timezone.utc).isoformat()
        session.execute(text("""
            INSERT INTO clinical_notes (user_id, note_date, author, note_type, content, created_at)
            VALUES (:uid, :date, :author, :ntype, :content, :now)
        """), {
            "uid": payload.get("user_id"),
            "date": payload.get("note_date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "author": payload.get("author", "clinician"),
            "ntype": payload.get("note_type", "general"),
            "content": payload.get("content"),
            "now": now_iso
        })
        session.commit()
        return {"status": "success", "message": "Clinical note recorded."}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.get("/api/clinical/notes/{user_id}")
async def get_clinical_notes(user_id: str, limit: int = 20):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT note_date, author, note_type, content FROM clinical_notes
            WHERE user_id = :uid ORDER BY note_date DESC LIMIT :lim
        """), {"uid": user_id, "lim": limit})
        rows = result.fetchall()
        notes = [{"date": str(r[0]), "author": r[1], "type": r[2], "content": r[3]} for r in rows]
        return {"user_id": user_id, "notes": notes, "count": len(notes)}
    finally:
        session.close()

@app.post("/api/athlete/population-type")
async def set_population_type(payload: dict):
    from tasks import get_session
    session = get_session()
    try:
        session.execute(text("""
            UPDATE daily_checkins SET population_type = :ptype
            WHERE user_id = :uid AND date = (SELECT MAX(date) FROM daily_checkins WHERE user_id = :uid)
        """), {"uid": payload.get("user_id"), "ptype": payload.get("population_type", "athlete")})
        session.commit()
        return {"status": "updated", "user_id": payload.get("user_id"), "population_type": payload.get("population_type")}
    except Exception as e:
        session.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()


@app.get("/api/athlete/population-type/{user_id}")
async def get_population_type(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT COALESCE(population_type, 'athlete') FROM daily_checkins
            WHERE user_id = :uid ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        row = result.fetchone()
        ptype = row[0] if row else "athlete"
        recommendations = {}
        if ptype == "general_population":
            recommendations = {
                "activity_target": "150 minutes moderate aerobic activity per week (ACSM 2024)",
                "strength_target": "2 sessions per week, 8-12 reps, major muscle groups",
                "screening": "PAR-Q+ required. Physician clearance if score >1.",
                "monitoring": "Focus on adherence and enjoyment, not performance metrics.",
                "reference": "ACSM Guidelines for Exercise Testing and Prescription, 11th Ed (2024)"
            }
        else:
            recommendations = {
                "activity_target": "Periodized training based on sport-specific demands",
                "strength_target": "NSCA load-repetition guidelines applied",
                "screening": "PAR-Q+ plus sport-specific pre-participation screening",
                "monitoring": "ACWR, readiness, monotony, and performance metrics active.",
                "reference": "NSCA Essentials of Strength Training, 4th Ed."
            }
        return {"user_id": user_id, "population_type": ptype, "recommendations": recommendations}
    finally:
        session.close()

@app.get("/api/dashboard/periodic-table")
async def get_periodic_table_dashboard():
    """Returns a color-coded squad overview in periodic-table style grid format."""
    from tasks import get_session, _calculate_readiness
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT dc.user_id, dc.gender, dc.daily_load, dc.sleep_hours, dc.sleep_quality,
                   dc.stress, dc.fatigue, dc.muscle_soreness, dc.cycle_phase, dc.calories,
                   dc.ffm, dc.injury_location, dc.pain_level, dc.mood,
                   COALESCE(reds.training_paused, 0) as training_paused
            FROM daily_checkins dc
            LEFT JOIN reds_medical_referrals reds ON dc.user_id = reds.user_id AND reds.physician_cleared = 0
            WHERE (dc.user_id, dc.date) IN (
                SELECT user_id, MAX(date) FROM daily_checkins GROUP BY user_id
            )
            ORDER BY dc.user_id
        """))
        rows = result.fetchall()
        
        elements = []
        for row in rows:
            readiness = _calculate_readiness(
                row[4] or 4, row[5] or 3, row[6] or 3,
                row[7] or 2, float(row[3] or 7)
            )
            paused = bool(row[14])
            
            if paused:
                color = "#ff2244"
                symbol = "⛔"
                zone = "PAUSED"
            elif readiness >= 75:
                color = "#00ff88"
                symbol = "●"
                zone = "OPTIMAL"
            elif readiness >= 50:
                color = "#ffaa00"
                symbol = "◐"
                zone = "CAUTION"
            elif readiness >= 30:
                color = "#ff6622"
                symbol = "◑"
                zone = "WARNING"
            else:
                color = "#ff2244"
                symbol = "○"
                zone = "CRITICAL"
            
            elements.append({
                "id": row[0],
                "symbol": symbol,
                "readiness": readiness,
                "color": color,
                "zone": zone,
                "gender": row[1] or "?",
                "load": float(row[2] or 0),
                "cycle_phase": row[8] or "",
                "injury": bool(row[11] and str(row[11]).strip()),
                "paused": paused
            })
        
        return {
            "elements": elements,
            "total": len(elements),
            "summary": {
                "optimal": sum(1 for e in elements if e["zone"] == "OPTIMAL"),
                "caution": sum(1 for e in elements if e["zone"] == "CAUTION"),
                "warning": sum(1 for e in elements if e["zone"] == "WARNING"),
                "critical": sum(1 for e in elements if e["zone"] == "CRITICAL"),
                "paused": sum(1 for e in elements if e["zone"] == "PAUSED")
            },
            "generated_at": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()

@app.get("/api/competition/readiness/{user_id}")
async def get_competition_readiness(user_id: str, competition_date: str = Query(...)):
    from tasks import get_session, _calculate_readiness, get_hormonal_status
    session = get_session()
    try:
        today = date.today()
        comp_date = date.fromisoformat(competition_date)
        days_to_competition = (comp_date - today).days

        readiness_result = session.execute(text("""
            SELECT sleep_quality, stress, fatigue, muscle_soreness, sleep_hours, mood, daily_load, gender, cycle_phase, calories, ffm, exercise_type, duration_minutes
            FROM daily_checkins WHERE user_id = :uid ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        row = readiness_result.fetchone()
        if not row:
            return {"status": "NO_DATA", "message": "No current readiness data available."}

        sleep_quality = row[0] or 4
        stress_val = row[1] or 3
        fatigue_val = row[2] or 3
        soreness_val = row[3] or 2
        sleep_hours = float(row[4] or 7)
        mood = row[5] or "neutral"
        daily_load = float(row[6] or 0)
        gender = row[7] or "Male"
        cycle_phase = row[8] or ""
        calories = float(row[9] or 0)
        ffm = float(row[10] or 0)
        exercise_type = row[11] or ""
        duration_minutes = float(row[12] or 60)

        readiness_score = _calculate_readiness(sleep_quality, stress_val, fatigue_val, soreness_val, sleep_hours)

        acwr = 1.0
        loads_result = session.execute(text("""
            SELECT daily_load FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC LIMIT 42
        """), {"uid": user_id})
        loads = [float(r[0] or 0) for r in loads_result.fetchall()]

        hormonal_status = get_hormonal_status(user_id)
        if hormonal_status in ("NOT_FEMALE", "UNKNOWN_PHASE"):
            hormonal_status = cycle_phase

        if len(loads) >= 42:
            acwr_data = await get_validated_acwr(loads, gender, hormonal_status)
            acwr = acwr_data.get("acwr", 1.0)

        ea = None
        if ffm > 0 and calories > 0:
            ea_result = await get_validated_energy_availability(
                calories=calories, daily_load=daily_load, ffm=ffm,
                exercise_type=exercise_type, duration_minutes=duration_minutes,
                gender=gender, cycle_phase=hormonal_status
            )
            if ea_result and ea_result.get("ea_value") is not None:
                ea = float(ea_result["ea_value"])

        hrv = None
        hrv_result = session.execute(text("""
            SELECT hrv_rmssd FROM sleep_architecture WHERE user_id = :uid ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        hrv_row = hrv_result.fetchone()
        if hrv_row and hrv_row[0]:
            hrv = float(hrv_row[0])

        biomarker_result = session.execute(text("""
            SELECT creatine_kinase_u_l, ferritin_ng_ml, testosterone_ng_dl, cortisol_ug_dl
            FROM blood_biomarkers WHERE user_id = :uid ORDER BY test_date DESC LIMIT 1
        """), {"uid": user_id})
        bio_row = biomarker_result.fetchone()
        ck = float(bio_row[0]) if bio_row and bio_row[0] else None
        ferritin = float(bio_row[1]) if bio_row and bio_row[1] else None

        psych_result = session.execute(text("""
            SELECT csai_cognitive_anxiety, csai_somatic_anxiety, csai_self_confidence
            FROM psychological_assessments WHERE user_id = :uid ORDER BY assessment_date DESC LIMIT 1
        """), {"uid": user_id})
        psych_row = psych_result.fetchone()
        csai_cog = psych_row[0] if psych_row else None
        csai_som = psych_row[1] if psych_row else None
        csai_conf = psych_row[2] if psych_row else None

        env_result = session.execute(text("""
            SELECT altitude_m, days_at_altitude, heat_acclimation_status
            FROM environmental_logs WHERE user_id = :uid ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        env_row = env_result.fetchone()
        altitude = env_row[0] if env_row else None
        days_altitude = env_row[1] if env_row else 0
        heat_status = env_row[2] if env_row else None

        physical_score = readiness_score
        if acwr >= 1.5:
            physical_score -= 25
        elif acwr >= 1.35:
            physical_score -= 15
        elif acwr < 0.8:
            physical_score -= 15
        if ck and ck > 2500:
            physical_score -= 20
        if hrv and hrv < 30:
            physical_score -= 10
        if sleep_hours < 6:
            physical_score -= 10
        physical_score = max(0, min(100, physical_score))

        nutritional_score = 70
        if ea is not None:
            if ea >= 45:
                nutritional_score = 95
            elif ea >= 30:
                nutritional_score = 75
            else:
                nutritional_score = 40
        if ferritin and ferritin < 30:
            nutritional_score -= 20
        nutritional_score = max(0, min(100, nutritional_score))

        psychological_score = 75
        if csai_cog and csai_cog > 25:
            psychological_score -= 20
        if csai_som and csai_som > 20:
            psychological_score -= 15
        if csai_conf and csai_conf < 15:
            psychological_score -= 15
        if mood and mood.lower() in ("anxious", "depressed", "irritable"):
            psychological_score -= 10
        psychological_score = max(0, min(100, psychological_score))

        environmental_score = 85
        if altitude and altitude > 2500 and days_altitude and days_altitude < 5:
            environmental_score -= 20
        if heat_status and heat_status == "NOT_ACCLIMATED":
            environmental_score -= 15
        environmental_score = max(0, min(100, environmental_score))

        final_score = round((physical_score * 0.35) + (nutritional_score * 0.25) + (psychological_score * 0.25) + (environmental_score * 0.15))

        if final_score >= 85:
            recommendation = "CLEARED: Optimal competition readiness across all domains."
        elif final_score >= 70:
            recommendation = "CAUTION: Proceed with competition but address flagged components."
        elif final_score >= 50:
            recommendation = "MODIFIED: Significant concerns. Consider reduced competition load or event withdrawal."
        else:
            recommendation = "WITHDRAWAL RECOMMENDED: Multiple systems indicate elevated risk of underperformance or injury."

        return {
            "user_id": user_id,
            "competition_date": competition_date,
            "days_to_competition": days_to_competition,
            "final_readiness_score": final_score,
            "recommendation": recommendation,
            "components": {
                "physical": {"score": physical_score, "acwr": round(acwr, 2), "readiness": readiness_score, "sleep_hours": sleep_hours, "ck_u_l": ck, "hrv_rmssd": hrv},
                "nutritional": {"score": nutritional_score, "ea_kcal_kg": ea, "ferritin_ng_ml": ferritin},
                "psychological": {"score": psychological_score, "csai_cognitive": csai_cog, "csai_somatic": csai_som, "csai_confidence": csai_conf, "mood": mood},
                "environmental": {"score": environmental_score, "altitude_m": altitude, "heat_status": heat_status}
            },
            "reference": "Pyne et al. (2009) Br J Sports Med. Mujika & Padilla (2003) Sports Med. Mountjoy et al. (2023) BJSM."
        }
    finally:
        session.close()

@app.get("/api/validation/calibrate-acwr/{user_id}")
async def calibrate_acwr_threshold(user_id: str):
    """Find personalized ACWR threshold based on athlete's injury history."""
    from tasks import get_session
    session = get_session()
    try:
        # Get all data with injury flags
        result = session.execute(text("""
            SELECT date, daily_load, injury_location FROM daily_checkins
            WHERE user_id = :uid ORDER BY date ASC
        """), {"uid": user_id})
        rows = result.fetchall()
        
        if len(rows) < 42:
            return {"error": "Need at least 42 days", "available": len(rows)}
        
        loads = [float(r[1] or 0) for r in rows]
        injury_dates = [str(r[0]) for r in rows if r[2] and str(r[2]).strip()]
        
        if len(injury_dates) < 1:
            return {"user_id": user_id, "personalized_threshold": 1.5, "note": "No injury history. Using population threshold 1.5.", "confidence": "LOW"}
        
        # Calculate ACWR at each injury event
        injury_acwr_values = []
        for i in range(28, len(loads)):
            date_str = str(rows[i][0])
            # Check if injury occurred within 7 days after this date
            window_injury = any(
                inj_date > date_str and inj_date <= str(rows[min(i+7, len(rows)-1)][0])
                for inj_date in injury_dates
            ) if i + 7 < len(rows) else False
            
            if window_injury:
                acute = sum(loads[i-6:i+1]) / 7
                chronic = sum(loads[i-27:i+1]) / 28
                acwr = round(acute / chronic, 3) if chronic > 0 else 1.0
                injury_acwr_values.append(acwr)
        
        if len(injury_acwr_values) < 1:
            return {"user_id": user_id, "personalized_threshold": 1.5, "note": "Could not calculate pre-injury ACWR. Using population threshold.", "confidence": "LOW"}
        
        # Set personalized threshold at 90% of minimum pre-injury ACWR
        min_injury_acwr = min(injury_acwr_values)
        personalized_threshold = round(min_injury_acwr * 0.90, 2)
        
        # Calculate current ACWR
        current_acute = sum(loads[-7:]) / 7
        current_chronic = sum(loads[-28:]) / 28
        current_acwr = round(current_acute / current_chronic, 3) if current_chronic > 0 else 1.0
        
        return {
            "user_id": user_id,
            "population_threshold": 1.5,
            "personalized_threshold": personalized_threshold,
            "current_acwr": current_acwr,
            "exceeds_personalized": current_acwr >= personalized_threshold,
            "exceeds_population": current_acwr >= 1.5,
            "pre_injury_acwr_values": injury_acwr_values,
            "injuries_analyzed": len(injury_acwr_values),
            "confidence": "HIGH" if len(injury_acwr_values) >= 3 else "MEDIUM" if len(injury_acwr_values) >= 1 else "LOW",
            "reference": "Blanch & Gabbett (2016). Personalized thresholds improve injury prediction specificity by 22%.",
            "generated_at": datetime.now(timezone.utc).isoformat()
        }
    finally:
        session.close()

@app.get("/api/analytics/career-summary/{user_id}")
async def get_career_summary(user_id: str):
    from tasks import get_session
    session = get_session()
    try:
        stats = session.execute(text("""
            SELECT COUNT(*) as total_sessions,
                   MIN(date) as first_date,
                   MAX(date) as last_date,
                   AVG(daily_load) as avg_load,
                   MAX(daily_load) as max_load,
                   AVG(rpe) as avg_rpe,
                   AVG(sleep_hours) as avg_sleep,
                   AVG(stress) as avg_stress
            FROM daily_checkins WHERE user_id = :uid
        """), {"uid": user_id}).fetchone()

        injury_count = session.execute(text("""
            SELECT COUNT(DISTINCT date) FROM daily_checkins
            WHERE user_id = :uid AND injury_location IS NOT NULL AND injury_location != ''
        """), {"uid": user_id}).scalar()

        reds_events = session.execute(text("""
            SELECT COUNT(*) FROM reds_medical_referrals WHERE user_id = :uid
        """), {"uid": user_id}).scalar()

        peak_load = session.execute(text("""
            SELECT date, daily_load FROM daily_checkins WHERE user_id = :uid ORDER BY daily_load DESC LIMIT 1
        """), {"uid": user_id}).fetchone()

        return {
            "user_id": user_id,
            "total_sessions": stats[0],
            "career_span": f"{stats[1]} to {stats[2]}",
            "avg_daily_load": round(float(stats[3] or 0), 1),
            "max_daily_load": round(float(stats[4] or 0), 1),
            "avg_rpe": round(float(stats[5] or 0), 1),
            "avg_sleep_hours": round(float(stats[6] or 0), 1),
            "avg_stress": round(float(stats[7] or 0), 1),
            "total_injury_events": injury_count or 0,
            "reds_referral_events": reds_events or 0,
            "peak_performance_day": {"date": str(peak_load[0]) if peak_load else None, "load": round(float(peak_load[1] or 0), 1) if peak_load else None},
            "reference": "Gabbett TJ. (2016) Br J Sports Med. Hopkins et al. (2009) Med Sci Sports Exerc."
        }
    finally:
        session.close()


@app.get("/api/analytics/peak-prediction/{user_id}")
async def predict_peak_window(user_id: str, target_date: str = Query(...)):
    from tasks import get_session, _calculate_readiness
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, daily_load, rpe, sleep_hours, sleep_quality, stress, fatigue, muscle_soreness, mood
            FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 42:
            return {"status": "INSUFFICIENT_DATA", "message": "Need at least 42 days of data for peak prediction."}

        weekly_loads = []
        for i in range(0, len(rows) - 6, 7):
            week_data = rows[i:i+7]
            avg_load = sum(float(r[1] or 0) for r in week_data) / 7
            week_readiness_scores = [
                _calculate_readiness(r[4] or 4, r[5] or 3, r[6] or 3, r[7] or 2, float(r[3] or 7))
                for r in week_data
            ]
            avg_readiness = sum(week_readiness_scores) / 7
            weekly_loads.append({"week_start": str(week_data[0][0]), "avg_load": round(avg_load, 1), "avg_readiness": round(avg_readiness, 1)})

        if len(weekly_loads) >= 6:
            recent = weekly_loads[-6:]
            load_trend = recent[-1]["avg_load"] - recent[0]["avg_load"]
            readiness_trend = recent[-1]["avg_readiness"] - recent[0]["avg_readiness"]
            if load_trend < 0 and readiness_trend > 0:
                prediction = "PEAK_WINDOW_OPEN: Load tapering with rising readiness indicates optimal competition window."
            elif load_trend > 0 and readiness_trend < 0:
                prediction = "DECLINE_WINDOW: Increasing load with declining readiness. Avoid competition scheduling."
            else:
                prediction = "MAINTENANCE: Stable load-readiness relationship. Continue monitoring."
        else:
            prediction = "INSUFFICIENT_TREND_DATA"

        return {
            "user_id": user_id,
            "target_date": target_date,
            "prediction": prediction,
            "weekly_trend": weekly_loads[-12:] if len(weekly_loads) > 12 else weekly_loads,
            "reference": "Mujika & Padilla (2003) Sports Med. Pyne et al. (2009) Br J Sports Med."
        }
    finally:
        session.close()

@app.get("/api/analytics/injury-forecast/{user_id}")
async def forecast_injury_risk(user_id: str, days_ahead: int = 30):
    from tasks import get_session, _compute_monotony_strain, get_hormonal_status
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT daily_load, gender, cycle_phase, sleep_hours, sleep_quality, stress, fatigue, muscle_soreness
            FROM daily_checkins WHERE user_id = :uid ORDER BY date ASC LIMIT 90
        """), {"uid": user_id})
        rows = result.fetchall()
        if len(rows) < 42:
            return {"status": "INSUFFICIENT_DATA", "message": "Need at least 42 days for injury forecasting."}

        loads = [float(r[0] or 0) for r in rows]
        gender = rows[-1][1] or "Male"
        cycle_phase = rows[-1][2] or ""
        sleep_hours = float(rows[-1][3] or 7)
        stress_val = rows[-1][5] or 3
        fatigue_val = rows[-1][6] or 3
        soreness_val = rows[-1][7] or 2

        hormonal_status = get_hormonal_status(user_id)
        if hormonal_status in ("NOT_FEMALE", "UNKNOWN_PHASE"):
            hormonal_status = cycle_phase

        acwr_data = await get_validated_acwr(loads[-42:], gender, hormonal_status)
        acwr = acwr_data.get("acwr", 1.0)

        mono_data = _compute_monotony_strain(loads[-7:])
        monotony = mono_data.get("monotony", 0.0)
        monotony_flag = mono_data.get("risk", False)

        chronic_loads = []
        for i in range(28, len(loads)):
            chronic_loads.append(sum(loads[i-28:i]) / 28)

        capacity_ceiling = max(chronic_loads) if chronic_loads else 0
        current_chronic = chronic_loads[-1] if chronic_loads else 0

        risk_factors = 0
        risk_details = []

        if current_chronic < (capacity_ceiling * 0.70):
            risk_factors += 2
            risk_details.append(f"WARNING: Chronic capacity decayed by >30% from season peak. Protective base lost.")

        if acwr >= 1.5:
            risk_factors += 3
            risk_details.append("CRITICAL: ACWR > 1.5 indicates imminent high injury risk.")
        elif acwr >= 1.35:
            risk_factors += 2
            risk_details.append("ELEVATED: ACWR 1.35-1.5 indicates elevated injury risk.")
        elif acwr < 0.8:
            risk_factors += 1
            risk_details.append("CAUTION: ACWR < 0.8 indicates potential undertraining and deconditioning risk.")

        if monotony_flag:
            risk_factors += 2
            risk_details.append(f"HIGH MONOTONY: Training monotony {monotony} > 2.0. Injury risk independent of ACWR.")
        if sleep_hours < 6:
            risk_factors += 2
            risk_details.append("SLEEP DEFICIT: Chronic sleep deprivation increases injury risk 1.7x (Milewski et al., 2014).")
        if stress_val >= 6:
            risk_factors += 1
            risk_details.append("HIGH STRESS: Psychological stress increases injury risk (Ivarsson et al., 2017).")
        if fatigue_val >= 6:
            risk_factors += 1
            risk_details.append("HIGH FATIGUE: Persistent fatigue impairs neuromuscular control.")
        if soreness_val >= 6:
            risk_factors += 1
            risk_details.append("HIGH SORENESS: Incomplete recovery from prior sessions.")

        if risk_factors >= 7:
            risk_level = "CRITICAL"
            probability = ">70%"
        elif risk_factors >= 5:
            risk_level = "HIGH"
            probability = "40-70%"
        elif risk_factors >= 3:
            risk_level = "MODERATE"
            probability = "15-40%"
        else:
            risk_level = "LOW"
            probability = "<15%"

        return {
            "user_id": user_id,
            "forecast_days": days_ahead,
            "risk_level": risk_level,
            "estimated_injury_probability": probability,
            "risk_factors": risk_factors,
            "risk_details": risk_details,
            "acwr": round(acwr, 2),
            "season_chronic_ceiling_au": round(capacity_ceiling, 1),
            "current_chronic_base_au": round(current_chronic, 1),
            "training_monotony": monotony,
            "reference": "Gabbett TJ. (2016) Br J Sports Med. Blanch & Gabbett (2016) Br J Sports Med."
        }
    finally:
        session.close()

@app.get("/api/analytics/season-report/{user_id}")
async def get_season_report(user_id: str, season_start: str = Query(...), season_end: str = Query(...)):
    from tasks import get_session
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT date, daily_load, rpe, sleep_hours, sleep_quality, stress, fatigue, muscle_soreness, injury_location
            FROM daily_checkins WHERE user_id = :uid AND date BETWEEN :start AND :end ORDER BY date ASC
        """), {"uid": user_id, "start": season_start, "end": season_end})
        rows = result.fetchall()
        if not rows:
            return {"status": "NO_DATA", "message": "No data for specified season."}

        total_sessions = len(rows)
        avg_load = sum(float(r[1] or 0) for r in rows) / total_sessions
        avg_rpe = sum(r[2] or 0 for r in rows) / total_sessions
        avg_sleep = sum(float(r[3] or 0) for r in rows) / total_sessions
        avg_stress = sum(r[5] or 0 for r in rows) / total_sessions
        avg_fatigue = sum(r[6] or 0 for r in rows) / total_sessions
        avg_soreness = sum(r[7] or 0 for r in rows) / total_sessions
        injury_days = len([r for r in rows if r[8] and str(r[8]).strip()])

        weekly_breakdown = []
        for i in range(0, len(rows) - 6, 7):
            week = rows[i:i+7]
            week_load = sum(float(r[1] or 0) for r in week)
            week_rpe = sum(r[2] or 0 for r in week) / 7
            weekly_breakdown.append({"week_start": str(week[0][0]), "total_load": round(week_load, 1), "avg_rpe": round(week_rpe, 1)})

        return {
            "user_id": user_id,
            "season": f"{season_start} to {season_end}",
            "total_sessions": total_sessions,
            "averages": {"load": round(avg_load, 1), "rpe": round(avg_rpe, 1), "sleep_hours": round(avg_sleep, 1), "stress": round(avg_stress, 1), "fatigue": round(avg_fatigue, 1), "soreness": round(avg_soreness, 1)},
            "injury_days": injury_days,
            "injury_rate_per_1000_hours": round((injury_days / max(1, total_sessions)) * 1000, 1),
            "weekly_breakdown": weekly_breakdown,
            "reference": "Gabbett TJ. (2016) Br J Sports Med. Hopkins et al. (2009) Med Sci Sports Exerc."
        }
    finally:
        session.close()

@app.get("/api/roster")
async def get_dynamic_roster():
    """
    Scans the database and returns the current roster with triage status 
    based on the latest daily check-ins. Optimized for the search UI.
    """
    from tasks import get_session
    session = get_session()
    try:
        # Fetch the most recent checkin for every athlete
        result = session.execute(text("""
            SELECT user_id, exercise_type, stress, fatigue, daily_load 
            FROM daily_checkins 
            WHERE (user_id, date) IN (
                SELECT user_id, MAX(date) FROM daily_checkins GROUP BY user_id
            )
            ORDER BY user_id ASC
        """))
        
        roster = []
        for row in result.fetchall():
            uid = row[0]
            ex_type = row[1] or "General"
            stress = row[2] or 0
            fatigue = row[3] or 0
            
            # Autonomic Triage Logic for UI Badges
            status_class = "green"
            status_label = "OK"
            if stress >= 6 or fatigue >= 6:
                status_class = "amber"
                status_label = "TIRED"
            
            roster.append({
                "id": uid,
                "name": uid,
                "pos": ex_type,
                "status": status_class,
                "label": status_label
            })
            
        return {"athletes": roster, "count": len(roster)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database error: {str(e)}")
    finally:
        session.close()


@app.get("/api/athlete/{user_id}/dashboard")
async def get_athlete_dashboard_data(user_id: str):
    """
    Fetches the 28-day trailing telemetry and full profile for a specific athlete.
    """
    from tasks import get_session, _calculate_readiness
    session = get_session()
    try:
        # 1. Fetch 28-Day Telemetry for Charts
        telemetry_result = session.execute(text("""
            SELECT date, daily_load, rpe, sleep_hours, sleep_quality, stress, fatigue, muscle_soreness
            FROM daily_checkins 
            WHERE user_id = :uid AND date >= date('now', '-28 days')
            ORDER BY date ASC
        """), {"uid": user_id})
        
        telemetry = []
        for row in telemetry_result.fetchall():
            telemetry.append({
                "date": str(row[0]),
                "daily_load": float(row[1] or 0),
                "rpe": row[2] or 0,
                "sleep_hours": float(row[3] or 0),
                "sleep_quality": row[4] or 0,
                "stress": row[5] or 0,
                "fatigue": row[6] or 0,
                "muscle_soreness": row[7] or 0
            })
            
        # 2. Fetch Latest Profile Stats (for HUD/Vitals)
        profile_result = session.execute(text("""
            SELECT sleep_hours, sleep_quality, stress, fatigue, muscle_soreness, daily_load
            FROM daily_checkins 
            WHERE user_id = :uid ORDER BY date DESC LIMIT 1
        """), {"uid": user_id})
        
        latest = profile_result.fetchone()
        profile_data = {}
        if latest:
            readiness = _calculate_readiness(latest[1] or 4, latest[2] or 3, latest[3] or 3, latest[4] or 2, float(latest[0] or 7))
            profile_data = {
                "wellness": {
                    "readiness_pct": readiness,
                    "sleep_hours": latest[0]
                },
                "performance": {
                    "daily_load": float(latest[5] or 0)
                }
            }

        return {
            "user_id": user_id,
            "profile": profile_data,
            "telemetry_28d": telemetry
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        session.close()

@app.get("/api/system/export-portable")
async def export_portable_backup():
    import zipfile
    import shutil
    from tasks import SQLITE_DB_PATH
    backup_dir = BASE_DIR / "backups"
    backup_dir.mkdir(exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    zip_path = backup_dir / f"athena_portable_{timestamp}.athena-backup"
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
        if SQLITE_DB_PATH.exists():
            zf.write(SQLITE_DB_PATH, "athena.db")
        for f in [".athena_api_key", ".athena_encryption_key", "system_profile.json"]:
            fpath = BASE_DIR / f
            if fpath.exists():
                zf.write(fpath, f)
        zf.writestr("metadata.json", json.dumps({
            "export_date": timestamp,
            "version": "5.0.0",
            "record_count": get_db_record_count(),
            "checksum": hashlib.sha256(open(SQLITE_DB_PATH, 'rb').read()).hexdigest() if SQLITE_DB_PATH.exists() else "N/A"
        }))
    return FileResponse(zip_path, media_type="application/zip", filename=f"athena_portable_{timestamp}.athena-backup")

@app.post("/api/system/import-portable")
async def import_portable_backup(file: UploadFile = File(...)):
    import zipfile
    import shutil
    from tasks import SQLITE_DB_PATH
    if not file.filename or not file.filename.endswith(".athena-backup"):
        raise HTTPException(status_code=400, detail="Invalid file format. Use .athena-backup extension.")
    extract_dir = BASE_DIR / f"import_{uuid.uuid4().hex[:8]}"
    extract_dir.mkdir(exist_ok=True)
    try:
        with zipfile.ZipFile(io.BytesIO(await file.read()), 'r') as zf:
            zf.extractall(extract_dir)
        imported_db = extract_dir / "athena.db"
        if imported_db.exists():
            backup_path = BASE_DIR / "backups" / f"pre_import_backup_{datetime.now().strftime('%Y%m%d_%H%M%S')}.db"
            backup_path.parent.mkdir(exist_ok=True)
            if SQLITE_DB_PATH.exists():
                shutil.copy2(SQLITE_DB_PATH, backup_path)
            shutil.copy2(imported_db, SQLITE_DB_PATH)
        for keyfile in [".athena_api_key", ".athena_encryption_key"]:
            imported_key = extract_dir / keyfile
            if imported_key.exists() and not (BASE_DIR / keyfile).exists():
                shutil.copy2(imported_key, BASE_DIR / keyfile)
        return {"status": "imported", "message": "Portable backup restored successfully. Previous database backed up."}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Import failed: {str(e)}")
    finally:
        shutil.rmtree(extract_dir, ignore_errors=True)

def get_db_record_count():
    try:
        from tasks import get_session
        session = get_session()
        count = session.execute(text("SELECT COUNT(*) FROM daily_checkins")).scalar()
        session.close()
        return count
    except Exception:
        return 0