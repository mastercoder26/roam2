#!/usr/bin/env bash
#
# Live check for the automatic post-drive route difficulty analysis.
#
# RouteAnalysisChecks.swift covers the request/response contract offline. This
# script covers the half that only the deployed stack can answer: that the
# route backend is reachable, its Google Routes credentials work, and the exact
# request the app sends after a drive comes back scored.
#
# It is deliberately NOT part of run-checks.sh — it needs the network and the
# deployed backend, so a failure here means "the deployment is unhealthy",
# not "the code regressed".
#
# Usage:
#   ios/tests/live-route-analysis.sh                 # uses API_BASE_URL from xcconfig
#   API_BASE_URL=http://localhost:3000 ios/tests/live-route-analysis.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

# The xcconfig escapes "//" as "/$()/" so Xcode does not treat it as a comment.
if [[ -z "${API_BASE_URL:-}" ]]; then
    for config in ios/Roam/Config/Debug.local.xcconfig ios/Roam/Config/Release.local.xcconfig; do
        [[ -f "$config" ]] || continue
        API_BASE_URL="$(sed -n 's/^API_BASE_URL[[:space:]]*=[[:space:]]*//p' "$config" | head -1 | sed 's|/\$()/|//|g' | tr -d '[:space:]')"
        [[ -n "$API_BASE_URL" ]] && break
    done
fi

if [[ -z "${API_BASE_URL:-}" ]]; then
    echo "No API_BASE_URL configured. Set it in the environment or in ios/Roam/Config/Debug.local.xcconfig." >&2
    exit 1
fi

echo "Route backend: $API_BASE_URL"

# San Francisco -> San Jose. Coordinates, not addresses: this mirrors what
# DriveRouteAnalysisEngine.endpoints() derives from a recorded GPS trace.
read -r -d '' request <<'JSON'
{
  "origin": { "latitude": 37.7749, "longitude": -122.4194 },
  "destination": { "latitude": 37.3382, "longitude": -121.8863 },
  "departureLocalMinutes": 600,
  "includeAlternates": false,
  "continuousDriveMinutes": 30
}
JSON

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

status="$(curl -s -m 45 -o "$response_file" -w '%{http_code}' \
    -X POST "$API_BASE_URL/api/route/difficulty" \
    -H 'Content-Type: application/json' \
    -d "$request")"

if [[ "$status" != "200" ]]; then
    echo "FAIL  the post-drive analysis request returned HTTP $status"
    echo "      $(head -c 400 "$response_file")"
    echo
    echo "If the body says ROUTE_UNAVAILABLE, the backend reached Google and was"
    echo "refused. Check the Cloud Run logs for route_analysis_failed entries:"
    echo "  gcloud logging read 'resource.labels.service_name=roam-backend' --freshness=1h"
    exit 1
fi

python3 - "$response_file" <<'PY'
import json, sys

with open(sys.argv[1]) as handle:
    body = json.load(handle)

route = body.get("primaryRoute")
if not route:
    print("FAIL  response had no primaryRoute")
    sys.exit(1)

missing = [key for key in ("score", "label", "reasons", "modelVersion") if key not in route]
if missing:
    print(f"FAIL  primaryRoute is missing {missing}")
    sys.exit(1)

score = route["score"]
if not isinstance(score, (int, float)) or not 0 <= score <= 10:
    print(f"FAIL  score {score!r} is outside the expected 0-10 range")
    sys.exit(1)

print(f"pass  scored {score} ({route['label']}) via {route['modelVersion']}")
print(f"      reasons: {', '.join(route['reasons'][:3])}")
PY
analysis_status=$?

if [[ $analysis_status -ne 0 ]]; then
    exit 1
fi

# Regression guard: the old client sent departureTime="now", which Google
# rejects once request latency pushes it into the past. Confirm the backend
# still accepts the request WITHOUT it, which is what the app now sends.
echo
echo "Checking the historical failure mode (departureTime set to 'now')..."
past_status="$(curl -s -m 45 -o /dev/null -w '%{http_code}' \
    -X POST "$API_BASE_URL/api/route/difficulty" \
    -H 'Content-Type: application/json' \
    -d "{\"origin\":{\"latitude\":37.7749,\"longitude\":-122.4194},\"destination\":{\"latitude\":37.3382,\"longitude\":-121.8863},\"departureTime\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"departureLocalMinutes\":600,\"includeAlternates\":false}")"

if [[ "$past_status" == "200" ]]; then
    echo "note  a 'now' departureTime happened to succeed this run (HTTP 200)."
    echo "      It is latency-dependent, which is exactly why the app omits it."
else
    echo "note  a 'now' departureTime returned HTTP $past_status — the original bug, still reproducible."
fi

echo
echo "Live route analysis check passed."
