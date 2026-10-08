"""Pure timeline partition tests: no mocked network/process boundaries."""
import unittest
from timing import breakdown


class TimelineTests(unittest.TestCase):
    def test_queue_cache_handoff_and_finalization_are_not_stage_time(self):
        at = lambda s: f"2026-10-08T00:00:{s:02d}Z"
        jobs = [
            {"name": "checks", "started_at": at(10), "completed_at": at(30), "steps": [
                {"name": "setup", "started_at": at(10), "completed_at": at(12)},
                {"name": "cache", "started_at": at(12), "completed_at": at(15)},
                {"name": "install", "started_at": at(15), "completed_at": at(20)},
                {"name": "Post cache", "started_at": at(20), "completed_at": at(22)},
            ]},
            {"name": "deploy", "started_at": at(35), "completed_at": None, "steps": [
                {"name": "setup", "started_at": at(35), "completed_at": at(37)},
                {"name": "staging-smoke", "started_at": at(37), "completed_at": at(40)},
                {"name": "image-cleanup", "started_at": at(40), "completed_at": at(42)},
            ]},
        ]
        stages = [{"id": "install", "started_at": at(15), "finished_at": at(20)},
                  {"id": "staging-smoke", "started_at": at(37), "finished_at": at(41)}]
        result = breakdown(at(0), at(2), at(40), jobs, stages)
        buckets = result["buckets_ms"]
        self.assertEqual(result["total_ms"], 40000)
        self.assertEqual(sum(buckets.values()), 40000)
        self.assertEqual(buckets["dispatch"], 2000)
        self.assertEqual(buckets["queue"], 8000)
        self.assertEqual(buckets["cache_restore"], 3000)
        self.assertEqual(buckets["cache_save"], 2000)
        self.assertEqual(buckets["handoff"], 5000)
        self.assertEqual(buckets["job_finalization"], 8000)
        self.assertEqual(buckets["setup"], 4000)
        self.assertEqual(buckets["timed_stages"], 8000)
        self.assertNotIn("image-cleanup", str(result))

    def test_missing_metadata_is_not_a_zero_duration_success(self):
        self.assertEqual(breakdown(None, None, None, [], [])["status"], "unavailable")


if __name__ == "__main__": unittest.main()
