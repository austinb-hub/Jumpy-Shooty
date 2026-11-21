#!/usr/bin/env bash
# A building coming down, online: a host and a client play on the Construction Site over
# a laggy network, and the host blows out the tower's north-west corner column
# (--blow-column). One spectator joins while it is falling and one after it is down.
# Checks that:
#  - the host starts one collapse, and every copy ends with exactly the same heap and
#    the same walls and floors gone (the two who joined late as well)
#  - there are no script errors
# MAP=cirrus COLUMN=9:0,0,1 does it on Cirrus: a ground-floor corner of the first island
# that is up, a building held up by its walls on an island that flies.
# MAP=empyrean COLUMN=14:2,2,1 SLOW=30 does it on Empyrean Tower: a stretch of wall in
# its lowest tier (one map with six buildings). SLOW: seconds more that everyone stays,
# for a map that takes long to load (a late joiner has to load it and catch up).
# Usage: [MAP=...] [COLUMN=SECONDS:X,Z,STOREY] [SLOW=SECONDS] tests/run_collapse_test.sh [NET_SIM]
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
SIM="${1:-100,30,5}"
SLOW="${SLOW:-0}"
OUT=tests/out
mkdir -p "$OUT"
rm -f "$OUT"/collapse_*.log
PORT=$((26300 + RANDOM % 100))
COMMON=(--sync-log --map="${MAP:-construction_site}" --net-sim="$SIM")

"$GODOT" --headless --path . -- --host --port="$PORT" --name=P1 --autostart=2 --time-limit=$((90 + 2 * SLOW)) --blow-column="${COLUMN:-9:0,0,0}" --quit-after=$((44 + 2 * SLOW)) "${COMMON[@]}" \
  > "$OUT/collapse_host.log" 2>&1 &
sleep 1
"$GODOT" --headless --path . -- --join="127.0.0.1:$PORT" --name=P2 --quit-after=$((42 + 2 * SLOW)) "${COMMON[@]}" > "$OUT/collapse_player.log" 2>&1 &
# The host tells of the collapse a second and a half before anything lets go.
for _ in $(seq 1 60); do
  sleep 0.5
  if grep -q "^COLLAPSE " "$OUT/collapse_host.log"; then break; fi
done
sleep 4
"$GODOT" --headless --path . -- --join="127.0.0.1:$PORT" --name=During --spectate --quit-after=$((30 + 2 * SLOW)) "${COMMON[@]}" > "$OUT/collapse_during.log" 2>&1 &
for _ in $(seq 1 60); do
  sleep 0.5
  if grep -q "^COLLAPSE_DOWN " "$OUT/collapse_host.log"; then break; fi
done
sleep 2
"$GODOT" --headless --path . -- --join="127.0.0.1:$PORT" --name=After --spectate --quit-after=$((10 + SLOW)) "${COMMON[@]}" > "$OUT/collapse_after.log" 2>&1 &
sleep $((11 + SLOW))
pkill -f -- "--port=$PORT" || true
pkill -f -- "--join=127.0.0.1:$PORT" || true
wait || true

fail=0
if grep -h "SCRIPT ERROR" "$OUT"/collapse_*.log; then echo "FAIL: script errors"; fail=1; fi
python3 - "$OUT" <<'PY' || fail=1
import sys
out = sys.argv[1]
ok = True


def check(cond, what):
    global ok
    print(("  ok    " if cond else "  FAIL  ") + what)
    ok = ok and cond


def lines(name, start):
    return [l.strip() for l in open(f"{out}/collapse_{name}.log", errors="replace") if l.startswith(start)]


started = lines("host", "COLLAPSE ")
check(len(started) == 1, f"the host starts one collapse ({started})")
heaps = {name: lines(name, "COLLAPSE_DOWN ") for name in ["host", "player", "during", "after"]}
host = heaps["host"]
check(len(host) == 1, f"it comes to rest on the host ({host})")
for name, who in [("player", "the other player"), ("during", "a spectator who joined while it fell"), ("after", "a spectator who joined once it was down")]:
    check(len(host) == 1 and heaps[name] == host, f"{who} has the very same heap, and the same walls and floors gone ({heaps[name]})")
print("PASS: collapse test" if ok else "FAIL: collapse test")
sys.exit(0 if ok else 1)
PY
exit $fail
