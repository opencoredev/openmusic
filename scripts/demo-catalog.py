#!/usr/bin/env python3
"""Regenerate the demo catalog (Debug builds only) from the public iTunes Search API.

    python3 scripts/demo-catalog.py

Writes two files:
  Sources/OpenMusicCore/Mock/DemoCatalogData.swift   album titles, tracklists, durations (committed)
  scripts/demo-art.tsv                            key -> public artwork URL (committed; the images are not)

`scripts/demo-art.sh` downloads the images in demo-art.tsv into a cache directory at run time. Lyrics are never
fetched: the mock layer writes its own placeholder lines.

Albums are picked by hand from Apple Music's US Top Albums / Top Songs charts (November 2026). Edit ALBUMS and
rerun to refresh. Artist photos come from Deezer's public search API.
"""
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (iTunes collection id, service, max tracks). Order within a service is the order shelves use.
ALBUMS = [
    # YouTube Music
    (1842897453, "yt", 12),  # Taylor Swift - The Life of a Showgirl
    (6779097512, "yt", 13),  # Olivia Rodrigo - you seem pretty sad for a girl so in love
    (1870984032, "yt", 12),  # Harry Styles - Kiss All The Time. Disco, Occasionally.
    (1895420874, "yt", 13),  # Ariana Grande - petal
    (1817609404, "yt", 12),  # Olivia Dean - The Art of Loving
    (6822497770, "yt", 1),   # Tate McRae - Housewife
    (1820264137, "yt", 12),  # KPop Demon Hunters soundtrack
    (1787022393, "yt", 17),  # Bad Bunny - DeBÍ TiRAR MáS FOToS
    (6796864741, "yt", 14),  # KAROL G - NO ME ARREPIENTO DE SENTIR TANTO
    (1739659134, "yt", 10),  # Billie Eilish - HIT ME HARD AND SOFT
    (1752214909, "yt", 12),  # Sabrina Carpenter - Short n' Sweet
    (6812894902, "yt", 1),   # ROSÉ - new trick
    (6822390423, "yt", 2),   # Olivia Rodrigo & Chappell Roan - expectations
    (1832087626, "yt", 10),  # sombr - I Barely Know Her
    (1707412988, "yt", 14),  # Chappell Roan - The Rise and Fall of a Midwest Princess
    (6773775032, "yt", 12),  # Steve Lacy - Oh yeah?
    # Spotify
    (6822944288, "sp", 14),  # Zach Bryan - Young Manhood and Other Donatable Organs
    (1872241079, "sp", 14),  # Noah Kahan - The Great Divide
    (1869436835, "sp", 14),  # Ella Langley - Dandelion
    (1802103906, "sp", 14),  # Morgan Wallen - I'm The Problem
    (6805707169, "sp", 12),  # Dominic Fike - HOW TO QUIT SMOKING
    (6810781932, "sp", 14),  # Jhené Aiko - Westside Whimsy
    (6800467151, "sp", 12),  # Remi Wolf - Mud
    (6769553652, "sp", 10),  # SIENNA SPIRO - Visitor
    (6807192580, "sp", 11),  # ADÉLA - PRIMA
    (1873328276, "sp", 14),  # Don Toliver - OCTANE
    (1781316864, "sp", 12),  # Kendrick Lamar - GNX
    (1658650093, "sp", 14),  # SZA - SOS
    (1793702595, "sp", 14),  # The Weeknd - Hurry Up Tomorrow
    (1842444456, "sp", 1),   # Tame Impala - Dracula
    (1791184860, "sp", 12),  # Djo - The Crux
    (1807490612, "sp", 10),  # Benson Boone - American Heart
]

ART_SIZE = "1200x1200bb"

# Deezer's photo for these names is a single's cover or a different artist; they use their album cover instead.
NO_PHOTO = {"Bad Bunny", "Morgan Wallen", "Djo", "Steve Lacy", "ROSÉ", "KPop Demon Hunters Cast"}


def get(url):
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001 - retry anything; the API is flaky
            if attempt == 3:
                raise
            time.sleep(2 + attempt * 2)


