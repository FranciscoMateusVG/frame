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



if __name__ == "__main__":
    unittest.main()
