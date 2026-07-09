#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$repo_root/plugins/codex-token-usage/hooks/codex-stop-token-usage.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

session_id="11111111-2222-4333-8444-555555555555"
session_dir="$tmp/sessions/2026/07/09"
session_path="$session_dir/rollout-test-$session_id.jsonl"
mkdir -p "$session_dir"

cat >"$session_path" <<'JSONL'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":200,"reasoning_output_tokens":100,"total_tokens":1200}}}}
{"type":"event_msg","payload":{"type":"user_message","message":"Measure this turn"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Measure this turn"}]}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":17054,"cached_input_tokens":5280,"output_tokens":275,"reasoning_output_tokens":167,"total_tokens":17329}}}}
JSONL

output="$(printf '{"session_id":"%s"}\n' "$session_id" | CODEX_HOME="$tmp" "$hook")"
expected='turn total: 16,129 tokens (fresh input 11,574, cache read 4,480, output 75, reasoning 67)'

jq -e --arg expected "$expected" '.systemMessage | contains($expected)' <<<"$output" >/dev/null
printf 'Codex hook test passed: %s\n' "$(jq -r '.systemMessage' <<<"$output")"
