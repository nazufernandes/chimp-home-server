from flask import Flask, render_template, jsonify, request, send_file, abort, send_from_directory
from pathlib import Path
import os
import shutil
import mimetypes
import zipfile
import io

app = Flask(__name__)

# Dedicated root folder strictly confined for ChimpDrive
CHIMPDRIVE_ROOT = (Path.home() / "ChimpDrive").resolve()
CHIMPDRIVE_ROOT.mkdir(parents=True, exist_ok=True)

def is_system_file(name: str) -> bool:
    """Return True if the name corresponds to a hidden or system file/folder."""
    if not name:
        return False
    # Hidden files / dotfiles (e.g. .bashrc, .git, .env, .trashed-*, .DS_Store)
    if name.startswith("."):
        return True
    lower = name.lower()
    # System & runtime directories / caches
    if lower in {
        "__pycache__",
        "lost+found",
        "thumbs.db",
        "desktop.ini",
        "$recycle.bin",
        "system volume information",
        ".ds_store",
        "node_modules"
    }:
        return True
    if lower.endswith(".pyc") or lower.endswith(".pyo"):
        return True
    return False

def get_real_path(rel_path):
    rel_path = (rel_path or "").strip().lstrip("/")
    target = (CHIMPDRIVE_ROOT / rel_path).resolve()
    # Jail check: must remain inside CHIMPDRIVE_ROOT
    if target != CHIMPDRIVE_ROOT and not target.is_relative_to(CHIMPDRIVE_ROOT):
        abort(403)
    # Check that no path component inside relative parts is a hidden/system file
    try:
        rel_parts = target.relative_to(CHIMPDRIVE_ROOT).parts
        if any(is_system_file(p) for p in rel_parts):
            abort(403)
    except ValueError:
        abort(403)
    return target

def format_size(bytes_val):
    if bytes_val >= 1073741824:
        return f"{bytes_val / 1073741824:.2f} GB"
    elif bytes_val >= 1048576:
        return f"{bytes_val / 1048576:.2f} MB"
    elif bytes_val >= 1024:
        return f"{bytes_val / 1024:.1f} KB"
    return f"{bytes_val} B"

def get_file_type(path):
    if path.is_dir():
        return "folder"
    ext = path.suffix.lower()
    if ext in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".svg"}:
        return "image"
    if ext in {".mp4", ".mkv", ".webm", ".mov", ".3gp"}:
        return "video"
    if ext in {".mp3", ".wav", ".ogg", ".flac", ".m4a"}:
        return "audio"
    if ext in {".pdf"}:
        return "pdf"
    if ext in {".zip", ".tar", ".gz", ".rar", ".7z"}:
        return "archive"
    if ext in {".txt", ".py", ".sh", ".json", ".html", ".css", ".js", ".md", ".log", ".yaml", ".yml", ".xml", ".ini", ".conf"}:
        return "text"
    return "file"

