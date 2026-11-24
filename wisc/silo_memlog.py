#!/usr/bin/env python3
"""Run GIAnT SILo on a registered acquisition and log MATLAB memory per trial.

Launches ``run_slap2_wisc(acqDir, acqDir, "silo")`` in a ``matlab -batch``
process, echoes its output, and samples the resident memory (RSS) of the main
MATLAB process and of its descendant processes (parallel-pool workers) every
``--interval`` seconds. SILo prints ``Processing trial N from ...`` as each
trial's extraction starts; the main-process RSS at those marks gives the
per-trial memory growth, which is extrapolated to longer acquisitions.

Outputs (in ``<acq_dir>/silo_memlog_<timestamp>/`` unless ``--out`` is given):
    memory.csv  - time_s, main_rss_mb, batch_rss_mb, workers_rss_mb, n_workers, avail_mb, phase
                  (batch_rss_mb: trial-batch MATLAB processes, when SILo runs with
                  trialsPerProcess > 0; workers_rss_mb: all other descendants,
                  i.e. parallel-pool workers)
    events.csv  - time_s, event (SILo progress lines)
    matlab.log  - full MATLAB output, prefixed with elapsed seconds
    summary.txt - peak memory, per-trial growth, projections
    memory.png  - memory vs time with trial starts marked (needs matplotlib)

Usage (the slap_mi_2_sleep venv has matplotlib for the plot)::

    /data/slap_analysis/slap_mi_2_sleep/.venv/bin/python \\
        /home/driessen2/slap2_processing/GIAnT-MATLAB/wisc/silo_memlog.py \\
        /data/raw_mirror/antares/exp_2/loc_B/acq_1 --project-trials 113
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

GIANT_ROOT = Path(__file__).resolve().parents[1]
SLAP2_ROOT = Path("/home/driessen2/slap2_processing/slap2")
FAST_TIFF_ROOT = Path("/home/driessen2/slap2_processing/Fast_Tiff_Write")
MATLAB_BIN = Path("/usr/local/MATLAB/R2024b/bin/matlab")

# SILo progress lines worth recording as events; the first group names the phase
EVENT_PATTERNS = [
    (re.compile(r"^Loading data and performing localizations"), "localize"),
    (re.compile(r"^Making template for aligning across trials"), "template"),
    (re.compile(r"^Aligning across trials"), "align"),
    (re.compile(r"^Number of sources: \d+"), "sources"),
    (re.compile(r"^Processing trial (\d+) from"), "extract"),
    (re.compile(r"^Error processing trial"), None),
    (re.compile(r"^experiment_summary\.h5 written"), "save"),
    (re.compile(r"^Done SILo"), "done"),
]
TRIAL_START = re.compile(r"^Processing trial (\d+) from")


def read_rss_mb(pid: int) -> float:
    """Resident set size of one process in MB (NaN if it has exited)."""
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) / 1024
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        pass
    return float("nan")


def is_trial_batch_process(pid: int) -> bool:
    """True for a processTrialBatch MATLAB process (SILo trialsPerProcess > 0)."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return b"processTrialBatch" in f.read()
    except OSError:
        return False


def mem_available_mb() -> float:
    """System MemAvailable in MB."""
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) / 1024
    return float("nan")


def process_table() -> dict[int, tuple[int, str]]:
    """pid -> (ppid, command name) for every process."""
    table = {}
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            with open(f"/proc/{entry.name}/stat") as f:
                stat = f.read()
        except OSError:
            continue
        # comm is parenthesised and may contain spaces
        comm = stat[stat.index("(") + 1 : stat.rindex(")")]
        ppid = int(stat[stat.rindex(")") + 2 :].split()[1])
        table[int(entry.name)] = (ppid, comm)
    return table


