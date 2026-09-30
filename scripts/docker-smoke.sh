#!/usr/bin/env bash
# Start a throwaway container from the image and wait until /healthz answers 200.
set -euo pipefail

docker_bin="$1"
image="$2"
port="${3:-4000}"
name="c3-smoke-$$"

cleanup() { "$docker_bin" rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

"$docker_bin" run -d --name "$name" -p "127.0.0.1:${port}:4000" \
  -e SECRET_KEY_BASE="$(head -c 48 /dev/urandom | base64 | tr -d '\n')" \
  -e PHX_HOST=localhost \
  "$image" >/dev/null

for _ in $(seq 1 30); do
  if body="$(curl -fsS "http://127.0.0.1:${port}/healthz" 2>/dev/null)"; then
    echo "healthz OK: $body"
    exit 0
  fi
  sleep 1
done

echo "healthz did not answer within 30s; container logs:" >&2
"$docker_bin" logs "$name" >&2
exit 1
