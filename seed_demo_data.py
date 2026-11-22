#!/usr/bin/env python3
"""
A.T.H.E.N.A. — Synthetic Cohort Data Seeder (Sanitized Demo Generator)
Generates HIPAA-compliant, completely fictitious physiological time-series data
for local demonstration, unit tests, and research simulation.
Zero real athlete PII/PHI is included.
"""

import os
import random
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from sqlalchemy import create_engine, text

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = BASE_DIR / "athena.db"
DATABASE_URL = os.getenv("ATHENA_DATABASE_URL", f"sqlite:///{DB_PATH}")

SYNTHETIC_ATHLETES = [
    {"user_id": "ATH-001", "name": "Elena Rostova", "sport": "Track & Field", "gender": "F", "ffm": 52.4, "phase": "Follicular", "contra": "None"},
    {"user_id": "ATH-002", "name": "Marcus Vance", "sport": "Football", "gender": "M", "ffm": 76.8, "phase": "", "contra": "N/A"},
    {"user_id": "ATH-003", "name": "Chloe Dupont", "sport": "Swimming", "gender": "F", "ffm": 58.2, "phase": "Ovulatory", "contra": "Combined Oral"},
    {"user_id": "ATH-004", "name": "Liam O'Connor", "sport": "Rowing", "gender": "M", "ffm": 82.5, "phase": "", "contra": "N/A"},
    {"user_id": "ATH-005", "name": "Amina Al-Mansoor", "sport": "Cycling", "gender": "F", "ffm": 49.6, "phase": "Luteal", "contra": "LNG-IUD"},
    {"user_id": "ATH-006", "name": "Sofia Lindqvist", "sport": "Gymnastics", "gender": "F", "ffm": 44.1, "phase": "Luteal", "contra": "None"},
    {"user_id": "ATH-007", "name": "Taro Tanaka", "sport": "Weightlifting", "gender": "M", "ffm": 71.0, "phase": "", "contra": "N/A"},
    {"user_id": "ATH-008", "name": "Sarah Jenkins", "sport": "Triathlon", "gender": "F", "ffm": 51.5, "phase": "Follicular", "contra": "Progestin Only"},
    {"user_id": "ATH-009", "name": "Darius King", "sport": "Basketball", "gender": "M", "ffm": 88.0, "phase": "", "contra": "N/A"},
    {"user_id": "ATH-010", "name": "Freja Nielsen", "sport": "Handball", "gender": "F", "ffm": 61.2, "phase": "Follicular", "contra": "None"},
    {"user_id": "ATH-011", "name": "Mateo Silva", "sport": "Combat Sports", "gender": "M", "ffm": 68.4, "phase": "", "contra": "N/A"},
    {"user_id": "ATH-012", "name": "Yuki Mori", "sport": "Speed Skating", "gender": "F", "ffm": 53.0, "phase": "Ovulatory", "contra": "None"},
]

