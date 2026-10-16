import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import thought_dump as td


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/three-thoughts.md"
SUCCESS = 'print(json.dumps({"is_error": False, "subtype": "success", "result": "Local result", "permission_denials": []}))\n'


class Base(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix=".test-", dir=ROOT)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.state = self.directory / "batch"
        # A config of its own: never anyone's real pages, phone or to-do list.
        self.home = self.directory / "home"
        self.env = {**os.environ, "THOUGHT_DUMP_HOME": str(self.home)}
        self.env.pop("THOUGHT_DUMP_CAPTURE_ARGS", None)
        patcher = patch.object(td, "HOME", self.home)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.configure()

    def configure(self, **settings):
        self.home.mkdir(parents=True, exist_ok=True)
        workspaces = {name: name for name in ("orbital", "recos", "founder", "oss", "personal")}
        td.write_json(self.home / "config.json", {"owner": "Jon", "workspaces": workspaces, **settings})

    def page(self):
        return (self.home / "pages" / self.state.name / "index.html").read_text()

    def cli(self, *arguments, check=True):
        result = subprocess.run(
            [sys.executable, str(ROOT / "dump"), *map(str, arguments), "--state-dir", str(self.state)],
            cwd=ROOT, text=True, capture_output=True, timeout=15, env=self.env,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def batch(self, count=1):
        transcript = "\n\n".join(f"Plan synthetic local task {index}." for index in range(count))
        self.cli("ingest", transcript, "--fake-claude")
        return td.load_tasks(self.state)

    def worker(self, body):
        path = self.directory / "worker.py"
        path.write_text("import json, os, sys, time\nfrom pathlib import Path\npayload = json.load(sys.stdin)\n" + body)
        return [sys.executable, str(path)]

    def run_worker(self, body, *options):
        command = self.worker(body)
        with patch.object(td, "claude_command", return_value=command), contextlib.redirect_stdout(io.StringIO()):
            return td.main(["run", "--state-dir", str(self.state), "--fake-claude", *options])


class RunnerTests(Base):
    def test_fake_demo_through_public_cli(self):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/demo.py"), "--state-dir", str(self.state)],
            cwd=ROOT, text=True, capture_output=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Claude calls: 0 real", result.stdout)
        self.assertIn("FAKE splitter", (self.state / "pages" / self.state.name / "index.html").read_text())

    def test_ingest_accepts_stdin_and_preserves_source(self):
        source = "Plan a synthetic afternoon."
        result = subprocess.run(
            [sys.executable, str(ROOT / "dump"), "ingest", "-", "--fake-claude", "--state-dir", str(self.state)],
            input=source, text=True, capture_output=True, cwd=ROOT, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.state / "transcript.md").read_text(), source)
        self.assertEqual(td.load_tasks(self.state)[0]["jon_words"], source)

    def test_long_literal_text_is_not_treated_as_a_filename(self):
        source = "Plan a local task. " * 100
        self.cli("ingest", source, "--fake-claude")
        self.assertEqual((self.state / "transcript.md").read_text(), source)

    def test_literal_text_can_end_with_a_filename(self):
        self.assertEqual(td.transcript_input("Write a README.md"), "Write a README.md")

    def test_splitter_time_budget_leaves_no_runnable_tasks(self):
        command = self.worker("time.sleep(30)\n")
        with patch.object(td, "claude_command", return_value=command), contextlib.redirect_stderr(io.StringIO()):
            code = td.main(["ingest", "Synthetic text", "--state-dir", str(self.state), "--timeout-seconds", "0.1"])
        self.assertEqual(code, 1)
        self.assertFalse((self.state / "tasks.json").exists())

    def test_invalid_time_budgets_are_rejected(self):
        for seconds in ("0", "-1", "nan", "inf", "3601"):
            with self.subTest(seconds=seconds):
                result = self.cli("run", "--fake-claude", "--timeout-seconds", seconds, check=False)
                self.assertEqual(result.returncode, 2)

    def test_missing_claude_does_not_silently_use_stub(self):
        with patch.object(td.shutil, "which", return_value=None), self.assertRaises(td.DumpError):
            td.claude_command(False, "split")

    def test_ingest_does_not_replace_existing_batch(self):
        self.batch()
        before = (self.state / "tasks.json").read_bytes()
        result = self.cli("ingest", "Different words", "--fake-claude", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.state / "tasks.json").read_bytes(), before)

    def test_schema_rejects_unsafe_or_invented_tasks(self):
        task = self.batch()[0]
        mutations = (
            {"workspace": "../../escape"}, {"id": "../escape"},
            {"outward": "false"}, {"outward": 0}, {"kind": "execute"},
            {"kind": []}, {"jon_words": "Invented quote"}, {"extra": "field"},
        )
        source = (self.state / "transcript.md").read_text()
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(td.DumpError):
                td.validate_tasks([dict(task, **mutation)], source)
        with self.assertRaises(td.DumpError):
            td.validate_tasks([task, task], source)

    def test_invalid_splitter_output_never_becomes_a_queue(self):
        command = self.worker('print(json.dumps({"is_error": False, "result": "not JSON"}))\n')
        with patch.object(td, "claude_command", return_value=command), contextlib.redirect_stderr(io.StringIO()):
            code = td.main(["ingest", "Synthetic text", "--state-dir", str(self.state)])
        self.assertEqual(code, 1)
        self.assertFalse((self.state / "tasks.json").exists())

    def test_concurrency_is_capped_and_workspaces_are_separate(self):
        tasks = self.batch(7)
        events = self.directory / "events.jsonl"
        body = f'''events = Path({str(events)!r})
def event(name):
    descriptor = os.open(events, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(descriptor, (json.dumps([name, str(Path.cwd())]) + "\\n").encode())
    os.close(descriptor)
event("start")
time.sleep(0.15)
event("finish")
''' + SUCCESS
        code = self.run_worker(body)
        current = peak = 0
        directories = set()
        for event, cwd in map(json.loads, events.read_text().splitlines()):
            current += 1 if event == "start" else -1
            peak = max(peak, current)
            directories.add(cwd)
        self.assertEqual(code, 0)
        self.assertEqual(peak, 4)
        self.assertEqual(current, 0)
        self.assertEqual(directories, {str(self.state / task["workspace"]) for task in tasks})

    def test_concurrency_above_four_is_rejected(self):
        result = self.cli("run", "--fake-claude", "--concurrency", "5", check=False)
        self.assertEqual(result.returncode, 2)

    def test_timeout_stops_worker_and_child_process(self):
        task = self.batch()[0]
        marker = self.state / task["workspace"] / "child-survived"
        child_code = f"import time; from pathlib import Path; time.sleep(0.7); Path({str(marker)!r}).touch()"
        body = f"import subprocess\nsubprocess.Popen([sys.executable, '-c', {child_code!r}])\ntime.sleep(30)\n"
        started = time.monotonic()
        code = self.run_worker(body, "--timeout-seconds", "0.2")
        self.assertEqual(code, 1)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(td.task_status(self.state, task)["status"], "timed_out")
        time.sleep(0.8)
        self.assertFalse(marker.exists(), "worker descendant survived timeout")

    def test_one_failed_worker_does_not_stop_others(self):
        tasks = self.batch(3)
        code = self.run_worker('if payload["task"]["id"] == "task-002":\n    sys.exit(7)\n' + SUCCESS)
        self.assertEqual(code, 1)
        self.assertEqual([td.task_status(self.state, task)["status"] for task in tasks], ["completed", "failed", "completed"])

    def test_denied_tool_is_reported_as_blocked(self):
        task = self.batch()[0]
        code = self.run_worker('print(json.dumps({"is_error": False, "result": "Cannot execute", "permission_denials": [{"tool_name": "Bash"}]}))\n')
        self.assertEqual(code, 1)
        self.assertEqual(td.task_status(self.state, task)["status"], "blocked")

    def test_malformed_worker_json_is_a_failure(self):
        task = self.batch()[0]
        self.assertEqual(self.run_worker('print("not JSON")\n'), 1)
        self.assertEqual(td.task_status(self.state, task)["status"], "failed")

    def test_run_is_idempotent_for_finished_tasks(self):
        task = self.batch()[0]
        self.cli("run", "--fake-claude")
        before = (td.result_dir(self.state, task) / "status.json").read_bytes()
        self.cli("run", "--fake-claude")
        self.assertEqual((td.result_dir(self.state, task) / "status.json").read_bytes(), before)

    def test_batch_lock_prevents_duplicate_supervisors(self):
        self.batch()
        with td.batch_lock(self.state):
            result = self.cli("run", "--fake-claude", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("already has an ingest or run", result.stderr)

    def test_symlink_workspace_is_rejected(self):
        task = self.batch()[0]
        (self.state / "workspaces").mkdir()
        (self.state / task["workspace"]).symlink_to(self.directory, target_is_directory=True)
        result = self.cli("run", "--fake-claude", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("symlink", result.stderr)

    def test_report_escapes_content_and_works_before_run(self):
        self.cli("ingest", 'Plan a synthetic <script>alert("x")</script> task.', "--fake-claude")
        self.cli("report")
        page = self.page()
        self.assertNotIn("<script>", page)
        self.assertIn("&lt;script&gt;", page)
        self.assertIn("waiting", page)
        self.assertIn("Content-Security-Policy", page)

    def test_real_commands_have_file_only_or_zero_tools(self):
        with patch.object(td.shutil, "which", return_value="/bin/claude"):
            internal = td.claude_command(False, "work", False)
            outward = td.claude_command(False, "work", True)
            splitter = td.claude_command(False, "split")
        for command in (internal, outward, splitter):
            self.assertEqual(command[command.index("--permission-mode") + 1], "default")
            self.assertEqual(command[command.index("--permission-prompts") + 1], "none")
            self.assertIn("--restricted", command)
            self.assertIn("--safe-mode", command)
            self.assertIn("--no-chrome", command)
            self.assertIn("--strict-mcp-config", command)
            self.assertNotIn("--dangerously-skip-permissions", command)
        self.assertEqual(internal[internal.index("--tools") + 1], "Read,Write,Edit,Glob,Grep")
        for command in (outward, splitter):
            self.assertEqual(command[command.index("--tools") + 1], "")

    def test_sigterm_cleans_up_running_workers(self):
        self.batch(4)
        command = self.worker("time.sleep(30)\n" + SUCCESS)
        harness = self.directory / "harness.py"
        harness.write_text(
            f"import sys\nsys.path.insert(0, {str(ROOT)!r})\nimport thought_dump as td\n"
            f"td.claude_command = lambda *args: {command!r}\n"
            f"raise SystemExit(td.main(['run', '--state-dir', {str(self.state)!r}, '--fake-claude', '--concurrency', '3']))\n"
        )
        supervisor = subprocess.Popen([sys.executable, str(harness)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            status_path = self.state / "results/task-003/status.json"
            while not status_path.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(status_path.exists())
            supervisor.send_signal(signal.SIGTERM)
            stdout, stderr = supervisor.communicate(timeout=5)
            self.assertEqual(supervisor.returncode, 130, stderr)
            self.assertIn("3 interrupted", stdout)
            self.assertIn("1 pending", stdout)
        finally:
            if supervisor.poll() is None:
                supervisor.kill()
                supervisor.communicate()


class RoutingTests(Base):
    """Jon's defaults, guard rails and the published page."""

    def tasks(self, *specs):
        """Write a batch directly: (portal, needs_jon, outward, kind) per task."""
        transcript = " ".join(f"Item {index} words." for index in range(len(specs)))
        tasks = [{
            "id": f"task-{index:03d}", "title": f"Item {index} title", "jon_words": f"Item {index} words.",
            "kind": kind, "outward": outward, "workspace": f"workspaces/task-{index:03d}",
            "portal": portal, "needs_jon": needs_jon,
        } for index, (portal, needs_jon, outward, kind) in enumerate(specs)]
        self.state.mkdir(parents=True)
        td.atomic_text(self.state / "transcript.md", transcript)
        td.write_json(self.state / "meta.json", {"created_at": "2026-10-16T10:00:00+00:00", "fake_splitter": True})
        td.write_json(self.state / "tasks.json", tasks)
        return tasks

    def recorder(self, name, stdout=""):
        """A fake executable that logs its argv as one JSON line."""
        log = self.directory / f"{name}.jsonl"
        path = self.directory / name
        path.write_text(f"#!{sys.executable}\nimport json, sys\n"
                        f"open({str(log)!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
                        f"print({stdout!r})\n")
        path.chmod(0o755)
        return path, log

    def status(self, task_id):
        return json.loads((self.state / "results" / task_id / "status.json").read_text())

    def test_old_six_field_batches_still_load_with_safe_defaults(self):
        task = {"id": "task-001", "title": "T", "jon_words": "do  the\nthing", "kind": "plan",
                "outward": False, "workspace": "workspaces/task-001"}
        [loaded] = td.validate_tasks([task], "please do the thing now")
        self.assertEqual((loaded["portal"], loaded["needs_jon"]), ("unsure", False))

    def test_new_fields_are_validated(self):
        base = {"id": "task-001", "title": "T", "jon_words": "x", "kind": "plan", "outward": False,
                "workspace": "workspaces/task-001", "portal": "orbital", "needs_jon": False}
        for change in ({"portal": "Not Valid!"}, {"portal": 3}, {"needs_jon": "yes"}, {"extra": 1}):
            with self.subTest(change=change), self.assertRaises(td.DumpError):
                td.validate_tasks([{**base, **change}], "x")

    def test_routes_follow_jons_defaults(self):
        def task(needs_jon, outward):
            return {"needs_jon": needs_jon, "outward": outward}
        self.assertEqual(td.route(task(True, True)), "todo")
        self.assertEqual(td.route(task(False, True)), "draft")
        self.assertEqual(td.route(task(False, False)), "run")

    def test_run_never_gives_a_to_do_to_a_worker(self):
        self.tasks(("personal", True, False, "plan"), ("oss", False, False, "plan"))
        code = self.run_worker(SUCCESS)
        self.assertEqual(code, 0)
        self.assertEqual(self.status("task-000")["status"], "for_jon")
        self.assertFalse((self.state / "workspaces/task-000").exists())
        self.assertEqual(self.status("task-001")["status"], "completed")

    def test_go_files_orbital_to_dos_once_and_tells_jon(self):
        self.tasks(("orbital", True, False, "plan"), ("personal", True, True, "plan"),
                   ("orbital", False, True, "draft"), ("oss", False, False, "research"))
        todo, todo_log = self.recorder("todo", stdout='{"id": "t-42"}')
        notify, notify_log = self.recorder("notify")
        self.configure(todo={"adapter": "portal-todo", "path": str(todo), "workspaces": ["orbital"]},
                       notify=[str(notify)], pages_url="https://my-mac.example.ts.net/pages/thought-dump/")
        with contextlib.redirect_stdout(io.StringIO()):
            code = td.main(["go", "--state-dir", str(self.state), "--fake-claude", "--hold", "0"])
            again = td.main(["go", "--state-dir", str(self.state), "--fake-claude", "--hold", "0"])
        self.assertEqual((code, again), (0, 0))
        [call] = map(json.loads, todo_log.read_text().splitlines())   # once, and only the Orbital one
        self.assertEqual(call[call.index("--key") + 1], "thought-dump:batch:task-000")
        self.assertEqual(call[call.index("--since") + 1], "2026-10-16T10:00:00+00:00")
        self.assertEqual(self.status("task-000")["todo_id"], "t-42")
        self.assertEqual(self.status("task-001")["status"], "for_jon")      # personal: page only
        self.assertEqual(self.status("task-002")["status"], "drafted")
        self.assertEqual(self.status("task-003")["status"], "completed")
        message = json.loads(notify_log.read_text().splitlines()[0])[0]
        self.assertIn("1 done, 1 draft, 2 for you", message)
        self.assertIn("https://my-mac.example.ts.net/pages/thought-dump/batch/", message)
        self.assertNotIn("Item", message)                                     # counts, never words
        page = self.page()
        for heading in ("Needs you (2)", "Drafts to approve (1)", "Done for you (1)"):
            self.assertIn(heading, page)

    def test_a_failing_to_do_list_leaves_the_item_on_the_page(self):
        self.tasks(("orbital", True, False, "plan"))
        todo = self.directory / "todo-broken"
        todo.write_text(f"#!{sys.executable}\nimport sys\nprint('todo: store locked', file=sys.stderr)\nsys.exit(1)\n")
        todo.chmod(0o755)
        self.configure(todo={"adapter": "portal-todo", "path": str(todo), "workspaces": ["orbital"]})
        with contextlib.redirect_stdout(io.StringIO()):
            td.main(["go", "--state-dir", str(self.state), "--fake-claude", "--no-notify", "--hold", "0"])
        status = self.status("task-000")
        self.assertEqual(status["status"], "for_jon")
        self.assertIn("store locked", status["error"])

    def codex_run(self, body):
        """Run one coding spike through a fake codex that obeys -C and -o."""
        self.tasks(("oss", False, False, "spike"))
        fake = self.directory / "codex.py"
        fake.write_text("import sys, os\nfrom pathlib import Path\nargs = sys.argv[1:]\n"
                        "workdir = Path(args[args.index('-C') + 1]); last = Path(args[args.index('-o') + 1])\n"
                        "prompt = sys.stdin.read()\n" + body)
        with patch.object(td, "engine_for", return_value="codex"), \
                patch.object(td, "codex_command", lambda workspace, last: [sys.executable, str(fake), "-C", str(workspace), "-o", str(last)]), \
                contextlib.redirect_stdout(io.StringIO()):
            return td.main(["run", "--state-dir", str(self.state), "--fake-claude"])

    def test_codex_spikes_get_a_git_repo_and_their_report_is_collected(self):
        code = self.codex_run("assert 'untrusted' in prompt\n(workdir / 'spike.py').write_text('print(1)')\n"
                              "last.write_text('Built spike.py and ran it: prints 1.')\n")
        self.assertEqual(code, 0)
        workspace = self.state / "workspaces/task-000"
        self.assertTrue((workspace / ".git").is_dir())
        self.assertEqual(self.status("task-000")["status"], "completed")
        self.assertIn("ran it", (self.state / "results/task-000/output.md").read_text())
        with contextlib.redirect_stdout(io.StringIO()):
            td.main(["report", "--state-dir", str(self.state)])
        published = self.home / "pages/batch/files/task-000"
        self.assertEqual(sorted(path.name for path in published.rglob("*")), ["spike.py"])  # no .git

    def test_a_codex_worker_with_no_report_fails(self):
        code = self.codex_run("sys.exit(0)\n")
        self.assertEqual(code, 1)
        self.assertIn("no written result", self.status("task-000")["error"])

    def test_engine_choice(self):
        args = type("Args", (), {"fake_claude": False, "codex": True})()
        spike = {"kind": "spike", "outward": False, "needs_jon": False}
        with patch.object(td.shutil, "which", return_value="/bin/codex"):
            self.assertEqual(td.engine_for(spike, args), "codex")
            self.assertEqual(td.engine_for({**spike, "kind": "research"}, args), "claude")
            self.assertEqual(td.engine_for({**spike, "outward": True}, args), "claude")
            args.codex = False
            self.assertEqual(td.engine_for(spike, args), "claude")
        args.codex = True
        with patch.object(td.shutil, "which", return_value=None):
            self.assertEqual(td.engine_for(spike, args), "claude")

    def test_codex_command_ignores_jons_config_and_stays_sandboxed(self):
        command = td.codex_command(Path("/w"), Path("/l/last.md"))
        self.assertIn("--ignore-user-config", command)
        self.assertEqual(command[command.index("--sandbox") + 1], "workspace-write")
        self.assertNotIn("danger-full-access", command)
        self.assertEqual(command[command.index("-C") + 1], "/w")

    def test_quotamax_caps_the_fan_out(self):
        def answer(stdout):
            return subprocess.CompletedProcess([], 0, stdout=stdout, stderr="")
        cases = [
            (json.dumps({"ok": True, "headroom": "constrained", "advice": {"parallelism": 2}}), (2, "constrained")),
            (json.dumps({"ok": True, "headroom": "ample", "advice": {"parallelism": 8}}), (4, "ample")),
            (json.dumps({"ok": True, "headroom": "critical", "advice": {"parallelism": 2}}), (1, "critical")),
            (json.dumps({"ok": False}), (2, "quotamax unavailable")),
            ("not json", (2, "quotamax unavailable")),
        ]
        self.assertEqual(td.quota_parallelism(4, False), (4, "not configured"))
        self.configure(quota=["node", "quotamax", "agent"])
        for stdout, expected in cases:
            with self.subTest(stdout=stdout), patch.object(td.subprocess, "run", return_value=answer(stdout)):
                self.assertEqual(td.quota_parallelism(4, False), expected)
        self.assertEqual(td.quota_parallelism(4, True), (4, "not checked (fake)"))

    def test_claude_cost_and_turns_are_recorded(self):
        self.tasks(("oss", False, False, "plan"))
        self.run_worker('print(json.dumps({"is_error": False, "subtype": "success", "result": "ok", '
                        '"permission_denials": [], "total_cost_usd": 0.09, "num_turns": 3}))\n')
        status = self.status("task-000")
        self.assertEqual((status["cost_usd"], status["turns"]), (0.09, 3))

    def test_the_page_publishes_worker_files_but_not_the_batch(self):
        self.tasks(("oss", False, False, "plan"))
        self.run_worker('Path("notes.md").write_text("n")\nPath("sub").mkdir()\nPath("sub/a.txt").write_text("a")\n'
                        'Path("__pycache__").mkdir()\nPath("__pycache__/x.pyc").write_text("c")\n' + SUCCESS)
        with contextlib.redirect_stdout(io.StringIO()):
            td.main(["report", "--state-dir", str(self.state)])
        target = self.home / "pages/batch"
        published = sorted(path.relative_to(target).as_posix() for path in target.rglob("*") if path.is_file())
        self.assertEqual(published, ["files/task-000/notes.md", "files/task-000/sub/a.txt", "index.html", "summary.json"])
        index = (self.home / "pages/index.html").read_text()
        self.assertIn('href="batch/"', index)
        self.assertNotIn("http-equiv=\"refresh\"", self.page())               # finished: no auto-refresh


class PlanTests(Base):
    """The app's countdown, route changes, skip and stop."""
    tasks, recorder, status = RoutingTests.tasks, RoutingTests.recorder, RoutingTests.status

    def test_a_route_chosen_in_the_app_wins(self):
        self.tasks(("oss", False, True, "draft"), ("oss", False, False, "plan"), ("oss", True, False, "plan"))
        td.update_plan(self.state, routes={"task-000": "run", "task-001": "skip", "task-002": "draft"})
        self.run_worker(SUCCESS)
        self.assertEqual(self.status("task-000")["status"], "completed")   # was a draft, now runs
        self.assertEqual(self.status("task-001")["status"], "skipped")
        self.assertEqual(self.status("task-002")["status"], "drafted")     # was a to-do, now a draft
        brief = json.loads((self.state / "results/task-002/input.json").read_text())
        self.assertTrue(brief["draft_only"])

    def test_unknown_routes_are_refused(self):
        self.tasks(("oss", False, False, "plan"))
        with self.assertRaises(td.DumpError):
            td.update_plan(self.state, routes={"task-000": "send-it"})

    def test_stop_ends_a_running_worker(self):
        self.tasks(("oss", False, False, "plan"), ("oss", False, False, "plan"))
        command = self.worker("time.sleep(30)\n" + SUCCESS)

        def stop_soon():
            deadline = time.monotonic() + 5
            while not (self.state / "results/task-000/status.json").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            td.update_plan(self.state, stop=["task-000", "task-001"])

        import threading
        threading.Thread(target=stop_soon).start()
        started = time.monotonic()
        with patch.object(td, "claude_command", return_value=command), contextlib.redirect_stdout(io.StringIO()):
            code = td.main(["run", "--state-dir", str(self.state), "--fake-claude", "--concurrency", "1"])
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(code, 0)
        self.assertEqual(self.status("task-000")["status"], "stopped")
        self.assertEqual(self.status("task-001")["status"], "skipped")

    def test_the_countdown_waits_unless_started_now(self):
        self.tasks(("oss", False, False, "plan"))
        started = time.monotonic()
        td.wait_for_start(self.state, 0.3)
        self.assertGreaterEqual(time.monotonic() - started, 0.25)
        self.assertIn("start_at", td.read_plan(self.state))

        other = self.directory / "other"
        self.state, first = other, self.state
        self.tasks(("oss", False, False, "plan"))
        td.update_plan(self.state, start_now=True)
        started = time.monotonic()
        td.wait_for_start(self.state, 30)
        self.assertLess(time.monotonic() - started, 1)

    def test_snapshot_phases(self):
        self.state.mkdir(parents=True)
        td.atomic_text(self.state / "source.md", "Thought dump. Plan a thing.\n")
        self.assertEqual(td.snapshot(self.state)["phase"], "splitting")
        self.assertEqual(td.snapshot(self.state)["text"], "Thought dump. Plan a thing.\n")
        td.write_json(self.state / "failed.json", {"error": "Splitter timed out", "at": "2026-10-16T10:00:00+00:00"})
        self.assertEqual(td.snapshot(self.state)["phase"], "failed")
        (self.state / "failed.json").unlink()
        for name in ("source.md",):
            (self.state / name).unlink()
        self.state.rmdir()
        self.tasks(("oss", False, False, "plan"), ("orbital", True, False, "plan"))
        td.update_plan(self.state, start_at="2999-01-01T00:00:00+00:00")
        view = td.snapshot(self.state)
        self.assertEqual(view["phase"], "planned")
        self.assertEqual([task["route"] for task in view["tasks"]], ["run", "todo"])
        self.assertEqual(view["tasks"][1]["needs_you"], True)
        self.assertEqual(view["tasks"][0]["quote"], "Item 0 words.")
        td.update_plan(self.state, start_now=True)
        self.assertEqual(td.snapshot(self.state)["phase"], "working")
        self.run_worker(SUCCESS)
        view = td.snapshot(self.state)
        self.assertEqual(view["phase"], "done")
        self.assertEqual(view["counts"], {"completed": 1, "for_jon": 1})
        self.assertEqual(view["tasks"][0]["output"], "Local result")

    def test_a_failed_split_is_recorded_for_the_app(self):
        self.state.mkdir(parents=True)
        source = self.state / "source.md"
        td.atomic_text(source, "Synthetic text\n")
        with patch.object(td, "claude_command", return_value=[sys.executable, "-c", "import sys; sys.exit(3)"]), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = td.main(["capture", str(source), "--state-dir", str(self.state), "--fake-claude", "--hold", "0", "--no-notify"])
        self.assertEqual(code, 1)
        view = td.snapshot(self.state)
        self.assertEqual(view["phase"], "failed")
        self.assertIn("exited with code 3", view["error"])

    def test_the_splitter_prompt_comes_from_the_config(self):
        self.configure(owner="Sam", workspaces={"studio": "Sam's design studio", "home": "family"})
        prompt = td.splitter_prompt()
        self.assertIn("The speaker is Sam.", prompt)
        self.assertIn("studio (Sam's design studio), home (family)", prompt)
        self.assertNotIn("orbital", prompt.lower())
        self.assertEqual(td.task_schema()["properties"]["tasks"]["items"]["properties"]["portal"]["enum"],
                         ["studio", "home", "unsure"])


class ServerTests(Base):
    """The app's API, on a real socket."""

    def setUp(self):
        super().setUp()
        import server
        import threading
        from http.server import ThreadingHTTPServer
        self.server_module = server
        td.atomic_text(self.home / "token", "secret-token\n")
        environment = patch.dict(os.environ, {"THOUGHT_DUMP_HOME": str(self.home),
                                              "THOUGHT_DUMP_CAPTURE_ARGS": '["--fake-claude", "--hold", "0", "--no-notify"]'})
        environment.start()
        self.addCleanup(environment.stop)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def call(self, method, path, body=None, token="secret-token", headers=None):
        import urllib.error
        import urllib.request
        request = urllib.request.Request(self.base + path, method=method,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers={**({"Authorization": f"Bearer {token}"} if token else {}), **(headers or {})})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.read()

    def json_call(self, *args, **kwargs):
        code, body = self.call(*args, **kwargs)
        return code, json.loads(body)

    def wait_for(self, dump_id, phase):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            _, view = self.json_call("GET", f"/api/dumps/{dump_id}")
            if view["phase"] == phase:
                return view
            time.sleep(0.1)
        self.fail(f"{dump_id} never reached {phase}: {view}")

    def test_every_route_needs_the_token(self):
        for token in (None, "wrong"):
            self.assertEqual(self.call("GET", "/api/dumps", token=token)[0], 401)
        self.assertEqual(self.json_call("GET", "/api/health")[1]["name"], "Thought Dump")

    def test_tailscale_logins_are_checked_when_configured(self):
        self.configure(server={"allowed_logins": ["jon@example.com"]})
        self.assertEqual(self.call("GET", "/api/health", headers={"Tailscale-User-Login": "someone@else.com"})[0], 401)
        self.assertEqual(self.call("GET", "/api/health", headers={"Tailscale-User-Login": "jon@example.com"})[0], 200)
        self.assertEqual(self.call("GET", "/api/health")[0], 200)    # straight from this Mac

    def test_pairing_by_tailscale_identity(self):
        self.assertEqual(self.call("GET", "/api/pair", token=None)[0], 401)          # not configured
        self.configure(server={"allowed_logins": ["jon@example.com"]})
        self.assertEqual(self.call("GET", "/api/pair", token=None)[0], 401)          # no identity
        self.assertEqual(self.call("GET", "/api/pair", token=None,
                                   headers={"Tailscale-User-Login": "eve@example.com"})[0], 401)
        code, body = self.json_call("GET", "/api/pair", token=None, headers={"Tailscale-User-Login": "jon@example.com"})
        self.assertEqual((code, body["token"]), (200, "secret-token"))

    def test_a_note_becomes_a_dump_that_runs(self):
        note = {"text": "Plan a synthetic picnic.\n\nDraft an email to fictional teammate Alex.",
                "client_id": "client-0001", "recorded_at": "2026-10-16T09:00:00+00:00", "device": "iPhone"}
        code, view = self.json_call("POST", "/api/dumps", note)
        self.assertEqual(code, 201)
        dump_id = view["id"]
        self.assertTrue(dump_id.startswith("app-20261016-090000-"))
        again, same = self.json_call("POST", "/api/dumps", note)          # the app retrying
        self.assertEqual((again, same["id"]), (200, dump_id))
        view = self.wait_for(dump_id, "done")
        self.assertEqual([task["status"] for task in view["tasks"]], ["completed", "drafted"])
        self.assertEqual(view["client"]["device"], "iPhone")
        listing = self.json_call("GET", "/api/dumps")[1]["dumps"]
        self.assertEqual([item["id"] for item in listing], [dump_id])
        self.assertNotIn("output", listing[0]["tasks"][0])
        files = view["tasks"][0]["files"]
        self.assertEqual(files, ["checklist.md"])
        code, body = self.call("GET", f"/api/dumps/{dump_id}/files/task-001/checklist.md")
        self.assertEqual(code, 200)
        self.assertIn(b"Fictional folder tidy", body)
        for bad in ("/files/task-001/../tasks.json", "/files/task-001/%2e%2e/transcript.md", "/files/task-009/x"):
            self.assertEqual(self.call("GET", f"/api/dumps/{dump_id}{bad}")[0], 404, bad)
        self.assertEqual(self.call("POST", f"/api/dumps/{dump_id}/retry", {})[0], 409)

    def test_plan_changes_go_through_the_api(self):
        note = {"text": "Plan a synthetic picnic.", "client_id": "client-0002"}
        with patch.dict(os.environ, {"THOUGHT_DUMP_CAPTURE_ARGS": '["--fake-claude", "--hold", "20", "--no-notify"]'}):
            dump_id = self.json_call("POST", "/api/dumps", note)[1]["id"]
        view = self.wait_for(dump_id, "planned")
        self.assertEqual(view["tasks"][0]["route"], "run")
        code, view = self.json_call("POST", f"/api/dumps/{dump_id}/plan", {"routes": {"task-001": "skip"}})
        self.assertEqual((code, view["tasks"][0]["route"]), (200, "skip"))
        self.assertEqual(self.call("POST", f"/api/dumps/{dump_id}/plan", {"routes": {"task-001": "rm"}})[0], 400)
        self.json_call("POST", f"/api/dumps/{dump_id}/plan", {"start_now": True})
        view = self.wait_for(dump_id, "done")
        self.assertEqual(view["tasks"][0]["status"], "skipped")

    def test_bad_requests(self):
        self.assertEqual(self.call("POST", "/api/dumps", {"text": "", "client_id": "client-0003"})[0], 400)
        self.assertEqual(self.call("POST", "/api/dumps", {"text": "x", "client_id": "../bad"})[0], 400)
        self.assertEqual(self.call("GET", "/api/dumps/../../etc")[0], 404)
        self.assertEqual(self.call("GET", "/api/dumps/nope")[0], 404)
        self.assertEqual(self.call("GET", "/elsewhere")[0], 404)


if __name__ == "__main__":
    unittest.main()
