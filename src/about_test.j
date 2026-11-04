# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for about.j: the version and the User-Agent jvc sends.
# Run with:
#
#     jennifer test src/about_test.j

use testing;
use strings;
import "semver.j" as semver;

func testTheVersionIsSemVer() {
    testing.assertTrue(semver.isValid(VERSION));
}

# product/version first, so a rule matching the start of the agent sees jvc.
func testTheAgentNamesJvcAndItsVersion() {
    testing.assertTrue(strings.startsWith(USER_AGENT, "jvc/" + VERSION + " "));
    testing.assertEqual(
        USER_AGENT,
        "jvc/" + VERSION + " (Jennifer Vendor Console; +https://jvc.jennifer-lang.dev)");
}

func testTheHeadersCarryOnlyTheAgent() {
    def h as map of string to string init headers();
    testing.assertEqual(len($h), 1);
    testing.assertEqual($h["User-Agent"], USER_AGENT);
}

# Each call is a fresh map, so one request's headers never leak into the next.
func testEachCallIsAFreshMap() {
    def first as map of string to string init headers();
    $first["Authorization"] = "Bearer x";
    testing.assertEqual(len(headers()), 1);
}
