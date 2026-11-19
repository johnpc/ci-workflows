#!/usr/bin/env python3
"""Attach this run's build to every EXTERNAL TestFlight group of the app.

App Store Connect submits the build for Beta App Review on its first external
assignment. Never submits anything for App Store review. Environment:
BUNDLE_ID, BUILD_NUM (the CFBundleVersion this run uploaded) and the
asc_api credentials (ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID).
"""
import os
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ios-signing"))
import asc_api  # noqa: E402

ATTACH_ATTEMPTS = 20
ATTACH_DELAY_S = 15


def api(method, path, body=None):
    # App Store Connect answers a transient 500 now and then; retry server errors
    # only, a few times. asc_api raises SystemExit("... failed: <code> ...").
    for attempt in range(1, 4):
        try:
            return asc_api.call(method, path, body)
        except SystemExit as e:
            msg = str(e)
            print(f"  {msg}")
            if " failed: 5" not in msg or attempt == 3:
                raise
            time.sleep(10 * attempt)


def attach(group_id, build_id):
    # A build that /v1/builds already reports VALID can still be unknown to the
    # beta-group relationship endpoint for a short while (ASC replication lag): it
    # answers 404 "There is no resource of type 'builds'" (jpc-countdowns run
    # 44421773207, 2026-11-18, failed on the first POST; the rerun passed). Retry
    # only that 404 for up to 5 minutes; anything else is a real error.
    for attempt in range(1, ATTACH_ATTEMPTS + 1):
        try:
            return api("POST", f"/v1/betaGroups/{group_id}/relationships/builds",
                       {"data": [{"type": "builds", "id": build_id}]})
        except SystemExit as e:
            msg = str(e)
            if " failed: 404" not in msg or "'builds'" not in msg or attempt == ATTACH_ATTEMPTS:
                raise
            print(f"  build {build_id} not visible to beta groups yet ({attempt}/{ATTACH_ATTEMPTS}); retrying in {ATTACH_DELAY_S} s")
            time.sleep(ATTACH_DELAY_S)


def main():
    bundle_id, build_num = os.environ["BUNDLE_ID"], os.environ["BUILD_NUM"]
    apps = api("GET", f"/v1/apps?filter[bundleId]={urllib.parse.quote(bundle_id)}").get("data", [])
    apps = [a for a in apps if a["attributes"]["bundleId"] == bundle_id]
    if not apps:
        sys.exit(f"No app found for bundle id {bundle_id}")
    app_id = apps[0]["id"]

    build = None
    for _ in range(40):  # processing takes up to ~20 min
        builds = api("GET", f"/v1/builds?filter[app]={app_id}&filter[version]={build_num}&limit=1").get("data", [])
        state = builds[0]["attributes"].get("processingState") if builds else "not visible yet"
        print(f"  build {build_num}: {state}")
        if state == "VALID":
            build = builds[0]
            break
        if state in ("INVALID", "FAILED"):
            sys.exit(f"Build processing {state}")
        time.sleep(30)
    if not build:
        sys.exit("Timed out waiting for the build to finish processing")

    groups = [g for g in api("GET", f"/v1/betaGroups?filter[app]={app_id}&limit=200").get("data", [])
              if not g["attributes"].get("isInternalGroup", False)]
    if not groups:
        print("No external beta group: the build is uploaded and available to internal testers.")
        return
    for g in groups:
        attach(g["id"], build["id"])
        print(f"  attached build {build_num} to external group '{g['attributes'].get('name', g['id'])}'")
    print(f"Done: build {build_num} distributed to {len(groups)} external group(s).")


if __name__ == "__main__":
    main()
