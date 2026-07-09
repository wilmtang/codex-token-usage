#!/usr/bin/env bash
set -u

now="$(date +'%H:%M:%S')"
codex_home="${CODEX_HOME:-$HOME/.codex}"
sessions_dir="$codex_home/sessions"
hook_input="$(cat)"

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '
}

emit() {
  local message="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg systemMessage "$message" '{systemMessage:$systemMessage}'
  else
    printf '{"systemMessage":"%s"}\n' "$(printf '%s' "$message" | json_escape)"
  fi
}

comma() {
  local number="$1"
  local sign=""
  local out=""

  if [[ ! "$number" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$number"
    return
  fi

  if [[ "$number" == -* ]]; then
    sign="-"
    number="${number#-}"
  fi

  while ((${#number} > 3)); do
    out=",${number: -3}$out"
    number="${number:0:${#number}-3}"
  done

  printf '%s%s%s' "$sign" "$number" "$out"
}

session_path_from_input() {
  local candidate=""
  local session_id=""

  candidate="$(
    printf '%s' "$hook_input" | jq -r '
      [
        .transcript_path?,
        .transcriptPath?,
        .session_path?,
        .sessionPath?,
        .conversation_path?,
        .conversationPath?,
        .rollout_path?,
        .rolloutPath?,
        .session.path?,
        .session.file?
      ]
      | map(select(type == "string" and length > 0))
      | .[0] // empty
    ' 2>/dev/null
  )"

  if [[ -n "$candidate" && -r "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  session_id="$(
    printf '%s' "$hook_input" | jq -r '
      .session_id?
      // .sessionId?
      // .session.id?
      // .conversation_id?
      // .conversationId?
      // empty
    ' 2>/dev/null
  )"
  session_id="${session_id:-${CODEX_SESSION_ID:-}}"

  if [[ -n "$session_id" && -d "$sessions_dir" ]]; then
    candidate="$(find "$sessions_dir" -type f -name "*$session_id*.jsonl" -print 2>/dev/null | head -n 1)"
    if [[ -n "$candidate" && -r "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

parse_stats() {
  local session_path="$1"
  jq -rs '
    def n:
      if type == "number" then .
      elif type == "string" then (tonumber? // 0)
      else 0
      end;
    def zero:
      {input: 0, cached: 0, output: 0, reasoning: 0, total: 0};
    def usage:
      .payload.info.total_token_usage
      | {
          input: ((.input_tokens // 0) | n),
          cached: ((.cached_input_tokens // 0) | n),
          output: ((.output_tokens // 0) | n),
          reasoning: ((.reasoning_output_tokens // 0) | n),
          total: ((.total_tokens // 0) | n)
        };
    def subtract($a; $b):
      {
        input: ([($a.input - $b.input), 0] | max),
        cached: ([($a.cached - $b.cached), 0] | max),
        output: ([($a.output - $b.output), 0] | max),
        reasoning: ([($a.reasoning - $b.reasoning), 0] | max),
        total: ([($a.total - $b.total), 0] | max)
      };
    def is_user_prompt:
      (.type == "event_msg" and .payload.type == "user_message")
      or (.type == "response_item" and .payload.type == "message" and .payload.role == "user");
    def is_token_count:
      .type == "event_msg"
      and .payload.type == "token_count"
      and (.payload.info.total_token_usage? != null);

    reduce .[] as $record (
      {
        last_total: null,
        baseline: zero,
        current: null,
        prompt_seen: false,
        usage_after_prompt: false
      };
      if ($record | is_user_prompt) then
        .baseline = (.last_total // zero)
        | .current = null
        | .prompt_seen = true
        | .usage_after_prompt = false
      elif ($record | is_token_count) then
        ($record | usage) as $usage
        | .last_total = $usage
        | .current = $usage
        | if .prompt_seen then .usage_after_prompt = true else . end
      else
        .
      end
    )
    | if .current == null then
        {available: false, reason: "no token usage snapshot yet"}
      elif (.prompt_seen | not) then
        {available: false, reason: "no user prompt boundary"}
      elif (.usage_after_prompt | not) then
        {available: false, reason: "no usage after latest user prompt yet"}
      else
        subtract(.current; .baseline) as $turn
        | {available: true, turn: $turn}
      end
  ' "$session_path"
}

if ! command -v jq >/dev/null 2>&1; then
  emit "$now | tokens unavailable: jq not found"
  exit 0
fi

stats=""
reason="session file not found"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  session_path="$(session_path_from_input || true)"
  if [[ -n "${session_path:-}" && -r "$session_path" ]]; then
    stats="$(parse_stats "$session_path" 2>/dev/null || true)"
    if [[ -n "$stats" && "$(printf '%s' "$stats" | jq -r '.available // false' 2>/dev/null)" == "true" ]]; then
      break
    fi
    reason="$(printf '%s' "$stats" | jq -r '.reason // "token usage not ready"' 2>/dev/null)"
  fi
  sleep 0.2
done

if [[ -z "$stats" || "$(printf '%s' "$stats" | jq -r '.available // false' 2>/dev/null)" != "true" ]]; then
  emit "$now | tokens unavailable: $reason"
  exit 0
fi

input_tokens="$(printf '%s' "$stats" | jq -r '.turn.input')"
cached_tokens="$(printf '%s' "$stats" | jq -r '.turn.cached')"
output_tokens="$(printf '%s' "$stats" | jq -r '.turn.output')"
reasoning_tokens="$(printf '%s' "$stats" | jq -r '.turn.reasoning')"
total_tokens="$(printf '%s' "$stats" | jq -r '.turn.total')"

fresh_tokens=$((input_tokens - cached_tokens))
if ((fresh_tokens < 0)); then
  fresh_tokens=0
fi

emit "$now | turn total: $(comma "$total_tokens") tokens (fresh input $(comma "$fresh_tokens"), cache read $(comma "$cached_tokens"), output $(comma "$output_tokens"), reasoning $(comma "$reasoning_tokens"))"
