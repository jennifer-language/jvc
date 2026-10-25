# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# fish completion for jvc, the Jennifer deck manager.
#
#     source completions/jvc.fish
#
# or install it where fish looks for completions, usually one of:
#
#     /usr/share/fish/vendor_completions.d/jvc.fish
#     ~/.config/fish/completions/jvc.fish
#
# Nothing here runs jvc, so Tab never starts an interpreter: the manifest and
# the lockfile are read directly.

# --- reading the project -----------------------------------------------------

# __jvc_manifest prints the manifest in the current directory (deck.toml,
# deck.yaml, deck.yml or deck.json), or nothing. Like jvc, it does not look in
# parent directories.
function __jvc_manifest
    for name in deck.toml deck.yaml deck.yml deck.json
        if test -f "$PWD/$name"
            echo "$PWD/$name"
            return 0
        end
    end
    return 1
end

# __jvc_table prints the keys of one manifest table.
#
# The TOML header is matched with its closing bracket: as a prefix, `[decks`
# would also match `[dev-decks]`. The JSON arm assumes the pretty-printed form
# jvc writes, one key per line.
function __jvc_table --argument-names file table
    test -f "$file"; or return 0
    set -l inside 0
    for line in (cat $file)
        if string match -q '*.json' -- $file
            if test $inside -eq 0
                string match -qr "^\s*\"$table\"\s*:" -- $line; and set inside 1
                continue
            end
            string match -qr '^\s*\}' -- $line; and break
            set -l m (string match -r '^\s*"([^"]+)"\s*:' -- $line)
            test (count $m) -ge 2; and echo $m[2]
        else
            if test $inside -eq 0
                string match -qr "^\[$table\]" -- $line; and set inside 1
                continue
            end
            string match -qr '^\[' -- $line; and break
            set -l m (string match -r '^\s*"?([^"\s=]+)"?\s*=' -- $line)
            test (count $m) -ge 2; and echo $m[2]
        end
    end
end

# __jvc_decks prints every deck the manifest requires, dev included.
function __jvc_decks
    set -l m (__jvc_manifest); or return 0
    begin
        __jvc_table $m decks
        __jvc_table $m dev-decks
    end | sort -u
end

# __jvc_self prints this project's own deck name, the usual target of `yank`.
function __jvc_self
    set -l m (__jvc_manifest); or return 0
    for line in (cat $m)
        set -l k (string match -r '^\s*"?name"?\s*[=:]\s*"([^"]+)"' -- $line)
        if test (count $k) -ge 2
            echo $k[2]
            return 0
        end
    end
end

# __jvc_locked prints the decks camcorder.lock pins, transitive ones included:
# what `update` operates on.
#
# The names are the keys at exactly one level inside "decks", which the pretty
# printer puts at four spaces. Matching any `"key": {` instead would also return
# each entry's own "engines" and "requires" sub-objects.
function __jvc_locked
    set -l m (__jvc_manifest); or return 0
    set -l lock (string replace -r '/[^/]*$' '' -- $m)/camcorder.lock
    test -f "$lock"; or return 0
    for line in (cat $lock)
        set -l k (string match -r '^    "([^"]+)"\s*:\s*\{' -- $line)
        test (count $k) -ge 2; and echo $k[2]
    end
end

# __jvc_scopes prints the mapping keys `jvc registry` accepts (mapped scopes,
# depended-on scopes, and `*`), in the `@scope/*` form the manifest stores, so
# each appears once.
function __jvc_scopes
    set -l m (__jvc_manifest)
    if test -z "$m"
        echo '*'
        return 0
    end
    begin
        echo '*'
        __jvc_table $m registries
        __jvc_decks | string replace -r -f '^(@[^/]+)/.*' '$1/*'
    end | string replace -r '^(@[^/]+)$' '$1/*' | sort -u
end

# __jvc_scopenames prints bare scopes for `claim` and `owners`: no wildcard,
# no catch-all.
function __jvc_scopenames
    __jvc_decks | string replace -r -f '^@([^/]+)/.*' '$1' | sort -u
end

# __jvc_apps prints installed app names, read from the store's record file
# rather than by asking jvc.
function __jvc_apps
    set -l store $JVC_APP_HOME
    if test -z "$store"
        set -l data $XDG_DATA_HOME
        test -z "$data"; and set data $HOME/.local/share
        set store $data/jvc/apps
    end
    test -f "$store/installed.json"; or return 0
    # Keys one level inside "apps", at four spaces. Matching any `"key": {`
    # would return the "apps" header itself, and offer it as an app name.
    for line in (cat $store/installed.json)
        set -l k (string match -r '^    "([^"]+)"\s*:\s*\{' -- $line)
        test (count $k) -ge 2; and echo $k[2]
    end
