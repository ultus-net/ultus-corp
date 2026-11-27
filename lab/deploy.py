"""The deployment handshake.

`lab up` is only finished when the guest has recorded the deployment it ran.
The guest writes `/var/lib/ultus-corp/deployments/<id>.json`; the harness reads
it back over SSH, checks it against what the disk was built from, and keeps its
own copy keyed by deployment id.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RECORD_DIR = "/var/lib/ultus-corp/deployments"
RECORD_KEYS = {"id", "image_digest", "role", "completed_at"}


def ssh_command() -> list[str]:
    """The SSH prefix, or `$LAB_DEPLOY_SSH` when a test supplies one."""
    configured = os.environ.get("LAB_DEPLOY_SSH")
    if configured:
        return shlex.split(configured)
    return [
        "ssh",
        "-i",
        str(ROOT / "lab-secrets" / "id_ed25519"),
        # The VMs are ephemeral and an address is reused by the next run, so a
        # remembered host key would be stale rather than protective.
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "LogLevel=ERROR",
        "-o",
        "ConnectTimeout=5",
    ]


def record_path(deployment_id: str) -> str:
    return f"{RECORD_DIR}/{deployment_id}.json"


def await_record(
    address: str,
    deployment_id: str,
    timeout: float = 900.0,
    interval: float = 5.0,
    command: list[str] | None = None,
) -> dict:
    """Poll the guest until it has recorded this deployment, then return it."""
    ssh = command if command is not None else ssh_command()
    deadline = time.monotonic() + timeout
    last = "no attempt"
    while True:
        done = subprocess.run(
            [*ssh, f"root@{address}", "cat", record_path(deployment_id)],
            capture_output=True,
            text=True,
        )
        if done.returncode == 0 and done.stdout.strip():
            try:
                return json.loads(done.stdout)
            except json.JSONDecodeError as exc:
                last = f"record is not JSON: {exc}"
        else:
            last = (done.stderr or done.stdout).strip() or f"exit {done.returncode}"
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"no deployment record for {deployment_id} at {address} "
                f"within {timeout:.0f}s ({last})"
            )
        time.sleep(interval)


def verify_record(
    record: dict,
    deployment_id: str,
    role: str,
    digest: str | None = None,
) -> None:
    """Fail closed when the guest recorded a different deployment than intended."""
    missing = RECORD_KEYS - set(record)
    if missing:
        raise ValueError(f"deployment record is missing {sorted(missing)}")
    if record["id"] != deployment_id:
        raise ValueError(
            f"deployment record id is {record['id']}, expected {deployment_id}"
        )
    if record["role"] != role:
        raise ValueError(f"deployment record role is {record['role']}, expected {role}")
    if digest and record["image_digest"] != digest:
        raise ValueError(
            f"deployment record digest is {record['image_digest']}, expected {digest}"
        )
