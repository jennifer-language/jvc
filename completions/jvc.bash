# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# bash completion for jvc, the Jennifer deck manager.
#
#     source completions/jvc.bash
#
# or install it where your shell looks for completions, usually one of:
#
#     /usr/share/bash-completion/completions/jvc
#     ~/.local/share/bash-completion/completions/jvc
#
# Nothing here runs jvc, so Tab never starts an interpreter: the manifest and
# the lockfile are read directly.

# _jvc_manifest prints the manifest in the current directory (deck.toml,
# deck.yaml, deck.yml or deck.json), or nothing. Like jvc, it does not look in
# parent directories.
_jvc_manifest() {
    local name
    for name in deck.toml deck.yaml deck.yml deck.json; do
        if [[ -f "$PWD/$name" ]]; then
            printf '%s\n' "$PWD/$name"
            return 0
        fi
    done
    return 1
}

# _jvc_table prints the keys of one manifest table.
#
# Both patterns are anchored at line start: unanchored, `"decks"` also matches
# `"dev-decks"`, and the section name itself would be offered as a deck. The
# JSON arm assumes the pretty-printed form jvc writes, one key per line.
_jvc_table() {
    local file=$1 table=$2
    [[ -f $file ]] || return 0
    case $file in
        *.json)
            sed -n "/^[[:space:]]*\"$table\"[[:space:]]*:/,/^[[:space:]]*}/p" "$file" \
                | grep -o '^[[:space:]]*"[^"]\+"[[:space:]]*:' \
                | sed 's/[[:space:]]*:$//; s/^[[:space:]]*"//; s/"$//' \
                | grep -v "^$table$"
            ;;
        *)
            sed -n "/^\[$table\]/,/^\[/p" "$file" \
                | grep -o '^[[:space:]]*"\?[^"[:space:]=]\+"\?[[:space:]]*=' \
                | sed 's/[[:space:]]*=$//; s/^[[:space:]]*//; s/^"//; s/"$//'
            ;;
    esac
}

# _jvc_decks prints every deck the manifest requires, dev included.
_jvc_decks() {
    local m
    m=$(_jvc_manifest) || return 0
    { _jvc_table "$m" decks; _jvc_table "$m" dev-decks; } | sort -u
}

# _jvc_self prints this project's own deck name, the usual target of `yank`.
_jvc_self() {
    local m
    m=$(_jvc_manifest) || return 0
    sed -n 's/^[[:space:]]*"\?name"\?[[:space:]]*[=:][[:space:]]*"\([^"]*\)".*/\1/p' \
        "$m" | head -n1
}

# _jvc_locked prints the decks camcorder.lock pins, transitive ones included:
# what `update` operates on.
#
# The names are the keys at exactly one level inside "decks", which the pretty
# printer puts at four spaces. Matching any `"key": {` instead would also return
# each entry's own "engines" and "requires" sub-objects.
_jvc_locked() {
    local m dir lock
    m=$(_jvc_manifest) || return 0
    dir="${m%/*}"
    lock="$dir/camcorder.lock"
    [[ -f $lock ]] || return 0
    grep -o '^    "[^"]\+"[[:space:]]*:[[:space:]]*{' "$lock" \
        | sed 's/[[:space:]]*:[[:space:]]*{$//; s/^ *"//; s/"$//'
}

# _jvc_scopes prints the mapping keys `jvc registry` accepts (mapped scopes,
# depended-on scopes, and `*`), in the `@scope/*` form the manifest stores, so
# each appears once.
_jvc_scopes() {
    local m
    m=$(_jvc_manifest) || { printf '*\n'; return 0; }
    {
        printf '*\n'
        _jvc_table "$m" registries
        _jvc_decks | sed -n 's|^\(@[^/]*\)/.*|\1/*|p'
    } | sed 's|^\(@[^/]*\)$|\1/*|' | sort -u
}

# _jvc_apps prints installed app names, read from the store's record file rather
# than by asking jvc.
_jvc_apps() {
    local store="${JVC_APP_HOME:-}"
    if [[ -z $store ]]; then
        store="${XDG_DATA_HOME:-$HOME/.local/share}/jvc/apps"
    fi
    local record="$store/installed.json"
    [[ -f $record ]] || return 0
    # Keys one level inside "apps", at four spaces. Matching any `"key": {`
    # would return the "apps" header itself, and offer it as an app name.
    grep -o '^    "[^"]\+"[[:space:]]*:[[:space:]]*{' "$record" \
        | sed 's/[[:space:]]*:[[:space:]]*{$//; s/^ *"//; s/"$//'
}

# _jvc_offer fills COMPREPLY from a word list with globbing off: compgen expands
# its word list, and the scope list holds a literal `*`.
_jvc_offer() {
    local restore=0
    case $- in *f*) ;; *) set -f; restore=1 ;; esac
    COMPREPLY=($(compgen -W "$1" -- "$2"))
    (( restore )) && set +f
    return 0
}

