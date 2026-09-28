#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/orca-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$WS_CAPTURE"
STUB
chmod +x "$tmp/bin/orca-stub"
export WS_ORCA=$tmp/bin/orca-stub WS_CAPTURE=$tmp/capture PATH=$tmp/bin:/usr/bin:/bin

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_pass() {
    local -a original=("$@") actual=()
    rm -f -- "$WS_CAPTURE"
    bash "$repo/bin/ws" "$@" > "$tmp/output" 2>&1 || fail "unexpected denial: $*"
    [[ -f $WS_CAPTURE ]] || fail 'Orca stub was not called'
    while IFS= read -r -d '' item; do actual+=("$item"); done < "$WS_CAPTURE"
    [[ ${actual[0]} == orchestration && ${actual[1]} == worker-start ]] || fail 'wrong command'
    [[ ${#actual[@]} -eq $((${#original[@]} + 2)) ]] || fail 'argv length changed'
    for ((i = 0; i < ${#original[@]}; i++)); do
        [[ ${actual[i+2]} == "${original[i]}" ]] || fail "argv changed at $i"
    done
}
expect_deny() {
    local status=0
    rm -f -- "$WS_CAPTURE"
    bash "$repo/bin/ws" "$@" > "$tmp/output" 2>&1 || status=$?
    [[ $status -eq 2 ]] || fail "expected exit 2, got $status: $*"
    [[ ! -e $WS_CAPTURE ]] || fail 'Orca stub called on denial'
    grep -q 'needs a line' "$tmp/output" || fail 'denial explanation missing'
}

expect_pass --agent codex --model gpt-6-sol --effort medium --spec 'ordinary task' --worktree current
expect_pass --model gpt-6-luna --effort ultra --spec 'ordinary task'
expect_deny --model gpt-6-astra --spec 'high: wrong label'
expect_pass --model gpt-6-astra --spec $'Astra: required reason\nmore context'
expect_deny --agent claude --model claude-opus-4 --spec 'astra: wrong label'
expect_pass --agent claude --model claude-opus-4 --spec 'opus: required reason'
expect_pass --agent codex --model x-opus --spec 'ordinary task'
expect_deny --model gpt-5.6-sol --spec 'high: wrong label'
expect_pass --model gpt-5.6-sol --spec 'legacy: required reason'
expect_deny --model gpt-5.6-sol --effort high --spec 'legacy: only'
expect_pass --model gpt-5.6-sol --effort high --spec $'legacy: required\nhigh: required'
expect_deny --model gpt-6-sol --effort high --spec 'sol: old label'
expect_pass --model gpt-6-sol --effort high --spec 'high: required reason'
expect_deny --model gpt-6-sol --effort ultra --spec 'ordinary task'
expect_deny --model gpt-6-sol-codex --effort high --spec x
expect_deny --model openai/gpt-6-sol --effort high --spec x
expect_deny --model sol --effort max --spec x
expect_deny --model gpt-5.6-sol --effort high --spec 'legacy: y'
expect_pass --agent claude --model gpt-6-sol --effort high --spec x
expect_deny --model GPT-6-SOL --effort XHIGH --spec 'see high: x'
expect_pass --model GPT-6-SOL --effort XHIGH --spec '  - HIGH: reason'
expect_deny --model gpt-6-sol --effort max --spec 'ordinary task'
expect_pass --model gpt-6-sol --effort high --spec=high:x
printf '%s\n' 'high: reason from file' > "$tmp/spec"
expect_pass --model=gpt-6-sol --effort=high --spec "@$tmp/spec" --worktree current
expect_deny --model=gpt-6-sol --effort=high --spec "@$tmp/missing"
mkdir "$tmp/spec-dir"
expect_deny --model=gpt-6-sol --effort=high --spec "@$tmp/spec-dir"

# Fall back to binaries in PATH when WS_ORCA is absent.
cp "$tmp/bin/orca-stub" "$tmp/bin/orca-ide"
(unset WS_ORCA; expect_pass --model gpt-6-luna --spec x)
rm "$tmp/bin/orca-ide"
cp "$tmp/bin/orca-stub" "$tmp/bin/orca"
(unset WS_ORCA; expect_pass --model gpt-6-luna --spec x)

# Avoid Bash 4-only case conversion and unsafe empty-array expansion.
if grep -Eq '\$\{[^}]*,,\}' "$repo/bin/ws"; then fail 'Bash 4 case conversion'; fi
if grep -Fq '"${triggers[@]}"' "$repo/bin/ws" && ! grep -Fq '${triggers[@]+"${triggers[@]}"}' "$repo/bin/ws"; then fail 'unsafe empty array'; fi
printf 'ws smoke: ok\n'
