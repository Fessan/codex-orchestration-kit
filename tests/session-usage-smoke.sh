#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export CODEX_HOME=$tmp/codex CLAUDE_CONFIG_DIR=$tmp/claude
unset CODEX_SESSION_ID CLAUDE_CODE_SESSION_ID
mkdir -p "$CODEX_HOME/sessions/2026/10/02" "$CLAUDE_CONFIG_DIR/projects/project"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cat > "$CODEX_HOME/sessions/2026/10/02/rollout-test-c1.jsonl" <<'DATA'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":2}}}}
{"type":"token_usage_record","payload":{"thread_token_usage":{"input_tokens":200,"cached_input_tokens":150,"output_tokens":20,"reasoning_output_tokens":5}}}
{"type":"event_msg","payload":{"type":"token_count","info":null}}
DATA
[[ $(CODEX_SESSION_ID=c1 bash "$repo/bin/session-usage") == 'Расход: codex сессия c1 — вход 200 (из кэша 150), выход 20 (из них reasoning 5)' ]] || fail 'Codex cumulative usage'
cat > "$CLAUDE_CONFIG_DIR/projects/project/a1.jsonl" <<'DATA'
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"cache_read_input_tokens":8,"cache_creation_input_tokens":3,"output_tokens":2}}}
{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"cache_read_input_tokens":8,"cache_creation_input_tokens":3,"output_tokens":4}}}
{"type":"assistant","requestId":"r2","message":{"usage":{"input_tokens":5,"output_tokens":1}}}
{"type":"assistant","requestId":"r2","message":{"usage":{"input_tokens":5,"output_tokens":1}}}
DATA
[[ $(bash "$repo/bin/session-usage" --agent claude --session a1) == 'Расход: claude сессия a1 — вход 15, кэш-чтение 8, кэш-запись 3, выход 5' ]] || fail 'Claude deduplication'
expect_failure() {
    if bash "$repo/bin/session-usage" "$@" > "$tmp/out" 2> "$tmp/err"; then fail 'missing failure'; fi
    [[ ! -s $tmp/out && -s $tmp/err ]] || fail 'error must be in stderr'
}
expect_failure
expect_failure --agent codex --session missing
printf '{}\n' > "$CODEX_HOME/sessions/2026/10/02/rollout-test-empty.jsonl"
expect_failure --agent codex --session empty
expect_failure --agent unknown
printf 'PASS: session-usage smoke\n'
