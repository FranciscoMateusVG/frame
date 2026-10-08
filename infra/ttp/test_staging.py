"""Opt-in live HTTP regression; inputs arrive on stdin, never argv or logs.

Run only against the three synthetic staging portals. This deliberately does
not fake the cookie, Origin, CSRF, login, orders or logout HTTP boundaries.
The caller supplies a native secret-store read; CI exercises OIDC separately.
"""
import json
import sys
from staging import portal_smoke


def live():
    inputs = json.load(sys.stdin)
    variant = inputs["variant"]
    assert variant in ("ts", "rust", "phoenix")
    origin = "https://staging-grafica-" + variant + ".programaincluir.org"
    result = portal_smoke({"variant": variant, "source_sha": inputs["revision"]}, origin, inputs["password"])
    assert result["status"] == "success" and result["fixture_match"] and result["logout"]
    print(json.dumps({"variant": variant, "status": "success", "real_http_boundary": True}))


if __name__ == "__main__":
    try:
        live()
    except Exception as error:
        print("Live smoke regression: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
