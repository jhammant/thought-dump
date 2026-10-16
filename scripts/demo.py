#!/usr/bin/env python3
"""Exercise the public CLI and its artifacts without any real model calls."""
import argparse
import json
from pathlib import Path
import runpy
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=Path(".demo/fake"))
    args = parser.parse_args()
    if not args.state_dir.resolve().is_relative_to(ROOT):
        parser.error("demo state must stay inside this repository")
    if args.state_dir.exists():
        parser.error("choose a fresh --state-dir; the demo never deletes an existing batch")
    pages = args.state_dir / "pages"
    for command in (
        ["ingest", "tests/fixtures/three-thoughts.md", "--fake-claude"],
        ["run", "--fake-claude", "--concurrency", "3", "--timeout-seconds", "10"],
        ["report", "--pages-dir", str(pages)],
    ):
        subprocess.run([sys.executable, str(ROOT / "dump"), *command, "--state-dir", str(args.state_dir)], cwd=ROOT, check=True)
    state = ROOT / args.state_dir
    tasks = json.loads((state / "tasks.json").read_text())
    assert len(tasks) == 3 and sum(task["outward"] for task in tasks) == 1
    statuses = [json.loads((state / "results" / task["id"] / "status.json").read_text())["status"] for task in tasks]
    assert statuses == ["completed", "completed", "drafted"], statuses
    label = runpy.run_path(str(state / "workspaces/task-001/prototype.py"))["label_thought"]
    assert label("Why?  ") == "question" and label("A small idea") == "idea"
    assert not list((state / "workspaces/task-003").iterdir()), "outward task wrote an artifact"
    page = (ROOT / pages / state.name / "index.html").read_text()
    assert page.count("<article>") == 3 and "FAKE" in page and "nothing sent" in page
    assert "Drafts to approve (1)" in page and "Done for you (2)" in page
    assert (ROOT / pages / state.name / "files/task-001/prototype.py").is_file()
    assert "transcript" not in {path.name.split(".")[0] for path in (ROOT / pages).rglob("*")}
    print("Verified: 3 tasks, prototype behavior, local checklist, draft-only email, published page.")
    print("Claude calls: 0 real; 1 fake splitter + 3 fake workers.")


if __name__ == "__main__":
    main()
