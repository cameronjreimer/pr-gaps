"""Where the island-wide workflow stands, stage by stage (docs/hpc-scaling-plan.md §5.1).

    python python/status.py                          # summary; writes $PR_GAPS_WORKFLOW/status.csv
    python python/status.py --pending retile --out tasks.txt   # the tasks submit.sh should run
    python python/status.py --pending step1 --retry-failed      # ...including ones that failed twice

A task is done when its stage's own done marker says so (a retile marker matching the
source file, a DTM index row, a complete cache, ...), not when a job exited 0. Attempt
records written by workflow/stage.sbatch add what Slurm knows: how often a task ran,
whether it failed or is still running, which commit produced it and where its log is.

States: done, running, failed (its last attempt failed or was killed), pending (never
tried). A task that failed twice is left out of --pending unless --retry-failed, so it
gets looked at rather than resubmitted again.
"""

import argparse
import csv
import getpass
import json
import os
import shutil
import subprocess
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from canopy import DATA, GLIHT  # noqa: E402

WORKFLOW = Path(os.environ.get("PR_GAPS_WORKFLOW") or DATA / "workflow")
ORDER = ["retile", "dtm", "step1", "area", "voxels", "label", "join", "points", "qc"]


# ------------------------------------------------------------- stage definitions
# Each built stage: tasks() -> task keys, done(task) -> bool.

def retile_tasks():
    import retile

    return retile.maria_tasks()


def retile_done(task):
    import retile

    campaign, name = task.split("/", 1)
    path = Path(GLIHT) / campaign / "lidar" / "las" / name
    return path.is_file() and retile.is_done(campaign, path)


def dtm_done(task):
    import campaign_dtm

    if not campaign_dtm.INDEX.is_file():
        return False
    index = pd.read_csv(campaign_dtm.INDEX).set_index("campaign")
    needed = campaign_dtm.default_campaigns(False)
    return all(c in index.index and Path(index.at[c, "path"]).is_file() for c in needed)


_UNITS = None


def plan_units():
    global _UNITS
    if _UNITS is None:
        import units

        _UNITS = units.load_units()
    return _UNITS


def step1_tasks():
    return [str(job) for job in sorted(plan_units().job.unique())]


def step1_done(task):
    import units

    return units.job_done(task, plan_units())


def area_done(task):
    """An area run for this plan that left no unit out."""
    import hashlib

    plan_hash = hashlib.sha256((PLAN_DIR() / "plan.json").read_bytes()).hexdigest()
    for marker in (DATA / "runs" / "canopy" / "area").glob("*/area.json"):
        record = json.loads(marker.read_text(encoding="utf-8"))
        if record.get("plan_sha256") == plan_hash and not record.get("units_without_cache"):
            return True
    return False


def PLAN_DIR():  # noqa: N802
    from canopy import PLAN

    return PLAN


def island():
    import island_gaps

    return island_gaps, island_gaps.run_dir()


def job_units(task):
    plan = plan_units()
    return [pd.Series(row._asdict()) for row in plan[plan.job == int(task)].itertuples(index=False)]


def voxels_done(task):
    gaps, root = island()
    return all(gaps.unit_voxels_done(root, unit) for unit in job_units(task))


def label_tasks():
    return sorted(plan_units().tile.unique())


def label_done(task):
    gaps, root = island()
    return gaps.label_done(root, task, plan_units())


def join_tasks():
    import island_gaps

    return [f"{t:g}" for t in island_gaps.SETTINGS["thresholds"]]


def join_done(task):
    gaps, root = island()
    return (root / "gaps" / gaps.label(float(task)) / "join.json").is_file()


def points_done(task):
    gaps, root = island()
    return all(gaps.unit_points_done(root, unit) for unit in job_units(task))


STAGES = {
    "retile": (retile_tasks, retile_done),
    "dtm": (lambda: ["all"], dtm_done),
    "step1": (step1_tasks, step1_done),
    "area": (lambda: ["all"], area_done),
    "voxels": (step1_tasks, voxels_done),
    "label": (label_tasks, label_done),
    "join": (join_tasks, join_done),
    "points": (step1_tasks, points_done),
}


# ------------------------------------------------------------- attempt records