# _jvc_ltrim strips the part of each URL candidate before the last colon in the
# current word: bash splits words on `:` (COMP_WORDBREAKS), so `https:` would
# otherwise be inserted twice.
_jvc_ltrim() {
    if declare -F __ltrim_colon_completions >/dev/null 2>&1; then
        __ltrim_colon_completions "$1"
    fi
}

_jvc() {
    local cur prev words cword
    if declare -F _init_completion >/dev/null 2>&1; then
        _init_completion -n : || return
    else
        COMPREPLY=()
        cur=${COMP_WORDS[COMP_CWORD]}
        prev=${COMP_WORDS[COMP_CWORD-1]}
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    fi

    # bash shows no descriptions, so verbs are listed bare; `jvc help` has one
    # line each.
    local commands="init add remove list check conflict engine source
        query install update new publish pack app registry yank unyank whoami scopes
        claim owners login logout version help"

    # A flag that takes a value: complete the value, not a verb.
    case $prev in
        --registry)
            _jvc_offer "$JVC_REGISTRY https://registry.jennifer-lang.dev http://localhost:8080" "$cur"
            _jvc_ltrim "$cur"
            return
            ;;
        --scope)
            # project, user and system, plus a directory for the fourth form.
            _jvc_offer "project user system" "$cur"
            COMPREPLY+=($(compgen -d -- "$cur"))
            return
            ;;
        --out)
            COMPREPLY=($(compgen -d -- "$cur"))
            return
            ;;
        --from|--version|--source|--url|--repository|--tag|--remote)
            return
            ;;
    esac

    # Find the verb: the first word that is not a flag or a flag's value.
    local i verb="" sub="" skip=0 argc=0
    for ((i = 1; i < cword; i++)); do
        local w=${words[i]}
        if (( skip )); then skip=0; continue; fi
        case $w in
            --registry|--from|--version|--source|--url|--out|--scope\
                |--repository|--tag|--remote)
                skip=1; continue ;;
            -*) continue ;;
        esac
        if [[ -z $verb ]]; then verb=$w
        elif [[ -z $sub ]]; then sub=$w; argc=1
        else argc=$((argc + 1))
        fi
    done

    if [[ -z $verb ]]; then
        if [[ $cur == -* ]]; then
            _jvc_offer "--help --version" "$cur"
        else
            _jvc_offer "$commands" "$cur"
        fi
        return
    fi

    # Flags, per verb. --registry only where the verb talks to a repository:
    # the manifest verbs, pack, check and version never read it.
    if [[ $cur == -* ]]; then
        local flags=""
        case $verb in
            query|search|install|sync|update|upgrade|new|publish|yank|unyank\
                |whoami|scopes|claim|owners|login|logout|app)
                flags="--registry" ;;
        esac
        case $verb in
            add|remove|rm|install|sync|update|upgrade) flags="$flags --dev" ;;
        esac
        case $verb in
            install|sync|update|upgrade) flags="$flags --runtests" ;;
            publish) flags="$flags --no-verify --repository --tag --remote" ;;
            pack) flags="$flags --out --url --no-verify --operator-command" ;;
            new) flags="$flags --from --version --source" ;;
            app) flags="$flags --scope --system --version" ;;
            owners) flags="$flags --remove" ;;
        esac
        _jvc_offer "$flags" "$cur"
        return
    fi

    # Aliases (`rm`, `search`, `upgrade`, ...) are matched here but not offered
    # as verbs, to keep the verb list short.
    case $verb in
        remove|rm|conflict|source|query|search)
            # What the manifest requires: the only decks remove, conflict and
            # source can act on, and the likely ones for query.
            _jvc_offer "$(_jvc_decks)" "$cur"
            ;;
        update|upgrade)
            _jvc_offer "$(_jvc_locked)" "$cur"
            ;;
        yank|unyank)
            if (( argc == 0 )); then
                _jvc_offer "$(_jvc_self)" "$cur"
            fi
            ;;
        registry)
            if (( argc == 0 )); then
                _jvc_offer "$(_jvc_scopes)" "$cur"
            elif (( argc == 1 )); then
                _jvc_offer "https://registry.jennifer-lang.dev http://localhost:8080" "$cur"
            fi
            ;;
        claim|owners)
            # A scope name here, not a mapping key: no wildcard, no catch-all.
            if (( argc == 0 )); then
                _jvc_offer "$(_jvc_decks | sed -n 's|^@\([^/]*\)/.*|\1|p' | sort -u)" "$cur"
            fi
            ;;
        engine)
            if (( argc == 0 )); then
                _jvc_offer "jennifer jennifer-tiny" "$cur"
            fi
            ;;
        app)
            if [[ -z $sub ]]; then
                _jvc_offer "install list update uninstall" "$cur"
            else
                case $sub in
                    update|upgrade|uninstall|remove|rm)
                        _jvc_offer "$(_jvc_apps)" "$cur" ;;
                esac
            fi
            ;;
    esac

    _jvc_ltrim "$cur"
}

complete -F _jvc jvc
