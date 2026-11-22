import os
import sys
import json
import shutil
import logging
import platform
import subprocess
import socket
from pathlib import Path
from datetime import datetime, timezone

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger("athena-probe")

class SystemCapability:
    CRITICAL = "critical"
    LIMITED = "limited"
    MODERATE = "moderate"
    OPTIMAL = "optimal"

class SystemProbe:
    def __init__(self):
        self.capabilities = {}
        self.warnings = []
        self.recommendations = []
        self.probe_timestamp = datetime.now(timezone.utc).isoformat()

    def probe_cpu(self):
        cpu_count = os.cpu_count() or 2
        cpu_name = platform.processor() or "Unknown"
        architecture = platform.machine()

        self.capabilities["cpu"] = {
            "name": cpu_name,
            "logical_cores": cpu_count,
            "architecture": architecture
        }

        if cpu_count >= 8:
            self.capabilities["cpu_tier"] = SystemCapability.OPTIMAL
            self.capabilities["max_api_workers"] = 4
            self.capabilities["celery_worker_concurrency"] = 4
            self.capabilities["local_llm_suitable"] = True
        elif cpu_count >= 4:
            self.capabilities["cpu_tier"] = SystemCapability.MODERATE
            self.capabilities["max_api_workers"] = 2
            self.capabilities["celery_worker_concurrency"] = 2
            self.capabilities["local_llm_suitable"] = False
        else:
            self.capabilities["cpu_tier"] = SystemCapability.LIMITED
            self.capabilities["max_api_workers"] = 1
            self.capabilities["celery_worker_concurrency"] = 1
            self.capabilities["local_llm_suitable"] = False
            self.capabilities["r_engine_suitable"] = False
            self.warnings.append("CPU cores below 4. API will run single-threaded. R engine disabled. ML features disabled.")

    def probe_memory(self):
        total_gb = 4.0
        available_gb = 2.0
        memory_source = "default_estimate"

        try:
            import psutil
            mem = psutil.virtual_memory()
            total_gb = round(mem.total / (1024 ** 3), 1)
            available_gb = round(mem.available / (1024 ** 3), 1)
            memory_source = "psutil"
        except ImportError:
            try:
                with open("/proc/meminfo", "r") as f:
                    for line in f:
                        if line.startswith("MemTotal"):
                            total_kb = int(line.split()[1])
                            total_gb = round(total_kb / (1024 ** 2), 1)
                        if line.startswith("MemAvailable"):
                            available_kb = int(line.split()[1])
                            available_gb = round(available_kb / (1024 ** 2), 1)
                memory_source = "/proc/meminfo"
            except Exception:
                self.warnings.append("Cannot detect memory. Using conservative defaults.")

        self.capabilities["memory"] = {
            "total_gb": total_gb,
            "available_gb": available_gb,
            "source": memory_source
        }

        if total_gb >= 16:
            self.capabilities["memory_tier"] = SystemCapability.OPTIMAL
        elif total_gb >= 8:
            self.capabilities["memory_tier"] = SystemCapability.MODERATE
        else:
            self.capabilities["memory_tier"] = SystemCapability.LIMITED
            self.capabilities["r_engine_suitable"] = False
            self.capabilities["celery_suitable"] = False
            self.warnings.append(f"RAM ({total_gb}GB) below minimum recommendation of 8GB.")

        if available_gb < 2:
            self.capabilities["celery_suitable"] = False
            self.capabilities["r_engine_suitable"] = False
            self.warnings.append(f"Only {available_gb}GB RAM available. Close other applications before running ATHENA.")
        if available_gb < 1:
            self.capabilities["operating_mode"] = "embedded"
            self.warnings.append("CRITICAL: Less than 1GB RAM available. Embedded mode only.")

    def probe_disk(self):
        project_root = Path(__file__).resolve().parent
        try:
            usage = shutil.disk_usage(project_root)
            free_gb = round(usage.free / (1024 ** 3), 1)
            total_gb = round(usage.total / (1024 ** 3), 1)
        except Exception:
            free_gb = 10.0
            total_gb = 100.0

        self.capabilities["disk"] = {
            "total_gb": total_gb,
            "free_gb": free_gb,
            "project_root": str(project_root)
        }

        if free_gb >= 100:
            self.capabilities["disk_tier"] = SystemCapability.OPTIMAL
        elif free_gb >= 20:
            self.capabilities["disk_tier"] = SystemCapability.MODERATE
        else:
            self.capabilities["disk_tier"] = SystemCapability.LIMITED
            self.warnings.append(f"Low disk space ({free_gb}GB free). Database growth and backups at risk.")

    def probe_gpu(self):
        gpu_name = "None"
        gpu_memory_mb = 0
        gpu_available = False

        try:
            result = subprocess.run(
                ["lspci"],
                capture_output=True, text=True, timeout=5
            )
            for line in result.stdout.split("\n"):
                if "VGA" in line or "3D" in line or "Display" in line:
                    gpu_name = line.strip()
                    gpu_available = True
                    break
        except Exception:
            pass

        if not gpu_available:
            try:
                result = subprocess.run(
                    ["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"],
                    capture_output=True, text=True, timeout=5
                )
                if result.returncode == 0 and result.stdout.strip():
                    parts = result.stdout.strip().split(",")
                    if len(parts) >= 2:
                        gpu_name = parts[0].strip()
                        gpu_memory_str = parts[1].strip().replace("MiB", "").replace(" ", "")
                        gpu_memory_mb = int(gpu_memory_str)
                        gpu_available = True
            except Exception:
                pass

        if not gpu_available or gpu_memory_mb == 0:
            try:
                result = subprocess.run(
                    ["rocm-smi", "--showmeminfo", "vram"],
                    capture_output=True, text=True, timeout=5
                )
                if result.returncode == 0:
                    for line in result.stdout.split("\n"):
                        if "VRAM" in line and "Total" in line:
                            try:
                                gpu_memory_mb = int(line.split(":")[-1].strip().replace("MB", "").strip())
                                gpu_available = True
                                if gpu_name == "None":
                                    gpu_name = "AMD Radeon (ROCm)"
                            except (ValueError, IndexError):
                                pass
            except Exception:
                pass

        if not gpu_available or gpu_memory_mb == 0:
            try:
                gpu_info_paths = [
                    "/sys/class/drm/card0/device/mem_info_vram_total",
                    "/sys/class/drm/card1/device/mem_info_vram_total"
                ]
                for gpu_path in gpu_info_paths:
                    try:
                        mem_path = Path(gpu_path)
                        if mem_path.exists():
                            vram_bytes = int(mem_path.read_text().strip())
                            gpu_memory_mb = vram_bytes // (1024 * 1024)
                            gpu_available = True
                            if gpu_name == "None":
                                gpu_name = "Integrated GPU (DRM)"
                            break
                    except (ValueError, OSError):
                        continue
            except Exception:
                pass

        self.capabilities["gpu"] = {
            "available": gpu_available,
            "name": gpu_name,
            "memory_mb": gpu_memory_mb
        }

        if gpu_available and gpu_memory_mb >= 6000:
            self.capabilities["gpu_tier"] = SystemCapability.OPTIMAL
            self.capabilities["gpu_llm_suitable"] = True
        elif gpu_available:
            self.capabilities["gpu_tier"] = SystemCapability.MODERATE
            self.capabilities["gpu_llm_suitable"] = False
        else:
            self.capabilities["gpu_tier"] = SystemCapability.LIMITED
            self.capabilities["gpu_llm_suitable"] = False

    def probe_thermal(self):
        thermal_throttling = False
        max_temp = 0.0

        try:
            result = subprocess.run(
                ["sensors"],
                capture_output=True, text=True, timeout=5
            )
            for line in result.stdout.split("\n"):
                if "°C" in line:
                    try:
                        if "+" in line:
                            temp_part = line.split("+")[1].split("°C")[0].strip()
                            temp_val = float(temp_part)
                            max_temp = max(max_temp, temp_val)
                    except (ValueError, IndexError):
                        pass
        except Exception:
            pass

        if max_temp == 0.0:
            try:
                for i in range(4):
                    temp_path = Path(f"/sys/class/thermal/thermal_zone{i}/temp")
                    if temp_path.exists():
                        temp_millideg = int(temp_path.read_text().strip())
                        temp_val = temp_millideg / 1000.0
                        max_temp = max(max_temp, temp_val)
            except Exception:
                pass

        if max_temp > 85:
            thermal_throttling = True

        self.capabilities["thermal"] = {
            "max_temperature_c": round(max_temp, 1) if max_temp > 0 else None,
            "throttling_detected": thermal_throttling
        }

        if thermal_throttling:
            self.warnings.append(f"CPU temperature ({max_temp:.1f}C) exceeds safe threshold. Reducing worker concurrency.")
            current = self.capabilities.get("celery_worker_concurrency", 2)
            self.capabilities["celery_worker_concurrency"] = max(1, current - 1)

    def determine_mode(self):
        cpu_tier = self.capabilities.get("cpu_tier", SystemCapability.LIMITED)
        memory_tier = self.capabilities.get("memory_tier", SystemCapability.LIMITED)
        gpu_llm = self.capabilities.get("gpu_llm_suitable", False)
        r_engine_suitable = self.capabilities.get("r_engine_suitable", True)
        r_installed = False
        try:
            result = subprocess.run(["Rscript", "--version"], capture_output=True, timeout=5)
            if result.returncode == 0:
                r_installed = True
        except Exception:
            pass
        if not r_installed:
            self.capabilities["r_engine_suitable"] = False
            self.warnings.append("R is not installed. Python-native analytics will be used.")
        celery_suitable = self.capabilities.get("celery_suitable", True)
        available_gb = self.capabilities.get("memory", {}).get("available_gb", 0)

        redis_reachable = False
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            s.connect(('localhost', 6379))
            s.close()
            redis_reachable = True
        except Exception:
            pass
        if not redis_reachable:
            self.capabilities["celery_suitable"] = False
            self.warnings.append("Redis not reachable. Celery disabled. Synchronous processing mode active.")
        if available_gb < 1:
            self.capabilities["operating_mode"] = "embedded"
            self.capabilities["ml_scikit_enabled"] = False
            self.capabilities["ml_prophet_enabled"] = False
            self.capabilities["local_llm_enabled"] = False
            self.capabilities["online_llm_enabled"] = False
            self.capabilities["r_engine_enabled"] = False
            self.capabilities["celery_enabled"] = False
            self.capabilities["redis_required"] = False
            self.capabilities["batch_size"] = 10
            self.capabilities["max_concurrent_users"] = 1
            self.capabilities["max_api_workers"] = 1
            self.capabilities["celery_worker_concurrency"] = 0
            self.warnings.append("EMBEDDED MODE: Minimal resources. Synchronous processing only. No R analytics. No Celery.")
            return

        if cpu_tier == SystemCapability.OPTIMAL and memory_tier == SystemCapability.OPTIMAL:
            self.capabilities["operating_mode"] = "full"
            self.capabilities["cdss_rules_enabled"] = True
            self.capabilities["ewma_analytics_enabled"] = True
            self.capabilities["ml_scikit_enabled"] = False
            self.capabilities["ml_prophet_enabled"] = False
            self.capabilities["local_llm_enabled"] = False
            self.capabilities["online_llm_enabled"] = False
            self.capabilities["r_engine_enabled"] = r_engine_suitable
            self.capabilities["celery_enabled"] = celery_suitable
            self.capabilities["redis_required"] = True
            self.capabilities["batch_size"] = 500
            self.capabilities["max_concurrent_users"] = 50
        elif cpu_tier in (SystemCapability.OPTIMAL, SystemCapability.MODERATE) and memory_tier in (SystemCapability.OPTIMAL, SystemCapability.MODERATE):
            self.capabilities["operating_mode"] = "standard"
            self.capabilities["cdss_rules_enabled"] = True
            self.capabilities["ewma_analytics_enabled"] = True
            self.capabilities["ml_scikit_enabled"] = False
            self.capabilities["ml_prophet_enabled"] = False
            self.capabilities["local_llm_enabled"] = False
            self.capabilities["online_llm_enabled"] = False
            self.capabilities["r_engine_enabled"] = r_engine_suitable
            self.capabilities["celery_enabled"] = celery_suitable
            self.capabilities["redis_required"] = True
            self.capabilities["batch_size"] = 200
            self.capabilities["max_concurrent_users"] = 20
        else:
            self.capabilities["operating_mode"] = "minimal"
            self.capabilities["cdss_rules_enabled"] = True
            self.capabilities["ewma_analytics_enabled"] = True
            self.capabilities["ml_scikit_enabled"] = False
            self.capabilities["ml_prophet_enabled"] = False
            self.capabilities["local_llm_enabled"] = False
            self.capabilities["online_llm_enabled"] = False
            self.capabilities["r_engine_enabled"] = False
            self.capabilities["celery_enabled"] = False
            self.capabilities["redis_required"] = False
            self.capabilities["batch_size"] = 50
            self.capabilities["max_concurrent_users"] = 5
            self.warnings.append("System in minimal mode. Core clinical telemetry active.")

    def generate_recommendations(self):
        mode = self.capabilities.get("operating_mode", "minimal")
        if mode == "embedded":
            self.recommendations.append("EMBEDDED MODE: System has less than 1GB available RAM. Upgrade to at least 4GB RAM for minimal mode.")
            self.recommendations.append("All analytics are disabled in embedded mode. Only basic data logging is available.")
        elif mode == "minimal":
            self.recommendations.append("Upgrade to at least 8GB RAM and 4 CPU cores for standard high-throughput cohort analytics.")
        if mode == "standard":
            self.recommendations.append("Standard clinical computing mode active. R analytics and SQLite storage operational.")
        if mode == "full":
            self.recommendations.append("Full operational mode active. High-concurrency squad analytics and asynchronous processing enabled.")
        disk_free = self.capabilities.get("disk", {}).get("free_gb", 0)
        if disk_free < 50:
            self.recommendations.append(f"Only {disk_free}GB free disk space. Recommend at least 50GB for production use with automated backups.")

    def run(self):
        logger.info("ATHENA system probe starting")
        self.probe_cpu()
        self.probe_memory()
        self.probe_disk()
        self.probe_gpu()
        self.probe_thermal()
        self.determine_mode()
        self.generate_recommendations()
        logger.info(f"Probe complete. Operating mode: {self.capabilities.get('operating_mode', 'unknown')}")
        return self.to_dict()

    def to_dict(self):
        return {
            "probe_timestamp": self.probe_timestamp,
            "capabilities": self.capabilities,
            "warnings": self.warnings,
            "recommendations": self.recommendations
        }

    def save(self, path=None):
        if path is None:
            path = Path(__file__).resolve().parent / "system_profile.json"
        with open(path, "w") as f:
            json.dump(self.to_dict(), f, indent=2)
        return path

    def print_report(self):
        logger.info("=" * 72)
        print("  A.T.H.E.N.A. SYSTEM COMPATIBILITY REPORT")
        print("=" * 72)
        print(f"  Timestamp:        {self.probe_timestamp}")
        print(f"  Operating Mode:   {self.capabilities.get('operating_mode', 'unknown').upper()}")
        print("-" * 72)
        print(f"  CPU:              {self.capabilities.get('cpu', {}).get('name', 'Unknown')}")
        print(f"  Logical Cores:    {self.capabilities.get('cpu', {}).get('logical_cores', 'Unknown')}")
        print(f"  Architecture:     {self.capabilities.get('cpu', {}).get('architecture', 'Unknown')}")
        print(f"  RAM Total:        {self.capabilities.get('memory', {}).get('total_gb', 'Unknown')} GB")
        print(f"  RAM Available:    {self.capabilities.get('memory', {}).get('available_gb', 'Unknown')} GB")
        print(f"  Disk Free:        {self.capabilities.get('disk', {}).get('free_gb', 'Unknown')} GB")
        print(f"  GPU:              {self.capabilities.get('gpu', {}).get('name', 'None detected')}")
        print(f"  Max CPU Temp:     {self.capabilities.get('thermal', {}).get('max_temperature_c', 'N/A')} C")
        print("-" * 72)
        print(f"  Clinical CDSS:    {'ENABLED' if self.capabilities.get('cdss_rules_enabled', True) else 'DISABLED'}")
        print(f"  R Analytics:      {'ENABLED' if self.capabilities.get('r_engine_enabled') else 'DISABLED'}")
        print(f"  EWMA Engine:      {'ENABLED' if self.capabilities.get('ewma_analytics_enabled', True) else 'DISABLED'}")
        print(f"  SQLite Storage:   ENABLED")
        print(f"  Batch Size:       {self.capabilities.get('batch_size', 50)}")
        print(f"  Max Users:        {self.capabilities.get('max_concurrent_users', 5)}")
        print("-" * 72)
        if self.warnings:
            print("  WARNINGS:")
            for w in self.warnings:
                print(f"    [!] {w}")
        if self.recommendations:
            print("  RECOMMENDATIONS:")
            for r in self.recommendations:
                print(f"    [>] {r}")
        print("=" * 72 + "\n")


def get_system_profile():
    profile_path = Path(__file__).resolve().parent / "system_profile.json"
    if profile_path.exists():
        try:
            with open(profile_path, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return None


def probe_and_configure():
    probe = SystemProbe()
    profile = probe.run()
    profile_path = probe.save()
    probe.print_report()
    return profile, profile_path


if __name__ == "__main__":
    probe_and_configure()