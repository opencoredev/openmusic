#!/usr/bin/env python3
"""Trims and scrubs a recorded InnerTube response for use as a test fixture.

Drops tracking and logging blobs, replaces visitor ids, and blanks the client IP and signatures in stream URLs.
Optional --keep-items N keeps only the first N entries of list renderers' contents (smaller fixtures).
Optional --drop k1,k2 removes those keys everywhere (e.g. menu, where no parser reads it).
usage: scrub.py <in.json> <out.json> [--keep-items N] [--drop k1,k2]
"""
import json, re, sys

DROP = {"trackingParams", "clickTrackingParams", "serviceTrackingParams", "frameworkUpdates", "loggingContext",
        "playbackTracking", "adPlacements", "playerAds", "attestation", "heartbeatParams", "storyboards",
        "loggingDirectives", "adSlots", "playerConfig_webPlayerConfig", "accessibilityData", "accessibility"}

EXTRA = set()

def scrub_url(s):
    s = re.sub(r"([?&/])ip[=/][0-9a-fA-F.:%]+", r"\1ip=0.0.0.0", s)
    s = re.sub(r"([?&](?:sig|lsig|signature|n|ei|pot)=)[^&]+", r"\1REDACTED", s)
    return s

def walk(node, keep):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k in DROP or k in EXTRA:
                continue
            if k == "visitorData" and isinstance(v, str):
                out[k] = "FIXTURE_VISITOR"
                continue
            if isinstance(v, str) and "googlevideo.com" in v:
                out[k] = scrub_url(v)
                continue
            if keep and k == "contents" and isinstance(v, list) and len(v) > keep and all(isinstance(x, dict) and len(x) == 1 and next(iter(x)).endswith("ItemRenderer") for x in v):
                v = v[:keep]
            out[k] = walk(v, keep)
        return out
    if isinstance(node, list):
        return [walk(x, keep) for x in node]
    return node

if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    keep = int(sys.argv[sys.argv.index("--keep-items") + 1]) if "--keep-items" in sys.argv else 0
    EXTRA.update(sys.argv[sys.argv.index("--drop") + 1].split(",") if "--drop" in sys.argv else [])
    data = json.load(open(src))
    json.dump(walk(data, keep), open(dst, "w"), ensure_ascii=False, separators=(",", ":"))
