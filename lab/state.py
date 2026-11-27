"""Typed run state for the lab CLI.

The record is written atomically so a crash cannot leave a half-written state
file. Every resource carries the name the renderer gave it, so teardown never
guesses.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

SCHEMA = 1


def new(scenario: str) -> dict:
    return {
        "schema": SCHEMA,
        "scenario": scenario,
        "owner": os.urandom(8).hex(),
        "nodes": {},
        # One record per deployment id. A redeploy adds one and leaves the old
        # one, so the harness keeps the history the guest deliberately does not.
        "deployments": {},
        "resources": [],
    }


def state_path(run: Path, scenario: str) -> Path:
    return run / scenario / "state.json"


def write(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".state-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def read(path: Path) -> dict:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
    if state.get("schema") != SCHEMA:
        raise ValueError(f"unsupported state schema {state.get('schema')!r} in {path}")
    return state


def add(state: dict, kind: str, name: str, **extra: object) -> None:
    state["resources"].append({"kind": kind, "name": name, **extra})


def drop(state: dict, kind: str, name: str) -> None:
    state["resources"] = [
        item
        for item in state["resources"]
        if not (item["kind"] == kind and item["name"] == name)
    ]


def record_deployment(state: dict, record: dict) -> None:
    """Keep one record per deployment id: a redeploy adds, never overwrites."""
    state.setdefault("deployments", {})[record["id"]] = record
