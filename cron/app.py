from flask import Flask, render_template, jsonify, request, abort
from pathlib import Path
import subprocess
import threading
import datetime
import time
import json
import os
import uuid

app = Flask(__name__)

BASE_DIR = Path.home() / "server"
DATA_DIR = BASE_DIR / "data/cron"
JOBS_FILE = DATA_DIR / "jobs.json"
HISTORY_FILE = DATA_DIR / "history.json"

DATA_DIR.mkdir(parents=True, exist_ok=True)

# Lock for thread-safe state access
state_lock = threading.Lock()
running_jobs = set()

DEFAULT_JOBS = [
    {
        "id": "job-clean-cache",
        "name": "Disk Cache & Temp Clean",
        "command": "rm -rf /tmp/* ~/.cache/pip/* 2>/dev/null && echo \"Cleaned system cache\"",
        "schedule_type": "interval",
        "schedule_value": "86400",  # every 24 hours
        "schedule_label": "Every 24 hours",
        "enabled": True,
        "timeout": 60,
        "last_run": None,
        "last_status": "idle",
        "last_duration": "0.0s",
        "last_exit_code": None,
        "last_output": "Not run yet"
    },
    {
        "id": "job-sync-photos",
        "name": "Auto-Sync Camera Photos",
        "command": "python ~/server/scripts/backup-photos.py 2>&1",
        "schedule_type": "interval",
        "schedule_value": "14400",  # every 4 hours
        "schedule_label": "Every 4 hours",
        "enabled": True,
        "timeout": 120,
        "last_run": None,
        "last_status": "idle",
        "last_duration": "0.0s",
        "last_exit_code": None,
        "last_output": "Not run yet"
    },
    {
        "id": "job-gateway-ping",
        "name": "Gateway Health Ping",
        "command": "ping -c 2 1.1.1.1 >/dev/null && echo \"Cloudflare 1.1.1.1 Reachable (OK)\" || echo \"Network Unreachable (FAIL)\"",
        "schedule_type": "interval",
        "schedule_value": "900",  # every 15 minutes
        "schedule_label": "Every 15 minutes",
        "enabled": True,
        "timeout": 30,
        "last_run": None,
        "last_status": "idle",
        "last_duration": "0.0s",
        "last_exit_code": None,
        "last_output": "Not run yet"
    }
]

