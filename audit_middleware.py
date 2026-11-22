import json
import logging
from datetime import datetime, timezone
from tasks import get_session as tasks_get_session
from sqlalchemy import text

logger = logging.getLogger("athena-audit")

def audit_log_action(user_id: str, action: str, resource: str, outcome: str, details: dict = None):
    try:
        session = tasks_get_session()
        session.execute(text("""
            INSERT INTO audit_logs (user_hash, action, resource, outcome, created_at)
            VALUES (:uh, :a, :r, :o, :now)
        """), {
            "uh": user_id[:16],
            "a": action,
            "r": resource,
            "o": outcome,
            "now": datetime.now(timezone.utc).isoformat()
        })
        session.commit()
        session.close()
    except Exception as e:
        logger.error(f"Audit log failed: {e}")
