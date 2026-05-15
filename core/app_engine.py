#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from typing import Any


class AppEngine:
    engine_type = "app"

    def dry_run(self, operation: dict[str, Any], root: str | Path) -> dict[str, Any]:
        return {
            "operation": operation.get("id", operation.get("op", "app")),
            "engine": self.engine_type,
            "root": str(root),
            "status": "placeholder",
            "mutates": False,
        }
