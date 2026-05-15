#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from target_resolver import REPO_ROOT, dump_json, load_target_registry, load_yaml


REGION_CODES = {
    "CNXM": "china",
    "MIXM": "global",
    "INXM": "india",
    "EUXM": "europe",
    "RUXM": "russia",
    "TWXM": "taiwan",
    "TRXM": "turkey",
    "IDXM": "indonesia",
}


def load_named_config(folder: str, config_id: str) -> dict[str, Any]:
    path = REPO_ROOT / folder / f"{config_id}.yml"
    if not path.exists():
        raise FileNotFoundError(f"Missing {folder} config: {path}")
    data = load_yaml(path)
    data["_path"] = str(path.relative_to(REPO_ROOT))
    return data


def detect_region(rom_url: str, requested: str, device_config: dict[str, Any]) -> str:
    if requested and requested != "auto":
        return requested
    for code, region in REGION_CODES.items():
        if code in rom_url.upper():
            return region
    return device_config.get("default_region", "global")


def detect_platform(rom_url: str, requested: str, device_config: dict[str, Any]) -> str:
    if requested and requested != "auto":
        return requested
    upper = rom_url.upper()
    if "OS3." in upper or re.search(r"\b3\.0\.", upper):
        return "hyperos3"
    if "OS2." in upper or re.search(r"\b2\.0\.", upper):
        return "hyperos2"
    if "OS1." in upper or re.search(r"\b1\.0\.", upper):
        return "hyperos1"
    if "MIUI" in upper:
        return "miui"
    return device_config.get("default_platform", "hyperos3")


def find_flavor(flavor: str, version: str) -> dict[str, Any]:
    candidates = sorted((REPO_ROOT / "flavors").glob("*.yml"))
    for path in candidates:
        data = load_yaml(path)
        names = {data.get("id"), *(data.get("aliases") or [])}
        expected = f"{flavor}_{version.upper()}" if not flavor.lower().endswith(version.lower()) else flavor
        if flavor in names or expected in names or data.get("id") == expected:
            data["_path"] = str(path.relative_to(REPO_ROOT))
            return data
    raise FileNotFoundError(f"Missing flavor config for {flavor} {version}")


def unique(items: list[str]) -> list[str]:
    seen = set()
    result = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def target_ids_for_patchpacks(patchpacks: list[str], registry: dict[str, dict[str, Any]]) -> list[str]:
    ids = []
    for target_id, target in registry.items():
        target_type = target.get("type")
        if target_type in ("jar", "apk", "overlay", "prop"):
            ids.append(target_id)
    return ids


def build_plan(args: argparse.Namespace) -> dict[str, Any]:
    device = load_named_config("devices", args.device)
    platform_id = detect_platform(args.rom_url, args.platform, device)
    region_id = detect_region(args.rom_url, args.region, device)
    platform = load_named_config("platforms", platform_id)
    region = load_named_config("regions", region_id)
    soc = load_named_config("soc", device.get("soc", "mediatek"))
    flavor = find_flavor(args.flavor, args.version)
    registry = load_target_registry()

    flavor_level = (flavor.get("patch_levels") or {}).get(args.patch_level, {})
    patchpacks = unique((platform.get("patchpacks") or []) + (flavor_level.get("patchpacks") or []))
    operations = flavor.get("operations") or []
    target_ids = unique((soc.get("default_targets") or []) + target_ids_for_patchpacks(patchpacks, registry))

    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "inputs": {
            "device": args.device,
            "rom_url": args.rom_url,
            "flavor": args.flavor,
            "version": args.version,
            "platform": args.platform,
            "region": args.region,
            "patch_level": args.patch_level,
        },
        "resolved": {
            "device": device.get("id"),
            "soc": soc.get("id"),
            "platform": platform.get("id"),
            "region": region.get("id"),
            "flavor": flavor.get("id"),
            "version": flavor.get("version", args.version),
        },
        "layers": [
            device.get("_path"),
            soc.get("_path"),
            platform.get("_path"),
            region.get("_path"),
            flavor.get("_path"),
            "device_quirks",
        ],
        "compatibility": {
            "legacy_build_flow_untouched": True,
            "vbmeta_mode": (device.get("quirks") or {}).get("vbmeta_mode", 3),
            "fastboot_slot_mode": (device.get("quirks") or {}).get("fastboot_slot_mode"),
            "legacy_conf": (device.get("compatibility") or {}).get("legacy_conf"),
        },
        "patchpacks": patchpacks,
        "targets": {
            target_id: registry[target_id]
            for target_id in target_ids
            if target_id in registry
        },
        "operations": operations,
        "notes": [
            "This plan is non-destructive and does not alter the legacy shell build path.",
            "JAR/APK/smali patchpacks are discovery-only placeholders in this architecture pass.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a config-driven DeadZone ROM patch plan.")
    parser.add_argument("--device", required=True)
    parser.add_argument("--rom-url", required=True)
    parser.add_argument("--flavor", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--platform", default="auto")
    parser.add_argument("--region", default="auto")
    parser.add_argument("--patch-level", default="safe", choices=("none", "safe", "full"))
    parser.add_argument("--out", default="output/build_plan.json")
    args = parser.parse_args()

    plan = build_plan(args)
    dump_json(plan, args.out)
    print(f"Wrote {args.out}")
    print(json.dumps(plan["resolved"], indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
