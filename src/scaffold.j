# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Stamping an app **frame** out of an engine deck: the pure half of `jvc new`.
 *
 * The language forces a split between a library and a runnable program. A deck
 * is a module, a module's top level is declarations-only, so a deck **cannot be
 * run**. Anything runnable needs a non-module entry point. A framework-shaped
 * deck is therefore consumed by a thin, per-project frame that owns a `main.j`,
 * imports the engine, and keeps its own data:
 *
 *     my-site/
 *       main.j                 the runnable entry (imports the engine deck)
 *       deck.toml              the frame's own manifest
 *       config.toml            structure only; secrets come from the environment
 *       content/               the user's data, never mixed with the engine
 *       vendor/you/cms/        the engine deck, jvc-managed, never hand-edited
 *       public/                build OUTPUT, the only web-facing directory
 *
 * **A deck ships its own template.** jvc is the stamper, not the author: the
 * files come from a `template/` directory inside the engine deck's release, so
 * the engine decides what a frame looks like. A deck with no `template/` still
 * scaffolds, from the minimal built-in frame here, so `jvc new` works against
 * any deck.
 *
 * **The security rule the templates bake in:** the project directory is never
 * the web root. Only `public/` is web-facing; `main.j`, `config.toml`, and
 * `vendor/` sit above it, unreachable over HTTP. Serving the project root would
 * expose the manifest, the engine source, and any secrets beside them.
 * @module scaffold
 * @example
 * import "./scaffold.j" as scaffold;
 * def vars as map of string to string init scaffold.vars("my-site", "@you/cms", "1.0.0");
 * def files as list of scaffold.File init scaffold.builtin($vars);
 */

use strings;
use convert;
use archive;
import "./safepath.j" as safepath;

/**
 * One file to write into a new frame.
 * @field path {string} the frame-relative path (e.g. "main.j", "content/index.md")
 * @field data {bytes} the file's contents, placeholders already substituted
 */
export def struct File {
    path as string,
    data as bytes
};

/**
 * Build the placeholder bindings a template is stamped with.
 *
 * The four placeholders are the whole contract; a template that wants anything
 * else should compute it in `main.j` rather than at stamp time.
 *
 * | placeholder     | value                                        |
 * | --------------- | -------------------------------------------- |
 * | `{{name}}`      | the frame's name, e.g. `my-site`              |
 * | `{{deck}}`      | the engine deck's canonical name, `@you/cms`  |
 * | `{{namespace}}` | the import namespace the deck binds, `cms`    |
 * | `{{version}}`   | the resolved engine version, e.g. `1.0.0`     |
 * @param name {string} the frame's name (its directory name)
 * @param deck {string} the engine deck's canonical name (`@scope/deck`)
 * @param version {string} the resolved engine deck version
 * @return {map of string to string} the placeholder bindings
 */
export func vars(name as string, deck as string, version as string) {
    def namespace as string init $deck;
    def slash as int init strings.indexOf($deck, "/");
    if ($slash >= 0) {
        $namespace = strings.substring($deck, $slash + 1, len($deck));
    }
    return {"name": $name, "deck": $deck, "namespace": $namespace, "version": $version};
}

/**
 * Replace every `{{key}}` placeholder in a text with its binding. An unbound
 * placeholder is left alone rather than blanked, so a typo shows up in the
 * stamped file instead of silently deleting content.
 * @param text {string} the template text
 * @param bindings {map of string to string} the placeholder bindings
 * @return {string} the substituted text
 */
export func substitute(text as string, bindings as map of string to string) {
    def out as string init $text;
    for (def key in $bindings) {
        # Single-quoted: "{{" would open an interpolation slot on jennifer >= 0.24.
        $out = strings.replace($out, '{{' + $key + '}}', $bindings[$key]);
    }
    return $out;
}

