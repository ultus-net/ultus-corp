#!/usr/bin/env python3
"""Run a scenario and report its wall time and peak resident memory.

GNU time is not on every host. The guest peak is sampled from the qemu
processes the run started, because libvirt daemonises them outside the
scenario's process tree. A qemu process that was already running when the run
started is excluded, so an unrelated lab VM cannot inflate the figure. The
harness peak is the maximum resident set size of the children that did stay in
that tree. Both values are KiB, as /proc reports them.
"""

from __future__ import annotations

import resource
import subprocess
import sys
import time


def qemu_rss_kib() -> dict[int, int]:
    out = subprocess.run(
        ["ps", "-eo", "pid=,rss=,comm="], capture_output=True, text=True, check=False
    ).stdout
    seen: dict[int, int] = {}
    for line in out.splitlines():
        pid, _, rest = line.strip().partition(" ")
        rss, _, comm = rest.strip().partition(" ")
        # Linux truncates comm to 15 characters, so match the prefix.
        if comm.startswith("qemu-system-x86") and pid.isdigit() and rss.isdigit():
            seen[int(pid)] = int(rss)
    return seen


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: measure.py <command> [args...]", file=sys.stderr)
        return 2
    baseline = set(qemu_rss_kib())
    started = time.monotonic()
    proc = subprocess.Popen(sys.argv[1:])
    peaks: dict[int, int] = {}
    while proc.poll() is None:
        for pid, rss in qemu_rss_kib().items():
            if pid not in baseline:
                peaks[pid] = max(peaks.get(pid, 0), rss)
        time.sleep(1)
    wall = time.monotonic() - started
    harness_peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    print(
        f"wall_seconds={wall:.1f} guest_peak_rss_kib={sum(peaks.values())} "
        f"harness_peak_rss_kib={harness_peak}",
        file=sys.stderr,
    )
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
