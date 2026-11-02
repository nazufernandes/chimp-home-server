import os
import shutil
from pathlib import Path

SOURCE = Path.home() / "storage"
DEST = Path.home() / "server/data/photos/Phone"

FOLDERS = {
    "dcim/Camera": "Camera",
    "pictures/Screenshots": "Screenshots",
}

EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".webp",
    ".heic", ".heif", ".gif", ".bmp",
    ".dng", ".mp4", ".mov", ".3gp", ".mkv"
}

copied = 0
skipped = 0
failed = 0

for source_folder, destination_folder in FOLDERS.items():
    source = SOURCE / source_folder
    destination = DEST / destination_folder

    if not source.is_dir():
        print(f"Not found: {source}")
        continue

    print(f"\nScanning: {source}")

    for root, _, files in os.walk(source):
        for filename in files:
            src = Path(root) / filename

            if src.suffix.lower() not in EXTENSIONS:
                continue

            relative = src.relative_to(source)
            target = destination / relative

            try:
                if target.exists():
                    skipped += 1
                    continue

                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, target)

                if target.stat().st_size != src.stat().st_size:
                    target.unlink(missing_ok=True)
                    raise IOError("File size verification failed")

                copied += 1
                print(f"Copied: {relative}")

            except Exception as error:
                failed += 1
                print(f"Failed: {src} — {error}")

print("\n=== BACKUP SUMMARY ===")
print(f"Copied:  {copied}")
print(f"Skipped: {skipped}")
print(f"Failed:  {failed}")
