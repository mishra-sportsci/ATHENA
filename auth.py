import os
import secrets
import hashlib
from datetime import datetime, timedelta, timezone

ATHENA_API_KEY = None
ATHENA_MASTER_PASSPHRASE = None

def load_api_key():
    global ATHENA_API_KEY, ATHENA_MASTER_PASSPHRASE
    key_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".athena_api_key")
    passphrase_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".athena_passphrase")
    master_passphrase = os.getenv("ATHENA_MASTER_PASSPHRASE", "")
    if not master_passphrase and os.path.exists(passphrase_file):
        with open(passphrase_file, "r") as f:
            master_passphrase = f.read().strip()
    if not master_passphrase:
        master_passphrase = "athena-default-passphrase-change-me"
    ATHENA_MASTER_PASSPHRASE = master_passphrase
    derived_key = hashlib.pbkdf2_hmac("sha256", master_passphrase.encode(), b"athena-api-key-salt", 100000, dklen=32)
    ATHENA_API_KEY = derived_key.hex()
    if os.path.exists(key_file):
        with open(key_file, "r") as f:
            stored_key = f.read().strip()
            if stored_key != ATHENA_API_KEY:
                ATHENA_API_KEY = stored_key
    else:
        with open(key_file, "w") as f:
            f.write(ATHENA_API_KEY)
        os.chmod(key_file, 0o600)

TOKEN_BLACKLIST = set()

def verify_jwt(token: str) -> dict:
    try:
        import jwt
        payload = jwt.decode(token, ATHENA_API_KEY or "athena-secret", algorithms=["HS256"])
        if payload.get("exp", 0) < datetime.now(timezone.utc).timestamp():
            return None
        if payload.get("jti", "") in TOKEN_BLACKLIST:
            return None
        return payload
    except Exception:
        return None

def create_jwt(user_id: str, role: str = "athlete", expiry_hours: int = 24) -> str:
    import jwt
    import secrets
    payload = {
        "sub": user_id,
        "role": role,
        "jti": secrets.token_hex(16),
        "iat": datetime.now(timezone.utc).timestamp(),
        "exp": (datetime.now(timezone.utc) + timedelta(hours=expiry_hours)).timestamp()
    }
    return jwt.encode(payload, ATHENA_API_KEY or "athena-secret", algorithm="HS256")

ROLES = {
    "admin": {"read": True, "write": True, "delete": True, "export": True, "clinical_notes": True, "scope": "all"},
    "head_coach": {"read": True, "write": True, "delete": False, "export": True, "clinical_notes": False, "scope": "squad"},
    "coach": {"read": True, "write": True, "delete": False, "export": True, "clinical_notes": False, "scope": "squad"},
    "sports_scientist": {"read": True, "write": True, "delete": False, "export": True, "clinical_notes": True, "scope": "all"},
    "physician": {"read": True, "write": True, "delete": False, "export": True, "clinical_notes": True, "scope": "all"},
    "athlete": {"read": True, "write": False, "delete": False, "export": True, "clinical_notes": False, "scope": "self"},
}

def get_user_organization(user_id: str) -> str:
    try:
        from tasks import get_session
        from sqlalchemy import text
        session = get_session()
        result = session.execute(text("SELECT organization_id FROM daily_checkins WHERE user_id = :uid ORDER BY date DESC LIMIT 1"), {"uid": user_id})
        row = result.fetchone()
        session.close()
        return row[0] if row else "default"
    except Exception:
        return "default"

def check_permission(token_payload: dict, action: str, target_user_id: str = None) -> bool:
    if not token_payload:
        return False
    role = token_payload.get("role", "athlete")
    permissions = ROLES.get(role, ROLES["athlete"])
    if not permissions.get(action, False):
        return False
    if permissions["scope"] == "all":
        return True
    if permissions["scope"] == "squad":
        if target_user_id:
            requestor_org = get_user_organization(token_payload.get("sub", ""))
            target_org = get_user_organization(target_user_id)
            return requestor_org == target_org
        return True
    if permissions["scope"] == "self":
        return token_payload.get("sub") == target_user_id
    return False

def hash_password(password: str, salt: str = None) -> tuple:
    if salt is None:
        salt = secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 100000)
    return salt, h.hex()

load_api_key()