end

# __jvc_registries prints the repository URLs worth offering: whatever the
# environment points at, the default, and the usual local one.
function __jvc_registries
    test -n "$JVC_REGISTRY"; and echo $JVC_REGISTRY
    echo https://registry.jennifer-lang.dev
    echo http://localhost:8080
end

# --- reading the command line ------------------------------------------------

# __jvc_positionals prints the words that are neither a flag nor a flag's
# value: the verb and its arguments.
function __jvc_positionals
    set -l toks (commandline -poc)
    test (count $toks) -gt 1; or return 0
    set -l skip 0
    for w in $toks[2..-1]
        if test $skip -eq 1
            set skip 0
            continue
        end
        switch $w
            case --registry --from --version --source --url --out \
                --scope --repository --tag --remote
                set skip 1
            case '-*'
                # a flag that takes no value
            case '*'
                echo $w
        end
    end
end

# __jvc_needs_verb is true before the verb has been typed.
function __jvc_needs_verb
    test (count (__jvc_positionals)) -eq 0
end

# __jvc_verb_is is true when the verb is one of its arguments.
function __jvc_verb_is
    set -l p (__jvc_positionals)
    test (count $p) -ge 1; or return 1
    contains -- $p[1] $argv
end

# __jvc_sub_is is true when the verb's own subcommand is one of its arguments.
function __jvc_sub_is
    set -l p (__jvc_positionals)
    test (count $p) -ge 2; or return 1
    contains -- $p[2] $argv
end

# __jvc_at_arg is true when the word being typed is the nth positional, counting
# the verb as the first. `jvc yank <TAB>` is at 2.
function __jvc_at_arg --argument-names n
    test (count (__jvc_positionals)) -eq (math $n - 1)
end

# --- the completions themselves ----------------------------------------------

# jvc takes no filenames of its own; the options that do say so with -F.
complete -c jvc -f

complete -c jvc -n __jvc_needs_verb -a init -d 'create deck.toml (and a deck skeleton for @scope/deck)'
complete -c jvc -n __jvc_needs_verb -a add -d 'add a requirement'
complete -c jvc -n __jvc_needs_verb -a remove -d 'remove a requirement'
complete -c jvc -n __jvc_needs_verb -a list -d 'show the manifest'
complete -c jvc -n __jvc_needs_verb -a check -d 'verify this interpreter can run the deck'
complete -c jvc -n __jvc_needs_verb -a conflict -d 'declare a conflict with a deck'
complete -c jvc -n __jvc_needs_verb -a engine -d 'require a Jennifer engine version'
complete -c jvc -n __jvc_needs_verb -a source -d 'resolve a deck from git'
complete -c jvc -n __jvc_needs_verb -a query -d 'resolve a deck against the repository'
complete -c jvc -n __jvc_needs_verb -a install -d 'install what camcorder.lock pins'
complete -c jvc -n __jvc_needs_verb -a update -d 'advance to the newest allowed versions'
complete -c jvc -n __jvc_needs_verb -a new -d 'scaffold an app frame over an engine deck'
complete -c jvc -n __jvc_needs_verb -a publish -d 'run the gate, then publish to the repository'
complete -c jvc -n __jvc_needs_verb -a pack -d 'build a release tarball instead of publishing'
complete -c jvc -n __jvc_needs_verb -a app -d 'install and manage runnable apps'
complete -c jvc -n __jvc_needs_verb -a registry -d 'map a scope to a repository'
complete -c jvc -n __jvc_needs_verb -a yank -d 'withdraw a version from new resolutions'
complete -c jvc -n __jvc_needs_verb -a unyank -d 'restore a withdrawn version'
complete -c jvc -n __jvc_needs_verb -a whoami -d 'show who your stored token says you are'
complete -c jvc -n __jvc_needs_verb -a scopes -d 'list the scopes a repository knows'
complete -c jvc -n __jvc_needs_verb -a claim -d 'claim a scope for your account'
complete -c jvc -n __jvc_needs_verb -a owners -d 'add or drop a co-owner'
complete -c jvc -n __jvc_needs_verb -a login -d 'log in to the repository (device flow)'
complete -c jvc -n __jvc_needs_verb -a logout -d 'discard the token held for it'
complete -c jvc -n __jvc_needs_verb -a version -d 'print the jvc version'
complete -c jvc -n __jvc_needs_verb -a help -d 'show the usage summary'

