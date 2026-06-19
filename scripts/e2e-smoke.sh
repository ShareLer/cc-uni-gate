#!/usr/bin/env bash
set -euo pipefail

PREFERENCES_FILE="${HOME}/Library/Application Support/UniGate/preferences.json"
PORT="$(
  PREFERENCES_FILE="$PREFERENCES_FILE" python3 <<'PY'
import json
import os

path = os.environ["PREFERENCES_FILE"]
try:
    with open(path, "r", encoding="utf-8") as f:
        port = int(json.load(f).get("port") or 17888)
except Exception:
    port = 17888
print(port if port > 0 else 17888)
PY
)"

BASE_URL="${UNIGATE_BASE_URL:-http://127.0.0.1:${PORT}}"
MODEL="${UNIGATE_E2E_MODEL:-deepseek-v4-flash}"
CLAUDE_MODEL="${UNIGATE_E2E_CLAUDE_MODEL:-Deepseek-v4-flash}"
TIMEOUT="${UNIGATE_E2E_TIMEOUT:-120}"

tmpfiles=()
cleanup() {
  if ((${#tmpfiles[@]})); then
    rm -f "${tmpfiles[@]}"
  fi
}
trap cleanup EXIT

request() {
  local name="$1"
  local path="$2"
  local body="$3"
  local extra_header="${4:-}"
  local body_file
  body_file="$(mktemp)"
  tmpfiles+=("$body_file")

  local args=(-sS -m "$TIMEOUT" -o "$body_file" -w "%{http_code}" "$BASE_URL$path" -H "content-type: application/json" -d "$body")
  if [[ -n "$extra_header" ]]; then
    args+=(-H "$extra_header")
  fi

  local status
  status="$(curl "${args[@]}")"
  python3 - "$name" "$status" "$body_file" <<'PY'
import json
import sys

name, status, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
text = open(path, "rb").read().decode("utf-8", errors="replace")
summary = ""

try:
    data = json.loads(text) if text else {}
    if isinstance(data, dict):
        summary = data.get("output_text") or ""
        choices = data.get("choices")
        if not summary and isinstance(choices, list) and choices:
            message = choices[0].get("message", {}) if isinstance(choices[0], dict) else {}
            if isinstance(message, dict):
                summary = message.get("content") or ""
        content = data.get("content")
        if not summary and isinstance(content, list):
            summary = " ".join(
                part.get("text", "") for part in content if isinstance(part, dict)
            )
        error = data.get("error")
        if not summary and isinstance(error, dict):
            summary = error.get("message", "")
        if not summary and isinstance(error, str):
            summary = error
except Exception:
    summary = text

summary = " ".join(str(summary).split())[:240]
print(f"{name}: HTTP {status}" + (f" · {summary}" if summary else ""))
if not (200 <= status < 300):
    sys.exit(1)
if "OK" not in summary.upper() and "OK" not in text.upper():
    print(f"{name}: response did not contain expected OK", file=sys.stderr)
    sys.exit(1)
PY
}

echo "UniGate E2E smoke: $BASE_URL"
for _ in {1..40}; do
  if curl -fsS -m 2 "$BASE_URL/__manager/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
curl -fsS -m 10 "$BASE_URL/__manager/health" >/dev/null

catalog_file="$(mktemp)"
tmpfiles+=("$catalog_file")
curl -fsS -m 10 "$BASE_URL/__manager/catalog" -o "$catalog_file"
python3 - "$catalog_file" "$MODEL" "$CLAUDE_MODEL" <<'PY'
import json
import sys

path, model, claude_model = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(path, "r", encoding="utf-8"))
providers = data.get("providers", [])
candidates = data.get("candidates", [])
if any(p.get("name", "").lower() == "unigate" for p in providers):
    raise SystemExit("catalog still includes UniGate provider")
if not any(c.get("appType") == "codex" and c.get("logicalModel") == model for c in candidates):
    raise SystemExit(f"missing Codex model candidate: {model}")
if not any(c.get("appType") == "claude" and c.get("logicalModel") == claude_model for c in candidates):
    raise SystemExit(f"missing Claude Code model candidate: {claude_model}")
print(f"Catalog: {len(providers)} providers, {len(candidates)} candidates")
PY

request \
  "Codex Responses" \
  "/codex/v1/responses" \
  "{\"model\":\"${MODEL}\",\"input\":\"不要解释，只输出 OK\",\"max_output_tokens\":128}"

request \
  "Codex Chat" \
  "/codex/v1/chat/completions" \
  "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"不要解释，只输出 OK\"}],\"max_tokens\":128}"

request \
  "Claude Code Messages" \
  "/claude-code/v1/messages" \
  "{\"model\":\"${CLAUDE_MODEL}\",\"max_tokens\":128,\"messages\":[{\"role\":\"user\",\"content\":\"不要解释，只输出 OK\"}]}" \
  "anthropic-version: 2023-06-01"

echo "E2E smoke passed"
