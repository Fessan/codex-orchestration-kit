#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
base_tmp=$(mktemp -d)
base_tmp=$(cd -- "$base_tmp" && pwd -P)
tmp=$base_tmp/'space in test'
mkdir -p "$tmp"
trap 'rm -rf -- "$base_tmp"' EXIT
export HOME=$tmp/home CODEX_HOME=$tmp/custom-codex XDG_CONFIG_HOME=$tmp/xdg
mkdir -p "$HOME" "$CODEX_HOME"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_link() {
    [[ -L $1 ]] || fail "missing link: $1"
    [[ $(readlink "$1") == "$2" ]] || fail "wrong target: $1"
}
assert_absent() { [[ ! -e $1 && ! -L $1 ]] || fail "unexpected path: $1"; }
run_install() { sh "$repo/install.sh" --user --source "$repo" "$@" > "$tmp/output" 2>&1; }
run_default() { sh "$repo/install.sh" --user "$@" > "$tmp/output" 2>&1; }
assert_no_links() {
    for owner in "$HOME/.claude" "$CODEX_HOME"; do
        assert_absent "$owner/skills/dispatching-codex-workers"
        assert_absent "$owner/skills/codex-orchestration-kit"
    done
    assert_absent "$HOME/.claude/bin/ws"
}
assert_other_links() {
    assert_absent "$HOME/.claude/skills/dispatching-codex-workers"
    assert_absent "$HOME/.claude/skills/codex-orchestration-kit"
    assert_absent "$CODEX_HOME/skills/dispatching-codex-workers"
    assert_absent "$HOME/.claude/bin/ws"
}

# Project-only mode changes only the project policy.
mkdir -p "$tmp/project-only"
printf 'foreign policy\n' > "$tmp/project-only/AGENTS.md"
cp "$tmp/project-only/AGENTS.md" "$tmp/project-only-before"
if sh "$repo/install.sh" --project "$tmp/project-only" > "$tmp/output" 2>&1; then fail 'project-only conflict accepted'; fi
cmp -s "$tmp/project-only/AGENTS.md" "$tmp/project-only-before" || fail 'project-only conflict changed'
sh "$repo/install.sh" --uninstall --project "$tmp/project-only" > "$tmp/output" 2>&1
cmp -s "$tmp/project-only/AGENTS.md" "$tmp/project-only-before" || fail 'project-only foreign policy removed'
assert_no_links
rm -- "$tmp/project-only/AGENTS.md"
sh "$repo/install.sh" --project "$tmp/project-only" --dry-run > "$tmp/output" 2>&1
assert_absent "$tmp/project-only/AGENTS.md"
assert_no_links
sh "$repo/install.sh" --project "$tmp/project-only" > "$tmp/output" 2>&1
assert_link "$tmp/project-only/AGENTS.md" "$repo/AGENTS.md"
assert_no_links
sh "$repo/install.sh" --project "$tmp/project-only" > "$tmp/output" 2>&1
grep -q '^already installed:' "$tmp/output" || fail 'project-only repeat not idempotent'
sh "$repo/install.sh" --uninstall --project "$tmp/project-only" --dry-run > "$tmp/output" 2>&1
assert_link "$tmp/project-only/AGENTS.md" "$repo/AGENTS.md"
sh "$repo/install.sh" --uninstall --project "$tmp/project-only" > "$tmp/output" 2>&1
assert_absent "$tmp/project-only/AGENTS.md"
assert_no_links
if sh "$repo/install.sh" > "$tmp/output" 2>&1; then fail 'missing install mode accepted'; fi
if sh "$repo/install.sh" --uninstall > "$tmp/output" 2>&1; then fail 'missing uninstall mode accepted'; fi

# Dry run must not create even parent directories.
run_install --dry-run
assert_absent "$HOME/.claude"
assert_absent "$CODEX_HOME/skills"

# A late conflict must prevent all links and parent-directory creation.
mkdir -p "$HOME/.claude/bin"
printf 'owned by someone else\n' > "$HOME/.claude/bin/ws"
cp "$HOME/.claude/bin/ws" "$tmp/before"
if run_install; then fail 'conflict accepted'; fi
cmp -s "$HOME/.claude/bin/ws" "$tmp/before" || fail 'conflict changed'
assert_absent "$HOME/.claude/skills"
assert_absent "$CODEX_HOME/skills"
grep -Eq 'conflict:|Resolve conflicts manually' "$tmp/output" || fail 'conflict details missing'
rm -- "$HOME/.claude/bin/ws"

# An occupied parent must fail before any other target is written.
printf 'blocked directory\n' > "$CODEX_HOME/skills"
if run_install; then fail 'occupied parent accepted'; fi
assert_absent "$HOME/.claude/skills"
assert_absent "$HOME/.claude/bin/ws"
rm -- "$CODEX_HOME/skills"

# A late directory, broken link, and AGENTS.md directory must block every link.
mkdir -p "$CODEX_HOME/skills/codex-orchestration-kit"
printf 'keep\n' > "$CODEX_HOME/skills/codex-orchestration-kit/keep"
if run_install; then fail 'late directory accepted'; fi
assert_other_links
[[ $(find "$CODEX_HOME/skills/codex-orchestration-kit" -mindepth 1 | wc -l) -eq 1 ]] || fail 'wrote inside late directory'
rm -r -- "$CODEX_HOME/skills/codex-orchestration-kit"
ln -s "$tmp/missing" "$CODEX_HOME/skills/codex-orchestration-kit"
if run_install; then fail 'broken link accepted'; fi
assert_other_links
assert_link "$CODEX_HOME/skills/codex-orchestration-kit" "$tmp/missing"
rm -- "$CODEX_HOME/skills/codex-orchestration-kit"
mkdir -p "$CODEX_HOME/AGENTS.md"
printf 'keep\n' > "$CODEX_HOME/AGENTS.md/keep"
if run_install --with-global-agents; then fail 'AGENTS directory accepted'; fi
assert_no_links
[[ $(find "$CODEX_HOME/AGENTS.md" -mindepth 1 | wc -l) -eq 1 ]] || fail 'wrote inside AGENTS directory'
rm -r -- "$CODEX_HOME/AGENTS.md"