def running_jobs():
    """'<jobid>_<index>' of this user's running array tasks; empty without Slurm."""
    if not shutil.which("squeue"):
        return set()
    result = subprocess.run(["squeue", "-u", getpass.getuser(), "-h", "-t", "R,CG", "-o", "%i"],
                            capture_output=True, text=True, check=False)
    return set(result.stdout.split())


def attempts(stage, task):
    path = WORKFLOW / "attempts" / stage / f"{task.replace('/', '__')}.jsonl"
    if not path.is_file():
        return []
    runs = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            event = json.loads(line)
            runs.setdefault(event["job"], {}).update(
                {event["event"]: event["time"], "commit": event["commit"], "log": event["log"],
                 **({"exit": event["exit"]} if "exit" in event else {})})
    return sorted(runs.items(), key=lambda item: item[1].get("start", ""))


def seconds(start, end):
    if not (start and end):
        return None
    parse = lambda t: datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ")  # noqa: E731
    return int((parse(end) - parse(start)).total_seconds())


def task_rows(stage, running):
    tasks, done = STAGES[stage]
    rows = []
    for task in tasks():
        history = attempts(stage, task)
        failures = sum(1 for job, run in history
                       if run.get("exit", 0) != 0 or ("end" not in run and job not in running))
        last_job, last = history[-1] if history else (None, {})
        if done(task):
            state = "done"
        elif last_job in running and "end" not in last:
            state = "running"
        elif history:
            state = "failed"
        else:
            state = "pending"
        rows.append({"stage": stage, "task": task, "state": state, "attempts": len(history),
                     "failures": failures, "commit": last.get("commit", ""),
                     "seconds": seconds(last.get("start"), last.get("end")),
                     "log": last.get("log", "")})
    return rows


# ------------------------------------------------------------- commands

def pending(stage, out, retry_failed):
    if stage not in STAGES:
        raise SystemExit(f"stage {stage} is not built yet")
    rows = task_rows(stage, running_jobs())
    keep = [r["task"] for r in rows
            if r["state"] == "pending" or (r["state"] == "failed" and (retry_failed or r["failures"] < 2))]
    held = [r for r in rows if r["state"] == "failed" and r["failures"] >= 2 and not retry_failed]
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text("".join(f"{task}\n" for task in keep), encoding="utf-8")
    for row in held:
        print(f"held (failed {row['failures']}x, see {row['log']}): {row['task']}")
    print(f"{len(keep)} task(s) to run, {len(held)} held after two failures")


def summary():
    running = running_jobs()
    rows = []
    print(f"workflow state: {WORKFLOW}")
    for stage in ORDER:
        if stage not in STAGES:
            print(f"  {stage:<7} not built yet")
            continue
        try:
            stage_rows = task_rows(stage, running)
        except (SystemExit, FileNotFoundError, ValueError) as error:
            print(f"  {stage:<7} cannot list tasks: {error}")
            continue
        rows += stage_rows
        states = Counter(r["state"] for r in stage_rows)
        held = sum(1 for r in stage_rows if r["state"] == "failed" and r["failures"] >= 2)
        commits = {r["commit"] for r in stage_rows if r["state"] == "done" and r["commit"]}
        line = (f"  {stage:<7} {len(stage_rows):>5} tasks: {states['done']} done, "
                f"{states['running']} running, {states['failed']} failed ({held} twice), "
                f"{states['pending']} pending")
        if len(commits) > 1:
            line += f"  WARNING: done tasks come from {len(commits)} commits"
        print(line)
        for row in [r for r in stage_rows if r["state"] == "failed"][:10]:
            print(f"      failed {row['failures']}x: {row['task']}  {row['log']}")
    if rows:
        WORKFLOW.mkdir(parents=True, exist_ok=True)
        with (WORKFLOW / "status.csv").open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        print(f"per-task detail: {WORKFLOW / 'status.csv'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pending", metavar="STAGE", help="write the tasks of STAGE still to run")
    parser.add_argument("--out", help="with --pending: the task list to write")
    parser.add_argument("--retry-failed", action="store_true",
                        help="with --pending: include tasks that failed twice")
    args = parser.parse_args()
    if args.pending:
        if not args.out:
            parser.error("--pending needs --out")
        pending(args.pending, args.out, args.retry_failed)
    else:
        summary()


if __name__ == "__main__":
    main()
