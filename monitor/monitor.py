import json
import os
import time
import shutil
import subprocess
import re
import socket
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

BASE_DIR = os.path.expanduser("~/server")
DATA_DIR = os.path.join(BASE_DIR, "data")
STATE_FILE = os.path.join(DATA_DIR, "services_state.json")
LOG_DIR = os.path.join(BASE_DIR, "logs")

def load_env():
    env_file = os.path.join(BASE_DIR, ".env")
    env_vars = {}
    if os.path.exists(env_file):
        try:
            with open(env_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        env_vars[k.strip()] = v.strip().strip('"').strip("'")
        except Exception as e:
            print("Error loading .env:", e)
    return env_vars

def get_admin_password():
    env_vars = load_env()
    return env_vars.get("CHIMP_ADMIN_PASSWORD", os.environ.get("CHIMP_ADMIN_PASSWORD", "admin"))

SERVICES_DEF = [
    {
        "id": "drop",
        "name": "ChimpDrop",
        "desc": "Universal Clipboard & File Drop",
        "icon": "/icon-drop.svg",
        "color": "#22c997",
        "bg": "rgba(34,201,151,0.12)",
        "url": "/drop/",
        "port": 8082,
        "script": "drop/app.py",
        "type": "process"
    },
    {
        "id": "files",
        "name": "ChimpDrive",
        "desc": "Cloud Explorer & File Storage",
        "icon": "/icon-drive.svg",
        "color": "#38bdf8",
        "bg": "rgba(56,189,248,0.12)",
        "url": "/files/",
        "port": 8081,
        "script": "files/app.py",
        "type": "process"
    },
    {
        "id": "photos",
        "name": "ChimpPix",
        "desc": "Media Gallery & EXIF Inspector",
        "icon": "/icon-pix.svg",
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
        "icon": "/icon-cron.svg",
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
        "icon": "/icon-sites.svg",
        "color": "#22c997",
        "bg": "rgba(34,201,151,0.12)",
        "url": "/sites/",
        "port": 8080,
        "script": None,
        "type": "static"
    },
    {
        "id": "ai",
        "name": "ChimpAI",
        "desc": "Local Neural Engine & Assistant",
        "icon": "/chimp-ascii.svg",
        "color": "#22c997",
        "bg": "rgba(34,201,151,0.12)",
        "url": "/chimpai/",
        "port": 8092,
        "script": "run_llama.sh",
        "type": "process"
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

def get_tunnel_domain():
    conf = os.path.join(DATA_DIR, "tunnel.conf")
    base_conf = os.path.join(BASE_DIR, "config", "tunnel.conf")
    if os.path.exists(conf):
        try:
            with open(conf) as f:
                d = f.read().strip()
                if d: return d
        except Exception:
            pass
    if os.path.exists(base_conf):
        try:
            with open(base_conf) as f:
                d = f.read().strip()
                if d: return d
        except Exception:
            pass
    return "holstered-meltingly-pablo.ngrok-free.dev"

_last_ssh_check = 0
_cached_ssh_res = None

def get_public_ssh():
    global _last_ssh_check, _cached_ssh_res
    now = time.time()
    if _cached_ssh_res is not None and (now - _last_ssh_check < 4.0):
        return _cached_ssh_res

    res = None
    try:
        user = run_cmd(["whoami"]).strip() or "u0_a223"
    except Exception:
        user = "u0_a223"

    for port in (4040, 4041, 4042):
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{port}/api/tunnels", headers={"User-Agent": "ChimpMonitor/1.0"})
            with urllib.request.urlopen(req, timeout=0.5) as resp:
                data = json.loads(resp.read().decode())
                for t in data.get("tunnels", []):
                    if t.get("proto") == "tcp":
                        pub = t.get("public_url", "")
                        clean = pub.replace("tcp://", "")
                        if ":" in clean:
                            host, p = clean.split(":")
                            res = {
                                "command": f"ssh {user}@{host} -p {p}",
                                "host": host,
                                "port": p,
                                "user": user,
                                "public_url": pub
                            }
                            break
            if res:
                break
        except Exception:
            pass

    _cached_ssh_res = res
    _last_ssh_check = now
    return res

def get_public_url():
    for port in (4040, 4041, 4042):
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{port}/api/tunnels", headers={"User-Agent": "ChimpMonitor/1.0"})
            with urllib.request.urlopen(req, timeout=0.5) as resp:
                data = json.loads(resp.read().decode())
                for t in data.get("tunnels", []):
                    if t.get("proto") == "https":
                        return t.get("public_url")
        except Exception:
            pass
    if run_cmd(["pgrep", "-f", "ngrok http"]):
        return f"https://{get_tunnel_domain()}"
    return None

def is_service_running(svc):
    if svc["type"] == "static":
        return True
    if svc["type"] == "tunnel":
        pid = run_cmd(["pgrep", "-f", "ngrok http"])
        return bool(pid.strip())
    if svc.get("id") == "ai":
        pid = run_cmd(["pgrep", "-f", "llama-server"])
        return bool(pid.strip())
    script = svc["script"]
    if not script:
        return True
    pid = run_cmd(["pgrep", "-f", script])
    return bool(pid.strip())

def has_tmux_session():
    try:
        res = subprocess.run(["tmux", "has-session", "-t", "chimp"], capture_output=True)
        return res.returncode == 0
    except Exception:
        return False

def start_service_process(svc):
    if svc["type"] == "static":
        return
    s_id = svc["id"]
    if svc["type"] == "tunnel":
        if has_tmux_session():
            run_cmd(["tmux", "kill-window", "-t", "chimp:ngrok-web"])
            run_cmd(["tmux", "kill-window", "-t", "chimp:ngrok-ssh"])
            run_cmd(["tmux", "new-window", "-t", "chimp", "-n", "ngrok-web"])
            run_cmd(["tmux", "send-keys", "-t", "chimp:ngrok-web", f"while true; do termux-chroot $HOME/ngrok http --url=https://{get_tunnel_domain()} 8080; sleep 5; done", "C-m"])
            run_cmd(["tmux", "new-window", "-t", "chimp", "-n", "ngrok-ssh"])
            run_cmd(["tmux", "send-keys", "-t", "chimp:ngrok-ssh", "while true; do termux-chroot $HOME/ngrok tcp 8022; sleep 5; done", "C-m"])
        return

    script = svc.get("script")
    if not script:
        return

    script_path = os.path.join(BASE_DIR, script)
    if s_id == "ai":
        ai_cmd = script_path if os.path.exists(script_path) else os.path.expanduser("~/run_llama.sh")
        if has_tmux_session():
            run_cmd(["tmux", "kill-window", "-t", "chimp:ai"])
            run_cmd(["tmux", "new-window", "-t", "chimp", "-n", "ai"])
            run_cmd(["tmux", "send-keys", "-t", "chimp:ai", f"while true; do {ai_cmd}; sleep 3; done", "C-m"])
        else:
            os.makedirs(LOG_DIR, exist_ok=True)
            log_path = os.path.join(LOG_DIR, "ai.log")
            try:
                subprocess.Popen([ai_cmd], stdout=open(log_path, "a"), stderr=subprocess.STDOUT, start_new_session=True)
            except Exception as e:
                print("Failed to start ai:", e)
        return
    if has_tmux_session():
        run_cmd(["tmux", "kill-window", "-t", f"chimp:{s_id}"])
        run_cmd(["tmux", "new-window", "-t", "chimp", "-n", s_id])
        run_cmd(["tmux", "send-keys", "-t", f"chimp:{s_id}", f"while true; do python {script_path}; sleep 2; done", "C-m"])
    else:
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
    s_id = svc["id"]
    if svc["type"] == "tunnel":
        if has_tmux_session():
            run_cmd(["tmux", "kill-window", "-t", "chimp:ngrok-web"])
            run_cmd(["tmux", "kill-window", "-t", "chimp:ngrok-ssh"])
        run_cmd(["pkill", "-9", "-f", "ngrok"])
        run_cmd(["pkill", "-9", "-f", "proot"])
        return

    script = svc.get("script")
    if not script:
        return
    if s_id == "ai":
        if has_tmux_session():
            run_cmd(["tmux", "kill-window", "-t", "chimp:ai"])
        run_cmd(["pkill", "-9", "-f", "llama-server"])
        return
    if has_tmux_session():
        run_cmd(["tmux", "kill-window", "-t", f"chimp:{s_id}"])
    run_cmd(["pkill", "-9", "-f", script])

PORT_CATALOG = {
    8080: {"name": "Gateway (Nginx)", "desc": "Reverse Proxy & Web Dashboard"},
    8081: {"name": "ChimpDrive", "desc": "Files Cloud Storage Service"},
    8082: {"name": "ChimpDrop", "desc": "Universal Clipboard & Drop"},
    8083: {"name": "ChimpCron", "desc": "Scheduled Automation & Tasks"},
    8090: {"name": "ChimpMonitor", "desc": "Metrics Monitor & Admin API"},
    8091: {"name": "ChimpPix", "desc": "Photo Gallery & EXIF Inspector"},
    8092: {"name": "ChimpAI", "desc": "Local Neural Engine & Assistant"},
    8022: {"name": "SSH Daemon", "desc": "Termux OpenSSH Server"},
    4040: {"name": "Ngrok API", "desc": "Public Web Tunnel Inspector"}
}

def get_port_bindings():
    bindings = []
    for port, meta in PORT_CATALOG.items():
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.12)
        is_open = (s.connect_ex(("127.0.0.1", port)) == 0)
        s.close()
        bindings.append({
            "port": port,
            "name": meta["name"],
            "desc": meta["desc"],
            "open": is_open
        })
    return bindings

def get_tunnel_status_data():
    is_running = bool(run_cmd(["pgrep", "-f", "ngrok http"]).strip())
    state = load_services_state()
    tunnel_cfg = state.get("tunnel", {"enabled": is_running})
    enabled = tunnel_cfg.get("enabled", is_running)
    domain = get_tunnel_domain()
    public_url = get_public_url() if is_running else None
    public_ssh = get_public_ssh() if is_running else None
    port_bindings = get_port_bindings()

    return {
        "enabled": enabled,
        "running": is_running,
        "domain": domain,
        "public_url": public_url,
        "public_ssh": public_ssh,
        "ports": port_bindings
    }

def set_tunnel_state(enabled):
    state = load_services_state()
    state["tunnel"] = {"enabled": bool(enabled)}
    save_services_state(state)

    if enabled:
        if has_tmux_session():
            run_cmd(["tmux", "kill-window", "-t", "chimp:ngrok-web"])
            run_cmd(["tmux", "kill-window", "-t", "chimp:ngrok-ssh"])
            run_cmd(["tmux", "new-window", "-t", "chimp", "-n", "ngrok-web"])
            run_cmd(["tmux", "send-keys", "-t", "chimp:ngrok-web", f"while true; do termux-chroot $HOME/ngrok http --url=https://{get_tunnel_domain()} 8080; sleep 5; done", "C-m"])
            run_cmd(["tmux", "new-window", "-t", "chimp", "-n", "ngrok-ssh"])
            run_cmd(["tmux", "send-keys", "-t", "chimp:ngrok-ssh", "while true; do termux-chroot $HOME/ngrok tcp 8022; sleep 5; done", "C-m"])
        time.sleep(1.0)
    else:
        if has_tmux_session():
            run_cmd(["tmux", "kill-window", "-t", "chimp:ngrok-web"])
            run_cmd(["tmux", "kill-window", "-t", "chimp:ngrok-ssh"])
        run_cmd(["pkill", "-9", "-f", "ngrok"])
        run_cmd(["pkill", "-9", "-f", "proot"])
        time.sleep(0.5)

    return get_tunnel_status_data()

def get_processes_list():
    try:
        out = subprocess.check_output(['ps', 'aux'], text=True, stderr=subprocess.DEVNULL)
        lines = out.strip().splitlines()
    except Exception:
        return []
    
    if not lines:
        return []
    
    procs = []
    my_pid = os.getpid()
    for line in lines[1:]:
        parts = line.split(None, 10)
        if len(parts) < 11:
            continue
        user, pid, cpu, mem, vsz, rss, tty, stat, start, time_str, cmd = parts
        
        cmd_lower = cmd.lower()
        category = "system"
        friendly_name = cmd.split()[0].split('/')[-1]
        
        if "monitor.py" in cmd:
            friendly_name = "ChimpMonitor (API)"
            category = "chimp"
        elif "files/app.py" in cmd:
            friendly_name = "ChimpDrive (Files)"
            category = "chimp"
        elif "drop/app.py" in cmd:
            friendly_name = "ChimpDrop (Clipboard)"
            category = "chimp"
        elif "photos/app.py" in cmd:
            friendly_name = "ChimpPix (Photos)"
            category = "chimp"
        elif "cron/app.py" in cmd:
            friendly_name = "ChimpCron (Scheduler)"
            category = "chimp"
        elif "nginx" in cmd_lower:
            friendly_name = "Nginx Gateway"
            category = "server"
        elif "ngrok http" in cmd_lower:
            friendly_name = "Ngrok Web Tunnel"
            category = "tunnel"
        elif "ngrok tcp" in cmd_lower:
            friendly_name = "Ngrok SSH Tunnel"
            category = "tunnel"
        elif "proot" in cmd_lower:
            friendly_name = "PRoot Sandbox"
            category = "tunnel"
        elif "sshd" in cmd_lower:
            friendly_name = "OpenSSH Daemon"
            category = "server"
        elif "tmux" in cmd_lower:
            friendly_name = "Tmux Master Session"
            category = "system"
        elif cmd.startswith("-bash") or cmd.startswith("bash"):
            friendly_name = "Bash Shell"
            category = "system"
        elif "python" in cmd_lower:
            friendly_name = "Python Process"
            category = "chimp"

        try:
            pid_int = int(pid)
        except ValueError:
            continue

        is_self = (pid_int == my_pid)
        killable = (pid_int > 1) and not is_self

        try:
            cpu_val = float(cpu)
        except ValueError:
            cpu_val = 0.0

        try:
            mem_val = float(mem)
        except ValueError:
            mem_val = 0.0

        try:
            rss_mb = round(int(rss) / 1024.0, 1)
        except ValueError:
            rss_mb = 0.0

        procs.append({
            "pid": pid_int,
            "user": user,
            "cpu": cpu_val,
            "mem": mem_val,
            "rss_mb": rss_mb,
            "stat": stat,
            "time": time_str,
            "command": cmd,
            "name": friendly_name,
            "category": category,
            "is_self": is_self,
            "killable": killable
        })
    
    procs.sort(key=lambda x: (x["cpu"], x["mem"]), reverse=True)
    return procs

def kill_process(pid):
    try:
        pid = int(pid)
    except ValueError:
        return False, "Invalid PID"
        
    my_pid = os.getpid()
    if pid <= 1 or pid == my_pid:
        return False, "Cannot terminate protected system process"
    try:
        os.kill(pid, 9)
        return True, f"Process {pid} terminated successfully"
    except ProcessLookupError:
        return False, f"Process {pid} does not exist"
    except PermissionError:
        return False, f"Permission denied to terminate PID {pid}"
    except Exception as e:
        return False, str(e)

def get_services_catalog():
    state = load_services_state()
    res = []
    for s in SERVICES_DEF:
        s_id = s["id"]
        if s_id == "ai":
            has_ai = os.path.exists(os.path.join(BASE_DIR, "web", "chimpai", "index.html")) or \
                     os.path.exists(os.path.join(BASE_DIR, "run_llama.sh")) or \
                     os.path.exists(os.path.expanduser("~/run_llama.sh"))
            if not has_ai:
                continue
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
        "public_url": get_public_url(),
        "public_ssh": get_public_ssh(),
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
                data = json.dumps({
                    "services": get_services_catalog(),
                    "public_ssh": get_public_ssh(),
                    "public_url": get_public_url()
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self.send_error(500, f"Services catalog error: {e}")
        elif path in ("/api/admin/processes", "/api/monitor/admin/processes"):
            try:
                procs = get_processes_list()
                data = json.dumps({
                    "success": True,
                    "processes": procs,
                    "count": len(procs),
                    "timestamp": int(time.time())
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self.send_error(500, f"Process list error: {e}")
        elif path in ("/api/admin/tunnel", "/api/monitor/admin/tunnel"):
            try:
                status_data = get_tunnel_status_data()
                data = json.dumps({
                    "success": True,
                    "tunnel": status_data
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self.send_error(500, f"Tunnel status error: {e}")
        elif path in ("/api/admin/ports", "/api/monitor/admin/ports"):
            try:
                ports = get_port_bindings()
                data = json.dumps({
                    "success": True,
                    "ports": ports
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self.send_error(500, f"Port bindings error: {e}")
        else:
            self.send_error(404, "Endpoint not found")

    def do_POST(self):
        path = self.path.split("?")[0]
        if path in ("/api/admin/verify", "/api/monitor/admin/verify"):
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
                data = json.loads(body)
                provided_pw = data.get("password", "")
                actual_pw = get_admin_password()
                
                if provided_pw and provided_pw == actual_pw:
                    resp_data = json.dumps({"success": True, "message": "Admin authenticated"}).encode()
                    self.send_response(200)
                else:
                    resp_data = json.dumps({"success": False, "error": "Invalid admin password"}).encode()
                    self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(resp_data)
                return
            except Exception as e:
                self.send_error(500, f"Auth error: {e}")
                return

        elif path in ("/api/admin/processes/kill", "/api/monitor/admin/processes/kill"):
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
                data = json.loads(body)
                provided_pw = data.get("password", "")
                if provided_pw != get_admin_password():
                    resp_data = json.dumps({"success": False, "error": "Admin password required"}).encode()
                    self.send_response(403)
                    self.send_header("Content-Type", "application/json")
                    self.send_cors_headers()
                    self.end_headers()
                    self.wfile.write(resp_data)
                    return

                pid = data.get("pid")
                ok, msg = kill_process(pid)
                resp_data = json.dumps({
                    "success": ok,
                    "message": msg,
                    "processes": get_processes_list() if ok else None
                }).encode()
                self.send_response(200 if ok else 400)
                self.send_header("Content-Type", "application/json")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(resp_data)
                return
            except Exception as e:
                self.send_error(500, f"Error terminating process: {e}")
                return

        elif path in ("/api/admin/tunnel/toggle", "/api/monitor/admin/tunnel/toggle"):
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
                data = json.loads(body)
                provided_pw = data.get("password", "")
                if provided_pw != get_admin_password():
                    resp_data = json.dumps({"success": False, "error": "Admin password required"}).encode()
                    self.send_response(403)
                    self.send_header("Content-Type", "application/json")
                    self.send_cors_headers()
                    self.end_headers()
                    self.wfile.write(resp_data)
                    return

                enabled = data.get("enabled", True)
                tunnel_data = set_tunnel_state(enabled)
                resp_data = json.dumps({
                    "success": True,
                    "tunnel": tunnel_data
                }).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_cors_headers()
                self.end_headers()
                self.wfile.write(resp_data)
                return
            except Exception as e:
                self.send_error(500, f"Error toggling tunnel: {e}")
                return

        elif path in ("/api/services/toggle", "/api/monitor/services/toggle"):
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
                data = json.loads(body)
                
                svc_id = data.get("id") or data.get("service")
                svc = next((s for s in SERVICES_DEF if s["id"] == svc_id), None)
                if not svc:
                    self.send_error(404, "Service not found")
                    return

                state = load_services_state()
                current = state.get(svc_id, {"enabled": True, "show_dashboard": True})

                if "enabled" in data:
                    provided_pw = data.get("password", "")
                    if provided_pw != get_admin_password():
                        resp_data = json.dumps({"success": False, "error": "Admin password required to enable/disable services"}).encode()
                        self.send_response(403)
                        self.send_header("Content-Type", "application/json")
                        self.send_cors_headers()
                        self.end_headers()
                        self.wfile.write(resp_data)
                        return

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

class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True

    def server_bind(self):
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except (AttributeError, OSError):
            pass
        super().server_bind()

if __name__ == "__main__":
    print("Chimp monitoring & service controller running on port 8090", flush=True)
    server = ReusableHTTPServer(("0.0.0.0", 8090), MonitorHandler)
    server.serve_forever()
