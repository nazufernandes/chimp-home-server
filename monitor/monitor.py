import json
import os
import time
import shutil
import subprocess
import re
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler

def run_cmd(command):
    try:
        return subprocess.check_output(
            command, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return ""

def read_file(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except (PermissionError, OSError):
        return ""

def get_memory():
    data = {}
    content = read_file("/proc/meminfo")
    for line in content.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            try:
                data[parts[0].rstrip(":")] = int(parts[1])
            except ValueError:
                pass

    if not data:
        return {"total": 0, "used": 0, "available": 0, "percent": 0}

    total = data.get("MemTotal", 0)
    available = data.get("MemAvailable", data.get("MemFree", 0))
    used = max(0, total - available)

    return {
        "total": round(total / 1024, 1),
        "used": round(used / 1024, 1),
        "available": round(available / 1024, 1),
        "percent": round(used * 100 / total, 1) if total else 0
    }

def get_storage():
    disk = shutil.disk_usage(os.path.expanduser("~"))
    return {
        "total": round(disk.total / (1024**3), 2),
        "used": round((disk.total - disk.free) / (1024**3), 2),
        "free": round(disk.free / (1024**3), 2),
        "percent": round((disk.total - disk.free) * 100 / disk.total, 1)
    }

def get_battery():
    # Attempt reading from Linux power supply sysfs
    cap = read_file("/sys/class/power_supply/battery/capacity")
    temp = read_file("/sys/class/power_supply/battery/temp")
    status = read_file("/sys/class/power_supply/battery/status")
    health = read_file("/sys/class/power_supply/battery/health")

    percentage = int(cap) if cap and cap.isdigit() else None
    temperature = None
    if temp:
        try:
            t = float(temp)
            # Some kernels report in tenths of degree (e.g. 325 = 32.5 C)
            temperature = round(t / 10.0, 1) if t > 100 else round(t, 1)
        except ValueError:
            pass

    # Fallback to dumpsys battery if sysfs is restricted
    if percentage is None:
        dump = run_cmd(["dumpsys", "battery"])
        if dump:
            m_level = re.search(r"level:\s*(\d+)", dump)
            m_temp = re.search(r"temperature:\s*(\d+)", dump)
            m_status = re.search(r"status:\s*(\d+)", dump)
            if m_level:
                percentage = int(m_level.group(1))
            if m_temp:
                temperature = round(float(m_temp.group(1)) / 10.0, 1)
            if m_status:
                st_code = m_status.group(1)
                status = "Charging" if st_code == "2" else "Discharging"

    return {
        "percentage": percentage if percentage is not None else 100,
        "temperature": temperature if temperature is not None else 32.0,
        "status": status or "Charging",
        "health": health or "Good"
    }

def get_uptime_info():
    uptime_str = run_cmd(["uptime", "-p"])
    raw_uptime = run_cmd(["uptime"])

    # Extract load averages
    load = None
    m = re.search(r"load average:\s*([0-9.]+),\s*([0-9.]+),\s*([0-9.]+)", raw_uptime)
    if m:
        load = {
            "load1": float(m.group(1)),
            "load5": float(m.group(2)),
            "load15": float(m.group(3))
        }

    seconds = 0
    d_m = re.search(r"(\d+)\s*day", uptime_str)
    h_m = re.search(r"(\d+)\s*hour", uptime_str)
    min_m = re.search(r"(\d+)\s*min", uptime_str)
    if d_m: seconds += int(d_m.group(1)) * 86400
    if h_m: seconds += int(h_m.group(1)) * 3600
    if min_m: seconds += int(min_m.group(1)) * 60

    return {
        "seconds": seconds,
        "human": uptime_str or "Online",
        "load": load
    }

def get_ip():
    ip_out = run_cmd(["ip", "-4", "addr", "show", "wlan0"])
    m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)", ip_out)
    if m:
        return m.group(1)

    prop = run_cmd(["getprop", "dhcp.wlan0.ipaddress"])
    if prop and "." in prop:
        return prop

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

def get_metrics():
    memory = get_memory()
    uptime = get_uptime_info()
    battery = get_battery()

    return {
        "hostname": "chimp",
        "ip": get_ip(),
        "cpu": uptime["load"],
        "memory": memory,
        "storage": get_storage(),
        "battery": battery,
        "uptime": uptime["seconds"],
        "uptime_human": uptime["human"],
        "network": {"rx": 0, "tx": 0},
        "timestamp": int(time.time())
    }

class MonitorHandler(BaseHTTPRequestHandler):
    def send_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_cors_headers()
        self.end_headers()

    def do_GET(self):
        if self.path != "/api/status":
            self.send_error(404)
            return

        try:
            data = json.dumps(get_metrics()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(data)
        except Exception:
            self.send_error(500, "Monitoring error")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_cors_headers()
        self.end_headers()

    def log_message(self, format, *args):
        pass

print("Chimp monitoring service running on port 8090")
HTTPServer(("0.0.0.0", 8090), MonitorHandler).serve_forever()
