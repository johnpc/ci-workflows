#!/usr/bin/env python3
"""Manual App Store signing for Xcode projects built on the self-hosted Mac mini.

Why: GitHub runners here run in the *system* launchd context. Xcode's automatic
signing there can't see or write the login keychain, so it fails trying to mint
a certificate. Instead, every app/extension/watch target's Release config is
switched to manual signing with the Apple Distribution identity that lives in
~/Library/Keychains/ci-signing.keychain-db (on the system search list), using a
per-bundle "<bundle id> CI AppStore" provisioning profile that this tool
creates/refreshes through the App Store Connect API and installs.

Signing in the archive (rather than archiving unsigned and cloud-signing at
export) preserves the app's entitlements: cloud signing an unsigned archive
silently drops them (FinanceKit, app groups, push, HealthKit, ...).

  apply  <path/to/X.xcodeproj> [--export-options OUT.plist] [--destination upload|export]
         [--platform ios|tvos] [--profile BUNDLE_ID=PROFILE_NAME ...]
  revert <path/to/X.xcodeproj>

--profile pins a bundle id to an existing, already-installed profile instead of
the "<bundle id> CI AppStore" one this tool maintains (e.g. a profile carrying a
managed capability such as FinanceKit that an API-created profile cannot get).

Shared copy (johnpc/ci-workflows actions/ios-signing). Machine state stays on the
mini under $CI_SIGNING_HOME (default ~/ci-signing): backups/, teams.json, teams/.
App Store Connect credentials: see asc_api.py (ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID).

apply backs the project file up outside the repo; revert restores it byte for
byte (run it before any commit, e.g. the version-bump commit).
"""
import argparse
import urllib.parse
import base64
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_api  # noqa: E402

TEAM_ID = "JW5SC3NYUV"  # default team; a project's own DEVELOPMENT_TEAM wins
# Apple Distribution certificate (private key in the CI keychain) per team. A team
# seen for the first time gets one created through its own ASC API key.
HOME_DIR = os.path.expanduser(os.environ.get("CI_SIGNING_HOME", "~/ci-signing"))
TEAMS_FILE = os.path.join(HOME_DIR, "teams.json")
DEFAULT_TEAMS = {"JW5SC3NYUV": "3RTHH4LVZW"}
CERT_ID = DEFAULT_TEAMS[TEAM_ID]  # set per run by apply()
KEYCHAIN = os.path.expanduser("~/Library/Keychains/ci-signing.keychain-db")
BACKUPS = os.path.join(HOME_DIR, "backups")
PROFILE_DIRS = ["~/Library/Developer/Xcode/UserData/Provisioning Profiles",
                "~/Library/MobileDevice/Provisioning Profiles"]
SIGNABLE = re.compile(r"\.(application|app-extension|watchkit2-extension|watchapp2)")
OBJ = re.compile(r"\n(\t\t)([0-9A-F]{24}) /\* [^*]* \*/ = (\{.*?\n\t\t\});", re.S)
DROP = re.compile(r'^\s*"?(CODE_SIGN_STYLE|CODE_SIGN_IDENTITY(\[[^\]]*\])?|'
                  r'PROVISIONING_PROFILE(_SPECIFIER)?(\[[^\]]*\])?|OTHER_CODE_SIGN_FLAGS|'
                  r'DEVELOPMENT_TEAM(\[[^\]]*\])?)"? = .*;\s*$')


def pbxproj(xcodeproj: str) -> str:
    path = os.path.join(xcodeproj, "project.pbxproj")
    if not os.path.isfile(path):
        sys.exit(f"not an Xcode project: {xcodeproj}")
    return path


def backup_path(path: str) -> str:
    return os.path.join(BACKUPS, hashlib.sha1(os.path.abspath(path).encode()).hexdigest() + ".pbxproj")


def release_configs(text: str):
    """Yield (config_id, bundle_id) for each signable target's Release config."""
    objs = {m.group(2): m.group(3) for m in OBJ.finditer(text)}
    for body in objs.values():
        if "isa = PBXNativeTarget;" not in body:
            continue
        ptype = re.search(r'productType = "([^"]+)"', body)
        if not ptype or not SIGNABLE.search(ptype.group(1)):
            continue
        lst = objs[re.search(r"buildConfigurationList = ([0-9A-F]{24})", body).group(1)]
        ids = re.findall(r"([0-9A-F]{24}) /\*", lst.split("buildConfigurations = (")[1].split(");")[0])
        for cid in ids:
            cfg = objs[cid]
            if "name = Release;" not in cfg:
                continue
            bid = re.search(r'PRODUCT_BUNDLE_IDENTIFIER = "?([^;"]+)"?;', cfg)
            if not bid or "$(" in bid.group(1):
                sys.exit(f"Release config {cid} has no literal PRODUCT_BUNDLE_IDENTIFIER")
            yield cid, bid.group(1)


