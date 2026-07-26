#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# jvc - the jennifer deck manager command-line tool. A thin entry point over
# the `cli` module (which holds all the logic and its tests). Run as:
#
#     jennifer run -I ../jennifer-lang/modules cli/jvc.j <command> [args]
#
# e.g. `jennifer run -I ../jennifer-lang/modules cli/jvc.j add ansi ^1.2.0`.

use os;
import "./cli.j" as cli;

def code as int init cli.main(os.ARGS);
exit $code;