# The default source resolves from the installer, even from another cwd.
(cd "$tmp" && run_default)

run_install
for owner in "$HOME/.claude" "$CODEX_HOME"; do
    assert_link "$owner/skills/dispatching-codex-workers" "$repo/skills/dispatching-codex-workers"
    assert_link "$owner/skills/codex-orchestration-kit" "$repo/skills/codex-orchestration-kit"
done
assert_link "$HOME/.claude/bin/ws" "$repo/bin/ws"
run_install
[[ $(grep -c '^already installed:' "$tmp/output") == 5 ]] || fail 'repeat not idempotent'

# The optional global policy is opt-in and uses CODEX_HOME.
assert_absent "$CODEX_HOME/AGENTS.md"
printf 'existing policy\n' > "$CODEX_HOME/AGENTS.md"
cp "$CODEX_HOME/AGENTS.md" "$tmp/before"
if run_install --with-global-agents; then fail 'global policy conflict accepted'; fi
cmp -s "$CODEX_HOME/AGENTS.md" "$tmp/before" || fail 'global policy changed'
rm -- "$CODEX_HOME/AGENTS.md"
run_install --with-global-agents
assert_link "$CODEX_HOME/AGENTS.md" "$repo/AGENTS.md"

# Project-only removal leaves previously installed user and global links intact.
sh "$repo/install.sh" --project "$tmp/project-only" > "$tmp/output" 2>&1
sh "$repo/install.sh" --uninstall --project "$tmp/project-only" > "$tmp/output" 2>&1
assert_absent "$tmp/project-only/AGENTS.md"
assert_link "$HOME/.claude/bin/ws" "$repo/bin/ws"
assert_link "$CODEX_HOME/AGENTS.md" "$repo/AGENTS.md"

# Dry uninstall preserves installed links, including the global policy.
run_install --uninstall --dry-run
assert_link "$HOME/.claude/bin/ws" "$repo/bin/ws"
assert_link "$CODEX_HOME/AGENTS.md" "$repo/AGENTS.md"

# Project policy is opt-in and does not replace existing content.
mkdir -p "$tmp/project"
printf 'foreign policy\n' > "$tmp/project/AGENTS.md"
cp "$tmp/project/AGENTS.md" "$tmp/project-before"
if run_install --project "$tmp/project"; then fail 'project conflict accepted'; fi
cmp -s "$tmp/project/AGENTS.md" "$tmp/project-before" || fail 'project policy changed'
rm -- "$tmp/project/AGENTS.md"
run_install --project "$tmp/project"
assert_link "$tmp/project/AGENTS.md" "$repo/AGENTS.md"
run_install --uninstall --project "$tmp/project" --dry-run
assert_link "$tmp/project/AGENTS.md" "$repo/AGENTS.md"
run_install --uninstall --project "$tmp/project"
assert_absent "$tmp/project/AGENTS.md"
run_install --with-global-agents

# Uninstall skips foreign content without reporting failure.
rm -- "$HOME/.claude/skills/dispatching-codex-workers"
printf 'foreign\n' > "$HOME/.claude/skills/dispatching-codex-workers"
rm -- "$CODEX_HOME/skills/codex-orchestration-kit"
ln -s "$tmp/foreign-target" "$CODEX_HOME/skills/codex-orchestration-kit"
run_install --uninstall
[[ -f $HOME/.claude/skills/dispatching-codex-workers ]] || fail 'foreign file removed'
assert_link "$CODEX_HOME/skills/codex-orchestration-kit" "$tmp/foreign-target"
grep -q 'skip: not our link' "$tmp/output" || fail 'foreign skip not reported'
for path in \
    "$HOME/.claude/skills/codex-orchestration-kit" \
    "$CODEX_HOME/skills/dispatching-codex-workers" \
    "$HOME/.claude/bin/ws" \
    "$CODEX_HOME/AGENTS.md"; do
    assert_absent "$path"
done
if CODEX_HOME=relative run_install; then fail 'relative CODEX_HOME accepted'; fi
grep -q 'CODEX_HOME must be absolute' "$tmp/output" || fail 'relative CODEX_HOME explanation missing'

# A default source in a path with spaces resolves to the copied script's directory.
copy=$tmp/'repo source'
mkdir -p "$copy/skills/dispatching-codex-workers" "$copy/skills/codex-orchestration-kit" "$copy/bin"
cp "$repo/install.sh" "$copy/install.sh"
cp "$repo/bin/ws" "$copy/bin/ws"
printf 'agents\n' > "$copy/AGENTS.md"
(export HOME=$tmp/'copy home' CODEX_HOME=$tmp/'copy codex'; mkdir -p "$HOME"; cd "$tmp"; sh "$copy/install.sh" --user > "$tmp/copy-output"; assert_link "$HOME/.claude/bin/ws" "$copy/bin/ws")
printf 'install smoke: ok\n'
