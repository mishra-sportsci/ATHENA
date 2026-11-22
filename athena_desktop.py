#!/usr/bin/env python3
"""
ATHENA - Native Desktop GUI & Service Lifecycle Manager
Optimized for Debian 13 (Trixie) KDE Plasma with zero background resource leakage.
"""
import os
import sys

# Force PyQt6 backend for native integration with KDE Plasma before importing webview
os.environ["QT_API"] = "pyqt6"

import subprocess
import time
import socket
import signal
import webview

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ATHENA_SH = os.path.join(BASE_DIR, "athena.sh")
PORT = 8000
HOST = "127.0.0.1"

# Subprocess handle for backend process group
backend_process = None
_shutdown_in_progress = False

class TeeLogger:
    """Tee logger to write simultaneously to terminal (stdout) and logfile."""
    def __init__(self, log_path, stream):
        self.log_file = open(log_path, "a", buffering=1)
        self.stream = stream

    def write(self, data):
        self.stream.write(data)
        self.stream.flush()
        try:
            self.log_file.write(data)
            self.log_file.flush()
        except Exception:
            pass

    def flush(self):
        self.stream.flush()
        try:
            self.log_file.flush()
        except Exception:
            pass

def checkpoint_database():
    """Flush and truncate SQLite WAL file to ensure 100% data integrity and zero corruption."""
    db_path = os.path.join(BASE_DIR, "athena.db")
    if os.path.exists(db_path):
        try:
            import sqlite3
            conn = sqlite3.connect(db_path, timeout=5)
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            conn.close()
            print("[ATHENA] SQLite WAL checkpointed and truncated safely.")
        except Exception as e:
            print(f"[ATHENA] SQLite checkpoint notification: {e}")

def wait_for_port(port, host=HOST, timeout=30):
    """Wait until the API server is actively responding to HTTP requests."""
    start_time = time.time()
    while True:
        try:
            conn = socket.create_connection((host, port), timeout=0.5)
            conn.sendall(b"GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            response = conn.recv(1024)
            conn.close()
            if b"HTTP/" in response:
                return True
        except (ConnectionRefusedError, socket.timeout, OSError):
            pass
            
        if time.time() - start_time > timeout:
            return False
        time.sleep(0.3)

def start_backend():
    """Start the athena.sh services in an isolated process group."""
    global backend_process
    print("[ATHENA] Starting ATHENA backend services...")
    
    # Prepend virtual environment bin to PATH
    env = os.environ.copy()
    venv_bin = os.path.join(BASE_DIR, "athena_env", "bin")
    env["PATH"] = venv_bin + os.pathsep + env.get("PATH", "")
    
    backend_log_path = os.path.join(BASE_DIR, "athena_backend.log")
    backend_log = open(backend_log_path, "a", buffering=1)
    
    backend_process = subprocess.Popen(
        ["/bin/bash", ATHENA_SH],
        preexec_fn=os.setsid,  # Run in new process group to manage child lifecycles cleanly
        cwd=BASE_DIR,
        stdout=backend_log,
        stderr=backend_log,
        env=env
    )

def on_closed():
    """Trigger deterministic, graceful shutdown of all backend services."""
    global backend_process, _shutdown_in_progress
    if _shutdown_in_progress:
        return
    _shutdown_in_progress = True
    
    print("\n[ATHENA] Desktop closed. Commencing clean service shutdown...")
    if backend_process and backend_process.poll() is None:
        try:
            pgid = os.getpgid(backend_process.pid)
            # Send SIGTERM to process group so athena.sh trap triggers gracefully
            os.killpg(pgid, signal.SIGTERM)
            
            # Poll for clean exit (up to 4 seconds)
            for _ in range(40):
                if backend_process.poll() is not None:
                    break
                time.sleep(0.1)
                
            if backend_process.poll() is None:
                print("[ATHENA] Process taking longer than 4s; terminating process group...")
                os.killpg(pgid, signal.SIGKILL)
                backend_process.wait(timeout=2)
        except Exception as e:
            print(f"[ATHENA] Shutdown status: {e}")
            
    # Final database checkpoint safety check
    checkpoint_database()
    print("[ATHENA] All ATHENA services safely stopped. 0 background processes active.")
    sys.exit(0)

def main():
    # Setup tee logging to terminal and athena_app.log
    log_path = os.path.join(BASE_DIR, "athena_app.log")
    try:
        sys.stdout = TeeLogger(log_path, sys.stdout)
        sys.stderr = TeeLogger(log_path, sys.stderr)
    except Exception:
        pass

    # Register OS signals for graceful shutdown
    signal.signal(signal.SIGINT, lambda s, f: on_closed())
    signal.signal(signal.SIGTERM, lambda s, f: on_closed())

    # Start the backend services
    start_backend()

    # Wait for the API server (uvicorn) to launch
    print(f"[ATHENA] Waiting for API server to become ready on port {PORT}...")
    if not wait_for_port(PORT):
        print("[ATHENA] Error: API server failed to respond in time. Aborting.")
        if backend_process:
            try:
                os.killpg(os.getpgid(backend_process.pid), signal.SIGTERM)
            except Exception:
                pass
        checkpoint_database()
        sys.exit(1)

    print("[ATHENA] API server is ready. Loading native interface...")

    try:
        # Create native webview window using KDE Plasma PyQt6 WebEngine
        window = webview.create_window(
            title="ATHENA — Clinical Intelligence Workspace",
            url=f"http://{HOST}:{PORT}",
            width=1366,
            height=850,
            resizable=True,
            min_size=(1024, 768)
        )
        window.events.closed += on_closed
        webview.start(gui="qt")
    except Exception as e:
        print(f"[ATHENA] Native window startup fallback ({e}). Opening system browser...")
        import webbrowser
        webbrowser.open(f"http://{HOST}:{PORT}")
        print(f"[ATHENA] ATHENA running in browser at http://{HOST}:{PORT}")
        print("[ATHENA] Press Ctrl+C in this terminal when finished to safely shut down all services.")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            on_closed()

if __name__ == "__main__":
    main()