PROFILE_TYPES = {"ios": "IOS_APP_STORE", "tvos": "TVOS_APP_STORE"}


def project_team(text: str) -> str:
    teams = re.findall(r"DEVELOPMENT_TEAM = ([A-Z0-9]{10});", text)
    return max(set(teams), key=teams.count) if teams else TEAM_ID


def keychain_password() -> str:
    pw = os.environ.get("CI_KEYCHAIN_PASSWORD")
    if not pw:
        with open(os.path.join(HOME_DIR, "keychain-password")) as f:
            pw = f.read().strip()
    return pw


def ensure_team_cert(team: str) -> str:
    """Return the Distribution cert id for team, creating + importing one if needed."""
    teams = dict(DEFAULT_TEAMS)
    if os.path.exists(TEAMS_FILE):
        teams.update(json.load(open(TEAMS_FILE)))
    if team in teams:
        return teams[team]
    d = os.path.join(HOME_DIR, "teams", team)
    os.makedirs(d, mode=0o700, exist_ok=True)
    key, csr = os.path.join(d, "distribution.key"), os.path.join(d, "distribution.csr")
    subprocess.run(["openssl", "genrsa", "-out", key, "2048"], check=True, capture_output=True)
    subprocess.run(["openssl", "req", "-new", "-key", key, "-out", csr,
                    "-subj", f"/CN=CI Distribution {team}/C=US"], check=True, capture_output=True)
    csr_b64 = "".join(l for l in open(csr).read().splitlines() if "-----" not in l)
    cert = asc_api.call("POST", "/v1/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": csr_b64}}})["data"]
    der, pem, p12 = (os.path.join(d, n) for n in ("distribution.cer", "distribution.pem", "distribution.p12"))
    open(der, "wb").write(base64.b64decode(cert["attributes"]["certificateContent"]))
    subprocess.run(["openssl", "x509", "-inform", "der", "-in", der, "-out", pem], check=True)
    p12pw = hashlib.sha256(os.urandom(32)).hexdigest()[:24]
    subprocess.run(["openssl", "pkcs12", "-export", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
                    "-macalg", "sha1", "-inkey", key, "-in", pem, "-out", p12, "-passout", f"pass:{p12pw}"],
                   check=True)
    pw = keychain_password()
    subprocess.run(["security", "unlock-keychain", "-p", pw, KEYCHAIN], check=True)
    subprocess.run(["security", "import", p12, "-k", KEYCHAIN, "-P", p12pw, "-T", "/usr/bin/codesign",
                    "-T", "/usr/bin/security", "-T", "/usr/bin/productbuild"], check=True)
    subprocess.run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
                    "-k", pw, KEYCHAIN], check=True, capture_output=True)
    os.remove(p12)
    teams[team] = cert["id"]
    json.dump({k: v for k, v in teams.items() if k not in DEFAULT_TEAMS}, open(TEAMS_FILE, "w"), indent=1)
    print(f"created Apple Distribution certificate {cert['id']} for team {team}")
    return cert["id"]