def load_jobs():
    if not JOBS_FILE.exists():
        save_jobs(DEFAULT_JOBS)
        return list(DEFAULT_JOBS)
    try:
        with open(JOBS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return list(DEFAULT_JOBS)

def save_jobs(jobs):
    with open(JOBS_FILE, "w", encoding="utf-8") as f:
        json.dump(jobs, f, indent=2, ensure_ascii=False)

def load_history():
    if not HISTORY_FILE.exists():
        return []
    try:
        with open(HISTORY_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []

def append_history(entry):
    history = load_history()
    history.insert(0, entry)
    history = history[:50]  # retain last 50 runs
    with open(HISTORY_FILE, "w", encoding="utf-8") as f:
        json.dump(history, f, indent=2, ensure_ascii=False)

def execute_job_process(job):
    job_id = job["id"]
    command = job.get("command", "")
    timeout = int(job.get("timeout", 60))

    start_time = time.time()
    timestamp_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    try:
        # Expand user path in bash
        proc = subprocess.run(
            ["bash", "-c", command],
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(Path.home() / "server")
        )
        duration = round(time.time() - start_time, 2)
        exit_code = proc.returncode
        output = (proc.stdout + proc.stderr).strip() or "(No output)"
        status = "success" if exit_code == 0 else "failed"
    except subprocess.TimeoutExpired:
        duration = round(time.time() - start_time, 2)
        exit_code = -1
        output = f"Command timed out after {timeout} seconds"
        status = "failed"
    except Exception as e:
        duration = round(time.time() - start_time, 2)
        exit_code = -1
        output = f"Execution error: {str(e)}"
        status = "failed"

    with state_lock:
        if job_id in running_jobs:
            running_jobs.remove(job_id)

        jobs = load_jobs()
        for j in jobs:
            if j["id"] == job_id:
                j["last_run"] = timestamp_str
                j["last_run_timestamp"] = start_time
                j["last_status"] = status
                j["last_duration"] = f"{duration}s"
                j["last_exit_code"] = exit_code
                j["last_output"] = output[:1000]  # cap stored output
                break
        save_jobs(jobs)

        history_entry = {
            "id": str(uuid.uuid4())[:8],
            "job_id": job_id,
            "job_name": job.get("name", "Unknown Job"),
            "timestamp": timestamp_str,
            "duration": f"{duration}s",
            "exit_code": exit_code,
            "status": status,
            "output": output
        }
        append_history(history_entry)

    return {
        "status": status,
        "exit_code": exit_code,
        "duration": f"{duration}s",
        "output": output,
        "timestamp": timestamp_str
    }

def run_job_async(job):
    job_id = job["id"]
    with state_lock:
        if job_id in running_jobs:
            return False
        running_jobs.add(job_id)

    thread = threading.Thread(target=execute_job_process, args=(job,), daemon=True)
    thread.start()
    return True

def parse_cron_field(field_str, current_val, min_val, max_val):
    field_str = field_str.strip()
    if field_str == "*":
        return True
    if "/" in field_str:
        parts = field_str.split("/")
        step = int(parts[1])
        return (current_val % step) == 0
    if "," in field_str:
        vals = [int(v) for v in field_str.split(",") if v.isdigit()]
        return current_val in vals
    if field_str.isdigit():
        return current_val == int(field_str)
    return False

def is_job_due(job, now_dt):
    if not job.get("enabled", True):
        return False
    if job["id"] in running_jobs:
        return False

    sched_type = job.get("schedule_type", "interval")
    if sched_type in ("manual", "ondemand") or job.get("schedule_label") == "On Demand":
        return False

    now_ts = now_dt.timestamp()
    last_run_ts = job.get("last_run_timestamp", 0)

    if sched_type == "interval":
        interval_secs = int(job.get("schedule_value", 3600))
        if not last_run_ts:
            return False
        return (now_ts - last_run_ts) >= interval_secs

    elif sched_type == "daily":
        target_time = job.get("schedule_value", "03:00")
        current_time = now_dt.strftime("%H:%M")
        if current_time == target_time:
            # Check if it already ran in the last 70 seconds to avoid repeating in the same minute
            return (now_ts - last_run_ts) > 70
        return False

    elif sched_type == "cron":
        expr = job.get("schedule_value", "* * * * *").strip()
        parts = expr.split()
        if len(parts) != 5:
            return False
        m, h, dom, mon, dow = parts
        minute_match = parse_cron_field(m, now_dt.minute, 0, 59)
        hour_match = parse_cron_field(h, now_dt.hour, 0, 23)
        dom_match = parse_cron_field(dom, now_dt.day, 1, 31)
        mon_match = parse_cron_field(mon, now_dt.month, 1, 12)
        dow_match = parse_cron_field(dow, now_dt.weekday(), 0, 6)

        if minute_match and hour_match and dom_match and mon_match and dow_match:
            return (now_ts - last_run_ts) > 70
        return False

    return False

def scheduler_daemon():
    while True:
        try:
            now_dt = datetime.datetime.now()
            jobs = load_jobs()
            for job in jobs:
                if is_job_due(job, now_dt):
                    run_job_async(job)
        except Exception as e:
            print("Scheduler loop error:", e)
        time.sleep(10)

# Start background scheduler daemon
scheduler_thread = threading.Thread(target=scheduler_daemon, daemon=True)
scheduler_thread.start()

# --- Flask Routes ---

@app.after_request
def add_cors(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return response

@app.route("/")
@app.route("/cron")
@app.route("/cron/")
def index():
    return render_template("index.html")

@app.route("/api/jobs", methods=["GET"])
@app.route("/cron/api/jobs", methods=["GET"])
def get_jobs():
    jobs = load_jobs()
    with state_lock:
        running_list = list(running_jobs)

    # Attach live running flag
    for j in jobs:
        j["is_running"] = j["id"] in running_list

    return jsonify({
        "jobs": jobs,
        "running_count": len(running_list),
        "total_jobs": len(jobs)
    })

@app.route("/api/jobs", methods=["POST"])
@app.route("/cron/api/jobs", methods=["POST"])
def create_job():
    data = request.get_json(silent=True) or {}
    name = data.get("name", "").strip()
    command = data.get("command", "").strip()

    if not name or not command:
        return jsonify({"error": "Name and command are required"}), 400

    sched_type = data.get("schedule_type", "interval")
    sched_val = str(data.get("schedule_value", "3600")).strip()
    sched_label = data.get("schedule_label") or f"{sched_type}: {sched_val}"

    job_id = f"job-{str(uuid.uuid4())[:6]}"
    new_job = {
        "id": job_id,
        "name": name,
        "command": command,
        "schedule_type": sched_type,
        "schedule_value": sched_val,
        "schedule_label": sched_label,
        "enabled": bool(data.get("enabled", True)),
        "timeout": int(data.get("timeout", 60)),
        "last_run": None,
        "last_status": "idle",
        "last_duration": "0.0s",
        "last_exit_code": None,
        "last_output": "Not run yet"
    }

    with state_lock:
        jobs = load_jobs()
        jobs.append(new_job)
        save_jobs(jobs)

    return jsonify({"status": "ok", "job": new_job})

@app.route("/api/jobs/<job_id>", methods=["PUT"])
@app.route("/cron/api/jobs/<job_id>", methods=["PUT"])
def update_job(job_id):
    data = request.get_json(silent=True) or {}
    with state_lock:
        jobs = load_jobs()
        target = None
        for j in jobs:
            if j["id"] == job_id:
                target = j
                break
        if not target:
            return jsonify({"error": "Job not found"}), 404

        if "name" in data: target["name"] = data["name"].strip()
        if "command" in data: target["command"] = data["command"].strip()
        if "schedule_type" in data: target["schedule_type"] = data["schedule_type"]
        if "schedule_value" in data: target["schedule_value"] = str(data["schedule_value"]).strip()
        if "schedule_label" in data: target["schedule_label"] = data["schedule_label"]
        if "enabled" in data: target["enabled"] = bool(data["enabled"])
        if "timeout" in data: target["timeout"] = int(data["timeout"])

        save_jobs(jobs)
        return jsonify({"status": "ok", "job": target})

@app.route("/api/jobs/<job_id>", methods=["DELETE"])
@app.route("/cron/api/jobs/<job_id>", methods=["DELETE"])
def delete_job(job_id):
    with state_lock:
        jobs = load_jobs()
        new_jobs = [j for j in jobs if j["id"] != job_id]
        if len(new_jobs) == len(jobs):
            return jsonify({"error": "Job not found"}), 404
        save_jobs(new_jobs)
    return jsonify({"status": "ok"})

@app.route("/api/jobs/<job_id>/run", methods=["POST"])
@app.route("/cron/api/jobs/<job_id>/run", methods=["POST"])
def run_now(job_id):
    jobs = load_jobs()
    job = next((j for j in jobs if j["id"] == job_id), None)
    if not job:
        return jsonify({"error": "Job not found"}), 404

    # Run synchronously to give immediate feedback to user on click
    res = execute_job_process(job)
    return jsonify({"status": "ok", "result": res})

@app.route("/api/jobs/<job_id>/toggle", methods=["POST"])
@app.route("/cron/api/jobs/<job_id>/toggle", methods=["POST"])
def toggle_job(job_id):
    with state_lock:
        jobs = load_jobs()
        target = next((j for j in jobs if j["id"] == job_id), None)
        if not target:
            return jsonify({"error": "Job not found"}), 404
        target["enabled"] = not target.get("enabled", True)
        save_jobs(jobs)
    return jsonify({"status": "ok", "enabled": target["enabled"]})

@app.route("/api/history", methods=["GET"])
@app.route("/cron/api/history", methods=["GET"])
def get_history():
    return jsonify({"history": load_history()})

@app.route("/api/history", methods=["DELETE"])
@app.route("/cron/api/history", methods=["DELETE"])
def clear_history():
    with state_lock:
        with open(HISTORY_FILE, "w", encoding="utf-8") as f:
            json.dump([], f)
    return jsonify({"status": "ok"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8083, debug=False)

