"""Minimal App Store Connect API client for the Mac mini CI tooling.

Signs an ES256 JWT with the App Store Connect API key via openssl, so it has no
third-party dependencies. Credentials come from the environment only:
  ASC_KEY_PATH   path to AuthKey_<id>.p8 (the shared workflows write it under the
                 job's own $RUNNER_TEMP, never a shared folder)
  ASC_KEY_ID     key id (also selects ~/private_keys/AuthKey_<id>.p8 when
                 ASC_KEY_PATH is unset: the legacy per-repo workflows' layout)
  ASC_ISSUER_ID  issuer id paired with the key
"""
import base64
import glob
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

BASE = "https://api.appstoreconnect.apple.com"


def _issuer() -> str:
    # Repos on other Apple teams (e.g. stoop, team Y9PY7DKTGA) pass their own
    # ASC_ISSUER_ID alongside ASC_KEY_ID; the key and issuer must be a pair.
    issuer = os.environ.get("ASC_ISSUER_ID")
    if not issuer:
        raise SystemExit("ASC_ISSUER_ID is not set")
    return issuer


def _key_path() -> str:
    # Every repo's deploy writes its own AuthKey_<ASC_KEY_ID>.p8 here just before
    # signing, and they all share this folder. Use ASC_KEY_ID when set, else the
    # newest key, never an arbitrary glob order: a foreign key that sorted first
    # once made every deploy fail with a 401 (Nov 8 2026).
    explicit = os.environ.get("ASC_KEY_PATH")
    if explicit:
        if not os.path.exists(explicit):
            raise SystemExit(f"ASC_KEY_PATH {explicit} does not exist")
        return explicit
    kid = os.environ.get("ASC_KEY_ID")
    if kid:
        path = os.path.expanduser(f"~/private_keys/AuthKey_{kid}.p8")
        if os.path.exists(path):
            return path
    # Skip blank keys: a repo missing its ASC secrets writes AuthKey_.p8 with
    # no content, and openssl then fails for whichever repo signs next.
    keys = [k for k in glob.glob(os.path.expanduser("~/private_keys/AuthKey_*.p8"))
            if "BEGIN PRIVATE KEY" in open(k).read()]
    if not keys:
        raise SystemExit("No App Store Connect key in ~/private_keys")
    return max(keys, key=os.path.getmtime)


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _token() -> str:
    key = _key_path()
    kid = os.environ.get("ASC_KEY_ID") or os.path.basename(key)[len("AuthKey_"):-len(".p8")]
    now = int(time.time())
    header = _b64(json.dumps({"alg": "ES256", "kid": kid, "typ": "JWT"}).encode())
    payload = _b64(json.dumps({"iss": _issuer(), "iat": now, "exp": now + 1200,
                               "aud": "appstoreconnect-v1"}).encode())
    with tempfile.NamedTemporaryFile() as f:
        f.write(f"{header}.{payload}".encode())
        f.flush()
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key, f.name],
                             capture_output=True, check=True).stdout

    def int_at(offset):  # DER INTEGER -> 32-byte big-endian
        n = der[offset + 1]
        value = der[offset + 2:offset + 2 + n].lstrip(b"\0")
        return value.rjust(32, b"\0"), offset + 2 + n

    r, nxt = int_at(2)
    s, _ = int_at(nxt)
    return f"{header}.{payload}.{_b64(r + s)}"


def call(method: str, path: str, body=None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method, headers={
        "Authorization": "Bearer " + _token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"ASC {method} {path} failed: {e.code} {e.read().decode()[:500]}")
