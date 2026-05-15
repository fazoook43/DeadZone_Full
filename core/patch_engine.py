#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any

from apk_patch_engine import ApkPatchEngine
from app_engine import AppEngine
from jar_patch_engine import JarPatchEngine
from overlay_engine import OverlayEngine
from smali_patch_engine import SmaliPatchEngine
from target_resolver import resolve_targets


SAFE_OPS = {
    "remove_path",
    "search_remove_app",
    "move_path",
    "copy_file",
    "copy_tree",
    "set_prop",
    "delete_prop",
    "append_prop_once",
    "replace_xml_bool",
    "remove_oat",
    "inject_app",
    "replace_app",
    "overlay",
    "jar_patch",
    "apk_patch",
    "smali_patch",
}


def load_plan(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def validate_operation(operation: dict[str, Any]) -> list[str]:
    errors = []
    op = operation.get("op")
    if op not in SAFE_OPS:
        errors.append(f"{operation.get('id', 'operation')}: unsupported op {op}")
    if op in {"set_prop", "delete_prop", "append_prop_once"} and not operation.get("target"):
        errors.append(f"{operation.get('id', 'operation')}: prop operation needs a target")
    return errors


def operation_report(operation: dict[str, Any], resolved_targets: dict[str, Any], dry_run: bool) -> dict[str, Any]:
    errors = validate_operation(operation)
    target_id = operation.get("target")
    target = resolved_targets.get(target_id) if target_id else None
    return {
        "id": operation.get("id"),
        "op": operation.get("op"),
        "target": target_id,
        "target_applicable": bool(target and target.get("applicable")),
        "status": "dry-run" if dry_run else "pending",
        "validation_errors": errors,
        "would_mutate": not dry_run and not errors,
    }


def discover_patchpacks(plan: dict[str, Any]) -> list[dict[str, Any]]:
    patchpacks = []
    for pack in plan.get("patchpacks", []):
        pack_path = Path(pack)
        patch_file = pack_path / "patch.yml"
        verify_file = pack_path / "verify.yml"
        patchpacks.append(
            {
                "path": pack,
                "patch_yml": patch_file.exists(),
                "verify_yml": verify_file.exists(),
                "readme": (pack_path / "README.md").exists(),
                "files_dir": (pack_path / "files").exists(),
                "smali_dir": (pack_path / "smali").exists(),
                "overlays_dir": (pack_path / "overlays").exists(),
            }
        )
    return patchpacks


def framework_engine_reports(plan: dict[str, Any], resolved_targets: dict[str, Any], workspace: Path) -> list[dict[str, Any]]:
    reports = []
    jar_engine = JarPatchEngine()
    apk_engine = ApkPatchEngine()
    smali_engine = SmaliPatchEngine()
    patch = {
        "id": "architecture_discovery",
        "type": "framework",
        "targets": list(plan.get("targets", {})),
    }
    for target in resolved_targets.values():
        if target.get("type") == "jar":
            reports.append(jar_engine.dry_run(patch, target, workspace))
        elif target.get("type") == "apk":
            reports.append(apk_engine.dry_run({"id": "architecture_discovery", "type": "apk", "targets": [target["id"]]}, target, workspace))
            reports.append(smali_engine.dry_run({"id": "architecture_discovery", "type": "smali", "targets": [target["id"]]}, target, workspace))
    return reports


def write_text_report(path: str | Path, report: dict[str, Any]) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "DeadZone Patch Engine Dry-Run Report",
        "====================================",
        "",
        f"Device: {report['resolved'].get('device')}",
        f"Platform: {report['resolved'].get('platform')}",
        f"Region: {report['resolved'].get('region')}",
        f"Flavor: {report['resolved'].get('flavor')}",
        f"Patch level: {report['inputs'].get('patch_level')}",
        f"Dry-run: {report['dry_run']}",
        "",
        "Resolved targets:",
    ]
    for target_id, target in report["targets"].items():
        status = "FOUND" if target.get("applicable") else "MISSING"
        lines.append(f"- {target_id}: {status} {target.get('resolved_path') or ''}".rstrip())
    lines.extend(["", "Operations:"])
    for op in report["operations"]:
        errors = "; ".join(op["validation_errors"]) if op["validation_errors"] else "ok"
        lines.append(f"- {op.get('id')}: {op.get('op')} [{errors}]")
    lines.extend(["", "Patchpacks:"])
    for pack in report["patchpacks"]:
        status = "patch.yml" if pack["patch_yml"] else "missing patch.yml"
        lines.append(f"- {pack['path']}: {status}")
    lines.extend(["", "Structural engine checks:"])
    for item in report["engine_reports"]:
        if "applicability" in item:
            app = item["applicability"]
            lines.append(f"- {item['engine']} {item['target']}: {app['reason']}; workspace={item['workspace']['workspace']}")
        else:
            lines.append(f"- {item['engine']} {item.get('operation')}: {item.get('status')}")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def run(plan_path: str | Path, root: str | Path, dry_run: bool, report_path: str | Path) -> dict[str, Any]:
    plan = load_plan(plan_path)
    root_path = Path(root)
    workspace = root_path / ".deadzone_work"
    workspace.mkdir(parents=True, exist_ok=True)
    resolved_targets = resolve_targets(list(plan.get("targets", {})), root_path)

    if not dry_run:
        raise RuntimeError("Only dry-run mode is enabled in the first config-driven architecture pass.")

    app_engine = AppEngine()
    overlay_engine = OverlayEngine()
    operation_reports = [operation_report(operation, resolved_targets, dry_run) for operation in plan.get("operations", [])]
    placeholder_reports = [
        app_engine.dry_run({"id": "inject_app", "op": "inject_app"}, root_path),
        app_engine.dry_run({"id": "replace_app", "op": "replace_app"}, root_path),
        overlay_engine.dry_run({"id": "overlay", "op": "overlay"}, root_path),
    ]

    report = {
        "inputs": plan.get("inputs", {}),
        "resolved": plan.get("resolved", {}),
        "dry_run": dry_run,
        "root": str(root_path),
        "workspace": str(workspace),
        "targets": resolved_targets,
        "operations": operation_reports,
        "patchpacks": discover_patchpacks(plan),
        "engine_reports": framework_engine_reports(plan, resolved_targets, workspace) + placeholder_reports,
        "tooling": {
            "zip_available": shutil.which("zip") is not None,
            "unzip_available": shutil.which("unzip") is not None,
            "apktool_available": shutil.which("apktool") is not None,
            "baksmali_available": shutil.which("baksmali") is not None,
        },
    }
    write_text_report(report_path, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply or dry-run a DeadZone build plan.")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--report", required=True)
    args = parser.parse_args()

    report = run(args.plan, args.root, args.dry_run, args.report)
    print(f"Wrote {args.report}")
    print(json.dumps({"dry_run": report["dry_run"], "targets": len(report["targets"])}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
