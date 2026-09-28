#!/bin/sh
set -eu

usage() {
    printf 'usage: %s --user [--source DIR] [--project DIR] [--with-global-agents] [--dry-run] [--uninstall]\n' "$0" >&2
    exit 2
}

source_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
user_mode=false
global_agents=false
dry_run=false
uninstall=false
project_dir=

while [ "$#" -gt 0 ]; do
    case $1 in
        --user) user_mode=true ;;
        --source)
            [ "$#" -ge 2 ] || usage
            source_dir=$2
            shift
            ;;
        --with-global-agents) global_agents=true ;;
        --project)
            [ "$#" -ge 2 ] || usage
            project_dir=$2
            shift
            ;;
        --dry-run) dry_run=true ;;
        --uninstall) uninstall=true ;;
        *) usage ;;
    esac
    shift
done

[ "$user_mode" = true ] || usage
source_dir=$(CDPATH= cd "$source_dir" && pwd -P) || exit 2
codex_home=${CODEX_HOME:-"$HOME/.codex"}
case $codex_home in
    /*) ;;
    *) printf 'CODEX_HOME must be absolute\n' >&2; exit 2 ;;
esac
claude_home=$HOME/.claude
if [ -n "$project_dir" ]; then
    project_dir=$(CDPATH= cd "$project_dir" && pwd -P) || exit 2
fi

target_claude_dispatch=$claude_home/skills/dispatching-codex-workers
target_claude_kit=$claude_home/skills/codex-orchestration-kit
target_codex_dispatch=$codex_home/skills/dispatching-codex-workers
target_codex_kit=$codex_home/skills/codex-orchestration-kit
target_ws=$claude_home/bin/ws
source_dispatch=$source_dir/skills/dispatching-codex-workers
source_kit=$source_dir/skills/codex-orchestration-kit
source_ws=$source_dir/bin/ws
source_agents=$source_dir/AGENTS.md
target_agents=$codex_home/AGENTS.md
target_project_agents=${project_dir:+$project_dir/AGENTS.md}

check_source() {
    if [ ! -e "$1" ]; then
        printf 'missing source: %s\n' "$1" >&2
        exit 2
    fi
}

if [ "$uninstall" = false ]; then
    check_source "$source_dispatch"
    check_source "$source_kit"
    check_source "$source_ws"
    if [ "$global_agents" = true ] || [ -n "$project_dir" ]; then
        check_source "$source_agents"
    fi
fi

is_ours() {
    [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]
}

conflicts=0
reported_parents='|'
preflight() {
    parent=$(dirname "$1")
    while [ ! -d "$parent" ]; do
        if [ -e "$parent" ] || [ -L "$parent" ]; then
            case $reported_parents in
                *"|$parent|"*) ;;
                *) printf 'conflict: parent is not a directory: %s\n' "$parent" >&2
                   reported_parents="$reported_parents$parent|" ;;
            esac
            conflicts=1
            break
        fi
        parent=$(dirname "$parent")
    done
    if [ ! -e "$1" ] && [ ! -L "$1" ] && [ -d "$parent" ] && [ ! -w "$parent" ]; then
        printf 'conflict: parent is not writable: %s\n' "$parent" >&2
        conflicts=1
    fi
    if [ -e "$1" ] || [ -L "$1" ]; then
        if ! is_ours "$1" "$2"; then
            if [ -L "$1" ]; then
                found="link -> $(readlink "$1")"
            elif [ -d "$1" ]; then
                found=directory
            else
                found=file
            fi
            printf 'conflict: %s (%s); expected link -> %s\n' "$1" "$found" "$2" >&2
            conflicts=1
        fi
    fi
}

if [ "$uninstall" = false ]; then
    preflight "$target_claude_dispatch" "$source_dispatch"
    preflight "$target_claude_kit" "$source_kit"
    preflight "$target_codex_dispatch" "$source_dispatch"
    preflight "$target_codex_kit" "$source_kit"
    preflight "$target_ws" "$source_ws"
    if [ "$global_agents" = true ]; then
        preflight "$target_agents" "$source_agents"
    fi
    if [ -n "$project_dir" ]; then
        preflight "$target_project_agents" "$source_agents"
    fi
    if [ "$conflicts" -ne 0 ]; then
        printf 'Resolve conflicts manually: back up and compare each path, then move it yourself before retrying. No changes were made.\n' >&2
        exit 1
    fi
fi

install_one() {
    if is_ours "$1" "$2"; then
        printf 'already installed: %s\n' "$1"
    elif [ "$dry_run" = true ]; then
        printf 'would link: %s -> %s\n' "$1" "$2"
    else
        mkdir -p "$(dirname "$1")"
        ln -s "$2" "$1"
        printf 'linked: %s -> %s\n' "$1" "$2"
    fi
}

uninstall_one() {
    if is_ours "$1" "$2"; then
        if [ "$dry_run" = true ]; then
            printf 'would unlink: %s\n' "$1"
        else
            rm -- "$1"
            printf 'unlinked: %s\n' "$1"
        fi
    elif [ -e "$1" ] || [ -L "$1" ]; then
        printf 'skip: not our link: %s\n' "$1"
    fi
}

if [ "$uninstall" = true ]; then
    action=uninstall_one
else
    action=install_one
fi

"$action" "$target_claude_dispatch" "$source_dispatch"
"$action" "$target_claude_kit" "$source_kit"
"$action" "$target_codex_dispatch" "$source_dispatch"
"$action" "$target_codex_kit" "$source_kit"
"$action" "$target_ws" "$source_ws"
if [ "$global_agents" = true ] || [ "$uninstall" = true ]; then
    "$action" "$target_agents" "$source_agents"
fi
if [ -n "$project_dir" ]; then
    "$action" "$target_project_agents" "$source_agents"
fi
