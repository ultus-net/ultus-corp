#!/usr/bin/env python3
"""Run a scenario and report its wall time and peak resident memory.

GNU time is not on every host. The guest peak is sampled from the qemu
processes, because libvirt daemonises them outside the scenario's process tree.
The harness peak is the maximum resident set size of the children that did stay
in that tree. Both values are KiB, as /proc reports them.
"""

from __future__ import annotations

import resource
import subprocess
import sys
import time


def guest_peak_kib() -> int:
    out = subprocess.run(
        ["ps", "-eo", "rss=,comm="], capture_output=True, text=True, check=False
    ).stdout
    total = 0
    for line in out.splitlines():
        rss, _, comm = line.strip().partition(" ")
        # Linux truncates comm to 15 characters, so match the prefix.
        if comm.startswith("qemu-system-x86") and rss.isdigit():
            total += int(rss)
    return total


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: measure.py <command> [args...]", file=sys.stderr)
        return 2
    started = time.monotonic()
    proc = subprocess.Popen(sys.argv[1:])
    guest_peak = 0
    while proc.poll() is None:
        guest_peak = max(guest_peak, guest_peak_kib())
        time.sleep(1)
    wall = time.monotonic() - started
    harness_peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    print(
        f"wall_seconds={wall:.1f} guest_peak_rss_kib={guest_peak} "
        f"harness_peak_rss_kib={harness_peak}",
        file=sys.stderr,
    )
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