/**
 * Return an archive entry's path relative to the deck's `template/` directory,
 * or "" when the entry is not under it. `root` is the archive's layout root
 * (`safepath.archiveRoot` over every member name), so `template/` matches only
 * there: `template/main.j` and `./template/main.j` in a bare archive, and
 * `cms-1.0/template/main.j` in one wrapped in `cms-1.0/`, all yield `main.j`.
 * A `template/` any deeper (`src/template/`, a vendored dependency's) is not
 * the deck's template, and neither is one under a top-level directory when the
 * archive has more than one.
 *
 * The result is joined onto the new frame's directory, so anything that is not
 * a safe relative path (`safepath.isSafeRelative`) also yields "": an archive
 * hands back the raw member name, and `template/../../x` must not become
 * `../../x`. A directory entry (trailing `/`) yields "" for the same reason.
 * @param entryName {string} the archive member name
 * @param root {string} the archive's layout root, "" or `<w>/`
 * @return {string} the path under template/, or "" when not under it or unsafe
 */
export func templateSubpath(entryName as string, root as string) {
    def n as string init safepath.underRoot($entryName, $root);
    if (not strings.startsWith($n, "template/")) {
        return "";
    }
    def sub as string init strings.substring($n, 9, len($n));
    if (not safepath.isSafeRelative($sub)) {
        return "";
    }
    return $sub;
}

# stampBytes substitutes into a file's contents when they are text, and copies
# them verbatim when they are not (a template may ship a binary asset such as an
# icon, which must survive byte for byte).
func stampBytes(data as bytes, bindings as map of string to string) {
    try {
        def text as string init convert.stringFromBytes($data, "utf-8");
        return convert.bytesFromString(substitute($text, $bindings), "utf-8");
    } catch (err) {
        return $data;
    }
}

/**
 * Extract a deck archive's `template/` tree as the files to stamp, with every
 * placeholder substituted in **both** each file's path and its text contents.
 * An archive with no `template/` directory yields an empty list, which is the
 * caller's signal to fall back to `builtin`. Every returned path is a safe
 * relative path: an entry whose raw name, or whose name once its placeholders
 * are substituted, would leave the frame directory is skipped.
 * @param data {bytes} the deck archive bytes
 * @param format {string} the archive format, "tar.gz" or "tar"
 * @param bindings {map of string to string} the placeholder bindings
 * @return {list of File} the frame files (empty when the deck ships no template)
 * @throws {Error} when the archive cannot be unpacked
 */
export func fromArchive(data as bytes, format as string, bindings as map of string to string) {
    def out as list of File init [];
    def entries as list of archive.Entry init safepath.unpack($data, $format);
    def names as list of string init [];
    for (def e in $entries) {
        $names[] = $e.name;
    }
    def root as string init safepath.archiveRoot($names);
    for (def e in $entries) {
        def sub as string init templateSubpath($e.name, $root);
        if ($sub == "") {
            continue;
        }
        # A placeholder value may carry a `/` or spell `..`, so the rendered
        # name is checked again: it is what the caller joins onto the frame.
        def rendered as string init substitute($sub, $bindings);
        if (not safepath.isSafeRelative($rendered)) {
            continue;
        }
        $out[] = File{path: $rendered, data: stampBytes($e.data, $bindings)};
    }
    return $out;
}

# text builds a File from a template's lines, substituting placeholders. The
# templates below are lists of raw single-quoted lines rather than one
# double-quoted string, because a `{{` in a double-quoted string lexes as an
# interpolation slot on jennifer >= 0.24; raw lines also keep the templates
# readable, with no escaping at all.
func text(path as string, lines as list of string, bindings as map of string to string) {
    def body as string init strings.join($lines, "\n") + "\n";
    return File{path: $path, data: convert.bytesFromString(substitute($body, $bindings), "utf-8")};
}

# --- the built-in frame -----------------------------------------------------
#
# Used when the engine deck ships no template/ of its own. Deliberately minimal:
# enough to run, and correct about the web-root rule.

