from pathlib import Path

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
    p = Path(file)
    text = p.read_text(encoding="utf-8", errors="replace")
    text = text.replace("\r\n", "\n").replace("\r", "\n")

    lines = text.split("\n")

    # Force a real Git diff safely.
    marker = "LF normalized for GitHub raw"
    if file.endswith(".yml"):
        if not lines[0].startswith("# " + marker):
            lines.insert(0, "# " + marker)
    elif file.endswith(".sh"):
        if lines and lines[0].startswith("#!"):
            if len(lines) < 2 or marker not in lines[1]:
                lines.insert(1, "# " + marker)
        else:
            if not lines[0].startswith("# " + marker):
                lines.insert(0, "# " + marker)
    elif file.endswith(".conf"):
        if not lines[0].startswith("# " + marker):
            lines.insert(0, "# " + marker)

    p.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8", newline="\n")
    print(file, "lines:", len(lines))