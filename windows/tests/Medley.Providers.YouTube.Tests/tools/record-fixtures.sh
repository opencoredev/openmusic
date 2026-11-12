#!/usr/bin/env bash
# Records the live_* fixtures with medley-probe (signed out) and scrubs them. Run from this folder:
#   DOTNET_ROOT=~/.dotnet ./record-fixtures.sh /path/to/medley-probe
set -euo pipefail
probe="${1:?usage: record-fixtures.sh <medley-probe>}"
out="$(cd "$(dirname "$0")/../Fixtures" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT
rec() { # name endpoint body [client] [keep] [drop]
  local name="$1" endpoint="$2" body="$3" client="${4:-}" keep="${5:-0}" drop="${6:-_none_}"
  if [ -n "$client" ]; then "$probe" ytm raw "$endpoint" "$body" --client "$client" --out "$tmp/$name.json" >/dev/null
  else "$probe" ytm raw "$endpoint" "$body" --out "$tmp/$name.json" >/dev/null; fi
  python3 -I "$(dirname "$0")/scrub.py" "$tmp/$name.json" "$out/$name.json" --keep-items "$keep" --drop "$drop"
  echo "$name: $(wc -c < "$out/$name.json") bytes"
}
rec live_home browse '{"browseId":"FEmusic_home"}' "" 0 menu
rec live_explore browse '{"browseId":"FEmusic_explore"}' "" 8 menu
rec live_search_all search '{"query":"Daft Punk"}'
rec live_album browse '{"browseId":"MPREb_7ltM34kr0mH"}'
rec live_artist browse '{"browseId":"UCRr1xG_2WIDs18a6cIiCxeA"}' "" 0 menu
rec live_playlist browse '{"browseId":"VLPLgVLQgm4lkANkwLnIYZiwf6o2jKIc5Th3"}' "" 0 menu
token="$(python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
def f(n):
    if isinstance(n,dict):
        for k,v in n.items():
            if k=="continuationCommand": return v["token"]
            r=f(v)
            if r: return r
    if isinstance(n,list):
        for v in n:
            r=f(v)
            if r: return r
print(f(d))' "$tmp/live_playlist.json")"
rec live_playlist_continuation browse "{\"continuation\":\"$token\"}" "" 0 menu
rec live_next next '{"videoId":"kOn-HdEg6AQ","isAudioOnly":true,"playlistId":"RDAMVMkOn-HdEg6AQ","params":"wAEB","enablePersistentPlaylistPanel":true,"tunerSettingValue":"AUTOMIX_SETTING_NORMAL"}' "" 0 menu
lyrics="$(grep -o '"browseId":"MPLY[^"]*"' "$tmp/live_next.json" | head -1 | cut -d'"' -f4)"
rec live_lyrics_timed browse "{\"browseId\":\"$lyrics\"}" ANDROID_MUSIC
rec live_lyrics_untimed browse '{"browseId":"MPLYt_FY0XZwCKdnl"}' ANDROID_MUSIC
rec live_player_android_vr_refused player '{"videoId":"FGBhQbmPwH8","contentCheckOk":true,"racyCheckOk":true}' ANDROID_VR