@app.after_request
def add_cors_headers(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return response

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/files")
def list_files():
    rel = request.args.get("path", "").strip()
    target = get_real_path(rel)

    if not target.exists():
        return jsonify({"error": "Path does not exist"}), 404
    if not target.is_dir():
        return jsonify({"error": "Path is not a directory"}), 400

    items = []
    try:
        with os.scandir(target) as entries:
            for entry in entries:
                # Strictly filter out system and hidden files
                if is_system_file(entry.name):
                    continue
                try:
                    stat = entry.stat()
                    is_dir = entry.is_dir()
                    item_type = "folder" if is_dir else get_file_type(Path(entry.path))
                    items.append({
                        "name": entry.name,
                        "is_dir": is_dir,
                        "type": item_type,
                        "size": stat.st_size if not is_dir else 0,
                        "size_str": format_size(stat.st_size) if not is_dir else "--",
                        "modified": stat.st_mtime,
                        "ext": Path(entry.name).suffix.lower()
                    })
                except (PermissionError, OSError):
                    continue
    except PermissionError:
        return jsonify({"error": "Permission denied"}), 403

    # Sort: directories first, then alphabetical
    items.sort(key=lambda x: (not x["is_dir"], x["name"].lower()))

    # Build breadcrumb segments
    crumbs = []
    parts = [p for p in rel.split("/") if p]
    accum = ""
    for p in parts:
        accum = f"{accum}/{p}" if accum else p
        crumbs.append({"name": p, "path": accum})

    return jsonify({
        "current_path": rel,
        "breadcrumbs": crumbs,
        "items": items,
        "count": len(items)
    })

@app.route("/api/file/raw")
def get_raw_file():
    rel = request.args.get("path", "").strip()
    target = get_real_path(rel)
    if not target.is_file():
        abort(404)

    download = request.args.get("download", "0") == "1"
    mimetype = mimetypes.guess_type(target)[0] or "application/octet-stream"
    return send_file(
        target,
        mimetype=mimetype,
        as_attachment=download,
        download_name=target.name if download else None
    )

@app.route("/api/file/content")
def get_file_content():
    rel = request.args.get("path", "").strip()
    target = get_real_path(rel)
    if not target.is_file():
        return jsonify({"error": "File not found"}), 404

    # Limit editable text to 2MB
    if target.stat().st_size > 2 * 1024 * 1024:
        return jsonify({"error": "File is too large to preview (>2MB)"}), 400

    try:
        with open(target, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        return jsonify({
            "name": target.name,
            "path": rel,
            "size": target.stat().st_size,
            "content": content
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/file/save", methods=["POST"])
def save_file_content():
    data = request.get_json() or {}
    rel = data.get("path", "").strip()
    content = data.get("content", "")
    target = get_real_path(rel)

    if not target.is_file():
        return jsonify({"error": "Target is not a valid file"}), 404

    try:
        with open(target, "w", encoding="utf-8") as f:
            f.write(content)
        return jsonify({"success": True})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/upload", methods=["POST"])
def upload_files():
    rel = request.form.get("path", "").strip()
    target_dir = get_real_path(rel)
    if not target_dir.is_dir():
        return jsonify({"error": "Target directory not found"}), 404

    files = request.files.getlist("files")
    if not files:
        return jsonify({"error": "No files provided"}), 400

    saved_count = 0
    for f in files:
        if not f.filename:
            continue
        fname = Path(f.filename).name
        # Never save hidden or system files
        if is_system_file(fname):
            continue
        dest = target_dir / fname
        f.save(dest)
        saved_count += 1

    return jsonify({"success": True, "saved": saved_count})

@app.route("/api/folder/create", methods=["POST"])
def create_folder():
    data = request.get_json() or {}
    rel = data.get("path", "").strip()
    name = (data.get("name", "")).strip()

    if not name or "/" in name or "\\" in name or is_system_file(name):
        return jsonify({"error": "Invalid folder name"}), 400

    parent = get_real_path(rel)
    new_dir = parent / name
    if new_dir.exists():
        return jsonify({"error": "Folder already exists"}), 409

    try:
        new_dir.mkdir(parents=True, exist_ok=True)
        return jsonify({"success": True})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/item/delete", methods=["POST"])
def delete_item():
    data = request.get_json() or {}
    rel = data.get("path", "").strip()
    if not rel:
        return jsonify({"error": "Cannot delete home directory"}), 400

    target = get_real_path(rel)
    if target == CHIMPDRIVE_ROOT:
        return jsonify({"error": "Cannot delete home directory"}), 400

    if not target.exists():
        return jsonify({"error": "Item not found"}), 404

    try:
        if target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink()
        return jsonify({"success": True})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/item/rename", methods=["POST"])
def rename_item():
    data = request.get_json() or {}
    rel = data.get("path", "").strip()
    new_name = (data.get("new_name", "")).strip()

    if not rel:
        return jsonify({"error": "Cannot rename home directory"}), 400
    if not new_name or "/" in new_name or "\\" in new_name or is_system_file(new_name):
        return jsonify({"error": "Invalid target name"}), 400

    target = get_real_path(rel)
    if target == CHIMPDRIVE_ROOT:
        return jsonify({"error": "Cannot rename home directory"}), 400
    if not target.exists():
        return jsonify({"error": "Item not found"}), 404

    dest = target.parent / new_name
    if dest.exists():
        return jsonify({"error": "Destination name already exists"}), 409

    try:
        target.rename(dest)
        return jsonify({"success": True})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/zip")
def download_zip():
    rel = request.args.get("path", "").strip()
    target = get_real_path(rel)

    if not target.is_dir():
        abort(404)

    memory_file = io.BytesIO()
    with zipfile.ZipFile(memory_file, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, dirs, files in os.walk(target):
            # Exclude hidden and system dirs in-place to avoid traversing them
            dirs[:] = [d for d in dirs if not is_system_file(d)]
            for file in files:
                if is_system_file(file):
                    continue
                filepath = Path(root) / file
                arcname = filepath.relative_to(target)
                zf.write(filepath, arcname)

    memory_file.seek(0)
    zip_name = f"{target.name if target != CHIMPDRIVE_ROOT else 'ChimpDrive'}.zip"
    return send_file(
        memory_file,
        mimetype="application/zip",
        as_attachment=True,
        download_name=zip_name
    )

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8081, debug=False)