def ensure_profile(bundle_id: str, platform: str = "ios") -> str:
    """Make sure an active App Store profile for bundle_id exists, is installed, and return its name."""
    name = f"{bundle_id} CI AppStore" + ("" if platform == "ios" else f" {platform}")
    ids = [b for b in asc_api.call("GET", f"/v1/bundleIds?filter[identifier]={urllib.parse.quote(bundle_id)}&limit=200")["data"]
           if b["attributes"]["identifier"] == bundle_id]
    if not ids:
        sys.exit(f"bundle id {bundle_id} is not registered on the developer account")
    found = asc_api.call("GET", f"/v1/profiles?filter[name]={urllib.parse.quote(name)}&include=certificates&limit=20")
    profile = None
    for p in found.get("data", []):
        certs = [c["id"] for c in p["relationships"]["certificates"].get("data", [])]
        if p["attributes"]["profileState"] == "ACTIVE" and CERT_ID in certs:
            profile = p
        else:  # stale (expired/invalid or wrong cert): replace it
            asc_api.call("DELETE", f"/v1/profiles/{p['id']}")
    if profile is None:
        profile = asc_api.call("POST", "/v1/profiles", {"data": {
            "type": "profiles",
            "attributes": {"name": name, "profileType": PROFILE_TYPES[platform]},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": ids[0]["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": CERT_ID}]}}}})["data"]
    raw = base64.b64decode(profile["attributes"]["profileContent"])
    xml = subprocess.run(["openssl", "smime", "-inform", "der", "-verify", "-noverify"],
                         input=raw, capture_output=True, check=True).stdout
    uuid = plistlib.loads(xml)["UUID"]
    for d in PROFILE_DIRS:
        d = os.path.expanduser(d)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, f"{uuid}.mobileprovision"), "wb") as f:
            f.write(raw)
    return name


def patch(text: str, cid: str, profile: str, team: str) -> str:
    m = re.search(rf"\n\t\t{cid} /\* [^*]* \*/ = \{{.*?\n\t\t\}};", text, re.S)
    block = m.group(0)
    lines = [ln for ln in block.split("\n") if not DROP.match(ln)]
    i = next(n for n, ln in enumerate(lines) if "buildSettings = {" in ln)
    ind = "\t\t\t\t"
    lines[i + 1:i + 1] = [
        f"{ind}CODE_SIGN_STYLE = Manual;",
        f'{ind}CODE_SIGN_IDENTITY = "Apple Distribution";',
        f"{ind}DEVELOPMENT_TEAM = {team};",
        f'{ind}PROVISIONING_PROFILE_SPECIFIER = "{profile}";',
        f'{ind}OTHER_CODE_SIGN_FLAGS = "--keychain {KEYCHAIN}";',
    ]
    return text[:m.start()] + "\n".join(lines) + text[m.end():]


def check_keychain() -> None:
    """The CI keychain must be on the search list Xcode actually uses here."""
    out = subprocess.run(["security", "list-keychains"], capture_output=True, text=True).stdout
    if "ci-signing.keychain-db" not in out:
        sys.exit("CI keychain is not on the system search list. Fix once with:\n"
                 f"  sudo security list-keychains -d system -s /Library/Keychains/System.keychain {KEYCHAIN}")


def apply(args) -> None:
    check_keychain()
    path = pbxproj(args.xcodeproj)
    os.makedirs(BACKUPS, exist_ok=True)
    bak = backup_path(path)
    if os.path.exists(bak):  # a previous apply wasn't reverted: start from the original
        shutil.copyfile(bak, path)
    shutil.copyfile(path, bak)
    text = open(path).read()
    global CERT_ID
    team = project_team(text)
    CERT_ID = ensure_team_cert(team)
    pinned = dict(p.split("=", 1) for p in (args.profile or []))
    mapping = {}
    for cid, bundle_id in list(release_configs(text)):
        mapping[bundle_id] = pinned.get(bundle_id) or ensure_profile(bundle_id, args.platform)
        text = patch(text, cid, mapping[bundle_id], team)
    if not mapping:
        sys.exit("no signable targets found")
    open(path, "w").write(text)
    for bundle_id, name in sorted(mapping.items()):
        print(f"manual signing: {bundle_id} -> {name}")
    if args.export_options:
        with open(args.export_options, "wb") as f:
            plistlib.dump({
                "method": "app-store-connect", "destination": args.destination,
                "signingStyle": "manual", "teamID": team,
                "signingCertificate": "Apple Distribution",
                "provisioningProfiles": mapping}, f)
        print(f"wrote {args.export_options}")


def revert(args) -> None:
    path = pbxproj(args.xcodeproj)
    bak = backup_path(path)
    if not os.path.exists(bak):
        print("nothing to revert")
        return
    shutil.move(bak, path)
    print(f"reverted {path}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("apply")
    a.add_argument("xcodeproj")
    a.add_argument("--export-options")
    a.add_argument("--destination", default="upload", choices=["upload", "export"])
    a.add_argument("--platform", default="ios", choices=sorted(PROFILE_TYPES),
                   help="profile platform for this archive (multiplatform targets: run per platform)")
    a.add_argument("--profile", action="append", metavar="BUNDLE_ID=NAME",
                   help="use this existing installed profile for BUNDLE_ID (repeatable)")
    a.set_defaults(fn=apply)
    r = sub.add_parser("revert")
    r.add_argument("xcodeproj")
    r.set_defaults(fn=revert)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
