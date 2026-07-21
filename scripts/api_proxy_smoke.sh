#!/bin/sh
set -eu

base_url=${1:-http://127.0.0.1:4000}
user_agent=fornacast-proxy-smoke/1.0
connect_timeout=2
request_timeout=5
headers=$(mktemp)
body=$(mktemp)
trap 'rm -f "$headers" "$body"' EXIT

deadline=$(($(date +%s) + 60))

while :; do
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "timed out waiting for $base_url/api/v3/versions" >&2
    exit 1
  fi

  remaining=$((deadline - now))
  max_time=$request_timeout
  if [ "$remaining" -lt "$max_time" ]; then
    max_time=$remaining
  fi

  status=$(
    curl -sS -A "$user_agent" \
      --connect-timeout "$connect_timeout" \
      --max-time "$max_time" \
      -D "$headers" \
      -o "$body" \
      -w '%{http_code}' \
      "$base_url/api/v3/versions" || true
  )

  case "$status" in
    200)
      break
      ;;
    000|502|503)
      ;;
    *)
      echo "unexpected readiness response: HTTP $status" >&2
      exit 1
      ;;
  esac

  sleep 1
done

test "$(tr -d '\n ' < "$body")" = '["2022-11-28","2026-03-10"]'
grep -qi '^x-github-api-version-selected: 2022-11-28' "$headers"

curl -fsS -A "$user_agent" \
  --connect-timeout "$connect_timeout" \
  --max-time "$request_timeout" \
  -H "x-github-api-version: 2026-03-10" \
  -D "$headers" \
  "$base_url/api/v3/versions" \
  -o "$body"
test "$(tr -d '\n ' < "$body")" = '["2022-11-28","2026-03-10"]'
grep -qi '^x-github-api-version-selected: 2026-03-10' "$headers"

status=$(
  curl -sS -A "$user_agent" \
    --connect-timeout "$connect_timeout" \
    --max-time "$request_timeout" \
    -D "$headers" \
    -o "$body" \
    -w '%{http_code}' \
    "$base_url/api/uploads/not-a-resource"
)
test "$status" = 404
grep -qi '^x-github-request-id:' "$headers"

curl -fsS \
  --connect-timeout "$connect_timeout" \
  --max-time "$request_timeout" \
  "$base_url/health" \
  -o "$body"
grep -q '"status":"ok"' "$body"