def seed_database():
    print(f"Connecting to database at {DATABASE_URL}...")
    engine = create_engine(DATABASE_URL)
    
    with engine.begin() as conn:
        # 1. Schema Tables Verification
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS female_athlete_data (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id VARCHAR(64) UNIQUE NOT NULL,
                current_phase VARCHAR(20),
                contraceptive_type VARCHAR(30),
                cramp_severity INTEGER,
                bleeding_volume VARCHAR(20),
                mood_disturbance INTEGER,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
        """))
        
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS daily_checkins (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id VARCHAR(64) NOT NULL,
                date DATE NOT NULL,
                timestamp TEXT NOT NULL,
                gender VARCHAR(10) NOT NULL,
                duration_minutes FLOAT NOT NULL,
                rpe INTEGER NOT NULL,
                sleep_hours FLOAT NOT NULL,
                sleep_quality INTEGER NOT NULL,
                stress INTEGER NOT NULL,
                fatigue INTEGER NOT NULL,
                muscle_soreness INTEGER NOT NULL,
                mood VARCHAR(20),
                cycle_phase VARCHAR(20),
                calories FLOAT,
                ffm FLOAT,
                daily_load FLOAT NOT NULL,
                load_strength FLOAT NOT NULL,
                load_endurance FLOAT NOT NULL,
                load_power FLOAT NOT NULL,
                exercise_type VARCHAR(50),
                injury_location VARCHAR(50),
                pain_level INTEGER,
                injury_notes TEXT,
                rtp_date DATE,
                cmj_height_cm FLOAT,
                sprint_20m_s FLOAT,
                training_block_tag VARCHAR(100),
                symptoms_today VARCHAR(200),
                urine_color INTEGER,
                basal_body_temp_c FLOAT,
                travel_from_tz VARCHAR(10),
                travel_to_tz VARCHAR(10),
                flight_duration FLOAT,
                diet_type VARCHAR(30),
                classification VARCHAR(30),
                created_at TEXT NOT NULL,
                respiratory_rate FLOAT,
                perceived_recovery INTEGER,
                population_type VARCHAR(30),
                CONSTRAINT uq_user_date UNIQUE (user_id, date)
            );
        """))

        print("Tables initialized. Seeding synthetic longitudinal records...")
        today = date.today()
        
        for athlete in SYNTHETIC_ATHLETES:
            uid = athlete["user_id"]
            now_iso = datetime.now(timezone.utc).isoformat()
            
            # Seed female_athlete_data if female
            if athlete["gender"] == "F":
                conn.execute(text("""
                    INSERT OR REPLACE INTO female_athlete_data 
                    (user_id, current_phase, contraceptive_type, cramp_severity, bleeding_volume, mood_disturbance, created_at, updated_at)
                    VALUES (:uid, :phase, :contra, :cramp, :bleed, :mood, :ts, :ts)
                """), {
                    "uid": uid,
                    "phase": athlete["phase"],
                    "contra": athlete["contra"],
                    "cramp": random.randint(0, 3),
                    "bleed": random.choice(["None", "Light", "Moderate"]),
                    "mood": random.randint(1, 4),
                    "ts": now_iso
                })

            # Seed 45 days of longitudinal checkins for full ACWR / EA stability
            for day_offset in range(45, -1, -1):
                rec_date = today - timedelta(days=day_offset)
                duration = random.randint(45, 110)
                rpe = random.randint(4, 9)
                daily_load = duration * rpe
                
                conn.execute(text("""
                    INSERT OR REPLACE INTO daily_checkins
                    (user_id, date, timestamp, gender, duration_minutes, rpe, sleep_hours, sleep_quality, 
                     stress, fatigue, muscle_soreness, mood, cycle_phase, calories, ffm, daily_load, 
                     load_strength, load_endurance, load_power, exercise_type, cmj_height_cm, sprint_20m_s, 
                     urine_color, basal_body_temp_c, perceived_recovery, created_at)
                    VALUES
                    (:uid, :dt, :ts, :gender, :dur, :rpe, :sleep_h, :sleep_q, 
                     :stress, :fatigue, :soreness, :mood, :phase, :cals, :ffm, :load, 
                     :l_str, :l_end, :l_pow, :etype, :cmj, :sprint, :urine, :bbt, :recov, :created)
                """), {
                    "uid": uid,
                    "dt": rec_date.isoformat(),
                    "ts": f"{rec_date.isoformat()}T08:00:00Z",
                    "gender": athlete["gender"],
                    "dur": float(duration),
                    "rpe": rpe,
                    "sleep_h": round(random.uniform(6.5, 9.2), 1),
                    "sleep_q": random.randint(3, 7),
                    "stress": random.randint(1, 5),
                    "fatigue": random.randint(1, 6),
                    "soreness": random.randint(1, 6),
                    "mood": random.choice(["Energized", "Optimal", "Normal", "Fatigued"]),
                    "phase": athlete["phase"] if athlete["gender"] == "F" else "",
                    "cals": float(random.randint(2200, 3600)),
                    "ffm": float(athlete["ffm"]),
                    "load": float(daily_load),
                    "l_str": round(daily_load * 0.4, 1),
                    "l_end": round(daily_load * 0.4, 1),
                    "l_pow": round(daily_load * 0.2, 1),
                    "etype": athlete["sport"],
                    "cmj": round(random.uniform(32.0, 58.0), 1),
                    "sprint": round(random.uniform(2.82, 3.45), 2),
                    "urine": random.randint(1, 4),
                    "bbt": round(random.uniform(36.3, 37.1), 2),
                    "recov": random.randint(55, 95),
                    "created": now_iso
                })

    print(f"Successfully seeded {len(SYNTHETIC_ATHLETES)} synthetic athlete profiles with 46 days of telemetry each.")

if __name__ == "__main__":
    seed_database()
