#!/usr/bin/env python3
"""Thought Dump context adapter for any Taxi / Orbital semantic layer.

Runs one TaxiQL query per name, from templates you write for your own types, against Orbital's
/api/taxiql endpoint. The spoken name is the only thing substituted, and only after a strict check
(letters, digits, spaces, `.&-`; no quotes), so a sentence in a voice note can't change the query.

    python3 adapters/taxi.py --url http://localhost:9022 --queries ~/.thought-dump/taxi-queries.json

taxi-queries.json maps a kind to a query, with {name} where the name goes:
    {"person": "find { Person[](Name == '{name}') }",
     "organisation": "find { Company[](CompanyName == '{name}') }"}

stdin:  {"kind": "person" | "organisation", "name": "Sam", "workspace": "work"}
stdout: {"found": true, "title": "...", "summary": "...", "text": "..."} or {"found": false, "reason": "..."}
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

NAME = re.compile(r"[^\W_][\w .&-]{0,59}")


def summarise(name, rows):
    first = rows[0]
    if not isinstance(first, dict):
        return {"found": True, "title": name, "summary": str(first)[:160], "text": json.dumps(rows, indent=2)[:4000]}
    scalars = [(key, value) for key, value in first.items() if isinstance(value, (str, int, float)) and str(value).strip()]
    title = next((str(value) for key, value in scalars if "name" in key.lower()), name)
    summary = " · ".join(str(value) for key, value in scalars if str(value) != title)[:160]
    if len(rows) > 1:
        summary = f"{len(rows)} matches · " + summary
    return {"found": True, "title": title[:80], "summary": summary[:160], "text": json.dumps(rows, indent=2)[:4000]}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", default=os.environ.get("ORBITAL_URL", "http://localhost:9022"))
    parser.add_argument("--queries", required=True, help="JSON file: {kind: TaxiQL with {name}}")
    parser.add_argument("--timeout", type=float, default=15)
    args = parser.parse_args()
    request = json.load(sys.stdin)
    name = str(request.get("name", "")).strip()
    if not NAME.fullmatch(name):
        print(json.dumps({"found": False, "reason": "name has characters a query can't take"}))
        return 0
    with open(os.path.expanduser(args.queries), encoding="utf-8") as handle:
        template = json.load(handle).get(request.get("kind"))
    if not template:
        print(json.dumps({"found": False, "reason": f"no query for {request.get('kind')}"}))
        return 0
    query = template.replace("{name}", name)
    post = urllib.request.Request(args.url.rstrip("/") + "/api/taxiql", data=query.encode(),
                                  headers={"Content-Type": "application/taxiql", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(post, timeout=args.timeout) as response:
            rows = json.loads(response.read() or b"[]")
    except (urllib.error.URLError, ValueError, TimeoutError) as exc:
        print(json.dumps({"found": False, "reason": f"Orbital didn't answer: {type(exc).__name__}"}))
        return 0
    rows = rows if isinstance(rows, list) else [rows]
    rows = [row for row in rows if row]
    print(json.dumps(summarise(name, rows) if rows else {"found": False, "reason": "no match"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