def descendants(root: int, table: dict[int, tuple[int, str]]) -> list[int]:
    """All descendant pids of root."""
    children: dict[int, list[int]] = {}
    for pid, (ppid, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    out, stack = [], [root]
    while stack:
        for child in children.get(stack.pop(), []):
            out.append(child)
            stack.append(child)
    return out


def find_main_matlab(launcher_pid: int) -> int:
    """The MATLAB executable's pid: the launcher itself after exec, or a descendant."""
    table = process_table()
    if table.get(launcher_pid, (0, ""))[1] == "MATLAB":
        return launcher_pid
    for pid in descendants(launcher_pid, table):
        if table[pid][1] == "MATLAB":
            return pid
    return launcher_pid


def preflight(acq_dir: Path) -> None:
    """Fail early if register outputs are missing or SILo could not write its results."""
    trial_table = acq_dir / "trial_table.h5"
    problems = []
    if not trial_table.is_file():
        problems.append(f"missing {trial_table} (run the 'register' step first)")
    if not (acq_dir / "motion_correction").is_dir():
        problems.append(f"missing {acq_dir / 'motion_correction'} (run the 'register' step first)")
    # SILo rewrites trial_table.h5 at the end and creates source_extraction/ + annotations/
    for path in (acq_dir, trial_table):
        if path.exists() and not os.access(path, os.W_OK):
            problems.append(f"not writable by {os.environ.get('USER', 'this user')}: {path}")
    if problems:
        hint = ""
        if any("not writable" in p for p in problems):
            hint = (
                "\nIf register ran in a sudo MATLAB, hand the outputs back first:\n"
                f"  sudo chown -R $USER {acq_dir}/trial_table.h5 {acq_dir}/motion_correction"
            )
        sys.exit("silo_memlog: cannot start:\n  " + "\n  ".join(problems) + hint)


def matlab_command(acq_dir: Path, trials_per_process: int | None) -> str:
    """The -batch statement: clean path, then SILo only."""
    tpp = "" if trials_per_process is None else f", TrialsPerProcess={trials_per_process}"
    return (
        "restoredefaultpath; "
        f"addpath(genpath('{GIANT_ROOT}')); "
        f"addpath('{FAST_TIFF_ROOT}'); "
        f"addpath(genpath('{SLAP2_ROOT}'), '-end'); "
        f"run_slap2_wisc('{acq_dir}', '{acq_dir}', 'silo'{tpp})"
    )


def summarize(samples: list[dict], trial_marks: list[tuple[float, int]], project_trials: int | None) -> str:
    """Peak memory, per-trial growth of the main process, and projections."""
    lines = []
    main = [s["main_rss_mb"] for s in samples if s["main_rss_mb"] == s["main_rss_mb"]]
    total = [
        s["main_rss_mb"] + s["batch_rss_mb"] + s["workers_rss_mb"]
        for s in samples
        if s["main_rss_mb"] == s["main_rss_mb"]
    ]
    batch = [s["batch_rss_mb"] for s in samples]
    if not main:
        return "no memory samples\n"
    lines.append(f"samples: {len(samples)} over {samples[-1]['time_s']:.0f} s")
    lines.append(f"peak main MATLAB RSS: {max(main) / 1024:.2f} GB")
    if max(batch) > 0:
        lines.append(f"peak trial-batch process RSS: {max(batch) / 1024:.2f} GB")
    lines.append(f"peak total RSS (main + batch processes + workers): {max(total) / 1024:.2f} GB")
    lines.append(f"lowest system MemAvailable: {min(s['avail_mb'] for s in samples) / 1024:.1f} GB")

    # main RSS at each trial start: the last sample at or before the mark
    at_marks = []
    for t_mark, trial in trial_marks:
        before = [s for s in samples if s["time_s"] <= t_mark and s["main_rss_mb"] == s["main_rss_mb"]]
        if before:
            at_marks.append((len(at_marks) + 1, trial, before[-1]["main_rss_mb"]))
    lines.append(f"trial starts seen: {len(at_marks)}")
    if len(at_marks) >= 3:
        # least-squares slope of main RSS vs trial order, skipping the first
        # (pool start-up and first-trial allocations dominate it)
        pts = at_marks[1:]
        n = len(pts)
        mx = sum(p[0] for p in pts) / n
        my = sum(p[2] for p in pts) / n
        sxx = sum((p[0] - mx) ** 2 for p in pts)
        slope = sum((p[0] - mx) * (p[2] - my) for p in pts) / sxx if sxx else float("nan")
        lines.append(
            f"main RSS at trial starts: first {at_marks[0][2] / 1024:.2f} GB, "
            f"last {at_marks[-1][2] / 1024:.2f} GB"
        )
        lines.append(f"growth of main RSS per trial (trials 2..{len(at_marks)}): {slope:+.0f} MB/trial")
        if project_trials:
            projected = at_marks[-1][2] + slope * (project_trials - len(at_marks))
            lines.append(
                f"projected main RSS after {project_trials} trials: {projected / 1024:.1f} GB "
                "(linear extrapolation)"
            )
    else:
        lines.append("too few trial starts to estimate per-trial growth")
    return "\n".join(lines) + "\n"


def plot(samples: list[dict], trial_marks: list[tuple[float, int]], path: Path, title: str) -> bool:
    """memory.png: main and worker RSS vs time, trial starts marked."""
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return False
    t = [s["time_s"] / 60 for s in samples]
    fig, ax = plt.subplots(figsize=(10, 4.5))
    ax.plot(t, [s["main_rss_mb"] / 1024 for s in samples], color="#205EA6", label="main MATLAB")
    if any(s["batch_rss_mb"] > 0 for s in samples):
        ax.plot(t, [s["batch_rss_mb"] / 1024 for s in samples], color="#5E409D", label="trial-batch processes")
    ax.plot(t, [s["workers_rss_mb"] / 1024 for s in samples], color="#BC5215", label="pool workers (sum)")
    for t_mark, _ in trial_marks:
        ax.axvline(t_mark / 60, color="#66800B", alpha=0.35, linewidth=0.8)
    ax.set_xlabel("time since start (min)")
    ax.set_ylabel("RSS (GB)")
    ax.set_title(title + "  (green lines: trial extraction starts)", fontsize=10)
    ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), frameon=False)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("acq_dir", type=Path, help="acquisition folder that already has trial_table.h5 + motion_correction/")
    parser.add_argument("--interval", type=float, default=1.0, help="seconds between memory samples (default 1)")
    parser.add_argument("--out", type=Path, default=None, help="log folder (default <acq_dir>/silo_memlog_<timestamp>)")
    parser.add_argument("--project-trials", type=int, default=None, help="extrapolate main RSS to this many trials")
    parser.add_argument(
        "--trials-per-process",
        type=int,
        default=None,
        help="trials per separate MATLAB extraction process (run_slap2_wisc default 20; 0 = in-process)",
    )
    parser.add_argument("--matlab", type=Path, default=MATLAB_BIN, help=f"matlab launcher (default {MATLAB_BIN})")
    args = parser.parse_args()

    acq_dir = args.acq_dir.resolve()
    preflight(acq_dir)
    out = args.out or acq_dir / f"silo_memlog_{dt.datetime.now():%Y%m%d_%H%M%S}"
    out.mkdir(parents=True, exist_ok=True)

    t0 = time.monotonic()
    proc = subprocess.Popen(
        [str(args.matlab), "-batch", matlab_command(acq_dir, args.trials_per_process)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,  # own process group, so Ctrl+C here can stop all of MATLAB
    )
    print(f"silo_memlog: logging to {out}", flush=True)

    samples: list[dict] = []
    events: list[tuple[float, str]] = []
    trial_marks: list[tuple[float, int]] = []
    phase = ["startup"]
    stop = threading.Event()

    def sampler() -> None:
        main_pid, resolved = proc.pid, False
        while not stop.is_set():
            if not resolved:
                # the launcher script execs (or starts) the MATLAB executable
                main_pid = find_main_matlab(proc.pid)
                resolved = main_pid != proc.pid or time.monotonic() - t0 > 30
                if resolved:
                    print(f"silo_memlog: sampling MATLAB pid {main_pid}", flush=True)
            table = process_table()
            kids = [p for p in descendants(main_pid, table) if table[p][1] not in ("matlab_helper",)]
            batch_pids = {p for p in kids if table[p][1] == "MATLAB" and is_trial_batch_process(p)}
            batch = [read_rss_mb(p) for p in batch_pids]
            workers = [read_rss_mb(p) for p in kids if p not in batch_pids]
            samples.append(
                {
                    "time_s": time.monotonic() - t0,
                    "main_rss_mb": read_rss_mb(main_pid),
                    "batch_rss_mb": sum(b for b in batch if b == b),
                    "workers_rss_mb": sum(w for w in workers if w == w),
                    "n_workers": sum(1 for w in workers if w == w and w > 50),
                    "avail_mb": mem_available_mb(),
                    "phase": phase[0],
                }
            )
            stop.wait(args.interval)

    thread = threading.Thread(target=sampler, daemon=True)
    thread.start()

    try:
        with open(out / "matlab.log", "w") as log:
            for line in proc.stdout:
                t = time.monotonic() - t0
                sys.stdout.write(line)
                log.write(f"[{t:9.1f}] {line}")
                stripped = line.strip()
                for pattern, new_phase in EVENT_PATTERNS:
                    if pattern.search(stripped):
                        events.append((t, stripped))
                        if new_phase:
                            phase[0] = new_phase
                        break
                m = TRIAL_START.search(stripped)
                if m:
                    trial_marks.append((t, int(m.group(1))))
        returncode = proc.wait()
    except KeyboardInterrupt:
        print("\nsilo_memlog: interrupted, stopping MATLAB...", flush=True)
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
        returncode = -1
    finally:
        stop.set()
        thread.join(timeout=5)

    with open(out / "memory.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["time_s", "main_rss_mb", "batch_rss_mb", "workers_rss_mb", "n_workers", "avail_mb", "phase"])
        writer.writeheader()
        writer.writerows(samples)
    with open(out / "events.csv", "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["time_s", "event"])
        writer.writerows(events)

    summary = f"acq_dir: {acq_dir}\nMATLAB exit code: {returncode}\n" + summarize(samples, trial_marks, args.project_trials)
    (out / "summary.txt").write_text(summary)
    plotted = plot(samples, trial_marks, out / "memory.png", acq_dir.as_posix().split("/raw_mirror/")[-1])
    print("\n=== silo_memlog summary ===\n" + summary + (f"plot: {out / 'memory.png'}\n" if plotted else ""), flush=True)
    sys.exit(0 if returncode == 0 else 1)


if __name__ == "__main__":
    main()
