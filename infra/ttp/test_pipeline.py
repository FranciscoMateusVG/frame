"""Exercise timing records through real subprocess exits; no mocked process boundary."""
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
import pipeline


class TimingTests(unittest.TestCase):
    def test_real_success_and_failure_are_preserved(self):
        previous_state = pipeline.STATE
        previous_command = pipeline.COMMANDS["ts"]["install"]
        try:
            with tempfile.TemporaryDirectory(prefix="ttp-timing-test-") as tmp:
                pipeline.STATE = Path(tmp)
                pipeline.save("context", {"variant": "ts"})
                for exit_code in (0, 7):
                    pipeline.COMMANDS["ts"]["install"] = "exit " + str(exit_code)
                    self.assertEqual(pipeline.run("install"), exit_code)
                    record = json.loads((Path(tmp) / "install.json").read_text())
                    self.assertEqual(record["exit_code"], exit_code)
                    self.assertEqual(record["status"], "success" if exit_code == 0 else "failure")
                    self.assertGreaterEqual(record["duration_ms"], 0)
                    self.assertLessEqual(record["started_at"], record["finished_at"])
        finally:
            pipeline.STATE = previous_state
            pipeline.COMMANDS["ts"]["install"] = previous_command

    def test_run_state_can_live_outside_source_checkout(self):
        with tempfile.TemporaryDirectory(prefix="ttp-runner-temp-") as tmp:
            output = subprocess.check_output(
                [sys.executable, "-c", "import pipeline; print(pipeline.STATE)"],
                cwd=Path(__file__).parent,
                env={**os.environ, "TTP_STATE_DIR": tmp}, text=True,
            ).strip()
            self.assertEqual(output, tmp)

    def test_resume_uses_frozen_selector_not_changed_environment(self):
        from test_feature_smoke import config
        import hashlib
        previous_state, previous_env = pipeline.STATE, dict(os.environ)
        try:
            with tempfile.TemporaryDirectory(prefix="ttp-selector-test-") as tmp:
                pipeline.STATE = Path(tmp)
                sha = pipeline.capture(["git", "rev-parse", "HEAD"])
                setting = config()
                context = {"source_sha": sha, "event": "push", "repo": "owner/frame",
                           "run_id": "42", "run_attempt": "1", "variant": "ts",
                           "smoke_config": setting, "fake_upstream": {"source_sha": setting["fake_sha"]},
                           "smoke_config_sha256": hashlib.sha256(json.dumps(setting, sort_keys=True).encode()).hexdigest()}
                pipeline.save("context", context)
                for stage in pipeline.STAGES[:4]: pipeline.save(stage, {"status": "success"})
                os.environ.update(GITHUB_SHA=sha, GITHUB_REPOSITORY="owner/frame", GITHUB_RUN_ID="42",
                                  GITHUB_RUN_ATTEMPT="1", GITHUB_BASE_REF="", GITHUB_REF_NAME="portal-ts",
                                  TTP_SMOKE_CONFIG="invalid newer variable must not affect this run")
                pipeline.resume()
                self.assertEqual(pipeline.load("context")["smoke_config"], setting)
                context["smoke_config"]["generation"] += 1
                pipeline.save("context", context)
                with self.assertRaises(AssertionError): pipeline.resume()
        finally:
            pipeline.STATE = previous_state
            os.environ.clear(); os.environ.update(previous_env)



if __name__ == "__main__":
    unittest.main()
