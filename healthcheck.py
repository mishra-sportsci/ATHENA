import sys
import os
import socket
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

def check_health():
    results = {"api": "fail", "database": "fail", "disk": "fail", "memory": "fail", "alerts": "fail"}
    try:
        s = socket.create_connection(('localhost', 8000), timeout=2.0)
        s.close()
        results["api"] = "pass"
    except Exception:
        pass
    try:
        db_path = Path(__file__).resolve().parent / "athena.db"
        if db_path.exists():
            results["database"] = f"pass ({round(db_path.stat().st_size / (1024*1024), 1)}MB)"
    except Exception:
        pass
    try:
        usage = shutil.disk_usage(Path(__file__).resolve().parent)
        free_gb = round(usage.free / (1024**3), 1)
        results["disk"] = f"pass ({free_gb}GB free)" if free_gb > 1 else "low_space"
    except Exception:
        pass
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if "MemAvailable" in line:
                    avail_kb = int(line.split()[1])
                    avail_mb = round(avail_kb / 1024, 1)
                    results["memory"] = f"pass ({avail_mb}MB)" if avail_mb > 200 else "low_memory"
                    break
    except Exception:
        pass
    try:
        alert_path = Path("/tmp/athena_alert_status.json")
        if alert_path.exists():
            with open(alert_path, "r") as f:
                alert_data = json.load(f)
            results["alerts"] = f"pass ({alert_data.get('pending_critical', 0)} critical)"
    except Exception:
        pass
    healthy = all(v.startswith("pass") for v in results.values())
    status = "HEALTHY" if healthy else "DEGRADED"
    print(f"[{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')}] {status}: {json.dumps(results)}")
    return 0 if healthy else 1

if __name__ == "__main__":
    sys.exit(check_health())
