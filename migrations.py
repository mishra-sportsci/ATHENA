import logging
import os as _os
from datetime import datetime
from tasks import get_engine, get_session
from sqlalchemy import text

logger = logging.getLogger("athena-migrations")

CURRENT_SCHEMA_VERSION = 2

MIGRATIONS = {
    1: [
        "ALTER TABLE daily_checkins ADD COLUMN IF NOT EXISTS population_type VARCHAR(30)",
        "ALTER TABLE daily_checkins ADD COLUMN IF NOT EXISTS respiratory_rate FLOAT",
        "ALTER TABLE daily_checkins ADD COLUMN IF NOT EXISTS perceived_recovery INTEGER",
    ],
    2: [
        "ALTER TABLE daily_checkins ADD COLUMN IF NOT EXISTS data_hash VARCHAR(32)",
        "CREATE TABLE IF NOT EXISTS user_credentials (user_id VARCHAR(64) PRIMARY KEY, salt TEXT NOT NULL, password_hash TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS failed_tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, task_name TEXT NOT NULL, task_data TEXT NOT NULL, error_message TEXT NOT NULL, attempts INTEGER DEFAULT 0, created_at TEXT NOT NULL)",
    ],
}

def run_migrations():
    engine = get_engine()
    import shutil as _shutil
    import os as _os_module
    db_url = _os_module.getenv("ATHENA_DATABASE_URL", "")
    if "sqlite" in db_url:
        db_path = db_url.replace("sqlite:///", "")
    else:
        db_path = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "athena.db")
    backup_dir = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "backups")
    _os.makedirs(backup_dir, exist_ok=True)
    backup_path = _os.path.join(backup_dir, f"pre_migration_backup_{datetime.now().strftime('%Y%m%d_%H%M%S')}.db")
    if _os.path.exists(db_path):
        _shutil.copy2(db_path, backup_path)
        logger.info(f"Pre-migration backup saved to {backup_path}")
    with engine.connect() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL
            )
        """))
        conn.commit()
        result = conn.execute(text("SELECT MAX(version) FROM schema_version"))
        current = result.scalar() or 0
        if current >= CURRENT_SCHEMA_VERSION:
            logger.info(f"Database schema is current (version {current}).")
            return
        for version in range(current + 1, CURRENT_SCHEMA_VERSION + 1):
            if version in MIGRATIONS:
                logger.info(f"Applying migration {version}...")
                try:
                    import re
                    for stmt in MIGRATIONS[version]:
                        match = re.match(r"ALTER\s+TABLE\s+(\w+)\s+ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s+(.+)", stmt, re.IGNORECASE)
                        if match:
                            table_name, col_name, col_type = match.groups()
                            existing = [c[1] for c in conn.execute(text(f"PRAGMA table_info({table_name})")).fetchall()]
                            if col_name not in existing:
                                conn.execute(text(f"ALTER TABLE {table_name} ADD COLUMN {col_name} {col_type}"))
                        else:
                            conn.execute(text(stmt))
                    conn.execute(text("INSERT INTO schema_version (version, applied_at) VALUES (:v, datetime('now'))"), {"v": version})
                    conn.commit()
                    logger.info(f"Migration {version} applied successfully.")
                except Exception as e:
                    conn.rollback()
                    logger.error(f"Migration {version} failed: {e}")
                    raise
    logger.info("All migrations complete.")

if __name__ == "__main__":
    run_migrations()
