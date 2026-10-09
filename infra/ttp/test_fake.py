"""Real HTTP/lifecycle check of the standalone synthetic upstream bundle."""
import json
import os
import secrets
import socket
import subprocess
import time
import unittest
import urllib.error
import urllib.request


class FakeBoundaryTest(unittest.TestCase):
    def test_frozen_http_and_clean_shutdown(self):
        for port in (4001, 4002):
            with socket.socket() as probe:
                self.assertNotEqual(probe.connect_ex(("127.0.0.1", port)), 0, "port occupied")
        token = "svc_" + secrets.token_hex(32)
        env = {**os.environ, "INCLUIR_PRINT_SERVICE_TOKEN": token}
        # Signal the actual runtime, not a Volta/fnm launcher subprocess.
        node = subprocess.check_output(["node", "-p", "process.execPath"], text=True).strip()
        proc = subprocess.Popen(
            [node, "dist/ttp/fake-upstream.mjs"], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def request(path, authenticated=True, method="GET"):
            req = urllib.request.Request(
                "http://127.0.0.1:4001" + path,
                headers={"Authorization": "Bearer " + token} if authenticated else {},
                method=method,
            )
            try:
                with opener.open(req, timeout=3) as response:
                    return response.status, response.read()
            except urllib.error.HTTPError as error:
                try:
                    return error.code, error.read()
                finally:
                    error.close()

        try:
            for _ in range(100):
                try:
                    code, body = request("/healthz", False)
                    self.assertEqual(code, 200)
                    self.assertEqual(json.loads(body)["delayMs"], 0)
                    break
                except urllib.error.URLError:
                    self.assertIsNone(proc.poll())
                    time.sleep(0.1)
            else:
                self.fail("fake startup timeout")
            # The actual bundled server must wire the loopback control listener.
            with opener.open("http://127.0.0.1:4002/status", timeout=3) as response:
                control = json.load(response)
                self.assertEqual(control["phase"], "idle")
                self.assertTrue(control["configured"])
                self.assertEqual(control["generation"], 0)
                self.assertTrue(control["boot_id"])
            reset = urllib.request.Request("http://127.0.0.1:4002/reset", method="POST",
                data=json.dumps({"boot_id": control["boot_id"], "generation": 0,
                    "trial_id": "not-a-trial", "scenario": "unconfigured"}).encode(),
                headers={"Content-Type": "application/json"})
            with self.assertRaises(urllib.error.HTTPError) as pending:
                opener.open(reset, timeout=3)
            self.assertEqual(pending.exception.code, 400)
            pending.exception.close()
            self.assertEqual(request("/api/print-portal/v2/batches", False)[0], 401)
            def admin(path, payload):
                req = urllib.request.Request("http://127.0.0.1:4002" + path, method="POST",
                    data=json.dumps(payload).encode(), headers={"Content-Type":"application/json"})
                with opener.open(req, timeout=3) as response:
                    return json.load(response)
            prepared = admin("/reset", {"boot_id":control["boot_id"],"generation":0,
                "trial_id":"bundle-test","scenario":"flow"})
            admin("/start", {k:prepared[k] for k in ("boot_id","generation","trial_id")})
            code, data = request("/api/print-portal/v2/batches/open")
            self.assertEqual(code, 200)
            batch = json.loads(data)["batch"]
            item = batch["items"][0]
            file = item["jobs"][0]["file"]
            code, data = request("/api/print-portal/v2/batches/" + batch["id"] + "/orders/" + item["orderId"] + "/files/" + file["id"])
            self.assertEqual(code, 200)
            import hashlib
            self.assertEqual(hashlib.sha256(data).hexdigest(), file["sha256"])
            self.assertEqual(len(data), file["bytes"])
            with opener.open("http://127.0.0.1:4002/manifest", timeout=3) as response:
                manifest = json.load(response)
                self.assertEqual(manifest["source_sha"], "270224676d61431c2d26a8e20ec911c328a1f5f3")
                self.assertEqual(manifest["generation"], 1)
                self.assertEqual(manifest["checkpoints"], [])
            self.assertEqual(request("/__ttp/status", False)[0], 404)
            self.assertEqual(request("/api/print-portal/v1/orders", False)[0], 401)
            code, body = request("/api/print-portal/v1/orders")
            page = json.loads(body)
            self.assertEqual(code, 200)
            self.assertEqual(len(page["items"]), 1)
            order_id = page["items"][0]["id"]
            code, body = request("/api/print-portal/v1/orders/" + order_id)
            self.assertEqual(code, 200)
            self.assertEqual(len(json.loads(body)["order"]["jobs"]), 2)
            self.assertEqual(request(
                "/api/print-portal/v1/orders/" + order_id + "/collected", method="POST"
            )[0], 405)
            self.assertEqual(json.loads(request("/api/print-portal/v1/orders")[1]), page)
            proc.terminate()
            try:
                out, err = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired as error:
                captured = error.stdout or b""
                self.fail("shutdown timeout; signal_handler_seen=" + str(
                    b"ttp_fake_stopping" in captured
                ))
            self.assertEqual(proc.returncode, 0)
            self.assertNotIn(token, out + err)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate(timeout=5)
            for stream in (proc.stdout, proc.stderr):
                if stream is not None:
                    stream.close()


if __name__ == "__main__":
    unittest.main()
