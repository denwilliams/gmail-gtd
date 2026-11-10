#!/usr/bin/env python3
"""Writes the AltStore source for the iPhone app: build/source.json.

    scripts/altstore-source.py <version> <build> <ipa> <ipa download URL>

The release workflow attaches it to each GitHub release, so the source's address never changes:
https://github.com/denwilliams/gmail-gtd/releases/latest/download/source.json
"""
import datetime
import json
import os
import sys

REPO = "denwilliams/gmail-gtd"
ICON = f"https://raw.githubusercontent.com/{REPO}/main/iOS/GmailGTD/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

version, build, ipa, url = sys.argv[1:5]

source = {
    "name": "Gmail GTD",
    "identifier": "dev.denw.gmail-gtd.source",
    "sourceURL": f"https://github.com/{REPO}/releases/latest/download/source.json",
    "subtitle": "GTD triage for Gmail",
    "iconURL": ICON,
    "website": f"https://github.com/{REPO}",
    "apps": [
        {
            "name": "Gmail GTD",
            "bundleIdentifier": "dev.denw.gmail-gtd.ios",
            "developerName": "Den Williams",
            "subtitle": "File Gmail threads into GTD statuses.",
            "localizedDescription": (
                "Process your Gmail in-tray GTD-style: file each thread as Next, Waiting, Someday, Reference, "
                "Project, Noise or Junk, with Gmail labels as the only storage. Summaries run on-device with "
                "Apple Intelligence. You need your own Google OAuth client ID (iOS type); see the README."
            ),
            "iconURL": ICON,
            "tintColor": "#0A84FF",
            "category": "productivity",
            "versions": [
                {
                    "version": version,
                    "buildVersion": build,
                    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "downloadURL": url,
                    "size": os.path.getsize(ipa),
                    "minOSVersion": "26.0",
                }
            ],
            "appPermissions": {"entitlements": [], "privacy": {}},
        }
    ],
    "news": [],
}

with open("build/source.json", "w") as f:
    json.dump(source, f, indent=2)
print("Wrote build/source.json")
