"""Scoped webhook and HTTP smoke. Secrets only live in this process's memory."""
import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pipeline import load, now, save


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


STRICT = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())


def json_request(url, body=None, headers=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json", **(headers or {})})
    with STRICT.open(req, timeout=20) as response:
        if response.status != 200:
            raise RuntimeError("unexpected HTTP status")
        assert response.headers.get_content_type() == "application/json"
        return json.load(response)


def secret_reader():
    assert os.environ["GITHUB_EVENT_NAME"] == "push"
    audience = "https://github.com/FranciscoMateusVG"
    oidc_url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]
    oidc_url += ("&" if "?" in oidc_url else "?") + urllib.parse.urlencode({"audience": audience})
    jwt = json_request(oidc_url, headers={"Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})["value"]
    base = os.environ["INFISICAL_URL"].rstrip("/")
    assert urllib.parse.urlsplit(base).scheme in ("http", "https")
    auth = json_request(base + "/api/v1/auth/oidc-auth/login", {
        "identityId": os.environ["INFISICAL_IDENTITY_ID"], "jwt": jwt})
    headers = {"Authorization": "Bearer " + auth["accessToken"]}
    project = os.environ["INFISICAL_PROJECT_ID"]
    assert project and os.environ["INFISICAL_ENVIRONMENT"] == "staging"
    # A nonexistent key proves authorization denial without fetching real prod data.
    for denied_project, denied_env in [(project, "prod"), (os.environ["INFISICAL_DENIED_PROJECT_ID"], "prod")]:
        query = urllib.parse.urlencode({"workspaceId": denied_project, "environment": denied_env, "secretPath": "/"})
        try:
            json_request(base + "/api/v3/secrets/raw/TTP_SCOPE_DENIAL_PROBE?" + query, headers=headers)
        except urllib.error.HTTPError as error:
            code = error.code
            error.close()
            if code not in (401, 403):
                raise RuntimeError("scope denial not proven") from None
        else:
            raise RuntimeError("scope unexpectedly allowed")

    def read(key):
        assert re.fullmatch(r"[A-Z_]+", key)
        query = urllib.parse.urlencode({"workspaceId": project, "environment": "staging", "secretPath": "/"})
        return json_request(base + "/api/v3/secrets/raw/" + key + "?" + query, headers=headers)["secret"]["secretValue"]
    return read


def branch_sha(ctx):
    data = json_request(f'https://api.github.com/repos/{ctx["repo"]}/git/ref/heads/{ctx["branch"]}',
        headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"], "Accept": "application/vnd.github+json"})
    return data["object"]["sha"]


def deploy(ctx, origin):
    read = secret_reader()
    hook = read("DOKPLOY_WEBHOOK_" + ctx["variant"].upper())
    parsed = urllib.parse.urlsplit(hook)
    allowed = urllib.parse.urlsplit(os.environ["DOKPLOY_WEBHOOK_ORIGIN"])
    assert parsed.scheme == allowed.scheme and parsed.netloc == allowed.netloc
    assert parsed.scheme in ("http", "https")
    assert parsed.path.startswith("/api/deploy/compose/") and not parsed.query
    result = {"requested_sha": ctx["source_sha"], "requested_at": now(),
        "deployment_id": None, "remote_image_id": None, "finished_at": None,
        "remote_metadata_status": "not_exposed", "healthy_at": None}
    if branch_sha(ctx) != ctx["source_sha"]:
        result["status"] = "invalidated_branch_race_before_deploy"
        save("deployment", result)
        raise RuntimeError("superseded before deploy")
    save("deployment", result)
    json_request(hook, {"ref": "refs/heads/" + ctx["branch"], "after": ctx["source_sha"],
        "head_commit": {"id": ctx["source_sha"], "message": "TTP CI gates passed"},
        "commits": [{"id": ctx["source_sha"], "modified": ["docker-compose.staging.yml"]}]},
        {"X-GitHub-Event": "push"})
    result["accepted_at"] = now()
    save("deployment", result)
    deadline = time.monotonic() + 1200
    while time.monotonic() < deadline:
        if branch_sha(ctx) != ctx["source_sha"]:
            result["status"] = "invalidated_branch_race"
            save("deployment", result)
            raise RuntimeError("branch race")
        try:
            revision = json_request(origin + "/version")["revision"]
            with STRICT.open(origin + "/healthz", timeout=10) as response:
                healthy = response.status == 200
            if healthy and revision == ctx["source_sha"]:
                result.update(observed_sha=revision, healthy_at=now(), status="healthy_revision_observed")
                save("deployment", result)
                return
        except (urllib.error.URLError, ValueError, KeyError):
            pass
        time.sleep(5)
    result["status"] = "readiness_timeout"
    save("deployment", result)
    raise RuntimeError("readiness timeout")


def portal_smoke(ctx, origin, password, result=None):
    result = result if result is not None else {"started_at": now(), "status": "running"}
    result["authentication_transport"] = "json_session_api"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(path, method="GET", body=None, csrf=None, expected=200, as_json=False):
        headers = {"Origin": origin}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if csrf is not None:
            headers["X-CSRF-Token"] = csrf
        req = urllib.request.Request(origin + path, method=method,
            data=None if body is None else json.dumps(body).encode(), headers=headers)
        with opener.open(req, timeout=20) as response:
            assert response.status == expected
            assert response.geturl() == origin + path
            if as_json:
                assert response.headers.get_content_type() == "application/json"
                return json.load(response)
            return response.read().decode()

    result["checkpoint"] = "public_endpoints"
    assert request("/version", as_json=True) == {"revision": ctx["source_sha"]}
    request("/healthz")
    request("/login")
    result["checkpoint"] = "pre_session"
    pre = request("/api/session", as_json=True)
    assert pre["authenticated"] is False and pre["csrfToken"]
    result["checkpoint"] = "login"
    session = request("/api/session", method="POST", body={"password": password},
        csrf=pre["csrfToken"], as_json=True)
    assert session["authenticated"] is True and session["csrfToken"]
    try:
        result["checkpoint"] = "orders"
        page = request("/orders")
        data = request("/api/print/v1/orders", as_json=True)
        fixture_ids = ["6b8337b0-4dbc-4c1f-8644-9691aa494c21"]
        assert sorted(item["id"] for item in data["items"]) == fixture_ids and data["nextCursor"] is None
        assert all("/orders/" + order_id in page for order_id in fixture_ids)
        result.update(health=200, login=200, orders_html=200, orders_api=200, fixture_match=True)
    finally:
        result["logout_attempted"] = True
        request("/api/session", method="DELETE", csrf=session["csrfToken"], expected=204)
        result["logout"] = True
    result.update(status="success", completed_at=now(), checkpoint="complete",
        visually_verified=False, phoenix_ws="separate_acceptance_probe" if ctx["variant"] == "phoenix" else "not_applicable")
    return result


def smoke(ctx, origin):
    result = {"started_at": now(), "status": "running", "checkpoint": "secret_reader"}
    save("smoke", result)
    try:
        read = secret_reader()
        result["oidc_scope_denial_proven"] = True
        password = read("PRINT_PORTAL_PASSWORD_" + ctx["variant"].upper())
        portal_smoke(ctx, origin, password, result)
    except Exception as error:
        result.update(status="failure", failed_at=now(), error_type=type(error).__name__)
        raise
    finally:
        save("smoke", result)


if __name__ == "__main__":
    try:
        context = load("context")
        assert context["variant"] in ("ts", "rust", "phoenix")
        public_origin = "https://staging-grafica-" + context["variant"] + ".programaincluir.org"
        if sys.argv[1] == "staging-deploy": deploy(context, public_origin)
        elif sys.argv[1] == "staging-smoke": smoke(context, public_origin)
        else: raise ValueError("unknown operation")
    except Exception as error:
        # Never stringify an HTTP exception: webhook URLs and credentials are sensitive.
        print("TTP staging failed: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
