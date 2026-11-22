import logging
import json
from datetime import datetime, timezone
from tasks import get_session
from sqlalchemy import text

logger = logging.getLogger("athena-alerts")

def dispatch_pending_alerts():
    session = get_session()
    try:
        result = session.execute(text("""
            SELECT id, user_id, alert_type, severity, title, body, created_at
            FROM alert_log
            WHERE created_at >= datetime('now', '-10 minutes')
            ORDER BY created_at DESC
            LIMIT 20
        """))
        alerts = result.fetchall()
        if alerts:
            critical = [a for a in alerts if a[3] in ("critical", "CRITICAL")]
            warnings = [a for a in alerts if a[3] in ("warning", "WARNING")]
            if critical:
                logger.warning(f"ALERT DISPATCH: {len(critical)} critical, {len(warnings)} warnings in last 10 minutes.")
                for a in critical:
                    logger.warning(f"CRITICAL: {a[1]} - {a[4]}")
        status_path = "/tmp/athena_alert_status.json"
        with open(status_path, "w") as f:
            json.dump({
                "last_check": datetime.now(timezone.utc).isoformat(),
                "pending_critical": len(critical) if alerts else 0,
                "pending_warnings": len(warnings) if alerts else 0
            }, f)
        return len(alerts)
    except Exception as e:
        logger.error(f"Alert dispatch failed: {e}")
        return 0
    finally:
        session.close()

if __name__ == "__main__":
    dispatch_pending_alerts()
