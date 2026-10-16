#!/usr/bin/env python3
"""Deterministic Claude-shaped subprocess for demos/tests; no network or model."""
import json
from pathlib import Path
import re
import sys


def split(transcript):
    parts = [part.strip() for part in re.split(r"\n\s*\n", transcript) if part.strip()]
    parts = [part for part in parts if not part.startswith("#")]
    tasks = []
    for index, part in enumerate(parts or [transcript.strip()], 1):
        words = re.sub(r"^\d+[.)]\s+|^[-*]\s+", "", part)
        lower = words.lower()
        outward = bool(re.search(r"\b(email|send|publish|post|deploy|pay|slack|whatsapp|linkedin|teammate)\b", lower))
        kind = next((kind for kind in ("draft", "fix", "spike", "research", "plan") if re.search(rf"\b{kind}\b", lower)), "plan")
        task_id = f"task-{index:03d}"
        needs_jon = bool(re.search(r"\b(pay|buy|renew|subscription|sign in)\b", lower))
        portal = next((name for name in ("orbital", "recos", "founder", "personal") if name in lower), "unsure")
        tasks.append({
            "id": task_id, "title": words.split(".")[0][:100], "jon_words": words,
            "kind": kind, "outward": outward, "workspace": f"workspaces/{task_id}",
            "portal": portal, "needs_jon": needs_jon,
            "mentions": [{"name": name, "kind": "person"}
                         for name in re.findall(r"(?:teammate|partner|to|with) ([A-Z][a-z]+)", words)][:6],
        })
    return {"tasks": tasks}


def work(task, draft_only):
    if draft_only:
        return (
            "[FAKE CLAUDE — illustrative draft; nothing sent]\n\n"
            "Subject: Feedback on the thought-label prototype\n\n"
            "Hi Alex,\nCould you review the small thought-label prototype when you have a moment? "
            "I'd appreciate feedback on the labels and edge cases.\nThanks!\n\n"
            "This fixture draft is canned; no recipient was contacted."
        )
    if task["kind"] == "spike":
        Path("prototype.py").write_text(
            '"""Synthetic demo artifact; a punctuation heuristic, not intent recognition."""\n'
            'def label_thought(text):\n'
            '    return "question" if text.rstrip().endswith("?") else "idea"\n',
            encoding="utf-8",
        )
        return (
            "[FAKE CLAUDE — canned fixture implementation]\n\n"
            "Created prototype.py with label_thought(text).\n"
            "Limit: punctuation only; rhetorical questions and empty input need product decisions.\n"
            "The stub did not test this file; scripts/demo.py checks it separately."
        )
    Path("checklist.md").write_text(
        "# Fictional folder tidy\n\n- 0–5 min: inventory files.\n"
        "- 5–10 min: propose groups.\n- 10–15 min: identify duplicates for review.\n"
        "- 15–20 min: review the plan before moving anything.\n",
        encoding="utf-8",
    )
    return (
        "[FAKE CLAUDE — canned fixture plan]\n\nCreated checklist.md.\n"
        "No existing files were moved or deleted; the folder is fictional."
    )


def main():
    request = json.load(sys.stdin)
    response = {"type": "result", "subtype": "success", "is_error": False, "permission_denials": []}
    if request["operation"] == "split":
        response["structured_output"] = split(request["transcript"])
        response["result"] = ""
    else:
        response["result"] = work(request["task"], request["draft_only"])
    print(json.dumps(response))


if __name__ == "__main__":
    main()