# --registry, only on the verbs that talk to a repository: the manifest verbs,
# pack, check and version never read it.
set -l __jvc_remote_verbs query search install sync update upgrade new publish \
    yank unyank whoami scopes claim owners login logout app
complete -c jvc -n "__jvc_verb_is $__jvc_remote_verbs" \
    -l registry -r -f -a '(__jvc_registries)' -d 'repository URL'
complete -c jvc -n __jvc_needs_verb -l help -d 'show the usage summary'
complete -c jvc -n __jvc_needs_verb -l version -d 'print the jvc version'

# Options per verb.
complete -c jvc -n '__jvc_verb_is add remove rm install sync update upgrade' \
    -l dev -d 'the dev-decks table, not decks'
complete -c jvc -n '__jvc_verb_is install sync update upgrade' \
    -l runtests -d "also run each deck's own tests on this machine"
complete -c jvc -n '__jvc_verb_is publish pack' -l no-verify -d 'skip the quality gate'
complete -c jvc -n '__jvc_verb_is publish' -l remote -x \
    -d 'the git remote to read the repository URL from (default origin)'
complete -c jvc -n '__jvc_verb_is publish' -l repository -x -d 'the repository URL to publish'
complete -c jvc -n '__jvc_verb_is publish' -l tag -x \
    -d 'the tag to publish (default: the tag on HEAD matching the version)'
complete -c jvc -n '__jvc_verb_is pack' -l out -x -a '(__fish_complete_directories)' \
    -d 'the directory for the tarball and publish.json (default dist)'
complete -c jvc -n '__jvc_verb_is pack' -l url -x -d 'the URL the tarball will be served from'
complete -c jvc -n '__jvc_verb_is pack' -l operator-command \
    -d 'also print the operator command that registers it'
complete -c jvc -n '__jvc_verb_is new' -l from -x -a '(__jvc_decks)' -d 'the engine deck to frame'
complete -c jvc -n '__jvc_verb_is new app' -l version -x -d 'the version constraint'
complete -c jvc -n '__jvc_verb_is new' -l source -x -d 'a git URL to take the engine deck from'
complete -c jvc -n '__jvc_verb_is app' -l scope -x -a 'project user system' \
    -d 'where to install it'
# The fourth form of --scope is a directory, so only directories are offered.
complete -c jvc -n '__jvc_verb_is app' -l scope -x -a '(__fish_complete_directories)' \
    -d 'install under this prefix'
complete -c jvc -n '__jvc_verb_is app' -l system -d 'install under /usr/local'
complete -c jvc -n '__jvc_verb_is owners' -l remove -d 'drop the co-owner instead of adding'

# Arguments per verb: what the manifest requires is all remove, conflict and
# source can act on.
complete -c jvc -n '__jvc_verb_is remove rm conflict source query search' \
    -a '(__jvc_decks)' -d required
complete -c jvc -n '__jvc_verb_is update upgrade' -a '(__jvc_locked)' -d locked
complete -c jvc -n '__jvc_verb_is registry; and __jvc_at_arg 2' -a '(__jvc_scopes)' -d scope
complete -c jvc -n '__jvc_verb_is registry; and __jvc_at_arg 3' \
    -a '(__jvc_registries)' -d 'repository URL'
complete -c jvc -n '__jvc_verb_is claim owners; and __jvc_at_arg 2' \
    -a '(__jvc_scopenames)' -d scope
complete -c jvc -n '__jvc_verb_is engine; and __jvc_at_arg 2' \
    -a 'jennifer jennifer-tiny' -d engine
complete -c jvc -n '__jvc_verb_is yank unyank; and __jvc_at_arg 2' \
    -a '(__jvc_self)' -d 'this deck'

# The app verb has subcommands of its own.
complete -c jvc -n '__jvc_verb_is app; and __jvc_at_arg 2' -a install -d 'fetch an app and put its command on PATH'
complete -c jvc -n '__jvc_verb_is app; and __jvc_at_arg 2' -a list -d 'show installed apps'
complete -c jvc -n '__jvc_verb_is app; and __jvc_at_arg 2' -a update -d 'advance installed apps'
complete -c jvc -n '__jvc_verb_is app; and __jvc_at_arg 2' -a uninstall -d 'remove an app and its command'
complete -c jvc -n '__jvc_verb_is app; and __jvc_sub_is update upgrade uninstall remove rm' \
    -a '(__jvc_apps)' -d installed
