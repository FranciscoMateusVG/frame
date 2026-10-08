"""Partition merge-to-smoke wall time; API steps have only second precision."""
import datetime as dt


def micros(value):
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    delta = parsed - dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)
    return (delta.days * 86400 + delta.seconds) * 1_000_000 + delta.microseconds


def breakdown(merged_at, created_at, smoke_at, jobs, stages):
    if not merged_at or not created_at or not smoke_at or not jobs:
        return {"status": "unavailable", "reason": "merge/workflow/jobs/smoke metadata missing"}
    start, end = micros(merged_at), micros(smoke_at)
    if end < start: raise ValueError("negative wall interval")
    intervals = []

    def add(left, right, bucket, priority):
        if not left or not right: return
        a, b = max(start, micros(left)), min(end, micros(right))
        if b > a: intervals.append((a, b, bucket, priority))

    checks = next((j for j in jobs if j["name"] == "checks"), None)
    deploy = next((j for j in jobs if j["name"] == "deploy"), None)
    if not checks or not deploy:
        return {"status": "unavailable", "reason": "both jobs required"}
    add(merged_at, created_at, "dispatch", 2)
    add(created_at, checks["started_at"], "queue", 2)
    add(checks.get("completed_at"), deploy["started_at"], "handoff", 2)
    for job in jobs:
        add(job["started_at"], job.get("completed_at") or smoke_at, "job_overhead", 0)
        finished = [s["completed_at"] for s in job.get("steps", []) if s.get("completed_at")]
        if finished and job.get("completed_at"):
            add(max(finished), job["completed_at"], "job_finalization", 1)
        for step in job.get("steps", []):
            name = step["name"]
            if name == "cache": bucket = "cache_restore"
            elif name == "Post cache": bucket = "cache_save"
            elif name in ("timing-report", "timing-artifact"): bucket = "evidence_report_upload"
            elif name.startswith("Post ") or name == "Complete job": bucket = "job_teardown"
            elif name in ("Set up job", "setup", "infrastructure-self-tests",
                          "checks-evidence", "validate-checks-evidence") or name.startswith("Run actions/checkout@"):
                bucket = "setup"
            else: continue
            add(step.get("started_at"), step.get("completed_at"), bucket, 3)
    # Stage boundaries override rounded API step boundaries. Clip the final stage
    # at smoke.completed_at; process-exit overhead after acceptance is not TTP.
    for stage in stages:
        add(stage.get("started_at"), stage.get("finished_at"), "timed_stages", 4)
    points = sorted({start, end, *(p for row in intervals for p in row[:2])})
    buckets = {key: 0 for key in ("dispatch", "queue", "setup", "cache_restore",
        "cache_save", "handoff", "timed_stages", "evidence_report_upload",
        "job_teardown", "job_finalization", "job_overhead", "unattributed")}
    for a, b in zip(points, points[1:]):
        covering = [row for row in intervals if row[0] <= a and row[1] >= b]
        bucket = max(covering, key=lambda row: row[3])[2] if covering else "unattributed"
        buckets[bucket] = buckets.get(bucket, 0) + b - a
    return {
        "status": "complete", "start_at": merged_at, "end_at": smoke_at,
        "total_ms": (end - start) / 1000,
        "buckets_ms": {key: value / 1000 for key, value in sorted(buckets.items())},
        "source": "GitHub merged PR timestamp + workflow/jobs/steps API + local stage/smoke timestamps",
        "precision": "GitHub job/step timestamps are whole seconds; adjacent setup/overhead buckets inherit that uncertainty",
        "notes": ["Buckets partition the interval without double counting",
                  "Dokploy queue/rebuild/readiness are already inside staging-deploy; not an extra bucket",
                  "Monotonic stage duration sum can differ slightly from clipped wall intervals",
                  "Image cleanup/final artifact upload after smoke are excluded from merge-to-smoke",
                  "Queue and handoff include scheduling delays; do not claim all are runner occupancy"],
    }