def swift(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def key(s):
    ascii_only = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", ascii_only.lower()).strip("-")[:48]


def split_artists(name):
    # "A, B & C" -> [A, B, C]; keep names like "Tyler, The Creator" out of scope (none in the list).
    parts = re.split(r", | & ", name)
    return [p.strip() for p in parts if p.strip()]


def clean_title(t):
    # "Song (feat. X)" stays as iTunes has it; drop edition noise from album titles.
    return re.sub(r" - (Single|EP)$", "", t)


def main():
    albums = []
    art = {}
    artist_names = []
    for cid, service, limit in ALBUMS:
        d = get(f"https://itunes.apple.com/lookup?id={cid}&entity=song&country=us&limit=200")
        rows = d["results"]
        if not rows:
            sys.exit(f"no result for {cid}")
        coll = rows[0]
        songs = sorted([r for r in rows[1:] if r.get("wrapperType") == "track" and r.get("kind") == "song"],
                       key=lambda r: (r.get("discNumber", 1), r.get("trackNumber", 0)))[:limit]
        title = clean_title(coll["collectionName"])
        artist = coll["artistName"]
        kind = "single" if coll["collectionName"].endswith(" - Single") else ("ep" if coll["collectionName"].endswith(" - EP") else "album")
        album_key = key(f"{artist} {title}")
        art[album_key] = coll["artworkUrl100"].replace("100x100bb", ART_SIZE)
        lead = split_artists(artist)
        for n in lead:
            if n not in artist_names:
                artist_names.append(n)
        tracks = []
        for s in songs:
            tracks.append({
                "title": s["trackName"],
                "seconds": round(s.get("trackTimeMillis", 180000) / 1000),
                "explicit": s.get("trackExplicitness") == "explicit",
                "artists": split_artists(s["artistName"]),
            })
        albums.append({
            "key": album_key, "service": service, "title": title, "artist": artist, "lead": lead,
            "released": coll["releaseDate"][:10], "kind": kind, "tracks": tracks,
            "genre": coll.get("primaryGenreName", ""), "copyright": coll.get("copyright", ""),
        })
        print(f"{service} {artist} - {title}: {len(tracks)} tracks", file=sys.stderr)
        time.sleep(0.5)

    for name in artist_names:
        if name in NO_PHOTO:
            continue
        q = urllib.parse.quote(name)
        d = get(f"https://api.deezer.com/search/artist?q={q}&limit=5")
        hit = next((a for a in d.get("data", []) if a["name"].lower() == name.lower()), None) or (d.get("data") or [None])[0]
        if hit and hit.get("picture_xl") and "/artist//" not in hit["picture_xl"]:
            art["artist-" + key(name)] = hit["picture_xl"]
        else:
            print(f"no photo for {name}", file=sys.stderr)
        time.sleep(0.3)

    out = [
        "// Generated by scripts/demo-catalog.py from the public iTunes Search API. Do not edit by hand.",
        "// Real, current chart albums for the demo dataset (`OPENMUSIC_MOCK=demo`, `-OpenMusicMock demo`). Titles, track",
        "// lengths and release dates only: no lyrics, no audio. Artwork keys resolve through scripts/demo-art.tsv.",
        "#if DEBUG",
        "extension DemoCatalogData {",
        "    static let albums: [DemoAlbum] = [",
    ]
    for a in albums:
        out.append(f"        DemoAlbum(key: {swift(a['key'])}, service: .{ 'youtubeMusic' if a['service'] == 'yt' else 'spotify' }, "
                   f"title: {swift(a['title'])}, artists: [{', '.join(swift(n) for n in a['lead'])}], released: {swift(a['released'])}, "
                   f"kind: .{a['kind']}, genre: {swift(a['genre'])}, copyright: {swift(a['copyright'])}, tracks: [")
        for t in a["tracks"]:
            extra = "" if t["artists"] == a["lead"] else f", artists: [{', '.join(swift(n) for n in t['artists'])}]"
            out.append(f"            DemoSong({swift(t['title'])}, {t['seconds']}{', explicit: true' if t['explicit'] else ''}{extra}),")
        out.append("        ]),")
    photos = [(n, "artist-" + key(n)) for n in artist_names if "artist-" + key(n) in art]
    out += ["    ]", "", "    /// Artist photo keys in demo-art.tsv. Artists without one use their first album's cover.",
            "    static let artistPhotos: [String: String] = ["]
    out += [f"        {swift(n)}: {swift(k)}," for n, k in photos]
    out += ["    ]",
            "}", "#endif", ""]
    with open(os.path.join(ROOT, "Sources/OpenMusicCore/Mock/DemoCatalogData.swift"), "w") as f:
        f.write("\n".join(out))
    with open(os.path.join(ROOT, "scripts/demo-art.tsv"), "w") as f:
        f.write("# key\turl  (generated by scripts/demo-catalog.py; images are downloaded by scripts/demo-art.sh, never committed)\n")
        for k, u in art.items():
            f.write(f"{k}\t{u}\n")
    print(f"{len(albums)} albums, {len(artist_names)} artists, {len(art)} images", file=sys.stderr)


if __name__ == "__main__":
    main()
