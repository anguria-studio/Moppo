#!/usr/bin/env python3
"""Validate public update settings before a release build."""
import argparse
import base64
import binascii
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()
    try:
        url = urlsplit(args.feed)
        secure = url.scheme == "https" and url.hostname and not url.username and not url.password
        key = base64.b64decode(args.key, validate=True)
    except (ValueError, binascii.Error):
        secure, key = False, b""
    if not secure or len(key) != 32:
        parser.error("Set an HTTPS MOPPO_UPDATE_FEED_URL and a 32-byte base64 MOPPO_UPDATE_PUBLIC_KEY.")


if __name__ == "__main__":
    main()
