#!/usr/bin/env python3
"""Aggregate per-route bot reports into an iteration report, or iterations into a summary.

Kept out of `loop.sh` deliberately. The aggregation has to partition a route
list into visited and unvisited and then ASSERT that the partition accounts for
every route — a shell pipeline of `jq` and `comm` can get that subtly wrong in
a way that reads as a clean run, and bulk JSON must not cross into argv anyway.

Two modes:

    loop_report.py iteration --routes FILE --area-reports DIR --out FILE ...
    loop_report.py summary --iterations FILE [FILE ...] --out FILE

Exit codes:
    0  report written, coverage partition accounts for every route
    4  a route is in neither the visited nor the unvisited list (a report bug)
    2  bad usage / unreadable input
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from typing import Any, Dict, List

# The oracle categories bot.py can emit, grouped by the question a reader asks
# of the report. `console` is deliberately present and deliberately always
# empty: bot.py fetches over urllib and never executes JavaScript, so it cannot
# observe a console error. An absent key would invite someone to read "no
# console errors" into a report that never looked.
NETWORK_CATEGORIES = {"BACKEND_HANG_TIMEOUT", "NETWORK_UNREACHABLE"}
HTTP_CATEGORIES = {"HTTP_5XX_SERVER_ERROR", "HTTP_STATUS_ERROR"}
CRASH_CATEGORIES = {"BAD_GATEWAY_BANNER", "APP_CRASH_BANNER"}


def read_json(path: str) -> Dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def read_routes(path: str) -> List[str]:
    with open(path, encoding="utf-8") as handle:
        return [line.strip() for line in handle if line.strip() and not line.startswith("#")]


def build_iteration(args) -> int:
    routes = read_routes(args.routes)
    if not routes:
        print(f"loop_report: empty route list {args.routes}", file=sys.stderr)
        return 2

    area_reports = sorted(glob.glob(os.path.join(args.area_reports, "*.json")))

    visited_status: Dict[str, int] = {}
    areas: List[Dict[str, Any]] = []
    defects: List[Dict[str, Any]] = []

    for report_path in area_reports:
        try:
            report = read_json(report_path)
        except (OSError, json.JSONDecodeError) as exc:
            # A bot run that died before writing valid JSON is itself a finding
            # about the run, not something to drop on the floor.
            areas.append(
                {
                    "report": os.path.basename(report_path),
                    "readable": False,
                    "error": str(exc),
                }
            )
            continue

        for path, status in (report.get("path_status") or {}).items():
            previous = visited_status.get(path)
            visited_status[path] = status if previous is None else max(previous, status)

        for defect in report.get("defects") or []:
            defect = dict(defect)
            defect["area"] = report.get("area_scope")
            defects.append(defect)

        areas.append(
            {
                "report": os.path.basename(report_path),
                "readable": True,
                "area": report.get("area_scope"),
                "turns_executed": report.get("turns_executed"),
                "duration_seconds": report.get("duration_seconds"),
                "visited_paths": report.get("visited_paths") or [],
                "defects_count": report.get("defects_count", 0),
                "passed": report.get("passed"),
                "mode": report.get("mode"),
            }
        )

    visited = [route for route in routes if route in visited_status]
    unvisited = [route for route in routes if route not in visited_status]

    # Routes the bot wandered onto that were never asked for. Not a failure —
    # the bot follows links — but worth reporting, because a route appearing
    # here and not in `routes` means the derived surface missed something.
    incidental = sorted(set(visited_status) - set(routes))

    # The coverage partition invariant. If this ever trips, the report is lying
    # about what was covered, which is worse than a failing test.
    accounted = set(visited) | set(unvisited)
    missing = [route for route in routes if route not in accounted]
    if missing or len(visited) + len(unvisited) != len(set(routes)):
        print(
            "loop_report: coverage partition does not account for every route; "
            f"missing={missing} visited={len(visited)} unvisited={len(unvisited)} "
            f"routes={len(set(routes))}",
            file=sys.stderr,
        )
        return 4

    def by_category(categories):
        return [d for d in defects if d.get("category") in categories]

    iteration = {
        "run_id": args.run_id,
        "iteration": args.iteration,
        "started_at": args.started_at,
        "finished_at": args.finished_at,
        "base_url": args.base_url,
        "dashboard": {
            "mode": args.dashboard_mode,
            "port": args.port,
            "started_locally": args.started_locally,
        },
        "turns_per_route": args.turns,
        "timeout_per_route_seconds": args.timeout,
        "routes_total": len(set(routes)),
        "routes_visited": visited,
        "routes_visited_count": len(visited),
        "routes_unvisited": unvisited,
        "routes_unvisited_count": len(unvisited),
        "routes_incidental": incidental,
        "coverage_ratio": round(len(visited) / len(set(routes)), 4),
        "path_status": visited_status,
        "areas": areas,
        "bugs": defects,
        "bug_count": len(defects),
        "http_errors": by_category(HTTP_CATEGORIES),
        "network_errors": by_category(NETWORK_CATEGORIES),
        "crash_errors": by_category(CRASH_CATEGORIES),
        # See NETWORK_CATEGORIES above: structurally unobservable from an
        # HTTP-level bot, reported as such rather than omitted.
        "console_errors": [],
        "console_errors_observable": False,
        "passed": not defects and not any(a.get("readable") is False for a in areas),
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(iteration, handle, indent=2)
        handle.write("\n")

    print(
        f"iteration {args.iteration}: {len(visited)}/{len(set(routes))} routes visited, "
        f"{len(defects)} bug(s), {len(unvisited)} unvisited"
    )
    return 0


def build_summary(args) -> int:
    iterations = []
    for path in args.iterations:
        try:
            iterations.append(read_json(path))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"loop_report: cannot read {path}: {exc}", file=sys.stderr)
            return 2

    if not iterations:
        print("loop_report: no iteration reports to summarise", file=sys.stderr)
        return 2

    union_visited: Dict[str, int] = {}
    for iteration in iterations:
        for path, status in (iteration.get("path_status") or {}).items():
            previous = union_visited.get(path)
            union_visited[path] = status if previous is None else max(previous, status)

    routes_total = max(i.get("routes_total", 0) for i in iterations)
    # A route unvisited in EVERY iteration is the one that needs chasing; one
    # that was missed once and hit later is a flake, not a gap.
    never_visited = sorted(
        set.intersection(*[set(i.get("routes_unvisited") or []) for i in iterations])
    ) if iterations else []

    summary = {
        "run_id": args.run_id or iterations[0].get("run_id"),
        "iterations": len(iterations),
        "iteration_reports": [os.path.basename(p) for p in args.iterations],
        "base_url": iterations[0].get("base_url"),
        "dashboard": iterations[0].get("dashboard"),
        "routes_total": routes_total,
        "routes_visited_union": sorted(union_visited),
        "routes_visited_union_count": len(union_visited),
        "routes_never_visited": never_visited,
        "coverage_ratio_union": round(len(union_visited) / routes_total, 4) if routes_total else 0.0,
        "per_iteration": [
            {
                "iteration": i.get("iteration"),
                "routes_visited_count": i.get("routes_visited_count"),
                "routes_unvisited_count": i.get("routes_unvisited_count"),
                "bug_count": i.get("bug_count"),
                "passed": i.get("passed"),
            }
            for i in iterations
        ],
        "bug_count_total": sum(i.get("bug_count", 0) for i in iterations),
        "bugs": [bug for i in iterations for bug in (i.get("bugs") or [])],
        "console_errors_observable": False,
        "passed": all(i.get("passed") for i in iterations),
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")

    print(
        f"summary: {len(iterations)} iteration(s), "
        f"{len(union_visited)}/{routes_total} routes covered across the run, "
        f"{summary['bug_count_total']} bug(s)"
    )
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="mode", required=True)

    iteration = sub.add_parser("iteration", help="Aggregate per-route bot reports")
    iteration.add_argument("--routes", required=True, help="File of requested routes, one per line")
    iteration.add_argument("--area-reports", required=True, help="Directory of per-route bot JSON")
    iteration.add_argument("--out", required=True)
    iteration.add_argument("--run-id", default="")
    iteration.add_argument("--iteration", type=int, default=1)
    iteration.add_argument("--base-url", default="")
    iteration.add_argument("--dashboard-mode", default="")
    iteration.add_argument("--port", default="")
    iteration.add_argument("--started-locally", action="store_true")
    iteration.add_argument("--started-at", default="")
    iteration.add_argument("--finished-at", default="")
    iteration.add_argument("--turns", type=int, default=0)
    iteration.add_argument("--timeout", type=int, default=0)
    iteration.set_defaults(func=build_iteration)

    summary = sub.add_parser("summary", help="Aggregate iteration reports")
    summary.add_argument("--iterations", nargs="+", required=True)
    summary.add_argument("--out", required=True)
    summary.add_argument("--run-id", default="")
    summary.set_defaults(func=build_summary)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
