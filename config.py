import os
from pathlib import Path
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

class Settings:
    database_url: str = os.getenv("ATHENA_DATABASE_URL", f"sqlite:///{BASE_DIR}/athena.db")
    redis_url: str = os.getenv("ATHENA_REDIS_URL", "redis://localhost:6379/0")
    encryption_key: str = os.getenv("ATHENA_ENCRYPTION_KEY", "")
    r_api_url: str = os.getenv("ATHENA_R_API_URL", "http://localhost:8001")
    r_bind_host: str = os.getenv("ATHENA_R_BIND_HOST", "127.0.0.1")
    ui_scanline: str = os.getenv("ATHENA_UI_SCANLINE", "true")
    ui_theme: str = os.getenv("ATHENA_UI_THEME", "tactical")
    ui_font_scale: str = os.getenv("ATHENA_UI_FONT_SCALE", "1.0")
    max_csv_size_mb: int = int(os.getenv("ATHENA_MAX_CSV_SIZE_MB", "50"))
    max_csv_rows: int = int(os.getenv("ATHENA_MAX_CSV_ROWS", "50000"))
    request_timeout_seconds: int = int(os.getenv("ATHENA_REQUEST_TIMEOUT", "30"))

settings = Settings()
