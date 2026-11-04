from flask import Flask, render_template, jsonify, request, send_file, abort
from pathlib import Path
from PIL import Image, ImageOps, ExifTags
from io import BytesIO
import os
import mimetypes
import threading
import time
import subprocess

app = Flask(__name__)

BASE = Path.home() / "server"
PHOTO_ROOT = (BASE / "data/photos").resolve()
THUMB_ROOT = BASE / "photos/thumbnails"
ALLOWED = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}

THUMB_ROOT.mkdir(parents=True, exist_ok=True)

# Sync state tracker
sync_state = {
    "running": False,
    "last_run": None,
    "last_result": None,
    "error": None
}

def get_exif_data(path):
    info = {}
    try:
        with Image.open(path) as img:
            info["width"], info["height"] = img.size
            raw_exif = img._getexif()
            if raw_exif:
                for tag, value in raw_exif.items():
                    decoded = ExifTags.TAGS.get(tag, tag)
                    if decoded == "DateTimeOriginal":
                        info["date_taken"] = str(value)
                    elif decoded == "Model":
                        info["camera"] = str(value).strip()
    except Exception:
        pass
    return info

def get_photos():
    photos = []
    if not PHOTO_ROOT.exists():
        return photos

    for path in PHOTO_ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in ALLOWED:
            continue

        try:
            relative = path.relative_to(PHOTO_ROOT).as_posix()
            stat = path.stat()
            photos.append({
                "name": path.name,
                "path": relative,
                "folder": path.parent.relative_to(PHOTO_ROOT).as_posix(),
                "size": stat.st_size,
                "modified": stat.st_mtime
            })
        except OSError:
            continue

    photos.sort(key=lambda x: x["modified"], reverse=True)
    return photos

def safe_photo(relative):
    path = (PHOTO_ROOT / relative).resolve()

    if not path.is_relative_to(PHOTO_ROOT) or not path.is_file():
        abort(404)

    if path.suffix.lower() not in ALLOWED:
        abort(404)

    return path

def thumbnail(relative):
    source = safe_photo(relative)
    # Using relative path string hash for thumb filename
    thumb_name = str(abs(hash(relative))) + ".jpg"
    target = THUMB_ROOT / thumb_name

    if not target.exists() or target.stat().st_mtime < source.stat().st_mtime:
        try:
            with Image.open(source) as image:
                image = ImageOps.exif_transpose(image)
                image.thumbnail((450, 450))
                image.convert("RGB").save(target, "JPEG", quality=85, optimize=True)
        except Exception:
            abort(415)

    return target

@app.after_request
def add_cors_headers(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return response

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/photos")
def api_photos():
    photos = get_photos()
    query = request.args.get("q", "").lower().strip()
    folder = request.args.get("folder", "").strip()

    if query:
        photos = [p for p in photos if query in p["name"].lower()]

    if folder:
        photos = [p for p in photos if p["folder"] == folder]

    all_raw = get_photos()
    folders = sorted(list(set(p["folder"] for p in all_raw if p["folder"] and p["folder"] != ".")))

    for photo in photos:
        photo["thumbnail"] = "/photos/thumb/" + photo["path"]
        photo["url"] = "/photos/photo/" + photo["path"]

    return jsonify({
        "count": len(photos),
        "folders": folders,
        "photos": photos
    })

@app.route("/thumb/<path:relative>")
def serve_thumbnail(relative):
    return send_file(thumbnail(relative), mimetype="image/jpeg", max_age=86400)

@app.route("/photo/<path:relative>")
def serve_photo(relative):
    path = safe_photo(relative)
    download = request.args.get("download", "0") == "1"
    mimetype = mimetypes.guess_type(path)[0] or "application/octet-stream"
    return send_file(
        path,
        mimetype=mimetype,
        as_attachment=download,
        download_name=path.name if download else None,
        max_age=86400
    )

@app.route("/api/photo/info/<path:relative>")
def photo_info(relative):
    path = safe_photo(relative)
    exif = get_exif_data(path)
    stat = path.stat()
    return jsonify({
        "name": path.name,
        "path": relative,
        "size": stat.st_size,
        "modified": stat.st_mtime,
        "exif": exif
    })

@app.route("/api/photo/delete/<path:relative>", methods=["DELETE", "POST"])
def delete_photo(relative):
    path = safe_photo(relative)
    try:
        # Delete thumbnail if exists
        thumb_name = str(abs(hash(relative))) + ".jpg"
        (THUMB_ROOT / thumb_name).unlink(missing_ok=True)
        # Delete source
        path.unlink()
        return jsonify({"success": True, "deleted": relative})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/upload", methods=["POST"])
def upload():
    files = request.files.getlist("files")
    if not files:
        return jsonify({"error": "No files selected"}), 400

    destination = PHOTO_ROOT / "Uploads"
    destination.mkdir(parents=True, exist_ok=True)
    saved = 0

    for file in files:
        name = Path(file.filename or "").name
        if not name or Path(name).suffix.lower() not in ALLOWED:
            continue

        target = destination / name
        if target.exists():
            stem, suffix = target.stem, target.suffix
            number = 1
            while target.exists():
                target = destination / f"{stem}_{number}{suffix}"
                number += 1

        file.save(target)
        saved += 1

    return jsonify({"saved": saved})

def run_backup_sync():
    global sync_state
    sync_state["running"] = True
    sync_state["error"] = None
    script_path = BASE / "scripts/backup-photos.py"
    try:
        res = subprocess.run(
            ["python", str(script_path)],
            capture_output=True,
            text=True,
            timeout=300
        )
        sync_state["last_result"] = res.stdout
        sync_state["last_run"] = time.time()
        if res.returncode != 0:
            sync_state["error"] = res.stderr
    except Exception as e:
        sync_state["error"] = str(e)
    finally:
        sync_state["running"] = False

@app.route("/api/sync", methods=["POST"])
def trigger_sync():
    global sync_state
    if sync_state["running"]:
        return jsonify({"status": "already_running"}), 409

    t = threading.Thread(target=run_backup_sync, daemon=True)
    t.start()
    return jsonify({"status": "started"})

@app.route("/api/sync/status")
def sync_status():
    return jsonify(sync_state)

@app.route("/api/status")
def status():
    photos = get_photos()
    return jsonify({
        "photo_count": len(photos),
        "library": str(PHOTO_ROOT),
        "sync": sync_state
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8091, debug=False)
