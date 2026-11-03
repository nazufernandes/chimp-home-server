import json
import os
import time
import shutil
import subprocess
import re
import socket
from http.server import HTTPServer, BaseHTTPRequestHandler

BASE_DIR = os.path.expanduser("~/server")
DATA_DIR = os.path.join(BASE_DIR, "data")
STATE_FILE = os.path.join(DATA_DIR, "services_state.json")
LOG_DIR = os.path.join(BASE_DIR, "logs")

SERVICES_DEF = [
    {
        "id": "drop",
        "name": "ChimpDrop",
        "desc": "Universal Clipboard & File Drop",
        "icon": "📋",
        "color": "#22c997",
        "bg": "rgba(34,201,151,0.12)",
        "url": "/drop/",
        "port": 8082,
        "script": "drop/app.py",
        "type": "process"
    },
    {
        "id": "files",
        "name": "File Manager",
        "desc": "Web Explorer & File Manager",
        "icon": "📁",
        "color": "#38bdf8",
        "bg": "rgba(56,189,248,0.12)",
        "url": "/files/",
        "port": 8081,
        "script": "files/app.py",
        "type": "process"
    },
    {
        "id": "photos",
        "name": "Photo Library",
        "desc": "Gallery & EXIF Inspector",
        "icon": "📷",
        "color": "#a78bfa",
        "bg": "rgba(167,139,250,0.12)",
        "url": "/photos/",
        "port": 8091,
        "script": "photos/app.py",
        "type": "process"
    },
    {
        "id": "cron",
        "name": "ChimpCron",
        "desc": "Scheduled Automation & Tasks",
        "icon": "⏰",
        "color": "#fbbf24",
        "bg": "rgba(251,191,36,0.12)",
        "url": "/cron/",
        "port": 8083,
        "script": "cron/app.py",
        "type": "process"
    },
    {
        "id": "sites",
        "name": "ChimpSites",
        "desc": "Zero-Config Static Web Host",
        "icon": "🌐",
        "color": "#22c997",
        "bg": "rgba(34,201,151,0.12)",
        "url": "/sites/",
        "port": 8080,
        "script": None,
        "type": "static"
    }
]

def load_services_state():
    default_state = {
        s["id"]: {"enabled": True, "show_dashboard": True} for s in SERVICES_DEF
    }
    if not os.path.exists(STATE_FILE):
        return default_state
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            for s in SERVICES_DEF:
                if s["id"] not in data:
                    data[s["id"]] = {"enabled": True, "show_dashboard": True}
            return data
    except Exception:
        return default_state

def save_services_state(state):
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)
    except Exception as e:
        print("Error saving service state:", e)

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

def is_service_running(svc):
    if svc["type"] == "static":
        return True
    script = svc["script"]
    if not script:
        return True
    pid = run_cmd(["pgrep", "-f", script])
    return bool(pid.strip())

def start_service_process(svc):
    if svc["type"] == "static":
        return
    script = svc["script"]
    if not script:
        return
    if is_service_running(svc):
        return
    
    script_path = os.path.join(BASE_DIR, script)
    os.makedirs(LOG_DIR, exist_ok=True)
    log_path = os.path.join(LOG_DIR, f"{svc['id']}.log")
    
    try:
        subprocess.Popen(
            ["python", script_path],
            stdout=open(log_path, "a"),
            stderr=subprocess.STDOUT,
            cwd=BASE_DIR,
            start_new_session=True
        )
    except Exception as e:
        print(f"Failed to start {svc['id']}:", e)

def stop_service_process(svc):
    if svc["type"] == "static":
        return
    script = svc["script"]
    if not script:
        return
    run_cmd(["pkill", "-9", "-f", script])

def get_services_catalog():
    state = load_services_state()
    res = []
    for s in SERVICES_DEF:
        s_id = s["id"]
        s_conf = state.get(s_id, {"enabled": True, "show_dashboard": True})
        running = is_service_running(s) if s_conf.get("enabled", True) else False
        res.append({
            "id": s_id,
            "name": s["name"],
            "desc": s["desc"],
            "icon": s["icon"],
            "color": s["color"],
            "bg": s["bg"],
            "url": s["url"],
            "port": s["port"],
            "type": s["type"],
            "enabled": s_conf.get("enabled", True),
            "show_dashboard": s_conf.get("show_dashboard", True),
            "running": running
        })
    return res

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
    cap = read_file("/sys/class/power_supply/battery/capacity")
    temp = read_file("/sys/class/power_supply/battery/temp")
    status = read_file("/sys/class/power_supply/battery/status")
    health = read_file("/sys/class/power_supply/battery/health")

    percentage = int(cap) if cap and cap.isdigit() else None
    temperature = None
    if temp:
        try:
            t = float(temp)
            temperature = round(t / 10.0, 1) if t > 100 else round(t, 1)
        except ValueError:
            pass

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
        self.send_header("Access-Control-Allow-Methods", "GET, POST, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_cors_headers()
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/api/status", "/api/monitor/status"):
            try:
                data = json.dumps(get_metrics()).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self.send_error(500, f"Monitoring error: {e}")
        elif path in ("/api/services", "/api/monitor/services"):
            try:
                data = json.dumps({"services": get_services_catalog()}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self.send_error(500, f"Services catalog error: {e}")
        else:
            self.send_error(404, "Endpoint not found")

    def do_POST(self):
        path = self.path.split("?")[0]
        if path in ("/api/services/toggle", "/api/monitor/services/toggle"):
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
                data = json.loads(body)
                
                svc_id = data.get("id")
                svc = next((s for s in SERVICES_DEF if s["id"] == svc_id), None)
                if not svc:
                    self.send_error(404, "Service not found")
                    return

                state = load_services_state()
                current = state.get(svc_id, {"enabled": True, "show_dashboard": True})

                if "enabled" in data:
                    current["enabled"] = bool(data["enabled"])
                    if current["enabled"]:
                        start_service_process(svc)
                    else:
                        stop_service_process(svc)

                if "show_dashboard" in data:
                    current["show_dashboard"] = bool(data["show_dashboard"])

                state[svc_id] = current
                save_services_state(state)

                # Return updated catalog
                resp_data = json.dumps({
                    "success": True,
                    "service": svc_id,
                    "state": current,
                    "services": get_services_catalog()
                }).encode()

                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(resp_data)

            except Exception as e:
                self.send_error(500, f"Error toggling service: {e}")
        else:
            self.send_error(404, "Endpoint not found")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_cors_headers()
        self.end_headers()

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    print("Chimp monitoring & service controller running on port 8090")
    HTTPServer(("0.0.0.0", 8090), MonitorHandler).serve_forever()
