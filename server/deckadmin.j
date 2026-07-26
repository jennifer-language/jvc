#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# deckadmin - maintain the jvc deck repository's flatdb store: insert, update,
# remove, and list deck versions. A thin entry point over the `admin` module
# (which holds the logic and its tests). The store path defaults to decks.json,
# overridable with the JVC_DB environment variable. Run from the repo root
# (with JVC_DB=server/decks.json in the environment), e.g.:
#
#     jennifer run -I ../jennifer-lang/modules server/deckadmin.j add ansi 1.3.0 <url>
#     jennifer run -I ../jennifer-lang/modules server/deckadmin.j list

use os;
use io;
use time;
use convert;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./admin.j" as admin;

def dbPath as string init "decks.json";
if (not (os.getEnv("JVC_DB") == "")) {
    $dbPath = os.getEnv("JVC_DB");
}

def db as flatdb.DB init store.open($dbPath);
def now as string init convert.toString(time.unix(time.utc()));
def result as admin.AdminResult init admin.run($db, os.ARGS, $now);

if ($result.changed) {
    store.save($result.db);
}
io.printf("%s\n", $result.message);

if (not $result.ok) {
    exit 1;
}
