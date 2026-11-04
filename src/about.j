# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * What jvc is, as it tells others: its version, and the `User-Agent` every
 * HTTP request it makes carries.
 *
 * Without one, a request goes out as the bundled client's `jennifer-http`, the
 * same as any other Jennifer program. A registry operator, a CDN rule or
 * GitHub's API then cannot tell jvc from a script, nor one jvc release from
 * another. The agent follows RFC 9110's `product/version (comment)` form:
 * `jvc/0.1.0 (Jennifer Vendor Console; +https://jvc.jennifer-lang.dev)`. The
 * product token leads, so a rule or log query matches the `jvc/` prefix; the
 * comment spells the name out and says where to read about the client.
 *
 * `VERSION` lives here rather than in `cli.j` because the registry and forge
 * modules send it, and they must not import the CLI. The release workflow reads
 * it from this file.
 * @module about
 * @example
 * import "./about.j" as about;
 * def headers as map of string to string init about.headers();
 */

/** jvc's own version, reported by `jvc version` and sent in `USER_AGENT`. */
export def const VERSION as string init "0.1.0";

/** jvc's name spelled out, the first part of the comment in `USER_AGENT`. */
export def const NAME as string init "Jennifer Vendor Console";

/** Where to read about the client, the last part of the comment in `USER_AGENT`. */
export def const HOMEPAGE as string init "https://jvc.jennifer-lang.dev";

/** The `User-Agent` value: `jvc/<version> (<name>; +<homepage>)`. */
export def const USER_AGENT as string init "jvc/" + VERSION + " (" + NAME + "; +" + HOMEPAGE + ")";

/**
 * A fresh header map holding only jvc's `User-Agent`, for a request to add
 * its own headers to.
 * @return {map of string to string} the headers every request starts from
 */
export func headers() {
    def out as map of string to string init {};
    $out["User-Agent"] = USER_AGENT;
    return $out;
}