# MAIN_TEMPLATE is the runnable entry point: the one file that makes a frame an
# app rather than a library. It carries the SPDX header the project convention
# asks of a generated .j file.
def const MAIN_TEMPLATE as list of string init [
    '#!/usr/bin/env -S jennifer run',
    '# SPDX-License-Identifier: LGPL-3.0-only',
    '# Copyright (C) 2026 {{name}} contributors',
    '#',
    '# {{name}} - an app frame over the {{deck}} engine deck.',
    '#',
    '# This file is yours: the engine lives in vendor/ and is replaced wholesale',
    '# by jvc, so keep your own code here and your data in content/.',
    '',
    'use io;',
    'import "{{deck}}/";',
    '',
    'io.printf("{{name}} is running on {{deck}} {{version}}\n");'
];

# CONFIG_TEMPLATE is structure only. Secrets belong in the environment, never in
# a file that could be committed or served.
def const CONFIG_TEMPLATE as list of string init [
    '# {{name}} configuration - structure only.',
    '#',
    '# Never put secrets here: read them from the environment with os.getEnv, so',
    '# nothing sensitive can be committed or accidentally served.',
    '',
    '[site]',
    'name = "{{name}}"',
    '',
    '[build]',
    '# The ONLY web-facing directory. Never serve the project root: it holds',
    '# main.j, config.toml, and vendor/, none of which belong on the web.',
    'output = "public"'
];

# GITIGNORE_TEMPLATE keeps the jvc-managed and generated trees out of the repo:
# `git clone` + `jvc install` reproduces vendor/ from camcorder.lock.
def const GITIGNORE_TEMPLATE as list of string init [
    '# jvc-managed: reproduced from camcorder.lock by `jvc install`.',
    '/vendor/',
    '',
    '# Build output.',
    '/public/',
    '',
    '# Secrets never belong in the repository.',
    '.env'
];

# README_TEMPLATE tells the frame's owner which directories are theirs.
def const README_TEMPLATE as list of string init [
    '# {{name}}',
    '',
    'An app frame over the {{deck}} engine deck ({{version}}).',
    '',
    '```sh',
    'jvc install      # reproduce vendor/ from camcorder.lock',
    'jennifer run main.j',
    '```',
    '',
    '## Layout',
    '',
    '| Path           | Whose it is                                       |',
    '| -------------- | ------------------------------------------------- |',
    '| `main.j`       | yours - the runnable entry point                  |',
    '| `config.toml`  | yours - structure only, secrets come from the env |',
    '| `content/`     | yours - data, never mixed with the engine         |',
    '| `vendor/`      | jvc-managed - the engine deck, never hand-edited  |',
    '| `public/`      | generated - the **only** web-facing directory     |',
    '',
    '**Never serve the project root.** Only `public/` may be web-facing;',
    '`main.j`, `config.toml`, and `vendor/` sit above it and must stay',
    'unreachable over HTTP.'
];

# CONTENT_TEMPLATE seeds the data directory so it exists in a fresh checkout.
def const CONTENT_TEMPLATE as list of string init [
    '# {{name}}',
    '',
    'Your content lives here. The engine deck never writes to this directory.'
];

# PUBLIC_TEMPLATE seeds the build output directory with a note, so the one
# web-facing directory exists and explains itself.
def const PUBLIC_TEMPLATE as list of string init [
    'This directory is the build output and the only web-facing zone of',
    '{{name}}. Everything generated here may be served; nothing above it may.'
];

/**
 * The minimal built-in frame, used when the engine deck ships no `template/`.
 * Produces a runnable `main.j`, a secret-free `config.toml`, a `.gitignore` that
 * keeps `vendor/` and `public/` out of the repository, a README explaining who
 * owns what, and the `content/` and `public/` directories seeded so both exist
 * in the new frame (`public/` is ignored by git, so only `content/` survives a
 * clone).
 * @param bindings {map of string to string} the placeholder bindings (see `vars`)
 * @return {list of File} the frame files
 */
export func builtin(bindings as map of string to string) {
    return [
        text("main.j", MAIN_TEMPLATE, $bindings),
        text("config.toml", CONFIG_TEMPLATE, $bindings),
        text(".gitignore", GITIGNORE_TEMPLATE, $bindings),
        text("README.md", README_TEMPLATE, $bindings),
        text("content/index.md", CONTENT_TEMPLATE, $bindings),
        text("public/.keep", PUBLIC_TEMPLATE, $bindings)
    ];
}
