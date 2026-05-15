#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from typing import Any


class OverlayEngine:
    engine_type = "overlay"

    def dry_run(self, operation: dict[str, Any], root: str | Path) -> dict[str, Any]:
        return {
            "operation": operation.get("id", operation.get("op", "overlay")),
            "engine": self.engine_type,
            "root": str(root),
            "status": "placeholder",
            "mutates": False,
        }
