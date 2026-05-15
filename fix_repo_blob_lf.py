from pathlib import Path
import subprocess

files = [
    ".github/workflows/build.yml",
    "main.sh",
    "core/package_fastboot.sh",
    "core/vbmeta_patch.sh",
    "core/repacker.sh",
    "core/validate_build.sh",
    "core/upload_release.sh",
    "core/setup_tools.sh",
    "core/collect_images.sh",
    "core/fs_detect.sh",
    "core/unpacker.sh",
    "core/utils.sh",
    "devices/zircon.conf",
    "devices/template.conf",
]

for file in files:
    # اقرأ نسخة Git نفسها raw من آخر commit
    data = subprocess.check_output(["git", "show", f"HEAD:{file}"])

    before_lf = data.count(b"\n")
    before_cr = data.count(b"\r")

    # حوّل CRLF و CR-only إلى LF حقيقي
    data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")

    after_lf = data.count(b"\n")
    after_cr = data.count(b"\r")

    Path(file).write_bytes(data)

    print(f"{file}: before LF={before_lf} CR={before_cr} -> after LF={after_lf} CR={after_cr}")