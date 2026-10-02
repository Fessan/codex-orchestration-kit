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
python3 - "$repo/bin/session-usage" <<'TESTS'
import json
import os
from pathlib import Path
import subprocess
import sys

script = sys.argv[1]
codex = Path(os.environ['CODEX_HOME']) / 'sessions/2026/10/02/rollout-test-c1.jsonl'
claude = Path(os.environ['CLAUDE_CONFIG_DIR']) / 'projects/project/a1.jsonl'
base = {p: p.read_text() for p in (codex, claude)}
def run(agent=None, env=None, ok=True, error=None):
    command = ['bash', script] + (['--agent', agent] if agent else [])
    result = subprocess.run(command, env={**os.environ, 'CODEX_SESSION_ID': 'c1',
        'CLAUDE_CODE_SESSION_ID': 'a1', **(env or {})}, capture_output=True, text=True)
    assert (result.returncode == 0) == ok, (command, result.returncode, result.stderr)
    if not ok:
        assert not result.stdout and result.stderr
    if error:
        assert error in result.stderr, result.stderr
    return result

def restore():
    for path, content in base.items():
        path.write_text(content)

# F1: the event stream can contain the newest cumulative snapshot.
with codex.open('a') as stream:
    stream.write(json.dumps({'type': 'event_msg', 'payload': {'type': 'token_count',
        'info': {'total_token_usage': {'input_tokens': 300, 'output_tokens': 30}}}}) + '\n')
assert 'вход 300 (из кэша 0), выход 30' in run('codex').stdout
restore()
# F2: duplicate matches must not silently select the first file.
duplicate = codex.with_name('rollout-duplicate-c1.jsonl')
duplicate.write_text(base[codex])
run('codex', ok=False, error='найдено 2, ожидался один')
duplicate.unlink()
# F3: non-assistant usage is ignored; negative values remain invalid.
with claude.open('a') as stream:
    stream.write(json.dumps({'type': 'user', 'message': {'id': 'user',
        'usage': {'input_tokens': 999, 'output_tokens': 999}}}) + '\n')
assert 'вход 15, кэш-чтение 8, кэш-запись 3, выход 5' in run('claude').stdout
restore()
for agent, path in [('codex', codex), ('claude', claude)]:
    path.write_text(base[path].replace('"input_tokens":10', '"input_tokens":-10')
                    if agent == 'claude' else base[path].replace('"input_tokens":200', '"input_tokens":-200'))
    run(agent, ok=False, error='некорректные значения расхода')
    restore()
    # F4: a torn final line is ignored, but corruption inside the file is fatal.
    expected = run(agent).stdout
    path.write_text(base[path] + '{"type":')
    result = run(agent)
    assert result.stdout == expected and not result.stderr
    path.write_text('{"type":\n' + base[path])
    run(agent, ok=False, error='JSONDecodeError')
    restore()
    # F5b: explicit nulls in every numeric field count as zero.
    records = [json.loads(line) for line in base[path].splitlines()]
    for record in records:
        if agent == 'codex':
            payload = record['payload']
            usage = payload.get('thread_token_usage') or (payload.get('info') or {}).get('total_token_usage')
        else:
            usage = record['message']['usage']
        if usage:
            for field in usage:
                usage[field] = None
    path.write_text(''.join(json.dumps(record) + '\n' for record in records))
    result = run(agent)
    assert ('вход 0 (из кэша 0), выход 0 (из них reasoning 0)' if agent == 'codex'
            else 'вход 0, кэш-чтение 0, кэш-запись 0, выход 0') in result.stdout
    restore()
# F5a: newer log wins in either direction; explicit agent overrides timestamps.
for chosen, newer, older in [('codex', codex, claude), ('claude', claude, codex)]:
    os.utime(older, ns=(1_000_000_000, 1_000_000_000))
    os.utime(newer, ns=(2_000_000_000, 2_000_000_000))
    result = run()
    assert f'Расход: {chosen} сессия' in result.stdout
    assert chosen in result.stderr and 'позже' in result.stderr
    other = 'claude' if chosen == 'codex' else 'codex'
    explicit = run(other)
    assert f'Расход: {other} сессия' in explicit.stdout and not explicit.stderr
TESTS
printf 'PASS: session-usage smoke\n'
