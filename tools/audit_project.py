#!/usr/bin/env python3
"""Dependency-free checks for Short Stack's client-only project boundary."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT_PATH = ROOT / "default.project.json"
SOURCE_ROOT = ROOT / "src" / "client"
EXPECTED_CONSOLES = {
    "gba",
    "nes",
    "gb",
    "gbc",
    "sms",
    "gg",
    "atari2600",
    "snes",
}

FORBIDDEN_LUA_PATTERNS = {
    "dynamic code execution": re.compile(r"\bloadstring\s*\("),
    "HTTP code/data fetch": re.compile(r"\b(?:HttpGet|RequestAsync|GetAsync|PostAsync)\s*\("),
    "numeric asset require": re.compile(r"\brequire\s*\(\s*\d+\s*\)"),
    "asset-id loader": re.compile(r"rbxassetid://", re.IGNORECASE),
    "remote event/function creation": re.compile(
        r"""Instance\.new\(\s*["']Remote(?:Event|Function)["']\s*\)"""
    ),
    "server service access": re.compile(
        r"""GetService\s*\(\s*["']Server(?:ScriptService|Storage)["']\s*\)"""
    ),
}


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    try:
        project = json.loads(PROJECT_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot parse default.project.json: {error}")

    tree = project.get("tree", {})
    if tree.get("$className") != "DataModel":
        fail("Rojo project root must be a DataModel")
    starter_player = tree.get("StarterPlayer", {})
    starter_scripts = starter_player.get("StarterPlayerScripts", {})
    short_stack = starter_scripts.get("ShortStack", {})
    if short_stack.get("$path") != "src/client":
        fail("ShortStack must map to src/client under StarterPlayerScripts")
    if "ServerScriptService" in tree or "ServerStorage" in tree:
        fail("server-only services must not be added to this client-only project")
    if not (SOURCE_ROOT / "init.client.lua").is_file():
        fail("missing src/client/init.client.lua LocalScript entry point")

    lua_files = sorted({*SOURCE_ROOT.rglob("*.lua"), *SOURCE_ROOT.rglob("*.luau")})
    if not lua_files:
        fail("no Luau source found under src/client")
    for path in lua_files:
        if path.name.endswith((".server.lua", ".server.luau")):
            fail(f"server script found in client source: {path.relative_to(ROOT)}")
        contents = path.read_text(encoding="utf-8")
        for description, pattern in FORBIDDEN_LUA_PATTERNS.items():
            if pattern.search(contents):
                fail(f"{description} found in {path.relative_to(ROOT)}")
        z_indexes = [int(value) for value in re.findall(r"\bZIndex\s*=\s*(\d+)", contents)]
        if any(value < 1 or value > 10 for value in z_indexes):
            fail(f"explicit ZIndex values exceed this project's 1–10 layer budget: {path.relative_to(ROOT)}")

    catalog = (SOURCE_ROOT / "Modules" / "ConsoleCatalog.lua").read_text(encoding="utf-8")
    found = set(re.findall(r'\bid\s*=\s*"([a-z0-9]+)"', catalog))
    missing = EXPECTED_CONSOLES - found
    if missing:
        fail(f"console catalog is missing: {', '.join(sorted(missing))}")

    print(f"PASS: Rojo JSON, client-only mapping, {len(lua_files)} Luau files, and {len(found)} catalog IDs checked.")
    print("PASS: no remote/server/network loaders or out-of-range explicit ZIndex values found.")
    print("NOTE: Static checks do not replace Roblox Studio playtests or core/license review.")


if __name__ == "__main__":
    main()
