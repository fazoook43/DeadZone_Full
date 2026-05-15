#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]


def _strip_comment(line: str) -> str:
    in_quote = False
    quote = ""
    out = []
    for char in line:
        if char in ("'", '"'):
            if not in_quote:
                in_quote = True
                quote = char
            elif quote == char:
                in_quote = False
        if char == "#" and not in_quote:
            break
        out.append(char)
    return "".join(out).rstrip()


def _scalar(value: str) -> Any:
    value = value.strip()
    if value == "":
        return ""
    if value in ("true", "True"):
        return True
    if value in ("false", "False"):
        return False
    if value in ("null", "None", "~"):
        return None
    if value == "[]":
        return []
    if value == "{}":
        return {}
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        return [_scalar(part.strip()) for part in inner.split(",")]
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    try:
        return int(value)
    except ValueError:
        return value


def _prepare_lines(text: str) -> list[tuple[int, str]]:
    lines: list[tuple[int, str]] = []
    for raw in text.splitlines():
        stripped = _strip_comment(raw)
        if not stripped.strip():
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        lines.append((indent, stripped.strip()))
    return lines


def _parse_block(lines: list[tuple[int, str]], index: int, indent: int) -> tuple[Any, int]:
    if index >= len(lines):
        return {}, index
    current_indent, content = lines[index]
    if current_indent < indent:
        return {}, index
    if content.startswith("- "):
        items = []
        while index < len(lines):
            current_indent, content = lines[index]
            if current_indent != indent or not content.startswith("- "):
                break
            item_text = content[2:].strip()
            index += 1
            if not item_text:
                item, index = _parse_block(lines, index, indent + 2)
                items.append(item)
                continue
            if ":" in item_text:
                key, value = item_text.split(":", 1)
                item: dict[str, Any] = {key.strip(): _scalar(value)}
                if value.strip() == "":
                    nested, index = _parse_block(lines, index, indent + 2)
                    item[key.strip()] = nested
                while index < len(lines) and lines[index][0] > indent:
                    nested, index = _parse_block(lines, index, lines[index][0])
                    if isinstance(nested, dict):
                        item.update(nested)
                    else:
                        item.setdefault("_items", []).extend(nested if isinstance(nested, list) else [nested])
                items.append(item)
            else:
                items.append(_scalar(item_text))
        return items, index

    mapping: dict[str, Any] = {}
    while index < len(lines):
        current_indent, content = lines[index]
        if current_indent != indent or content.startswith("- "):
            break
        key, value = content.split(":", 1)
        key = key.strip()
        value = value.strip()
        index += 1
        if value:
            mapping[key] = _scalar(value)
        else:
            nested, index = _parse_block(lines, index, indent + 2)
            mapping[key] = nested
    return mapping, index


def load_yaml(path: str | Path) -> Any:
    path = Path(path)
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore

        return yaml.safe_load(text) or {}
    except Exception:
        lines = _prepare_lines(text)
        parsed, _ = _parse_block(lines, 0, lines[0][0] if lines else 0)
        return parsed


def dump_json(data: Any, path: str | Path) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_target_registry(root: Path = REPO_ROOT) -> dict[str, dict[str, Any]]:
    registry: dict[str, dict[str, Any]] = {}
    for file_name in ("framework_targets.yml", "app_targets.yml", "overlay_targets.yml", "prop_targets.yml"):
        data = load_yaml(root / "targets" / file_name)
        for target in data.get("targets", []):
            validate_target(target, file_name)
            registry[target["id"]] = target
    return registry


def validate_target(target: dict[str, Any], source: str = "registry") -> None:
    required = ("id", "type", "partition", "candidate_paths")
    missing = [field for field in required if field not in target]
    if missing:
        raise ValueError(f"{source}: target missing required fields: {', '.join(missing)}")
    if not isinstance(target["candidate_paths"], list) or not target["candidate_paths"]:
        raise ValueError(f"{source}: target {target.get('id')} needs non-empty candidate_paths")


def resolve_target(target: dict[str, Any], root: str | Path) -> dict[str, Any]:
    root_path = Path(root)
    candidates = []
    resolved = None
    for relative in target.get("candidate_paths", []):
        candidate = root_path / relative
        exists = candidate.exists()
        candidates.append({"path": relative, "exists": exists})
        if exists and resolved is None:
            resolved = relative
    return {
        "id": target["id"],
        "name": target.get("name", target["id"]),
        "type": target["type"],
        "partition": target["partition"],
        "resolved_path": resolved,
        "candidates": candidates,
        "applicable": resolved is not None,
    }


def resolve_targets(target_ids: list[str], root: str | Path, registry: dict[str, dict[str, Any]] | None = None) -> dict[str, Any]:
    registry = registry or load_target_registry()
    results = {}
    for target_id in target_ids:
        if target_id not in registry:
            results[target_id] = {"id": target_id, "applicable": False, "error": "target is not registered"}
            continue
        results[target_id] = resolve_target(registry[target_id], root)
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve DeadZone target registry entries against an extracted root.")
    parser.add_argument("--root", required=True)
    parser.add_argument("--targets", nargs="*", default=[])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    registry = load_target_registry()
    target_ids = args.targets or list(registry)
    results = resolve_targets(target_ids, args.root, registry)
    if args.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        for target_id, result in results.items():
            status = "found" if result.get("applicable") else "missing"
            print(f"{target_id}: {status} {result.get('resolved_path') or ''}".rstrip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
