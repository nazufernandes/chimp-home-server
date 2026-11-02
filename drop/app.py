from flask import Flask, render_template, jsonify, request, send_from_directory, abort
from pathlib import Path
from werkzeug.utils import secure_filename
import json
import time
import os
import uuid
import re

app = Flask(__name__)

BASE_DIR = Path.home() / "server"
DATA_DIR = BASE_DIR / "data/drop"
FILES_DIR = DATA_DIR / "files"
CLIPS_FILE = DATA_DIR / "clips.json"

FILES_DIR.mkdir(parents=True, exist_ok=True)

def load_clips():
    if not CLIPS_FILE.exists():
        return []
    try:
        with open(CLIPS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return []

def save_clips(clips):
    with open(CLIPS_FILE, "w", encoding="utf-8") as f:
        json.dump(clips, f, indent=2, ensure_ascii=False)

def format_size(bytes_val):
    if bytes_val >= 1073741824:
        return f"{bytes_val / 1073741824:.2f} GB"
    elif bytes_val >= 1048576:
        return f"{bytes_val / 1048576:.2f} MB"
    elif bytes_val >= 1024:
        return f"{bytes_val / 1024:.1f} KB"
    return f"{bytes_val} B"

def detect_type(content):
    content_stripped = content.strip()
    if re.match(r"^https?://[^\s]+$", content_stripped, re.IGNORECASE):
        return "url"
    if "\n" in content and any(kw in content for kw in ["def ", "class ", "import ", "function", "const ", "let ", "var ", "{", "}", "#!/"]):
        return "code"
    return "text"

@app.after_request
def add_cors_headers(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return response

# Support both root and /drop prefix
@app.route("/")
@app.route("/drop")
@app.route("/drop/")
def index():
    return render_template("index.html")

@app.route("/api/clips", methods=["GET"])
@app.route("/drop/api/clips", methods=["GET"])
def get_clips():
    clips = load_clips()
    # Sort: pinned first, then newest first
    clips.sort(key=lambda x: (not x.get("pinned", False), -x.get("created_at", 0)))
    return jsonify({"clips": clips})

@app.route("/api/clips", methods=["POST"])
@app.route("/drop/api/clips", methods=["POST"])
def add_clip():
    data = request.get_json(silent=True) or {}
    content = data.get("content", "").strip()
    if not content:
        return jsonify({"error": "Empty content"}), 400

    clip_type = data.get("type") or detect_type(content)
    clip_id = str(uuid.uuid4())[:8]

    new_clip = {
        "id": clip_id,
        "type": clip_type,
        "content": content,
        "created_at": time.time(),
        "created_str": time.strftime("%b %d, %H:%M"),
        "pinned": False
    }

    clips = load_clips()
    clips.insert(0, new_clip)
    save_clips(clips)

    return jsonify({"status": "ok", "clip": new_clip})

@app.route("/api/upload", methods=["POST"])
@app.route("/drop/api/upload", methods=["POST"])
def upload_file():
    if "file" not in request.files:
        return jsonify({"error": "No file part"}), 400

    file = request.files["file"]
    if not file or not file.filename:
        return jsonify({"error": "No selected file"}), 400

    original_name = file.filename
    clean_name = secure_filename(original_name) or "dropped_file"
    unique_prefix = str(uuid.uuid4())[:8]
    stored_name = f"{unique_prefix}_{clean_name}"
    target_path = FILES_DIR / stored_name

    file.save(target_path)
    file_size = target_path.stat().st_size

    ext = target_path.suffix.lower()
    is_image = ext in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".svg"}
    clip_type = "image" if is_image else "file"

    clip_id = str(uuid.uuid4())[:8]
    new_clip = {
        "id": clip_id,
        "type": clip_type,
        "content": original_name,
        "filename": stored_name,
        "original_name": original_name,
        "size": file_size,
        "size_str": format_size(file_size),
        "is_image": is_image,
        "created_at": time.time(),
        "created_str": time.strftime("%b %d, %H:%M"),
        "pinned": False
    }

    clips = load_clips()
    clips.insert(0, new_clip)
    save_clips(clips)

    return jsonify({"status": "ok", "clip": new_clip})

@app.route("/api/file/<filename>")
@app.route("/drop/api/file/<filename>")
def download_file(filename):
    clean = secure_filename(filename)
    as_attachment = request.args.get("download", "0") == "1"
    original = request.args.get("name")
    return send_from_directory(
        FILES_DIR,
        clean,
        as_attachment=as_attachment,
        download_name=original
    )

@app.route("/api/clips/<clip_id>/pin", methods=["POST"])
@app.route("/drop/api/clips/<clip_id>/pin", methods=["POST"])
def toggle_pin(clip_id):
    clips = load_clips()
    found = False
    new_pinned = False
    for c in clips:
        if c["id"] == clip_id:
            c["pinned"] = not c.get("pinned", False)
            new_pinned = c["pinned"]
            found = True
            break
    if not found:
        return jsonify({"error": "Not found"}), 404
    save_clips(clips)
    return jsonify({"status": "ok", "pinned": new_pinned})

@app.route("/api/clips/<clip_id>", methods=["DELETE"])
@app.route("/drop/api/clips/<clip_id>", methods=["DELETE"])
def delete_clip(clip_id):
    clips = load_clips()
    new_clips = []
    for c in clips:
        if c["id"] == clip_id:
            # Delete stored file if exists
            if c.get("filename"):
                file_path = FILES_DIR / c["filename"]
                if file_path.exists():
                    try:
                        file_path.unlink()
                    except Exception:
                        pass
        else:
            new_clips.append(c)

    save_clips(new_clips)
    return jsonify({"status": "ok"})

@app.route("/api/clear", methods=["POST"])
@app.route("/drop/api/clear", methods=["POST"])
def clear_unpinned():
    clips = load_clips()
    kept = []
    for c in clips:
        if c.get("pinned", False):
            kept.append(c)
        else:
            if c.get("filename"):
                file_path = FILES_DIR / c["filename"]
                if file_path.exists():
                    try:
                        file_path.unlink()
                    except Exception:
                        pass
    save_clips(kept)
    return jsonify({"status": "ok", "cleared": len(clips) - len(kept)})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8082, debug=False)
