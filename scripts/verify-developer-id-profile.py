#!/usr/bin/env python3
"""Check a Developer ID profile against the certificate used to sign RiftVM."""

import datetime
import hashlib
import plistlib
import re
import subprocess
import sys


def fail(message: str) -> None:
    print(f"verify-developer-id-profile: {message}", file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 3:
    fail("usage: verify-developer-id-profile.py <profile> <signing-identity>")

profile_path, signing_identity = sys.argv[1:]
try:
    profile_data = subprocess.run(
        ["security", "cms", "-D", "-i", profile_path],
        check=True,
        capture_output=True,
    ).stdout
    profile = plistlib.loads(profile_data)
    identities = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
except (OSError, subprocess.CalledProcessError, ValueError) as error:
    fail(f"cannot inspect provisioning profile or signing identity: {error}")

entitlements = profile.get("Entitlements", {})
if entitlements.get("com.apple.application-identifier") != "YPV49M8592.com.riftvm.app":
    fail("profile does not match YPV49M8592.com.riftvm.app")
if profile.get("ProvisionsAllDevices") is not True:
    fail("profile is not a Developer ID distribution profile")
if entitlements.get("com.apple.developer.accessory-access.usb") is not True:
    fail("profile does not grant Claim USB Accessory")
if entitlements.get("com.apple.security.virtualization") is not True:
    fail("profile does not grant Virtualization")

expiration = profile.get("ExpirationDate")
if not isinstance(expiration, datetime.datetime) or expiration <= datetime.datetime.utcnow():
    fail("profile has expired or has no expiration date")

identity_hash = None
for line in identities.splitlines():
    match = re.match(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"([^"]+)"', line)
    if match and signing_identity in (match.group(1), match.group(2)):
        identity_hash = match.group(1)
        break
if identity_hash is None:
    fail("signing identity is not installed or valid")

profile_hashes = {
    hashlib.sha1(certificate).hexdigest().upper()
    for certificate in profile.get("DeveloperCertificates", [])
}
if identity_hash not in profile_hashes:
    fail("profile does not include the Developer ID signing certificate")

print("Verified Developer ID profile grants USB and matches the signing certificate.")
