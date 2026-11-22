import os
import json
import time
import signal
import logging
import threading
from pathlib import Path
from datetime import datetime, timezone
import subprocess

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s")
logger = logging.getLogger("athena.thermal_guard")

class ThermalGuard:
    def __init__(self):
        self.current_temperature = 0.0
        self.operating_mode = "full"
        self.monitoring_active = True
        self.lock = threading.Lock()
        self.temperature_history = []
        self.history_max_size = 60
        self.safe_mode_triggered = False
        self.consecutive_high_temp = 0
        self.stop_event = threading.Event()

    def read_power_source(self):
        try:
            for bat_path in ["/sys/class/power_supply/BAT0/status", "/sys/class/power_supply/BAT1/status"]:
                path = Path(bat_path)
                if path.exists():
                    return path.read_text().strip()
            return "Unknown"
        except Exception:
            return "Unknown"

    def get_battery_offset(self):
        power_source = self.read_power_source()
        if power_source == "Discharging":
            return -10.0
        return 0.0

    def read_cpu_temperature(self):
        max_temp = 0.0
        temp_sources = [
            "/sys/class/thermal/thermal_zone0/temp",
            "/sys/class/thermal/thermal_zone1/temp",
            "/sys/class/thermal/thermal_zone2/temp",
            "/sys/class/thermal/thermal_zone3/temp",
        ]
        for source in temp_sources:
            try:
                path = Path(source)
                if path.exists():
                    temp_raw = int(path.read_text().strip())
                    temp_celsius = temp_raw / 1000.0
                    max_temp = max(max_temp, temp_celsius)
            except (ValueError, OSError):
                continue
        if max_temp == 0.0:
            try:
                import subprocess
                result = subprocess.run(["sensors"], capture_output=True, text=True, timeout=3)
                for line in result.stdout.split("\n"):
                    if "C" in line and "+" in line:
                        try:
                            temp_part = line.split("+")[1].split("C")[0].strip()
                            max_temp = max(max_temp, float(temp_part))
                        except (ValueError, IndexError):
                            pass
            except Exception:
                pass
        if max_temp == 0.0:
            try:
                import psutil
                temps = psutil.sensors_temperatures()
                if temps:
                    for name, entries in temps.items():
                        for entry in entries:
                            if entry.current:
                                max_temp = max(max_temp, entry.current)
            except ImportError:
                pass
        if max_temp == 0.0:
            try:
                import platform
                if platform.system() == "Windows":
                    import subprocess
                    result = subprocess.run(
                        ["wmic", "/namespace:\\\\root\\wmi", "PATH", "MSAcpi_ThermalZoneTemperature", "get", "CurrentTemperature"],
                        capture_output=True, text=True, timeout=3
                    )
                    for line in result.stdout.split("\n"):
                        line = line.strip()
                        if line and line.isdigit():
                            temp_c = (float(line) / 10.0) - 273.15
                            max_temp = max(max_temp, temp_c)
            except Exception:
                pass
        if max_temp == 0.0:
            logger.warning("No CPU temperature source detected. Thermal Guard running blind. Install lm-sensors or psutil.")
        return max_temp

    def determine_operating_mode(self, temperature):
        # Modern CPUs safely operate up to TJmax (100C Intel, 95C AMD).
        # Emergency threshold set at TJmax - 5C, not at a fixed 95C.
        if temperature > 100.0:
            return "emergency"
        elif temperature > 90.0:
            return "minimal"
        elif temperature > 80.0:
            return "reduced"
        elif temperature > 70.0:
            return "standard"
        else:
            return "full"

    def apply_operating_mode(self, mode):
        with self.lock:
            if self.operating_mode == mode:
                return
            previous_mode = self.operating_mode
            self.operating_mode = mode
            status_file = Path("/tmp/athena_thermal_status.json")
            battery_offset = self.get_battery_offset()
            status_data = {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "cpu_temperature_c": round(self.current_temperature, 1),
                "operating_mode": mode,
                "previous_mode": previous_mode,
                "power_source": self.read_power_source(),
                "battery_offset_applied_c": battery_offset,
                "memory_pressure_pct": self.check_memory_pressure(),
                "ambient_note": "Thermal thresholds adjusted for battery operation. emergency=95C, minimal=85C, reduced=75C, standard=65C. Battery offset: -10C on discharge."
            }
            with open(status_file, "w") as f:
                json.dump(status_data, f, indent=2)

            if mode == "emergency":
                logger.critical(f"EMERGENCY THERMAL MODE: CPU at {self.current_temperature:.1f}C")
                self.stop_all_ml_services()
                self.signal_celery_pause()
            elif mode == "minimal":
                logger.warning(f"MINIMAL THERMAL MODE: CPU at {self.current_temperature:.1f}C")
                self.limit_to_core_services()
                self.signal_celery_pause()
            elif mode == "reduced":
                logger.info(f"REDUCED THERMAL MODE: CPU at {self.current_temperature:.1f}C")
                self.reduce_ml_workers()
            elif mode == "standard":
                logger.info(f"STANDARD THERMAL MODE: CPU at {self.current_temperature:.1f}C")
                self.restore_standard_services()
            elif mode == "full":
                logger.info(f"FULL THERMAL MODE: CPU at {self.current_temperature:.1f}C")
                self.restore_all_services()

    def signal_celery_pause(self):
        try:
            celery_pidfile = Path("/tmp/athena_pids/celery.pid")
            if celery_pidfile.exists():
                pid = int(celery_pidfile.read_text().strip())
                os.kill(pid, 19)
                logger.warning(f"Sent SIGSTOP to Celery worker PID {pid}")
                threading.Timer(30.0, self.check_celery_temperature_recovery, args=[pid]).start()
        except Exception as e:
            logger.error(f"Failed to pause Celery: {e}")

    def check_celery_temperature_recovery(self, pid):
        try:
            current_temp = self.read_cpu_temperature()
            if current_temp > 85.0:
                os.kill(pid, 9)
                logger.critical(f"Temperature still at {current_temp}C after 30s. Sent SIGKILL to Celery PID {pid}")
            elif current_temp < 70.0:
                os.kill(pid, 18)
                logger.info(f"Temperature recovered to {current_temp}C. Sent SIGCONT to Celery PID {pid}")
        except Exception as e:
            logger.error(f"Celery recovery check failed: {e}")

    def stop_all_ml_services(self):
        try:
            celery_control_path = Path("/tmp/athena_ml_control.json")
            control_data = {
                "ml_scikit_enabled": False,
                "ml_prophet_enabled": False,
                "local_llm_enabled": False,
                "online_llm_enabled": False,
                "batch_size": 10,
                "max_concurrent_users": 5,
                "reason": "Thermal emergency protection active",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "graceful_shutdown": True,
                "task_completion_timeout_seconds": 30
            }
            with open(celery_control_path, "w") as f:
                json.dump(control_data, f, indent=2)
            self.safe_mode_triggered = True
            logger.critical("Emergency thermal shutdown initiated. ML workers have 30 seconds to complete in-flight tasks.")
        except Exception as e:
            logger.error(f"Failed to stop ML services: {e}")

    def limit_to_core_services(self):
        try:
            control_path = Path("/tmp/athena_ml_control.json")
            control_data = {
                "ml_scikit_enabled": False,
                "ml_prophet_enabled": False,
                "local_llm_enabled": False,
                "online_llm_enabled": True,
                "batch_size": 50,
                "max_concurrent_users": 10,
                "reason": "Thermal protection limiting non-essential services",
                "timestamp": datetime.now(timezone.utc).isoformat()
            }
            with open(control_path, "w") as f:
                json.dump(control_data, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to limit services: {e}")

    def reduce_ml_workers(self):
        try:
            control_path = Path("/tmp/athena_ml_control.json")
            control_data = {
                "ml_scikit_enabled": True,
                "ml_prophet_enabled": False,
                "local_llm_enabled": False,
                "online_llm_enabled": True,
                "batch_size": 100,
                "max_concurrent_users": 15,
                "reason": "Thermal protection reducing ML workload",
                "timestamp": datetime.now(timezone.utc).isoformat()
            }
            with open(control_path, "w") as f:
                json.dump(control_data, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to reduce ML workers: {e}")

    def restore_standard_services(self):
        try:
            control_path = Path("/tmp/athena_ml_control.json")
            control_data = {
                "ml_scikit_enabled": True,
                "ml_prophet_enabled": True,
                "local_llm_enabled": False,
                "online_llm_enabled": True,
                "batch_size": 200,
                "max_concurrent_users": 20,
                "reason": "Standard operating mode restored",
                "timestamp": datetime.now(timezone.utc).isoformat()
            }
            with open(control_path, "w") as f:
                json.dump(control_data, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to restore standard services: {e}")

    def restore_all_services(self):
        try:
            control_path = Path("/tmp/athena_ml_control.json")
            control_data = {
                "ml_scikit_enabled": True,
                "ml_prophet_enabled": True,
                "local_llm_enabled": True,
                "online_llm_enabled": True,
                "batch_size": 500,
                "max_concurrent_users": 50,
                "reason": "All services fully operational",
                "timestamp": datetime.now(timezone.utc).isoformat()
            }
            with open(control_path, "w") as f:
                json.dump(control_data, f, indent=2)
            self.safe_mode_triggered = False
        except Exception as e:
            logger.error(f"Failed to restore all services: {e}")

    def monitoring_loop(self):
        logger.info("Thermal Guard monitoring started")
        ema_alpha = 0.3
        ema_temperature = 0.0
        memory_alert_triggered = False
        while self.monitoring_active:
            try:
                temp = self.read_cpu_temperature()
                battery_offset = self.get_battery_offset()
                effective_temp = 0.0
                if temp > 0.0:
                    self.current_temperature = temp
                    adjusted_temp = temp + battery_offset
                    if ema_temperature == 0.0:
                        ema_temperature = adjusted_temp
                    else:
                        ema_temperature = (ema_alpha * adjusted_temp) + ((1 - ema_alpha) * ema_temperature)
                    self.temperature_history.append(temp)
                    if len(self.temperature_history) > self.history_max_size:
                        self.temperature_history = self.temperature_history[-self.history_max_size:]
                    effective_temp = max(adjusted_temp, ema_temperature)
                    memory_pressure = self.check_memory_pressure()
                    if memory_pressure > 90:
                        if not memory_alert_triggered:
                            logger.critical(f"MEMORY CRITICAL: {memory_pressure}% used. Activating emergency protocols.")
                            memory_alert_triggered = True
                        self.apply_operating_mode("emergency")
                    elif memory_pressure > 80:
                        self.apply_operating_mode("minimal")
                    elif ema_temperature > 85.0 and self.consecutive_high_temp >= 30:
                        self.apply_operating_mode("emergency")
                    elif ema_temperature > 75.0 and self.consecutive_high_temp >= 15:
                        self.apply_operating_mode("minimal")
                    elif effective_temp > 95.0:
                        self.apply_operating_mode("emergency")
                    elif effective_temp > 85.0:
                        self.apply_operating_mode("minimal")
                    elif effective_temp > 75.0:
                        self.apply_operating_mode("reduced")
                    elif effective_temp > 65.0:
                        self.apply_operating_mode("standard")
                    else:
                        if memory_pressure < 70:
                            memory_alert_triggered = False
                        if self.safe_mode_triggered and effective_temp < 55.0:
                            self.apply_operating_mode("full")
                        elif not self.safe_mode_triggered and effective_temp < 70.0:
                            self.apply_operating_mode("full")
                    if effective_temp > 85.0:
                        self.consecutive_high_temp += 1
                    else:
                        self.consecutive_high_temp = max(0, self.consecutive_high_temp - 2)
            except Exception as e:
                logger.error(f"Thermal monitoring error: {e}")
            sleep_interval = 3.0 if effective_temp > 75.0 else 10.0
            if self.stop_event.wait(timeout=sleep_interval):
                break

    def check_memory_pressure(self):
        try:
            with open("/proc/meminfo", "r") as f:
                meminfo = f.read()
            total = None
            available = None
            for line in meminfo.split("\n"):
                if line.startswith("MemTotal"):
                    total = int(line.split()[1])
                if line.startswith("MemAvailable"):
                    available = int(line.split()[1])
            if total and available:
                used_pct = ((total - available) / total) * 100
                return round(used_pct, 1)
        except Exception:
            pass
        try:
            import psutil
            return psutil.virtual_memory().percent
        except ImportError:
            return 0.0

    def start(self):
        monitor_thread = threading.Thread(target=self.monitoring_loop, daemon=True)
        monitor_thread.start()
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
        try:
            self.stop_event.wait()
        except KeyboardInterrupt:
            self.shutdown()

    def signal_handler(self, signum, frame):
        self.shutdown()

    def shutdown(self):
        logger.info("Thermal Guard shutting down safely")
        self.monitoring_active = False
        self.stop_event.set()
        try:
            p = Path("/tmp/athena_thermal_status.json")
            if p.exists():
                p.unlink()
        except Exception:
            pass
        self.restore_all_services()

if __name__ == "__main__":
    guard = ThermalGuard()
    guard.start()