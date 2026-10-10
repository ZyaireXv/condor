#!/usr/bin/env bash
set -euo pipefail
image="${1:?Usage: bash docker/smoke-test.sh IMAGE}"
container="condor-smoke-${RANDOM}"
volume="${container}-data"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker volume create "$volume" >/dev/null
docker run --detach --name "$container" \
  --env CONDOR_MODE=local --env ADMIN_USER_ID=1 --env CONDOR_TELEMETRY=off \
  --mount "type=volume,source=$volume,target=/app/data" "$image" >/dev/null
wait_ready() {
  for attempt in $(seq 1 90); do
    if docker exec "$container" python -c \
      "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8088/api/v1/auth/mode', timeout=2)" \
      >/dev/null 2>&1; then
      return 0
    fi
    if [ "$(docker inspect --format '{{.State.Running}}' "$container")" != true ]; then
      break
    fi
    sleep 2
  done
  docker logs "$container"
  return 1
}
wait_ready
docker exec -i "$container" python - <<'PY'
import json
import os
from pathlib import Path
import re
import urllib.request

base = "http://127.0.0.1:8088"
def request(path, *, method="GET", body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=10) as response:
        return response.read()

assert os.getuid() != 0, "Container must not run as root"
html = request("/").decode()
assert '<div id="root"' in html, "Compiled dashboard is missing"
asset = re.search(r'(?:src|href)="(/assets/[^\"]+)"', html)
assert asset and request(asset.group(1)), "Dashboard asset cannot be served"
assert json.loads(request("/api/v1/auth/mode"))["mode"] == "local"
login = json.loads(request("/api/v1/auth/local-login", method="POST", body={}))
assert login["user"]["id"] == 1 and login["user"]["role"] == "admin"
token = login["token"]
assert json.loads(request("/api/v1/auth/me", token=token))["id"] == 1
request("/api/v1/auth/preferences", method="PATCH", body={"updates": {"container_smoke_marker": "persistent"}}, token=token)
assert Path("/app/data/config.yml").is_file(), "Config must be persisted"
Path("/app/data/smoke-jwt.txt").write_text(token)
print("PASS: non-root process, compiled dashboard, assets, local login and configuration")
PY
docker restart --time 60 "$container" >/dev/null
wait_ready
docker exec -i "$container" python - <<'PY'
import json
from pathlib import Path
import urllib.request
token_path = Path("/app/data/smoke-jwt.txt")
request = urllib.request.Request(
    "http://127.0.0.1:8088/api/v1/auth/preferences",
    headers={"Authorization": "Bearer " + token_path.read_text()},
)
with urllib.request.urlopen(request, timeout=10) as response:
    prefs = json.load(response)
assert prefs["container_smoke_marker"] == "persistent", "Configuration or JWT secret lost on restart"
token_path.unlink()
print("PASS: configuration and session survive restart")
PY
docker stop --time 60 "$container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0
echo "PASS: graceful shutdown"
