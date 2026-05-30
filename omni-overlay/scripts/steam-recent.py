#!/usr/bin/env python3
"""
Read the 3 most recently played Steam games from local files.
No SDK, no API key  -  pure local file parsing.
Outputs a single JSON line to stdout.
"""

import json, os, re, sys

STEAM_DIR   = os.path.expanduser("~/.local/share/Steam")
USERDATA    = os.path.join(STEAM_DIR, "userdata")
LIBCACHE    = os.path.join(STEAM_DIR, "appcache", "librarycache")
LIMIT       = 3

# Minimal VDF value extractor

def vdf_value(text, key):
    """Return the first value for a quoted key in flat VDF text."""
    m = re.search(r'"' + re.escape(key) + r'"\s+"([^"]*)"', text, re.IGNORECASE)
    return m.group(1) if m else None

# Find the most recently used Steam user

def find_user_id():
    try:
        ids = [d for d in os.listdir(USERDATA)
               if os.path.isdir(os.path.join(USERDATA, d)) and d.isdigit()]
        if not ids:
            return None
        # Pick the one with the most recently modified localconfig.vdf
        ids.sort(key=lambda d: os.path.getmtime(
            os.path.join(USERDATA, d, "config", "localconfig.vdf")), reverse=True)
        return ids[0]
    except Exception:
        return None

# Parse recently played AppIDs from localconfig.vdf

def recent_appids(userid, limit):
    path = os.path.join(USERDATA, userid, "config", "localconfig.vdf")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except Exception:
        return []

    # Extract every numeric AppID block that has a LastPlayed timestamp
    pattern = re.compile(
        r'"(\d{3,})"[\s\t]*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}',
        re.DOTALL)
    entries = []
    for m in pattern.finditer(text):
        appid, block = m.group(1), m.group(2)
        ts = vdf_value(block, "LastPlayed") or vdf_value(block, "lastplayed")
        if ts and int(ts) > 0:
            entries.append((int(ts), appid))

    entries.sort(reverse=True)
    return [appid for _, appid in entries[:limit * 4]]  # fetch extra, filter later

# Collect all steamapps library paths

def library_paths():
    paths = [os.path.join(STEAM_DIR, "steamapps")]
    vdf = os.path.join(STEAM_DIR, "steamapps", "libraryfolders.vdf")
    try:
        with open(vdf, encoding="utf-8", errors="replace") as f:
            text = f.read()
        for m in re.finditer(r'"path"\s+"([^"]+)"', text):
            p = os.path.join(m.group(1).replace("\\\\", "/"), "steamapps")
            if os.path.isdir(p) and p not in paths:
                paths.append(p)
    except Exception:
        pass
    return paths

# Get game name and image from manifest + cache

_manifest_cache = {}

def build_manifest_index(lib_paths):
    """Map appid -> (name, manifest_path) across all libraries."""
    index = {}
    for lib in lib_paths:
        try:
            for fname in os.listdir(lib):
                m = re.match(r"appmanifest_(\d+)\.acf", fname)
                if not m:
                    continue
                appid = m.group(1)
                full  = os.path.join(lib, fname)
                try:
                    with open(full, encoding="utf-8", errors="replace") as f:
                        text = f.read()
                    name = vdf_value(text, "name")
                    if name:
                        index[appid] = name
                except Exception:
                    pass
        except Exception:
            pass
    return index

def icon_path(appid):
    """Return best available square icon  -  local files first, CDN fallback."""
    # 1. Highest quality: system hicolor icon (only for installed/launched games)
    for size in ("256x256", "128x128", "64x64", "48x48"):
        p = os.path.expanduser(
            f"~/.local/share/icons/hicolor/{size}/apps/steam_icon_{appid}.png")
        if os.path.exists(p):
            return "file://" + p

    # 2. librarycache *.jpg files are the 32x32 game icons Steam downloads
    cache_dir = os.path.join(LIBCACHE, appid)
    try:
        for fname in os.listdir(cache_dir):
            if fname.endswith(".jpg"):
                return "file://" + os.path.join(cache_dir, fname)
    except Exception:
        pass

    # 3. CDN icon via known Steam CDN pattern (no hash needed for this format)
    return f"https://cdn.akamai.steamstatic.com/steam/apps/{appid}/capsule_sm_120.jpg"

# Main

def main():
    userid = find_user_id()
    if not userid:
        print(json.dumps([]), flush=True)
        return

    candidate_ids = recent_appids(userid, LIMIT)
    lib_paths     = library_paths()
    manifest_idx  = build_manifest_index(lib_paths)

    results = []
    seen = set()
    for appid in candidate_ids:
        if len(results) >= LIMIT:
            break
        name = manifest_idx.get(appid)
        if not name:
            continue
        # Skip utility/redistributable entries
        skip_words = ["redist", "runtime", "directx", "proton", "steamwork",
                      "linux", "sdk", "common", "vcredist"]
        if any(w in name.lower() for w in skip_words):
            continue
        if appid in seen:
            continue
        seen.add(appid)
        results.append({
            "appid": appid,
            "name":  name,
            "icon":  icon_path(appid),
            "url":   f"steam://rungameid/{appid}",
        })

    print(json.dumps(results), flush=True)

if __name__ == "__main__":
    main()
