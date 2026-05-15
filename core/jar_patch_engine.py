#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from typing import Any


class JarPatchEngine:
    engine_type = "jar"

    def validate_patch(self, patch: dict[str, Any]) -> list[str]:
        errors = []
        if patch.get("type") not in (None, "jar", "framework"):
            errors.append(f"{patch.get('id', 'patch')}: expected jar/framework patch type")
        if not patch.get("targets"):
            errors.append(f"{patch.get('id', 'patch')}: missing targets")
        return errors

    def prepare_workspace(self, target: dict[str, Any], workspace: str | Path) -> dict[str, Any]:
        path = Path(workspace) / "jar" / target["id"]
        path.mkdir(parents=True, exist_ok=True)
        return {"workspace": str(path), "prepared": True}

    def applicability(self, target: dict[str, Any]) -> dict[str, Any]:
        return {
            "target": target["id"],
            "type": self.engine_type,
            "applicable": bool(target.get("applicable")),
            "reason": "target resolved" if target.get("applicable") else "target file not found",
        }

    def dry_run(self, patch: dict[str, Any], target: dict[str, Any], workspace: str | Path) -> dict[str, Any]:
        return {
            "patch": patch.get("id"),
            "target": target["id"],
            "engine": self.engine_type,
            "validation_errors": self.validate_patch(patch),
            "applicability": self.applicability(target),
            "workspace": self.prepare_workspace(target, workspace),
            "mutates": False,
        }
