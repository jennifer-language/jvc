# JENNIFER.md - the Jennifer language, for coding assistants

Drop this file into a project where you write **Jennifer** (`.j` files) and
point your AI coding assistant at it ("we code in Jennifer, see JENNIFER.md").
It is a self-contained reference to the language so an assistant with no prior
knowledge of Jennifer can write correct code. It describes the *language*, not
the interpreter's internals.

Jennifer is a batteries-included, interpreted language (tree-walking interpreter
written in Go/TinyGo). Source files use the `.j` extension. Run a program with
`jennifer run program.j`, start a REPL with `jennifer repl`.

**Full documentation** - guides, the complete library reference, and an
alphabetical cheatsheet of every builtin - is hosted at
<https://jennifer-lang.dev/>. If an assistant has web access, fetch
the exact signature of any function there. Source and issues:
<https://github.com/jennifer-language/jennifer>.

> This file mirrors the authoritative spec. If something here conflicts with the
> [hosted docs](https://jennifer-lang.dev/), the docs win - tell the
> maintainer.

> **Keep this file in sync with the installed interpreter - it is your job.**
> This is a copy dropped into a project, so it silently goes stale as the local
> `jennifer` is upgraded (or was already older than this copy). A JENNIFER.md
> that does not match the installed release is the most common reason an
> assistant writes `.j` code the interpreter then rejects. So **you, the
> assistant, are responsible for keeping this file aligned with the installed
> release** - do this before you rely on it (and again whenever code you wrote
> fails with an "unknown"/"not defined"/pragma-version error).
>
> **Cheap self-check first.** Once you have synced this file you leave a marker on
> its last line recording the exact `jennifer version` string it was fetched for
> (`<!-- jennifer-md-synced-for: ... -->`). Run `jennifer version` and compare it
> to that marker: **equal -> this copy is current, do nothing**; **different, or
> no marker yet (a pristine copy just dropped into the project) -> run the sync
> below**. That is one command and a string compare, so it is cheap enough to do
> at the start of any `.j` work; you only fetch over the network when the marker
> actually disagrees.
>
> **Sync:**
>
> 1. Read the installed version: `jennifer version` (e.g. `0.24.0`, or
>    `0.24.0-dev+N.<sha>`).
> 2. Fetch the JENNIFER.md that matches it from the source repo:
>    - a **development build** - any version containing `-dev` (e.g.
>      `0.24.0-dev+N.<sha>`) or the bare string `dev` - is ahead of the last
>      release, so **always** fetch the `main` branch, regardless of the `X.Y.Z`
>      it prints:
>      `https://raw.githubusercontent.com/jennifer-language/jennifer/main/JENNIFER.md`;
>    - a **clean release** `X.Y.Z` (no `-dev` suffix) fetches its own tag:
>      `https://raw.githubusercontent.com/jennifer-language/jennifer/X.Y.Z/JENNIFER.md`.
> 3. If the fetched file differs from this local copy, **replace this local copy
>    with it**.
> 4. **Stamp the marker.** Whether or not step 3 replaced anything, set the last
>    line of the local copy to the full `jennifer version` string you read in
>    step 1, so the next self-check is a cheap compare:
>    `<!-- jennifer-md-synced-for: 0.24.0-dev+N.<sha> -->`. Record the whole
>    string verbatim - for a dev build it carries the commit (`+N.<sha>`), so the
>    marker changes the moment the installed interpreter is rebuilt and your check
>    catches it. (A dev build always re-fetches `main` per step 2, since `main`
>    advances even when the local commit has not; the marker still tells you the
>    interpreter itself moved.)
>
> Match the **installed interpreter**, not the newest release: if the local
> `jennifer` is `0.24.0` while `0.25.0` is out, fetch the `0.24.0` JENNIFER.md -
> this file must describe the features the interpreter you actually run has, no
> more and no less. (No web access? Then note in your reply that you could not
> verify JENNIFER.md against the installed `jennifer version`, so some guidance
> here may not match it.)

---

## The 10 rules that trip people up

Read these first; they are where Jennifer differs from Python/JS/Go and where
an assistant usually guesses wrong:

1. **Variables are referenced with a `$` sigil: `$x`.** But the *declaration*
   uses a bare name: `def x as int init 5;` then use `$x`. Writing `def $x` is
   an error; using bare `x` in an expression is an error.
2. **Constants are referenced bare (no `$`): `MAX`.** They are `UPPER_CASE`.
   Reading one *with* `$` (`$MAX`) is a parse error - the sigil is for
   mutable variables only. A method may not share a name with a top-level
   variable or constant either (`def foo ...; func foo() {}` is rejected).
3. **Method calls are bare and take `()`: `greet()`.** The parser tells a call
   from a constant by the `(`.
4. **`/` is true division and always returns `float`** (like Python 3).
   `5 / 2 == 2.5`. Use `//` for integer/floor division: `5 // 2 == 2`. `%`
   is **floored** to match `//` (`-7 % 3 == 2`, `7 % -3 == -2`). Integer
   arithmetic that overflows `int64` is a runtime error (no silent wrap,
   including `-(MinInt64)`), and **float arithmetic that overflows to a
   non-finite value is an error too** (`1e308 * 10.0` raises, never
   `+Inf`/`NaN`); a mixed `int`/`float` comparison is exact (no lossy
   promotion).
5. **Identifiers are letter-initial, then letters + digits, <= 64 chars.** No
   underscores in variable/method/parameter/library names. `myVar`, `var2`,
   `sha256` are fine; `my_var` is not, and a name cannot start with a digit.
   (Constants are the *only* names that take `_`: `MAX_RETRIES`.)
6. **Statements end with `;`.** Whitespace (including newlines) is
   insignificant everywhere.
7. **Comments are `#` (line) and `/* */` (block, nests).** Not `//` - that is
   the floor-division operator.
8. **No `++`, `--`, `+=`, or any compound assignment.** Only `$x = EXPR;`.
9. **Value semantics: assignment and argument passing copy.** `$b = $a;` then
   mutating `$b` never touches `$a`. Same for lists, maps, structs, bytes.
10. **Logical operators are words: `and`, `or`, `not`** (not `&&`/`||`/`!`).
    `&` `|` `^` `~` are the *bitwise* operators.

---

## Lexical basics

- **Identifiers** (variables, methods, parameters, library names):
  `[A-Za-z][A-Za-z0-9]*`, <= 64 chars. Letter-initial (a digit-initial token is a
  number), then letters and digits; no underscores. Legal: `myVar`, `sha256`,
  `x2`, `toUtf8`.
- **Constant names**: uppercase chunks joined by single `_`, with in-chunk
  digits: `[A-Z][A-Z0-9]*(_[A-Z][A-Z0-9]*)*` (each chunk starts with a letter).
  Legal: `MAX`, `MAX_RETRIES`, `HTTP_OK`, `SHA256`, `HTTP2`, `SCRAM_SHA256`.
  Illegal: `_MAX`, `MAX_`, `MAX__INT`, `maxInt`, `AES_256` (write `AES256`).
- **`.j` import paths** are strings and may contain digits, `_`, `/`.
- A leading `#!` line is allowed (shebang): `#!/usr/bin/env -S jennifer run`. A
  file with a shebang may also be run **without a `.j` extension** (as an
  executable installed under a bare command name); `import` / `include` targets
  still require `.j`.

## Types

Primitive: `null`, `int`, `float`, `string`, `bool`, `bytes`.
Compound: `list of T`, `map of K to V`, user `struct`s, user `enum`s (sum
types), `task of T` (a handle to a `spawn`ed computation), `func` (a first-class
function value), `channel of T` (a CSP channel between goroutines).

- **int** literals: `42`, `0xff`, `0o755`, `0b1010`, with `_` digit separators
  (`1_000_000`, `0xDEAD_BEEF`).
- **float** literals: a `.` (`3.14`, `0.5`) or an `[eE][+-]?` exponent
  (`6.022e23`, `1.6e-19`, `1e10` - the exponent alone makes it a float); `_`
  separators in the mantissa only. Overflow (`1e400`) is an error, not `Infinity`;
  underflow (`1e-400`) rounds to `0.0` (a finite value; only the non-finite is banned).
- **string** literals: two delimiters, one job each. `"..."` is **cooked** -
  escape sequences `\n \r \t \\ \" \' \0 \{ \}`, plus Unicode `\uXXXX` (exactly 4
  hex, the BMP) and `\UXXXXXXXX` (exactly 8 hex, any plane, e.g. `\U0001F600`), are
  processed; a surrogate, an out-of-range code point, or the wrong digit count is
  a lex error. A cooked string also **interpolates**: an unescaped `{expr}` is a
  slot (see below). `'...'` is **raw** - no
  escape processing at all and no interpolation: every byte to the next `'` is
  literal (backslashes, braces, and newlines included), so `'\d+\.\d+'` is an
  8-char string, `'{"port": 8080}'` is literal JSON, and a multi-line block is
  just a `'...'` that spans newlines. To put a `'` inside a string, use the cooked
  form: `"it's"`. There is no `r"..."` prefix.
- **string interpolation**: inside a cooked `"..."` string, each unescaped
  `{expr}` is a slot - one Jennifer **expression** evaluated in the current scope
  and stringified in place (the `convert.toString` form; no `use convert` needed).
  `"total: {$sum}, next {$n + 1}, up {strings.upper($s)}"`. A slot holds a single
  expression (a variable, constant, field / index access, arithmetic, a call), not
  a statement - a `;`, `def`, `if`, or assignment in a slot is a parse error, and
  an empty `{}` is an error. Write a literal brace as `\{` / `\}`; a bare unescaped
  `}` is a lex error. A **raw** `'...'` string never interpolates (it is the "no
  interpolation" form). No `f"..."` prefix - the cooked / raw split is the opt-in.
  Style: keep slots to variables, field / index access, and arithmetic; a
  side-effecting or expensive **call** in a slot is flagged by `lint` (L204) -
  compute it into a variable first. `undefined` variables in a slot are caught at
  parse time, exactly like any other reference.
- **bool**: `true`, `false`. **null**: `null`.
- **bytes** has no literal: build with `convert.bytesFromString(s, "utf-8")`
  or append into `def b as bytes;` with `$b[] = 65;`.
- **list** literals: `[1, 2, 3]`, `[]`. Lists are homogeneous (one element
  type).
- **map** literals: `{"a": 1, "b": 2}`, `{}`. Insertion-ordered.
- **struct** literals: `Point{x: 1, y: 2}` after
  `def struct Point { x as int, y as int };`. Every field must be named.
- **enum** (sum type): `def enum Shape { Circle { r as float }, Empty };` at top
  level. A value is one variant: construct with `Shape.Circle{r: 2.0}` or the
  payload-less `Shape.Empty` (cross-module: `alias.Shape.Circle{...}`). Value
  semantics + equality like structs. `def s as Shape;` (no init) zeroes to the
  **first** variant, payload zeroed. Read the payload only through `match` (no
  `$enum.field`). Names may be any case (an all-`UPPERCASE` name is a constant,
  so don't name a type all-caps).
- **func** (first-class function value): a bare method name in expression
  position **is** the value; a name followed by `(` is a call.
  `def f as func init greet;` binds the method `greet` into a value; call it
  through a variable or any function-valued expression: `$f(args)`,
  `$fns[0](x)`, `makeAdder(1)(2)`. Pass and return them like any value
  (`func apply(fn as func, x as int) { return $fn($x); }`). Arity + argument
  types are checked at the call site (the `func` type has no signature).
  Immutable (copies share the method; value semantics hold). Zero value
  (`def f as func;`) is a **null** function - calling it errors. No `&NAME`
  sigil and no anonymous-function / closure literal (yet). Powers the
  higher-order `lists` layer (`map` / `filter` / `reduce` / `find` / `any` /
  `all` / `sortBy`).

  ```jennifer
  use lists;
  func dbl(n as int) { return $n * 2; }
  func isEven(n as int) { return $n % 2 == 0; }
  def xs as list of int init [1, 2, 3, 4];
  def doubled as list of int init lists.map($xs, dbl);      # [2, 4, 6, 8]
  def evens as list of int init lists.filter($xs, isEven);  # [2, 4]
  ```

## Variables and constants

```jennifer
def x as int;                 # declare, zero value (0)
def y as int init 5;          # declare + initialize
def const MAX as int init 10; # constant, must be initialized, never reassigned
$x = 7;                       # assignment uses the $ sigil
```

- The name at the `def` site is bare (`def x`), never `def $x`.
- `const` is deep: a const list/map/struct rejects mutation at any depth.

## Operators

- Arithmetic: `+  -  *  /  //  %`. `/` is float division; `//` is floor.
- Unary `-` (negation). `+` also concatenates two strings.
- Comparison: `<  >  <=  >=  ==  !=` -> `bool`. `!=` is `not (a == b)`. The
  ordering operators (`<  >  <=  >=`) work on two numbers or two strings
  (strings compare lexicographically by UTF-8 bytes); a string/number mix is a
  type error. There is no bare `!` (logical negation is the word `not`); a lone
  `!` is a lex error.
- Logical (words, short-circuit): `and`, `or`, `not`. Operands must be `bool`.
- Bitwise (int only): `&  |  ^  ~  <<  >>`.
- Mixed int/float arithmetic promotes to `float`.
- Range `..`: `lo..hi` is a half-open range `[lo, hi)`, int bounds only,
  non-associative, looser than every other operator. Builds a `list of int`
  (`def r as list of int init 0..n;`), or iterates lazily as a for-each source
  (`for (def i in 0..n)`), or slices (`$xs[a..b]`). `lo > hi` errors; `lo == hi`
  is empty. Always a fresh copy, never a view.
- Precedence, low to high: `..` < `or` < `and` < `not` < comparison < `|` < `^`
  < `&` < shifts < `+ -` < `* / // %` < unary `- ~`. So `$x & 0xff == 0` parses
  as `($x & 0xff) == 0`, and `1+1..2*3` as `(1+1)..(2*3)`.

## Control flow

```jennifer
if ($n > 0) { ... } elseif ($n < 0) { ... } else { ... }

while ($i < 10) { ... }

for (def i as int init 0; $i < 10; $i = $i + 1) { ... }   # C-style

for (def x in $xs) { ... }     # for-each over a list (elements)
for (def k in $m) { ... }      # for-each over a map (keys, insertion order)
for (def i in 0..10) { ... }   # for-each over a half-open range (lazy)

repeat { ... } until ($done);  # post-test loop; body runs at least once

match ($cmd) {                 # multi-way value dispatch (subject evaluated once)
    when "start" {
        start();
    }
    when "stop", "halt" {      # several values per arm (an OR of equality)
        stop();
    }
    else {                     # optional default, must be last
        unknown();
    }
}

# Over an enum subject, `match` dispatches on the variant and binds its payload.
# It must be exhaustive (cover every variant) or carry an `else`.
match ($shape) {
    when Circle(c) { area($c.r); }   # $c is the variant's payload (a mini-struct)
    when Rect(rc)  { area2($rc.w, $rc.h); }
    when Empty     { }               # payload-less variant: no binder
}

break;      # exit innermost loop
continue;   # next iteration
exit;       # terminate the whole program (exit 0); exit EXPR sets the code (Unix: 0..255, masked to 8 bits)
```

Conditions must be `bool` (there is no truthiness). `and` / `or` **short-circuit**
(`true or f()` never calls `f`). `break`/`continue` do not cross a method-call or
`spawn` boundary.

`match` compares the subject to each `when` value by strict `==`; the first
matching arm runs and its values evaluate left-to-right only until a match. There
is **no fall-through**, and `match` is **not** a `break` target - `break` /
`continue` in an arm act on the enclosing loop. A bare `when Name { }` reads
`Name` as a value and `{` as the block, so a struct-literal value needs parens:
`when (Point{x: 1}) { ... }`. No matching arm and no `else` is a no-op.

### Errors

```jennifer
use io;
try {
    throw Error{kind: "bad", message: "nope", file: "", line: 0, col: 0};
} catch (e) {
    io.printf("%s\n", $e.message);
}
```

`throw EXPR;` raises any value; convention is the auto-provided `Error` struct
`{kind, message, file, line, col}`. `catch` also catches the runtime errors
builtins raise (out-of-range, missing key, etc.), wrapped into `Error`.
`exit`/`return`/`break`/`continue` are control flow, not catchable.

### Cleanup with `defer`

```jennifer
use fs;
func write(path as string) {
    def f as fs.File init fs.open($path, "write");
    defer fs.close($f);         # runs when the block exits, however it exits
    fs.writeString($f, "data\n");
}
```

`defer CALL(args);` schedules a **call** (method / namespaced / module call - a
non-call is a parse error) to run when the **enclosing block** exits, on every
path (`return`/`break`/`continue`/`throw`/`exit`/fall-through), **LIFO**.
Arguments are evaluated at the `defer` line; the call runs at block exit.
Block-scoped (a `defer` in a loop body runs each iteration); does not cross a
method or `spawn` boundary. A deferred throw propagates and supersedes a pending
error (never an `exit`). There is no `finally`.

`errdefer CALL(args);` is the error-path variant: same form, same LIFO stack,
but the call runs **only when the block exits with a propagating error** (a
`throw` or a runtime error) - skipped on fall-through, `return`, `break`,
`continue`, and `exit`. It is the undo half of an acquire whose resource must
survive on success:

```jennifer
func connect(addr as string) {
    def c as net.Conn init net.connect($addr);
    errdefer net.close($c);     # a failed handshake closes; success keeps it open
    handshake($c);
    return Session{conn: $c};
}
```

## Methods

```jennifer
use io;

func greet(name as string) {
    io.printf("hi %s\n", $name);   # parameters referenced as $name
    return;                        # bare return -> null; or return EXPR;
}

greet("ada");
```

- Bare parameter names (`name as string`), referenced inside as `$name`.
- No return type is declared; the caller's `def x as T init f();` checks it.
- Methods are **top-level only** (not nested). Recursion works.
- Method bodies see global variables/constants. A method may not shadow a
  global name, nor share a name with a builtin from an imported library.
- A program has **no required entry point**: top-level statements run in order.

## Compound types: indexing and iteration

```jennifer
def xs as list of int init [1, 2, 3];
$xs[0];            # read -> 1
$xs[0] = 9;        # write
$xs[] = 4;         # append (write-only; lists and bytes only)

def m as map of string to int init {"a": 1};
$m["a"];           # read (missing key is an error - test with maps.has)
$m["b"] = 2;       # write

def p as Point init Point{x: 1, y: 2};
$p.x;              # field read
$p.x = 5;          # field write

$grid[i][j] = v;   # chains nest and mix [index] and .field

def mid as list of int init $xs[1..3];   # slice: half-open [1, 3) copy
$xs[2..];  $xs[..3];  $xs[..];           # open ends default to 0 / len
```

**Slicing (`$xs[a..b]`)** returns a fresh, value-semantic copy of a half-open
`[a, b)` sub-range of a `list`, `bytes`, or `string` (rune-indexed). Open ends
default to the extremes (`$xs[a..]`, `$xs[..b]`, `$xs[..]`). Bounds are strict
(`0 <= a <= b <= len`). A slice is **read-only**: `$xs[a..b] = ...` is a parse
error (it is a copy, so a write through it would do nothing).

**Prefer `$xs[]` over `lists.push` in loops.** The `$xs[] = item;` append sugar
(lists and bytes) mutates in place via copy-on-write - amortized O(N) to append
N items. `$xs = lists.push($xs, item)` returns a *new* list each pass and copies
the whole list, so the same loop is O(N^2). Use `$xs[]` to build a list element
by element (a raster, a buffer, a big result set); use `lists.push` only when you
want a fresh list and keep the original.

`len(EXPR)` is a language built-in (not a library): rune count of a string,
element count of a list, entry count of a map, byte count of bytes.

## Concurrency

```jennifer
use task;
def t as task of int init spawn { return expensiveThing(); };
def result as int init task.wait($t);   # also poll / discard / waitAll / waitAny
```

`spawn { ... }` runs concurrently and evaluates to a `task of T`. It deep-copies
its enclosing scope at launch, so there are no shared-memory data races.

**Cancellation + timeouts.** `task.cancel($t)` requests cooperative cancellation:
the body observes it at its next loop checkpoint, where the runtime raises a
catchable "task cancelled" (so a runaway `spawn` can be stopped - this retires the
exit-time hang). Catch it inside the body for a clean partial result; `task.cancel
+ task.discard` is stop-and-forget. `task.cancelled()` is a non-raising poll.
`task.waitTimeout($t, ms)` / `task.waitAnyTimeout($ts, ms)` are bounded waits that
throw a catchable "timed out" error.

**Channels.** `channel of T` streams values between goroutines (the counterpart to
`task`'s single result). `channel.make(capacity)` (0 = unbuffered), `send`
(deep-copies the value in - the receiver gets its own copy), `recv` (blocks; throws
a catchable error on a closed+drained channel - drain with `try { while (true) {
process(channel.recv($ch)); } } catch (e) { }`), `close`, `select([...])` (fan-in:
next value from any open channel), `len` / `capacity`. A channel is a shared
handle but the values through it are copied, so no-shared-mutable-state holds.
`channel` is a contextual keyword (a type only in `channel of T`; a valid
identifier elsewhere).

## Imports

```jennifer
use io;                 # enable a system library, addressed io.printf(...)
use strings as s;       # alias: only s.upper(...) works after this
include "helpers.j";    # textual splice of another .j file (preprocessor)
import "./util.j" as u; # load util.j as a module, addressed u.fn(...) / u.CONST
```

- `use NAME [as ALIAS];` - system library. Nothing auto-loads; every program
  states its imports. Aliasing is a rename (the canonical prefix stops working).
- `include "path.j";` - textual file splice (path is a string literal ending in
  `.j`, resolved relative to the including file).
- `import "PATH.j" [as NAME];` - **module** import (a real boundary, not a
  splice). Path forms: `./x.j` / `../x.j` local, `/x.j` absolute, bare `x.j`
  from the module search path. Loads once (run-once, cached), depth-first
  post-order; cycles error. Reach the module's surface as `NAME.fn(args)`,
  `NAME.CONST`, and `NAME.Struct` / `NAME.Struct{...}` (`NAME` is the `as`
  alias, else the file stem). A **module top level is declarations-only**:
  `def const`, `def struct`, `func`, `use`, `import` - no mutable `def`, no
  free-standing statements. `use` is not transitive across the boundary.
- `export` publishes a top-level `def const` / `def struct` / `func` from a
  module; unmarked names are private (reaching one from outside errors). A
  module struct type keeps its identity `(module, name)` at the consumer, so
  `def p as NAME.Struct init NAME.make();` type-checks and `a.Point` /
  `b.Point` are distinct. An exported struct/func may not expose a private
  struct. `export` is only valid in a module (a parse error in a `run`
  script). A co-located `MODULE_test.j` white-box overlay runs under
  `jennifer test`.
- **Requirement header** - a file may declare what it needs with typed comment
  pragmas in its header block, checked at read time (a program, a module, and each
  `include`d file self-checks): `# pragma-jennifer-version: >=0.25.0` (a minimum
  interpreter floor; any `-dev` build bypasses, only a release tag is compared - one
  floor per file) and `# pragma-jennifer-capability: net` (a host facility the build
  must have: `net` or `exec`, neither on `jennifer-tiny`; multiple accumulate). A
  mismatch aborts with a clear message; a malformed directive is a hard error.
  Query capabilities at runtime with `meta.hasCapability("net")` / `meta.CAPABILITIES`.

## Standard library (all namespaced, all opt-in via `use`)

Call as `LIB.name(...)`. Enable with `use LIB;` first. Highlights:

- **`io`** - `printf` / `sprintf` with verbs `%d %f %s %t %v %a` and
  `%verb[|key=value]` modifiers (`pad`, `align`, `base`, `prec`, `sign`,
  `group`, `case`, ...); `readLine`, `eof`, `readBytes`.
- **`convert`** - `toInt toFloat toString toBool`, `typeOf`, `objectType`,
  `bytesFromString` / `stringFromBytes` (utf-8). Note: the callees are
  `toInt` etc. because `int`/`float`/`string`/`bool`/`bytes` are reserved type
  keywords (they appear only after `as`).
- **`math`** - arithmetic `abs min max sqrt pow floor ceil round trunc sign
  cbrt hypot`; trig `sin cos tan asin acos atan atan2` + hyperbolic `sinh cosh
  tanh asinh acosh atanh`; exp/log `exp expm1 ln log10 log2 log1p log`(x, base);
  combinatorics `factorial comb perm gcd lcm`; random `rand randInt randSeed`;
  special functions `erf erfc gamma lgamma beta lbeta regGammaP regGammaQ
  regBetaI` (the distribution-CDF engine); constants `PI`, `E`, `TAU`. Angles in
  radians; floor/ceil/round/trunc return int; undefined results error (no NaN).
- **`stats`** - 26 descriptive statistics over `list of int`/`float`: `mean median
  mode modes geometricMean harmonicMean weightedMean variance stddev sampleVariance
  sampleStddev range iqr mad skewness kurtosis percentile quartiles min max sum
  zscore correlation covariance sampleCovariance describe`. Real-valued reductions
  return `float`; `min`/`max`/`mode`/`modes`/`range`/`sum` keep the input kind;
  `quartiles`/`zscore` return `list of float`; `describe` returns a `stats.Summary`
  struct. Population (`variance`/`stddev`/`covariance`/moments) vs sample (`sample*`,
  `n-1`); `kurtosis` is excess. Undefined results (empty list, bad percentile,
  zero-variance, non-positive geometric/harmonic input) are catchable errors.
  Also **distributions** (flat R-style names, `float`): normal
  `normalPdf/normalCdf/normalQuantile/normalSample`, `tPdf/tCdf/tQuantile`,
  `chiSquareCdf/chiSquareQuantile`, `fCdf/fQuantile`, `binomialPmf/binomialCdf`,
  `poissonPmf/poissonCdf` (quantile `p` in `(0,1)`); and **inference**:
  `linearRegression`/`multipleRegression`, `confidenceInterval`, `proportionCi`
  (wald/wilson/clopper-pearson), `tTest`/`tTest2`, `chiSquareTest`, `fTest`,
  `anova`, `histogram`. Results are `stats.Regression`/`Interval`/`Test` structs.
  No separate `prob` library - distributions live in `stats` (like `scipy.stats`).
- **`ml`** - classical / predictive machine learning on tabular data
  (scikit-learn-lite), over `stats`/`linalg`. **Fit/predict shape**: a fit
  function returns an opaque `ml.Model` handle, applied with `ml.predict`
  (labels for a classifier/cluster, values for a regressor) / `ml.transform`
  (scalers, PCA) / `ml.predictProba` (binary logistic). Models: regression
  `linearRegression` `ridge` `lasso` `kNNRegressor` `decisionTreeRegressor`
  `randomForestRegressor`; classifiers `kNN` `naiveBayes` `logisticRegression`
  (binary or multiclass one-vs-rest) `decisionTree` `randomForest`; `kMeans`
  `pca` `standardScaler` `minMaxScaler`. Introspection: `coefficients`
  `intercept` `centroids` `components` `explainedVariance` `featureImportances`.
  Selection / preprocessing: `trainTestSplit` -> `ml.Split`, `kFold` -> list of
  `ml.Fold`, `polynomialFeatures`. Metrics: `accuracy` `precision` `recall`
  `f1`(+ positive label) `confusionMatrix` `rocAuc` `logLoss` `rmse` `mse` `mae`
  `r2`. X is `list of list of float/int` (rows), y a
  `list of float/int`. Random models honor `math.randSeed`; a degenerate input
  is a catchable error. Not a deep-learning framework.
- **`linalg`** - linear algebra, the companion to `stats`. Vectors are a
  `list of float`: `dot distance cross normalize`. Matrices are a
  `list of list of float`: `transpose trace determinant inverse solve identity
  zeros shape`. `norm`/`scale`/`add`/`sub` are polymorphic over a vector or a
  matrix (`norm` = L2 / Frobenius), and `matmul` covers matrix*matrix,
  matrix*vector, and vector*matrix (vector*vector errors - use `dot`).
  `dot`/`distance`/`norm`/`trace`/`determinant` return `float`; `shape` a
  `list of int`; the rest a vector or matrix. Strict like `math`/`stats`: a
  dimension mismatch, a non-rectangular matrix, a singular `inverse`/`solve`, the
  zero vector to `normalize`, or a non-finite (overflow) result is a catchable
  error, not a NaN.
- **`strings`** - `upper lower fold contains startsWith endsWith indexOf
  trim trimLeft trimRight replace repeat substring split chars join`.
  Rune-indexed (`fold` = case-insensitive compare).
- **`lists`** - `push pop first last head tail reverse sort contains concat
  slice shuffle range`, plus higher-order `map filter reduce find any all sortBy`
  (each takes a `func` value). Non-mutating (they return new lists).
- **`binary`** - bulk operations on `bytes` (the byte-data counterpart to
  `strings`/`lists`): `concat slice find split startsWith endsWith`.
  Non-mutating, value-semantic; each pushes a per-byte loop into Go for
  throughput. `indexOf`/`split` scan at native speed (a MIME boundary, a
  delimiter). Named `binary` because `bytes` is a reserved type keyword.
  For building a buffer from a stream use `net.readAll`/`readN`, not
  `binary.concat` in a loop (O(n^2)).
- **`maps`** - `keys values has delete merge`. `has` before a missing-key read.
- **`os`** - `getEnv`, `hasFlag`/`flag`, `isTerminal`, `run`/`spawn`,
  `cwd`/`homeDir`/`tempDir`; `catchSignal(name)`/`gotSignal(name)` to trap and poll
  a Unix signal (`"int"`/`"term"`/`"hup"`/`"usr2"`; cooperative, opt-in, for
  graceful shutdown; `"usr1"` reserved for `kill -USR1` interpreter diagnostics).
  Constants `PLATFORM ARCH NCPU EOL DIRSEP PATHSEP ARGS`.
- **`path`** - OS-aware filesystem path manipulation (the string layer paired
  with `fs`; no I/O): `path.base(p)`, `dir(p)`, `ext(p)`, `stem(p)`,
  `join(a, b, ...)`, `clean(p)`, `isAbs(p)`, `split(p)` -> `[dir, file]`. Uses
  the host separator, so `path.join` builds portable paths instead of hardcoding
  `/`. Not a filename sanitizer (OS-aware `base` does not strip a foreign `\`).
- **`json`** - `encode`/`encodePretty`/`decode`. `decode` returns an opaque
  `json.Value` walked by JSON Pointer accessors (`get`/`asInt`/`asString`/
  `typeOf`/`has`/`keys`/`length`/...) and edited by non-mutating writers
  (`set`/`insert`/`append`/`remove`/`move`, `map()`/`list()`).
- **`asn1`** - ASN.1 BER decode / DER encode (the byte layer under LDAP / SNMP /
  PKI), designed like `json`. `decode(bytes)` returns an opaque `asn1.Value`
  walked by `(node, pointer)` accessors where the pointer's tokens are child
  indices (`typeOf`/`tagClass`/`tagNumber`/`isConstructed`/`get`/`has`/`length`/
  `asInt`/`asBool`/`asString`/`asBytes`/`asOid`/`isNull`). Build with typed
  constructors (`integer`/`enumerated`/`boolean`/`null`/`octetString`/
  `utf8String`/`printableString`/`ia5String`/`oid`/`sequence`/`set`, plus
  `tagged` EXPLICIT / `retag` IMPLICIT context tags) and `encode(v)` -> DER
  `bytes`. Malformed input and wrong-type leaf reads are catchable errors.
- **`toml`** - RFC-conformant TOML 1.0 `encode`/`encodePretty`/`decode` with
  the **same opaque-value, read / walk / write surface as `json`, name for
  name** (JSON Pointer addressing), plus `asDatetime` (backed by `time.Time`)
  for TOML's native date-times. The config format Jennifer ships (not INI).
- **`xml`** - `decode`/`encode`/`encodePretty` over an opaque `xml.Value`,
  designed like `json`/`toml` but an element tree (ordered attributes + children
  + mixed text). Read: `tag`/`text`/`attr`/`hasAttr`/`attrs`/`children`,
  `typeOf`; navigate with an XPath-style path (`name`, `name[k]` 1-based, `*`)
  via `get`/`findAll`/`has`; build with `element`/`setAttr`/`setText`/`append`.
  Entities + numeric refs decode; namespace prefixes kept verbatim.
- **`yaml`** - YAML 1.2 `decode`/`decodeAll`/`encode`/`encodePretty` over an
  opaque `yaml.Value`, the **same opaque-value read / walk / write surface as
  `json`/`toml`, name for name** (JSON Pointer addressing), plus
  `asDatetime`/`isDatetime` for timestamps and `isNull`. `decode` is one
  document (a multi-doc stream errors); `decodeAll` returns a `list of
  yaml.Value`. Anchors / aliases resolve by value and `<<` merge keys apply
  (own key wins). `encode` is flow (compact `{a: 1}`); `encodePretty` is block
  (readable). Backed by `gopkg.in/yaml.v3` (the one library with a Go
  dependency; TinyGo-clean).
- **`intl`** - internationalization: message catalogs + locale-aware
  translation. `intl.load(lang, catalog)` ingests a `map of string to string`
  (first language loaded is the default); `intl.setLocale(lang)` /
  `intl.locale()`; `intl.tr(key)` / `intl.tr(key, params)` translates with
  `%name%` placeholder interpolation (`%%` escapes a literal `%`) and a
  fallback chain (current locale -> its base language -> default language -> the
  key itself, so a missing translation is visible). Named `intl` (letters-only,
  like JS `Intl`), not `i18n`; there is no ambient `_()`.
- **`httpd`** - HTTP/1.1 server engine over `net/http`. Pull loop (no handler
  callbacks): `httpd.listen(addr)` (or `listenTLS(addr, cert, key)`, TLS + HTTP/2)
  -> `Server`, then loop
  `httpd.accept($srv)` -> `Request` and `httpd.respond($req, status, body)`;
  request accessors `method`/`path`/`query`/`header`/`body`/`remoteAddr`, plus
  `setHeader`/`serveFile`/`serveDir`/`shutdown`. `spawn` several accept loops
  for a worker pool. Default binary only (`jennifer-tiny` stubs it).
- **`term`** - terminal control for interactive TUIs: `term.makeRaw(stream)` ->
  `term.State` and `term.restore(state)` (raw mode: unbuffered, no-echo input),
  `term.size(stream)` -> `term.Size{rows, cols}`, `term.readByte()` -> int (one
  raw byte from stdin, `-1` at EOF; bytes, not decoded keys). Over
  `golang.org/x/term`; default binary only (`jennifer-tiny` stubs it). Refused in
  the REPL. Output-only TUIs need only `ansi` + `os.isTerminal`.
- **`serial`** - serial ports: `serial.open(path, baud)` -> `serial.Port`, `read`
  / `write` / `flush` / `close`, `openWith` for full termios config. Linux-only,
  **default binary only** (stubs elsewhere and on `jennifer-tiny`).
- **`spi`** - SPI devices: `spi.open(path)` -> `spi.Device`, `configure(dev, mode,
  speedHz)`, full-duplex `transfer(dev, bytes)`, `close`. Linux-only, **default
  binary only**.
- **`i2c`** - the I2C bus: `i2c.open(path, addr)` -> `i2c.Bus`, `read` / `write` /
  `readReg(bus, reg, n)` / `writeReg` / `close`. Linux-only, **default binary
  only**.
- **`gpio`** - GPIO over `/dev/gpiochipN` lines, pin-keyed `setup` / `read` /
  `write` / `release` + `gpio.IN` / `gpio.OUT` (mirrors the sysfs `gpio` module).
  Linux-only, **default binary only**.
- **`sql`** - relational-database client over `database/sql`: MySQL / MariaDB +
  PostgreSQL (pure-Go drivers; SQLite excluded). `sql.open(driver, dsn)` ->
  `Connection`, `query`/`exec` (target is a Connection or Tx), pull cursor
  `next` + typed `asInt`/`asFloat`/`asString`/`asBool`/`asBytes`/`isNull`,
  `begin`/`commit`/`rollback`, prepared statements. Values bind **only through
  placeholders** (no string interpolation -> injection-safe). Default `jennifer`
  binary only; `jennifer-tiny` stubs it.
- **`time`** - dates, durations, zones. Structs `time.Time` / `Duration` / `Zone`;
  constructors + accessors, arithmetic (`add` / `sub` / `before` / `after` /
  `equal`), `inZone`, `sleep`, strftime `format` / `parse`, ISO 8601 `iso` /
  `fromIso`. Constants `UTC`, `PROGRAM_START`. Fixed-offset zones (no IANA / DST
  yet).
- **`fs`** - blocking filesystem I/O. Whole-file `read` / `write` / `append`
  (String / Bytes); metadata `exists` / `isFile` / `isDir` / `stat` (-> `fs.Stat`)
  / `realpath` / `readlink` / `symlink(target, linkPath)`; permissions `chmod` /
  `chown` (Unix); dir ops `mkdir` / `mkdirAll` / `remove` / `removeAll` / `rename`
  / `list` / `walk`; temp entries `makeTempFile` / `makeTempDir`; buffered `fs.File`
  handles (`open` / `readLine` / ... / `sync` / `close`); and a polling `watch` ->
  `fs.Watcher` (`next` / `hasEvent` / `close`). Path- vs handle-form verbs dispatch
  on the first arg.
- **`net`** - sockets. TCP `connect` / `listen` / `accept` / `readBytes` /
  `writeBytes`, bulk `readAll` / `readN`; TLS `connectTLS` / `startTLS` (opt-out
  verify via `net.TLSOptions{skipVerify, caCert}`); UDP `listenUDP` / `sendTo` /
  `recvFrom`; DNS `lookup` / `reverseLookup`; polymorphic `close` / `address`.
  `connect` takes an optional trailing `timeoutMs`. **Default `jennifer` binary
  only** (`jennifer-tiny` stubs it).
- **`regex`** - RE2 (linear-time): `matches` / `find` / `findAll` / `replace` /
  `split` / `escape`. A match is a `regex.Match{text, start, end, groups,
  groupsNamed}` (rune indices; `start == -1` means no match). Implicit 128-entry
  LRU pattern cache.
- **`hash`** - MD5 / SHA-1 / SHA-256 digests over `bytes`: `hash.compute(b, algo)`,
  keyed `hmac(key, message, algo)`, constant-time `equal(a, b)` (MAC / token
  checks), and streaming (`stream` / `update` / `finalize` via `hash.Stream`). The
  algorithm is always a value (`"sha256"`, ...), never a per-digest shortcut.
- **`crc`** - CRC-32 / CRC-64 checksums over `bytes`, the same codec-table shape as
  `hash`.
- **`crypto`** - security primitives above `hash`: crypto-grade random
  `randBytes(n)` / `randInt(lo, hi)`, constant-time `hmacEqual`, key derivation
  `hkdf` / `pbkdf2`, AES-256-GCM `encrypt` / `decrypt`, Ed25519 `signKeypair` /
  `sign` / `verify`, and PEM-key RSA / ECDSA `rsaSign` / `rsaVerify` / `ecdsaSign` /
  `ecdsaVerify` plus key generation / CSR / JWK `rsaGenerateKey` / `ecGenerateKey` /
  `jwkPublic` / `jwkToPem` / `csr` (for JWT RS\* / ES\* and ACME). TinyGo-clean
  except the RSA / ECDSA surface, which is **default binary only**.
- **`compress`** - byte-stream compression: `pack` / `unpack` for `"gzip"` /
  `"zlib"` / `"deflate"` (`bytes` in/out, optional `"fast"` / `"default"` /
  `"best"` level), plus streaming via a `compress.Stream` handle. Both binaries.
- **`archive`** - tar / zip containers over `bytes` (no `fs`): `pack` / `unpack`
  for `"tar"` / `"zip"` / `"tar.gz"`; a bundle is a `list of archive.Entry{name,
  data, mode, mtime}`. Both binaries.
- **`encoding`** - introspection (`isAscii` / `lenBytes` / `lenRunes`),
  binary-to-text `toText` / `fromText` (`hex` / `base32` / `base64` / `base64-url`
  / `ascii85` / `z85` / `quoted-printable`, plus `uri-percent` (RFC 3986) and
  `uri-form` (form-urlencoded) that the `uri` module builds on), and character
  `encode` / `decode` (`ascii` / `iso-8859-*` / `windows-*` / `ebcdic`). Codec
  names are exact-match.
- **`uuid`** - RFC 9562 UUIDs: `uuid.v4()` (random) / `v7()` (time-ordered),
  `parse` / `isValid` / `version`, constant `NIL`. Randomness is `crypto`-grade, so
  a generated UUID is safe as a security token.
- **`meta`** - interpreter self-identity: constants `VERSION` / `BUILD` /
  `SYSMODDIR` / `CAPABILITIES` + `hasCapability(name)`, and a small reflection
  surface - `call(name, args...)` / `defined(name)` (a top-level method by string
  name) and `callMain` / `definedMain` (resolve against the entry program, so a
  module can dispatch to handlers its host defined).
- **`testing`** - test-runner primitives: `run(name)` (invoke a user method by
  name; the one place `exit` is caught), assertions `assertEqual` / ... /
  `assertThrows` (throw `Error{kind: "assertion"}`), `results` / `reset`, and
  `report` (`text` / `tap` / `junit`). The `.j` test framework and the `jennifer
  test` subcommand build on top.
- **`kv`** - in-process key/value store with per-key TTL (the no-server local
  counterpart to the `memcache` / `redis` modules): `kv.open()` (in-memory) /
  `kv.openFile(path)` (persisted across `jennifer run` invocations) -> `kv.Store`,
  then `set(store, k, v, ttl)` / `add` / `get` / `has` / `delete` / `touch` /
  `incr(store, k, delta)` (memcache-shape: new value, `-1` when absent, does not
  create; `delta` is signed so a negative value decrements - no separate `decr` -
  and it does not floor at 0) / `close`. A `kv.Store` is an integer handle into a per-interpreter
  registry, so it shares its backing map across value-copies and `spawn`ed tasks
  (per-store mutex; `incr` atomic) - the shared mutable state a pure `.j` module
  cannot hold. Backs `kvstore`'s in-process option. TinyGo-clean (both binaries).

For the exact signature of any function, see the hosted library reference -
the [cheatsheet](https://jennifer-lang.dev/libraries/cheatsheet.html)
(every builtin in one table) or the
[per-library pages](https://jennifer-lang.dev/libraries/index.html)
(e.g. `.../libraries/json.html`).

## Module library (Jennifer-coded, brought in with `import`)

Distributable `.j` modules that ship with Jennifer - ordinary Jennifer source
you can read, fork, or replace, distinct from the Go libraries above. Installed
to the system module dir, so `import "NAME.j";` resolves with no path (or
`import "./NAME.j" as NAME;` for a local copy); addressed `NAME.fn(...)` /
`NAME.Struct` like a library.

- **`acme`** - ACME (RFC 8555) client: obtain / renew TLS certificates from Let's
  Encrypt and compatible CAs. `acme.connect(directoryUrl, accountKey)` /
  `register(client, email)`, `order(client, domains)`, `authorization` +
  `challenge(authz, kind)`, compute HTTP-01 `keyAuthorization(client, token)` /
  DNS-01 `dnsRecord(client, token)`, `accept` + `pollAuthorization`, then
  `finalize(client, order, csr, ...)` with a `crypto.csr` + `downloadCertificate`.
  Every request a JWS (`RS256` / `ES256`) over `http` + `json`; keys / CSR / JWK
  from `crypto`. Test against a CA **staging** endpoint first. Needs the default
  binary.
- **`ansi`** - terminal styling as string wrappers: `ansi.color(s, name)` /
  `bgColor` / `style(s, name)` (bold / dim / italic / underline / reverse) /
  `rgb` / `strip`, plus per-colour and per-style shortcuts (`ansi.red(s)`,
  `ansi.bold(s)`). TTY-aware: styling suppresses itself off a terminal or under
  `NO_COLOR`, and is forced on by `FORCE_COLOR`.
- **`args`** - a declarative CLI argument parser (argparse-style) over `os.ARGS`.
  Build a value-semantic `Parser` with copy-returning builders: `args.parser(prog,
  help)` then `args.flag` / `intFlag` / `floatFlag` / `boolFlag` (long + short,
  default, help), `countFlag` (`-vvv` -> 3), `listFlag` (repeatable -> list),
  `positional` / `positionalOpt` / `positionalList` / `positionalList1` /
  `positionalN` (`nargs` `?` / `*` / `+` / N), post-modifiers `required(p)` /
  `choices(p, allowed)`, `command(p, name, help, sub)` (subcommands), `version(p,
  ver)`. `args.parse($p, os.ARGS)` -> a `Result` read with `asString` / `asInt` /
  `asFloat` / `asBool` / `asList` / `count` / `has` (+ `$r.command` / `$r.done` /
  `$r.helpText`). Accepts `--flag=value` / `--flag value` / `-abc` bundling / `--`;
  an unknown flag / missing required / bad type / bad choice throws
  `Error{kind: "args"}`, while `-h` / `--help` / `--version` set `$r.done` with
  `helpText` to print. `args.dispatch($r, handlers)` routes the chosen subcommand
  to its handler (`handlers` a `map of string to func` of `func(r as Result)`
  values, run in the entry program's context), returning the handler's value.
  Pure `.j` over `strings` + `convert` + `lists` + `maps`; both binaries.
- **`csv`** - RFC 4180: `csv.parse(s)` / `format(rows)` (`parseWith` / `formatWith`
  for any single-character delimiter, e.g. TSV), plus `toRecords` / `fromRecords`
  for header-keyed `map of string to string`. Quoting-aware. `csv.formatSafe(rows)`
  neutralises spreadsheet-formula injection (CWE-1236); a `csv.Dialect`
  (`dialect(delim)` -> `parseDialect` / `formatDialect`) groups delimiter / quote /
  comment / trim knobs; streaming `csv.reader` / `writer` wrap an open `fs.File`.
- **`docblock`** - the Jennifer doc-comment format (`/**` ... `*/` with a
  summary, description, and `@param`/`@field`/`@return`/`@throws`/`@since`/
  `@deprecated`/`@see`/`@example`/`@internal`/`@module` tags; types in `{...}`)
  and its parser. `docblock.parse(source)` -> a typed `FileDoc` tree (module
  preamble + per-construct docs + `Diagnostic`s for doc drift / orphans). Data,
  not rendering. Over `regex` + `strings`; both binaries.
- **`feed`** - RSS 2.0 and Atom 1.0 web syndication in one module (format chosen
  on `build`, detected on `parse`). Value-semantic `feed.Feed{title, link, updated,
  entries, author, categories}` of `feed.Entry{..., enclosure}` (an
  `feed.Enclosure{url, length, type}`) with builders `feed.feed(title, link)` /
  `entry(title, link)` / `add(f, e)` / `feedUpdated` / `entryId` / `entryPublished`
  / `entrySummary` / `entryContent` / `entryAuthor` / `entryCategory` /
  `entryEnclosure` / `hasEnclosure`; `feed.build(f, "rss"|"atom")` / `parse(text)`
  / `kind(text)`, and `feed.fetch(url)` over `http`. Enclosures make it a podcast
  feed; author + categories round-trip. Over `xml` + `time` (build / parse both
  binaries, `fetch` the default). Hardened for untrusted feeds (nesting cap, 64 MiB
  body cap).
- **`font`** - a pure-Jennifer TrueType / OpenType font parser (no Go; `bytes` +
  bitwise ops + `fs`, so **both binaries**). `font.parse(b)` / `open(path)` ->
  `font.Font` (`.ttf` or `.otf`); `font.unitsPerEm` / `name` / `advance(f, cp)` /
  `kern(f, left, right)` / `ascender` / `descender` / `lineGap` / `capHeight` /
  `xHeight` (OS/2 metrics) / `glyphPath(f, cp)` -> an SVG path `d` / `glyph(f, cp)`
  -> `font.Glyph` (contours of `font.Point`s + advance + bbox). Both outline
  backends ship: TrueType `glyf` (quadratic) and CFF for OpenType `OTTO` (a Type2
  charstring interpreter with subrs + CID-keyed FDArray, so CJK too; cubic curves
  emit native `C` in `glyphPath`). GPOS / GSUB shaping, `CFF2` / variable axes, and
  hinting are out of scope.
- **`flatdb`** - a file-backed JSON store over `json` + `fs`. `flatdb.open(path)`
  -> value-semantic `DB` (empty if absent), or `flatdb.openString(text)` for a
  **read-only** DB from an in-memory JSON string (`save` throws). Query / edit by
  JSON Pointer (`get` / `has` / `keys` / `length`; fresh-`DB`-returning `set` /
  `append` / `remove`); `flatdb.save(db)` writes back crash-atomically (temp +
  `rename`), `flatdb.saveAs(db, path)` writes to a new file and returns a fresh `DB`
  bound to it. Values are `json.Value`s. Transport-agnostic (never imports `http` /
  `net`), so both binaries. Not a database engine - crash-atomic snapshotting of
  small data.
- **`dotenv`** - read `.env` config files with layered profiles + `${VAR}`
  interpolation. Single-file: `dotenv.parse(text)` / `read(path)` -> `map of string
  to string`; `dotenv.load(path)` also `os.setEnv`s each. Cascade loaders merge
  `.env` -> `.env.local` -> `.env.<profile>` -> `.env.<profile>.local` from one
  dir, a real OS env var always winning: `readCascade(dir, profile)` (no mutation)
  / `resolve(dir, profile)` (effective map) / `loadCascade(dir, profile)` (setEnv
  only unset keys) / `autoload(dir)` (profile from `JENNIFER_ENV`). Handles `#`
  comments, a leading `export`, single (literal) / double (`\n` etc., multi-line)
  quotes, and backward-reference `${VAR}` interpolation (earlier keys -> OS env ->
  ""; no command substitution). Profile labels validated (no traversal). Over `fs`
  + `strings` + `os` + `path` + `regex` + `maps`; both binaries.
- **`cron`** - parse and evaluate cron expressions. `cron.parse(expr) -> Schedule`;
  `cron.matches(schedule, t) -> bool`; `cron.next(schedule, after)` -> the next
  `time.Time` at or after a time. Five fields (minute / hour / day-of-month / month
  / day-of-week) with `*` / `,` / `-` / `/n` steps, three-letter month / day names,
  and `@`-nickname macros (`@daily` / `@hourly` / `@reboot` / ...). A pure calculator
  over `time` (no clock) - a scheduler is your own `spawn` + `time.sleep` loop. Both
  binaries.
- **`html`** - build an HTML element tree and render escaped HTML5:
  `html.element(tag, attrs, children)` / `text(s)` / `raw(s)` / `attr(n, v)`,
  `render` / `renderAll`, `escape`, `safeUrl(url)` (an `http` / `https` / `mailto`
  allowlist, else `"#"`), `boolAttr(name)`. `element` / `attr` reject a tag /
  attribute name outside `[A-Za-z][A-Za-z0-9-]*`. Also a **tolerant `parse(src)`**
  that reads HTML back into the same `Node` tree (void / self-closing /
  mismatched-nesting / comment / DOCTYPE tolerant, budget-capped), walked by
  `get(node, sel)` / `findAll` / `has` (XPath-ish `/`-path selectors with `*` and
  `name[k]`) + `attrOf` / `hasAttr` - re-serialized with the same `render`, so
  build and parse round-trip through one model.
- **`tengine`** - a text template engine (a subset of Go `text/template`) rendered
  over a `json.Value` tree. `tengine.newSet()` -> `Set`; `tengine.add(set, name,
  src)` (extracts `{{ define }}` blocks); `tengine.render(set, entry, data)` ->
  string. Addressing `.a.b` / `$` / `$var`; actions `{{ if }}` / `{{ else if }}` /
  `{{ else }}` (functions `eq` / `ne` / `lt` / `and` / `or` / `not`, parenthesised),
  `{{ range }}` / `{{ with }}` (each with `else`), `{{ $x := PIPE }}`, `{{ template
  }}` / `{{ block }}` layout inheritance, `{{/* comments */}}`, `{{- -}}` trim
  markers, and output pipes (`upper` / `lower` / `title` / `trim` / `html` /
  `urlize` / `default` / `truncate` / `join` / `len` / `printf`). Not auto-escaped
  (use the `html` pipe). Over `json` / `strings` / `lists` / `maps` / `convert`;
  both binaries.
- **`http`** - an HTTP/1.1 client over `net` (`https://` via TLS).
  `http.request(method, url, headers, body)` (or `requestWith(..., timeoutMs)`;
  the verbs default to a 30 s idle timeout) plus `get` / `post(url, contentType,
  body, headers)` / `put` / `patch` / `delete` / `head` / `options` return an
  `http.Response` (`status` / `statusText` / lowercased `headers` / `body`;
  `http.header(resp, name)` reads case-insensitively). Handles Content-Length +
  chunked framing, text (UTF-8) bodies. For **binary** downloads use
  `http.getBytes` / `requestBytes` -> `http.BytesResponse` (raw `bytes` body); to
  **upload** raw bytes byte-for-byte, `http.requestRawBody(...)` / `requestRawBodyTls`.
  For a request **with a policy** use `http.send(method, url, headers, body,
  options)` with an `http.Options{timeoutMs, maxBytes, maxRedirects, maxRetries,
  backoffMs, tls}` (zero value = one-shot): it follows redirects, retries 429 / 5xx
  with backoff (honouring `Retry-After`), and carries cookies. `http.basic(user,
  pass)` builds a `Basic` auth value. For a **keep-alive** connection,
  `http.connect(url, options)` -> `http.Session` and `http.exchange(session, method,
  path, headers, body)` -> `http.Exchange{response, session}` (thread the session
  forward: `$s = $x.session;`), `http.close(session)`. For a self-signed / private-CA
  server, pass `http.TlsOptions{skipVerify, caCert}` via `http.requestTls` /
  `requestWithTls` (the zero value full-verifies). **Default `jennifer` binary
  only** (`net`).
- **`gotify`** - push a notification to a [Gotify](https://gotify.net) server,
  on top of `http`: `gotify.push(cfg, title, message, priority)` POSTs the
  message form (`X-Gotify-Key` header) to `cfg.url + "/message"` and returns the
  `http.Response` (a bad token is a `4xx` value, not a crash).
  `gotify.pushMarkdown(...)` renders the body as markdown, `pushWith(..., url)`
  adds a tap/click action, and `pushExtras(..., ex)` attaches an arbitrary
  `Extras`. Value-semantic
  `gotify.Config{url, token}`, caller-supplied. **Default `jennifer` binary
  only** (`net`).
- **`gpio`** - Raspberry-Pi / Linux-SBC GPIO over sysfs (`fs` backend).
  Stateless, pin-keyed: `gpio.setup(pin, "in"/"out")` / `write(pin, 0/1)` /
  `read(pin)` / `release(pin)`. Root `/sys/class/gpio`, overridable via the
  `JENNIFER_GPIO_BASE` env var (`os.setEnv`, e.g. for a mock). Off a
  GPIO-capable host, calls throw `Error{kind: "gpio"}` clearly. Both binaries.
- **`rest`** - an ergonomic REST layer over `http` + `json`. Build a
  value-semantic `rest.client(baseUrl)` (`Client{baseUrl, headers, options}`,
  `options` an `http.Options` policy), then `rest.get(c, path, query)` / `post(c,
  path, contentType, body)` / `put` / `patch` / `delete` -> `rest.Response`, plus
  `getJson` (-> `json.Value`) / `postJson` / `putJson` / `patchJson`. Base-URL
  joining, form-encoded queries (via `uri`), auth (`rest.bearer` / `basic` /
  `withHeader`). Inherits the http policy via copy-returning builders
  (`withTimeout` / `withRedirects` / `withRetries` / `withBackoff`, TLS `withCA(c,
  pem)` / `insecure(c)`). For **paginated** collections, `rest.paginate(c, path,
  query, maxPages)` (Link-header `rel="next"`) / `paginateCursor(...)` -> `list of
  json.Value`. A 4xx/5xx is a `Response` value, not a crash. **Default `jennifer`
  binary only** (`net`).
- **`uri`** - URL / URI parsing, building, and query strings (RFC 3986), the
  shared URL layer the network modules build on. `uri.parse(raw)` -> `Uri`
  (`scheme` / `user` / `host` / `port` / `path` / `query` / `fragment`) and
  `uri.build(u)` back; `uri.encode` / `decode` (RFC 3986 percent-encoding, space
  `%20`) and `uri.encodeForm` / `decodeForm` (`application/x-www-form-urlencoded`,
  space `+`); `uri.buildQuery(params)` / `uri.parseQuery(q)` between a `map of
  string to string` and a query string (form-encoded); and `uri.resolve(base,
  ref)` for RFC 3986 relative-reference resolution (`../img.png` against a base).
  Pure `.j` over `strings` + `encoding` + `convert`, so **both binaries**; sits
  on `encoding`'s `uri-percent` / `uri-form` codecs.
- **`validate`** - declarative validation of a `map of string to string` (a form
  body, query, config) against a rule set, returning a structured failure list
  instead of ad-hoc `if` checks. Rules compose per field as value-semantic
  descriptors: `validate.required` / `isInt` / `isFloat` / `isBool` / `min(n)` /
  `max(n)` / `minLen(n)` / `maxLen(n)` / `pattern(re)` / `email` / `url` /
  `datetime(format)` / `oneOf(list)` / `noneOf(list)` / `password(schema)` /
  `custom(fn, msg)` (a `func` predicate) / `withMessage(r, m)`, grouped in a `map
  of string to list of validate.Rule`. `validate.check(data, rules)` -> `list of
  validate.Failure` (`{field, rule, param, message}`, `rule` a stable id);
  `validate.ok(...)` -> bool; `validate.messages` / `byField` render them, and
  `validate.localize(errs, templates)` re-messages via a `rule-id -> template` map
  (feed it `intl.tr` for non-English). An absent / blank field passes every rule
  but `required`; only named fields are checked. Pure `.j` over `regex` + `uri` +
  `time` + `password` + `convert` + `lists` + `strings` + `maps`; **both
  binaries**.
- **`graphql`** - a thin GraphQL client over `http` / `rest`. `graphql.client(endpoint)`,
  layer auth / TLS with `bearer(c, token)` / `basic` / `header` / `withCA` /
  `insecure`, then `graphql.query(c, query, variables)` POSTs `{"query", "variables"}`
  and returns the decoded `json.Value` (result under `/data`; `variables` a
  `json.Value`, empty `json.map()` for none). The rule it gets right: a GraphQL
  execution error is an **HTTP 200 with a top-level `errors` array**, so `query`
  raises `Error{kind: "graphql"}` (a non-2xx also raises). To read partial data,
  `graphql.tryQuery(...)` returns the raw envelope (raises only on non-2xx);
  inspect with `hasErrors` / `errorMessages`. `queryNamed` / `tryQueryNamed` add a
  trailing `operationName`. **Default `jennifer` binary only** (`net`).
- **`oauth`** - a generic OAuth2 client (the *get-a-token* half; `sasl` is the
  *use-a-token* half) over `http` + `json`: `oauth.clientCredentials(cfg)` /
  `refresh(cfg, refreshToken)` / device flow `deviceStart(cfg)` -> `deviceWait(cfg,
  dev)` -> `oauth.Token`. `google` / `microsoft` `Config` presets, `isExpired` +
  `save` / `load` token store; tokens feed `sasl.bearer` for mail XOAUTH2.
  Throws `Error` (kind `"oauth"`) on a token-endpoint error. Auth-Code+PKCE / JWT
  assertion gated on `httpd` / `crypto`. **Default `jennifer` binary only**
  (`net`).
- **`web`** - a small HTTP framework over the `httpd` engine. Register routes
  against handler methods **by name** (`web.get($app, "/users/:id", "showUser")`
  / `post` / `put` / `patch` / `delete` / `route`); patterns take `:param`
  captures and a trailing `*rest` wildcard (`/*path` an SPA fallback, registered
  last), plus `web.before` middleware, `web.notFound`, and `web.onError` (a
  throwing handler is contained as a logged 500, and handed to onError bound `as
  Error`). A handler is `func name(ctx as web.Context)`, dispatched by
  `meta.callMain`; `HEAD` is served by the matching `GET`. **Requests are handled
  concurrently** (each in its own `spawn`ed worker, dispatch race-safe): reads of
  shared top-level state are safe, but do not have two handlers **write** one
  top-level `def` at overlapping times. `web.Context` helpers: `param` / `query` /
  `method` / `path` / `header` / `body` / `bodyJson` / `form` / `formValue` /
  `remoteAddr`, and `text` / `html` / `sendJson` / `redirect` / `respond` /
  `setHeader` / `serveFile` / `serveDir` / `sendGzip`. Plus cookies (`web.cookie`
  / `setCookie` + `CookieOptions`), sessions (`web.sessionId` mints a UUID id
  cookie, `web.renewSession` rotates it after login; the app owns the store), CORS
  (`web.cors` + `CorsOptions`), caching (`web.etag`; `serveFile` sets `ETag` /
  `Last-Modified`), auth (`web.basicAuth` -> `BasicCredentials`, `web.bearerToken`),
  CSRF (`web.csrfToken` / `csrfCheck`, HMAC double-submit, app owns the secret),
  and mounting (`web.mount($app, prefix, sub)` / `joinRoute` composes a sub-router
  under a prefix). `web.run($app, addr)` owns the accept loop (`serveOn` to hold
  the server handle). Run with `jennifer serve app.j [--watch]`. **Default
  `jennifer` binary only** (`net`).
- **`webapi`** - a JSON-API conventions layer over `web`. A value-semantic
  `webapi.Api` builder (`new` / `mount(a, version, path)` / `alias` / `deprecate` /
  `authenticator(a, name)` / `limiter(a, name)` / `get` / `post` / ... with a
  `Spec` / `install(a, app, "guard")`). The `Spec` carries `auth` (`Auth.None` /
  `Auth.Bearer`, an **enum**), `scopes`, `rules` (reusing `validate`), `rateLimit`,
  and `produces` (`Produces.Json` / `Html` / `Negotiate` enum); `webapi.public()`
  is the zero `Spec`. Enforcement is one `before` guard the app wires with a shim
  `func apiGuard(ctx) { return webapi.guard($api, $ctx); }` (handlers dispatch **by
  name**, so the authenticator / limiter are entry-program handler names too). The
  guard authenticates, checks scopes (`403`), validates (`422`), rate-limits
  (`429`); `webapi.evaluate(spec, identity, data)` is the **pure**, testable core.
  Uniform error envelopes (`fail` / `notFound` / `denied` / `unauthorized`), request
  data (`queryData` / `jsonData` / `validated` / `identity`), content negotiation
  (`wants`), pagination (`page` / `sendPage`), and a drift-proof discovery
  `json.Value` (`webapi.discovery`). Over `web` + `validate` + `json`; **default
  `jennifer` binary only** (`net`).
- **`markdown`** - render a small CommonMark subset (headings, emphasis, links,
  lists, code, GFM tables) to HTML (`markdown.toHtml`, via `html`) and styled
  terminal text (`toAnsi`, via `ansi`); `parse(md)` surfaces a `Node` tree walked
  like `xml` / `html` (`typeOf` / `children` / `text` / `level` / `get` / `findAll`
  / `has`), and `render(doc, format)` renders a parsed or hand-built tree (parse ->
  transform -> render). `toPdf(md)` / `toPdfWith(md, opts)` / `renderPdf(doc, opts)`
  lay the document out to a paginated PDF via `pdf` (a `PdfOptions` from
  `pdfDefaults()` sets page size / fonts / metadata / `bookmarkLevel`). Author
  Markdown with `header` / `style` / `link` / `bullets` / `numbered` / `codeBlock`
  / `table`; align handcrafted table source with `tablePretty`.
- **`mcp`** - Model Context Protocol (stateless JSON-RPC 2.0), server and HTTP
  client, over `jsonrpc` + `json`. Build a `Server`: `mcp.server(name, version)`
  then `addTool(s, name, desc, inputSchema, handler)` / `addResource` / `addPrompt`,
  each `handler` a top-level `func NAME(arg as json.Value)` reached via
  `meta.callMain`; declare a tool schema with `mcp.schema()` + `mcp.property(...)`.
  `mcp.handle(server, requestBody) -> replyBody` is the transport-agnostic router
  (`initialize` / `tools/list` / `tools/call` / `resources/*` / `prompts/*`) - an
  **allow-list** (only a registered handler runs; a thrown message never reaches
  the wire); `mcp.serveStdio(server)` runs the stdio transport. Client:
  `mcp.connect(endpoint)` / `connectWith` -> `Client`, then `initialize` /
  `listTools` / `callTool(client, name, arguments)` / `listResources` /
  `readResource` / `listPrompts` / `getPrompt`. Stateless protocol only (no SSE /
  sessions). Default `jennifer` binary only (`net` via `http`).
- **`memcache`** - a memcached client over `net` (classic text protocol).
  `memcache.connect(opts)` -> `memcache.Session`, then `set(session, key, value,
  exptime)` / `add` (store-if-absent) / `get(session, key)` (`""` when absent) /
  `delete` / `incr(session, key, delta)` (`-1` when absent) / `decr` / `touch` /
  `quit`; every store carries a TTL. Binary values: `setBytes` / `getBytes`.
  `getMulti(session, keys)` fetches several in one round-trip; `gets` ->
  `memcache.Item{value, cas, found}` + `cas(session, key, value, exptime, casId)`
  -> `"stored"` / `"exists"` / `"not_found"` are the check-and-set pair. A volatile
  cache for sessions / counters / locks. Throws `Error{kind: "memcache"}`.
  **Default `jennifer` binary only** (`net`).
- **`kvstore`** - a **selectable** key/value backend with per-key TTL behind one
  API: a `kvstore.Store` is a sum-type enum with a variant per backend -
  `memcacheStore(mc)` / `redisStore(rc)` (distributed) / `inProcessStore()` /
  `fileStore(path)` (`kv`) - and `set(store, key, value, ttl)` / `get` / `delete` /
  `touch` / `incrWindow` dispatch via an exhaustiveness-checked `match`. The shared
  backend layer under `session` / `ratelimit`. Local backend both binaries;
  distributed needs the default.
- **`session`** - server-side sessions over a `kvstore.Store` backend: a
  **`json.Value`** (structured, nested) under `sess:ID` with a sliding TTL.
  `session.create(store, ttl)` -> id (UUID v4), `load(store, id)` (empty object when
  absent / expired), `save(store, id, data, ttl)`, `touch`, `destroy`. Data stored
  base64-wrapped JSON; the client-supplied id is validated. Volatile (a cache, not
  a store of record). Binary depends on the backend.
- **`ratelimit`** - a rate limiter over a `kvstore.Store` backend, **fixed or
  sliding window**: `ratelimit.fixedWindow(store, limit, window)` / `slidingWindow(...)`
  -> `Limiter`, then `check(limiter, key) -> Result` (records a hit) / `peek(...)`
  (no record). `Result{allowed, remaining, retryAfter, resetSeconds}` is everything
  for a compliant `429`. Sliding window blends current + previous window counts;
  both use window-aligned keys (portable via atomic `incrWindow`). Binary depends on
  the backend.
- **`mime`** - build and parse MIME messages (RFC 5322 headers, multipart,
  quoted-printable / base64 transfer encodings). Build a `Part` tree with
  `mime.text(contentType, body)` / `attachment` / `attachmentBytes(filename,
  contentType, data)` / `multipart(subtype, boundary, parts)` / `withHeader`, then
  `mime.encode(part)` / `parse(text)`, read with `headerValue` / `body` / `parts` /
  `contentType` / `address`. Pull a received message apart with `mime.walk` /
  `attachments` / `textBodies` / `findParts(part, mediaType)` + `mime.data` (raw
  `bytes`) / `filename` / `disposition` / `isAttachment`. A text `body` is decoded
  per the Content-Type `charset` (UTF-8 default, codepages honoured); RFC 2231
  extended filenames and RFC 2047 encoded-words round-trip (primitives
  `mime.encodeWord` / `decodeWord`). No networking. The foundation the mail clients
  build on (`imap.fetchMessage` returns a `mime.Part`).
- **`sasl`** - SASL auth mechanisms shared by the mail clients: base64 encoders
  `sasl.plain(user, pass)` / `loginUser` / `loginPass` / `bearer(user, token)`
  (XOAUTH2), challenge-response `sasl.cram(user, pass, challenge)` (CRAM-MD5), and
  SCRAM (`scramStart(user, algo)` -> `scramClientFirst` -> `scramClientFinal` ->
  `scramFinalToken` -> `scramVerify`, SCRAM-SHA-1 / -256 over `hash` + `crypto`).
  `sasl.negotiate(advertised)` picks the strongest mechanism (mail clients' `auth:
  "auto"`). No net; both binaries.
- **`transport`** - the shared connection-security mode for every socket client
  (`smtp` / `pop` / `imap` / `redis` / `amqp` / `mqtt`): one enum
  `transport.Security { None, Tls, Starttls }` (zero value `None`), used as the
  `security` field of each client's `Options` (build it with `import
  "transport.j" as transport;` alongside the client module, e.g.
  `smtp.Options{security: transport.Security.Starttls, ...}`). `redis` / `amqp` /
  `mqtt` have no in-band upgrade and reject `Starttls`. Helper
  `transport.encrypted(s)` -> bool (`Tls` / `Starttls` true). No net; both binaries.
- **`screen`** - terminal user interfaces (an explicit `screen`, not a GUI).
  Output-only layer (both binaries): a value-semantic cell `screen.Buffer`
  (`screen.newScreen(rows, cols)`) drawn with `screen.text` / `textColor` / `box` /
  `fill` / `hline` / `vline` / `set`, ANSI control builders (`screen.clear` /
  `moveTo(x, y)` / `hideCursor` / `enterAlt` / ...), and a flicker-free
  `screen.render(buf)` / `diff(old, new)` paint loop. Interactive layer (needs
  `term`, default binary): `screen.decodeKey(seq) -> screen.Key{name, char}`
  (arrows, nav, F1-F12, ctrl / alt) + `nextKey` / `begin` / `end` / `size` over raw
  mode. Coordinates 0-based (origin top-left); drawing past an edge is clipped.
- **`semver`** - strict SemVer 2.0.0 over a `Version` struct,
  package-registry-grade: `semver.parse(s)` / `isValid` / `toString`, `compare` /
  `lt` / `eq` / `gt` / ... / `diff`, `isStable` / `isPrerelease`, `incMajor` /
  `incMinor` / `incPatch`, `sort` / `rsort`, `coerce(s)` / `clean(s)`; plus
  **range matching**: `satisfies(version, range)` (caret `^1.2.0`, tilde `~1.2`,
  comparators, OR `||`, hyphen, x-ranges), `maxSatisfying` / `minSatisfying`,
  `minVersion`, `validRange`, and the solver algebra `intersects` / `subset` /
  `gtr` / `ltr` / `outside` / `simplifyRange`, all prerelease-precise.
- **`imap`** - IMAP4rev1 (RFC 3501) client over `net`; reads **and** manages
  folders. `imap.connect(opts)` -> `imap.Session`, then `folders(session, pattern)`
  -> `imap.Folder`, `status(session, folder)` -> `imap.Status` (counts without
  selecting), `selectFolder(session, name)`, `search(session, criteria)` (the
  **UIDs** matching an `imap.Criteria`), `fetch(session, uid)` (raw string) or
  `fetchMessage(session, uid)` (parsed to a `mime.Part`). Manage with `addFlags` /
  `removeFlags` / `flags` / `copy` / `move` (atomic `UID MOVE`) / `append` (upload
  an RFC 5322 message) / `createFolder` / expunge; `fetchPartial` pulls a byte
  range; `logout`, `imap.fetchAll(opts, folder)`. **Every message verb addresses
  by the stable UID** (survives an expunge - the key for "process what is new since
  last run"). `imap.Criteria` (`imap.criteria()` + fields) filters server-side
  (substring `subject` / `from` / `to` / `text`, `since` / `before` `time.Time`
  range, flags, size) and client-side (`subjectRegex` / `hasAttachments`); criteria
  can't inject a command. RFC 2177 `IDLE` push: `idle(session)` -> blocking
  `receiveNotification` / bounded `pollNotification` -> `done`, delivering typed
  `EXISTS` / `EXPUNGE` / `RECENT`. Throws `Error` (kind `"imap"`) on `NO` / `BAD`.
  **Default `jennifer` binary only** (`net`).
- **`idna`** - internationalized domain names: `idna.toAscii(domain)` /
  `idna.toUnicode(domain)` over a Punycode (RFC 3492) core
  (`münchen.de` <-> `xn--mnchen-3ya.de`), plus `idna.isAscii`. Pure Jennifer, no
  net (uses `convert.toCodepoint` / `fromCodepoint`). The mail clients encode
  hosts and SMTP envelope domains through it.
- **`pop`** - receive mail (POP3, RFC 1939) over `net`: `pop.connect(opts)` ->
  `pop.Session`, then `stat` / `count` / `sizes` / `retrieve(session, n)` /
  `deleteMessage(session, n)` / `quit`, plus `pop.fetchAll(opts)`. `uidl(session)`
  -> `list of pop.MessageId` (`number` + persistent `id`) / `uidlOne` give the
  stable ids for leave-on-server / skip-seen; `top(session, n, lines)` previews;
  `reset` (RSET) / `noop`. Retrieved messages are strings for `mime.parse`. Auth
  per `Options.auth`: USER/PASS / APOP / XOAUTH2 / CRAM-MD5 / SCRAM-\* / `"auto"`.
  **Default `jennifer` binary only** (`net`).
- **`redis`** - a Redis client speaking RESP2 over `net`. `redis.connect(opts)` ->
  `redis.Session`, then typed helpers `get` / `set(session, k, v)` / `del` /
  `exists` / `incr` / `decr` / `keys(session, pattern)` / `ping`, plus generic
  `redis.command(session, args) -> redis.Reply` (`kind` / `str` / `num` / `items`,
  walked like a `json.Value`). Binary values: `setBytes` / `getBytes`. Container
  helpers: hash (`hset` / `hget` / `hgetAll` / `hdel`), list (`lpush` / `rpush` /
  `lrange` / `llen` / `lpop`), set (`sadd` / `srem` / `smembers` / `sismember` /
  `scard`). Also RESP2 pub/sub (`subscribe` / `psubscribe` / `publish` /
  `receiveMessage`), `pipeline`, `multi` / `exec` / `discard`, and a production-safe
  `scan` cursor (`keys` flagged production-unsafe). A `-ERR` reply throws
  `Error{kind: "redis"}`. **Default `jennifer` binary only** (`net`).
- **`resque`** - background jobs on Redis, wire-compatible with Resque:
  `resque.enqueue(session, queue, class, args)` schedules a job (JSON envelope onto
  `resque:queue:NAME`); `resque.reserve(session, queues) -> resque.Job{queue, class,
  args}` pops the next job from the first non-empty queue (empty `Job` when
  drained), or `reserveBlocking(session, queues, timeoutSec)` (Redis `BLPOP`); plus
  `queueLength` / `queues` / `size` / `fail`. A Ruby / PHP Resque worker interops;
  the `class`-dispatch loop is user code (`args` a `list of string`). Built on
  `redis` + `json`. **Default `jennifer` binary only** (`net`).
- **`smtp`** - send mail (SMTP client) over `net`. `smtp.send(opts, from,
  recipients, message)` runs the dialogue (EHLO, STARTTLS / implicit TLS via
  `smtp.Options.security` a `transport.Security`, SASL auth per `Options.auth` -
  PLAIN / LOGIN / XOAUTH2 / CRAM-MD5 / SCRAM-\*, then MAIL / RCPT / DATA), `message`
  built by `mime`. Throws `Error{kind: "smtp"}` on rejection. Hardened: cleartext
  SASL refused unless `Options.allowInsecureAuth`; STARTTLS only if advertised
  (anti-downgrade); envelope addresses validated. For a **queue**, `smtp.open(opts)
  -> smtp.Session` does the handshake once, `smtp.sendOn(session, from, recipients,
  message)` delivers each (reusing the socket), `smtp.close(session)` QUITs.
  **Default `jennifer` binary only** (`net`).
- **`snmp`** - an SNMP v1 / v2c **client and agent** over UDP, on the `asn1` BER
  codec and `net`. *Client:* `snmp.client(host, community)` / `clientWith(address,
  community, version, timeoutMs, retries)` -> `snmp.Client`, then `snmp.get(c,
  oids)` / `getNext` / `set(c, varbinds)` / `walk(c, rootOid)` -> `list of
  snmp.Varbind{oid, type, value, number}` (typed `integer` / `octetString` / `oid`
  / `counter32` / `gauge32` / `timeTicks` / `counter64` / ...). *Agent:*
  `snmp.agent(community, version, bindings)` -> `snmp.Agent`, then `snmp.serve(a,
  address)` or `serveOn(a, socket, stop)` answer GET / GETNEXT / SET for the MIB.
  `snmp.intVar` / `stringVar` / `oidVar` / `varbind` build bindings; constants
  `VERSION1` / `VERSION2C`. Community-string auth only (no SNMPv3 / traps). Throws
  `Error` (kind `"snmp"`). **Default `jennifer` binary only** (`net`).
- **`ldap`** - an LDAP v3 **client and directory server** (RFC 4511) over the
  `asn1` BER codec and `net` (LDAPS / StartTLS via `transport.Security`). *Client:*
  `ldap.connect(address, security)` -> `ldap.Conn`, then `ldap.bind(c, dn,
  password)` / `bindSasl(c, user, password, algo)` -> `ldap.Result{code, matchedDn,
  message}`; `ldap.search(c, baseDn, scope, filter, attributes)` (scopes
  `SCOPE_BASE` / `SCOPE_ONE` / `SCOPE_SUB`) / `searchPaged` -> `list of ldap.Entry`
  (read with `ldap.values` / `firstValue`). Filters:
  `ldap.parseFilter("(&(objectClass=person)(uid=x))")` or constructors (`equals` /
  `present` / `substrings` / `allOf` / `anyOf` / `negate` / ...). *Writes:*
  `ldap.add` / `modify` (+ `ldap.change`, ops `MOD_ADD` / `MOD_DELETE` /
  `MOD_REPLACE`) / `delete` / `modifyDn` / `passwordModify`; `unbind` / `close`.
  *Server:* `ldap.directory(entries)` / `openDirectory(path)` (file-backed) ->
  `ldap.Directory`, built with `ldap.entry` / `group` / `password`, mutated with
  `addEntry` / `modifyEntry` / `getEntry` / ..., served by `ldap.serve(dir,
  address)` (simple bind + filtered search). Throws `Error` (kind `"ldap"`).
  **Default `jennifer` binary only** (`net`).
- **`totp`** - time-based one-time passwords (RFC 6238 over RFC 4226 HOTP), the
  two-factor codes authenticator apps show. `totp.generate(secret, opts)` /
  `verify(secret, code, opts)` read the clock (`verify` allows +/-1-step skew);
  `generateAt` / `verifyAt` take an explicit Unix time. `totp.uri(issuer, account,
  secret, opts)` builds the `otpauth://` provisioning string; `generateSecret()` /
  `generateSecretN(nbytes)` mint a crypto-grade base32 secret; `hotp(secret,
  counter)` is the raw HOTP block; `verifyWindow(..., window, opts)` widens the
  skew. A zero `totp.Options` is 6 digits / 30 s / SHA-1, else set `digits` /
  `period` / `algorithm`. `verify` compares constant-time (`crypto.hmacEqual`).
  Over `hash.hmac` + `crypto` + `encoding` + `time`; pure, both binaries.
- **`webhook`** - HMAC-signed webhooks (the GitHub `X-Hub-Signature-256`
  convention). `webhook.sign(payload, secret) -> "sha256=" + hex HMAC-SHA256`;
  `webhook.verify(payload, signature, secret) -> bool` (constant-time, never
  throws). Replay-protected timestamped schemes: `stripeSign` / `stripeVerify`,
  `slackSign` / `slackVerify`, and a generic `timestampedSign` / `timestampedVerify`
  (each verify recomputes, constant-time compares, rejects a stale timestamp).
  `webhook.send(url, payload, secret)` POSTs with the signature header ->
  `http.Response` (**default binary only**, over `http`). Sign / verify the raw body
  bytes, before parsing. Over `hash.hmac` + `encoding`; sign / verify both binaries.
- **`s3`** - an S3-compatible object-storage client (AWS S3 / MinIO / R2 / B2),
  every request AWS Signature V4-signed. `s3.connect(endpoint, region, accessKey,
  secretKey)` -> `Client`, then `s3.get` / `put` / `delete` / `listObjects` (ret
  `http.Response`; `s3.objectKeys(xml)` pulls keys from a listing). Binary objects:
  `s3.getBytes` / `putBytes`; `putWith` / `putBytesWith(..., contentType, metadata)`
  sign `Content-Type` + `x-amz-meta-*`; `s3.head` reads metadata; `s3.copy(...)`
  server-side. `s3.presign(client, method, bucket, key, expiresSeconds)` builds a
  query-signed URL (**both binaries**, no request sent). Large objects use the
  multipart API (`createMultipartUpload` -> `uploadPart` -> `completeMultipartUpload`
  / `abortMultipartUpload`). Path-style addressing; `listObjects` (not `list`, a
  keyword); `Client.timeout` fails a hung endpoint. Over `hash` + `encoding` +
  `time` + `http`; networked ops need the **default `jennifer` binary**.
- **`label`** - industrial label printing in a build / render / emit pipeline.
  Build a device-independent `label.Label` in millimetres: `label.new(w, h)` then
  value-semantic `text(label, x, y, opts, content)` (`label.TextOptions`: `height`
  mm / `points` / `rotation` / `bold`) / `barcode(label, x, y, type, opts, data)`
  (linear code128 / ean13 / ean8 / itf / code39 / gs1-128, 2D datamatrix / qr; a
  zero `label.BarcodeOptions` = defaults, else set `height` / `moduleWidth` /
  `ratio` / `checkDigit` / `errorLevel` / `hideText`) / `box` / `image(label, x, y,
  name)` (a pre-stored logo) / `quantity(label, n)`. `render(label, device)` emits
  a selectable dialect: `label.zpl(dpi)` (Zebra, raster) or `label.cab()` /
  `cabWith(setup)` (cab JScript, mm-native; print-setup lines ride in a
  `label.CabSetup`, ZPL ignores it). Build / render pure (both binaries);
  `send(host, port, rendered)` writes to a printer's raw `:9100` port (**default
  `jennifer` binary only**, `net`).
- **`prometheus`** - Prometheus metrics in two halves. **Exposition** (pure text,
  both binaries): `prometheus.counter(name, help)` / `gauge` / `histogram(name,
  help, buckets)` / `summary(name, help, quantiles)` -> `prometheus.Metric` (a
  `MetricType` enum), `observe(metric, labels, value)` / `observeAt(...,
  timestampMs)` records a sample, `render(metrics)` -> the text exposition format
  (`# HELP` / `# TYPE` / samples, incl. histogram `_bucket` / `_sum` / `_count`).
  `pushgatewayPath(job, grouping)` builds the Pushgateway path. Strict name / label
  validation; an invalid name throws `Error{kind: "prometheus"}`. **Retrieval**
  (default binary, over `http` + `json`): `query(base, promql)` / `queryRange(base,
  promql, start, end, step)` -> `prometheus.Result{resultType, series}`.
- **`mqtt`** - an MQTT 3.1.1 pub/sub client over `net` (`mqtts` via TLS).
  `mqtt.connect(opts)` -> `mqtt.Client`, then `subscribe(client, topic)` /
  `publish(client, topic, message)` / `publishBytes` at QoS 0, blocking
  `receive(client) -> mqtt.Message{topic, payload}` and `poll(client, timeoutMs) ->
  list of Message` (0 or 1), plus `ping` / `disconnect`. Also QoS-1 (`publishQos1` /
  `subscribeQos1`, PUBACK), retained messages, a CONNECT Last-Will (`connectWith`),
  and `reconnect` session resumption. Binary framing hand-built from `bytes` +
  bitwise ops; refusal throws `Error{kind: "mqtt"}`. **Default `jennifer` binary
  only** (`net`).
- **`log`** - leveled, structured logging. A `log.Logger` carries a minimum level
  (`debug` < `info` < `warn` < `error`), a format (`text` / `logfmt` / `json`), and
  a sink; build with `log.new(level, format)` (stdout) / `toStderr` / `toFile(...,
  path)` / `toSyslog(level, address, app)`. `log.debug(logger, message, fields)` /
  `info` / `warn` / `error` (and `at(logger, level, message, fields)`) render one
  record (RFC 3339 timestamp, level, message, a `map of string to string` of
  `fields`) and write it, dropping records below the level. `log.with(logger,
  fields)` returns a child logger stamping persistent fields; `log.fatal(...)` logs
  then exits 1. The syslog sink frames RFC 5424 over UDP; console / file sinks work
  on both binaries, the **syslog sink needs the default `jennifer` binary** (`net`).
  Over `io` / `fs` + `json` + `strings` + `time` + `os` (+ `net` for syslog).
- **`ical`** - iCalendar (RFC 5545) build and parse. Build a value-semantic
  `ical.Calendar` of `ical.Event`s / `ical.Todo`s: `ical.calendar()`, `event(uid,
  start, end, summary)` (dates `time.Time`), then `describe` / `locate` /
  `withAllDay` / `withZone(ev, tzid)` / `recur(ev, rrule)` (build with `ical.rule`)
  / `addRdate` / `addExdate` / `withOrganizer` / `addAttendee(ev, ical.attendee(...))`
  / `addAlarm(ev, ical.alarm(...))` / `add(cal, ev)` / `addTodo` (each returns a
  fresh copy). `ical.occurrences(ev, max) -> list of time.Time` expands the
  recurrence (`FREQ` / `INTERVAL` / `COUNT` / `UNTIL` + `RDATE` - `EXDATE`).
  `ical.encode(cal)` renders CRLF, escaped text, 75-char folding, UTC `DATE-TIME`;
  `ical.parse(text)` reads events / todos / alarms and the parameters, so
  `parse(encode(cal))` round-trips. Pure text over `strings` / `lists` + `time`;
  **both binaries**.
- **`vcard`** - vCard (RFC 6350, vCard 4.0) contacts build and parse. Build a
  value-semantic `vcard.Card`: `vcard.card(formattedName)` then `withName(c,
  family, given)` / `withFullName(...)` / `withNickname` / `withOrg(c, org, title)`
  / `addEmail` / `addEmailTyped(c, email, type)` / `addPhoneTyped` / `addAddress(c,
  vcard.address(...))` / `withBday` / `withPhoto` / `addCategory` / `withUrl` /
  `withNote` (each returns a fresh copy; emails / phones / addresses are
  `Typed{value, type}`). `vcard.encode(c)` / `encodeAll(cards)` writes
  `VERSION:4.0`, structured `N` / `ADR` / `ORG`, `TYPE` params, escaped text,
  75-char folding; `vcard.parse(text) -> list of Card` round-trips. Shares the
  content-line codec with `ical`. Pure text over `strings` / `lists`; **both
  binaries**.
- **`jwt`** - JSON Web Tokens (RFC 7519). `jwt.sign(claims, key, alg)` /
  `verify(token, key, alg)` / `decode(token)` / `header(token)` (claims a
  `json.Value`, `key` always `bytes`). Ten algorithms: HMAC `HS256/384/512`, RSA
  `RS256/384/512`, ECDSA `ES256/384/512`, `EdDSA`. `verify` pins the **expected**
  algorithm (rejects algorithm-confusion), enforces `exp` / `nbf`, compares in
  constant time; `decode` / `header` read without verifying (never authorize on
  them). `verifyWith(..., jwt.Policy{iss, aud})` enforces issuer / audience;
  `verifyLeeway(..., leeway)` widens `exp` / `nbf` for skew; `verifyWithKeys(token,
  keysByKid, alg)` / `verifyJwks(token, jwksJson, alg)` select the key by header
  `kid` (JWKS via `crypto.jwkToPem`, RS\* / ES\* only). Over `crypto` + `hash` +
  `encoding` + `json` + `time`. HS\* / EdDSA both binaries; RS\* / ES\* need the
  default binary. JWT auth is this module as a `web.before` middleware.
- **`jsonl`** - JSON Lines (JSONL / NDJSON): newline-delimited JSON, one
  `json.Value` per line. `jsonl.encode(records)` / `decode(text) -> list of
  json.Value` (blank lines skipped, trailing `\r` trimmed), so
  `decode(encode(rows))` round-trips. Whole-file `readFile` / `writeFile` /
  `appendFile` (append = the growing-log pattern), plus streaming handles over an
  open `fs.File`: a `jsonl.Reader` (`openReader` / `hasMore` / `readRecord` /
  `closeReader`, for files too large for memory) and a `jsonl.Writer` (`writer` /
  `writeRecord` / `closeWriter`). A thin framing layer over `json` + `fs`; **both
  binaries**.
- **`jsonrpc`** - JSON-RPC 2.0, client and server, over `http` + `json`.
  `jsonrpc.client(endpoint)` / `clientWith(endpoint, headers)` -> `Client`, then
  `jsonrpc.call(client, method, params) -> json.Value` (throws `Error{kind:
  "jsonrpc"}` on an error reply / transport failure) and `notify(client, method,
  params)` (no reply). Server side, `jsonrpc.handle(requestBody) -> replyBody` is
  transport-agnostic: it dispatches each `method` to a top-level `func NAME(params
  as json.Value)` via `meta.callMain`, and covers notifications, batches, and the
  reserved error codes. Needs the default binary (`net` via `http`).
- **`ipnet`** - IP addresses and CIDR networks, IPv4 and IPv6.
  `ipnet.parseAddress(s) -> Address` (v4-mapped folds to v4), `toString` (canonical,
  RFC 5952), `version` / `equal` / `unmap` / `next` / `prev` / `compare` (a total
  order). CIDR: `ipnet.parse(cidr) -> Network` (host bits zeroed), `contains(net,
  addr)`, `netmask` / `broadcast` -> `Address`, `networkString`. Subnet math:
  `hostCount`, `firstUsable` / `lastUsable`, `hosts(net)` / `split(net, newPrefix)`
  (each capped 65536), `aggregate(nets)`, `overlaps` / `subnetOf`. Classification:
  `scope(addr) -> Scope` (a disjoint enum `{Global, Private, Loopback, LinkLocal,
  Multicast, Unspecified, Reserved}` you can `match`) + `isGlobal` / `isPrivate` /
  `isLoopback` / ... predicates. An `Address` holds raw `octets as bytes` +
  `version`; a `Network` pairs a base `addr` + `prefix`. Malformed input throws
  `Error{kind: "ipnet"}`. Pure `.j` over `strings` + `convert`; **both binaries**.
- **`ntp`** - a simple SNTP network-time client (RFC 4330 / 5905). `ntp.query(host)
  -> Result` (port 123, 5s timeout) and `ntp.queryWith(address, timeoutMs) ->
  Result` query a server over UDP; `ntp.Result` carries `serverTime as time.Time`,
  `offset as time.Duration` (server minus local clock), and `delay as
  time.Duration` (round-trip). Packs / unpacks the 48-byte NTP packet with `bytes`
  + bitwise ops and converts the NTP epoch (seconds since 1900) through `time`; a
  lost reply times out via a UDP receive deadline (throws `Error{kind: "ntp"}`)
  rather than hanging. Query-only - it measures the offset, it does not discipline
  the clock or run as a daemon. **Default `jennifer` binary only** (`net`).
- **`pdf`** - generate PDF documents (text / lines / rectangles / images). Value-
  semantic builders: `pdf.document()`, `page(width, height)`, then `text(pg, x, y,
  font, size, str)` / `line` / `rect(pg, x, y, w, h, filled)` / `color(pg, r, g,
  b)` (each returns a fresh `Page`), `addPage(doc, pg)`, `render(doc) -> bytes`.
  Metadata via `info(doc, key, value)` (`pdfDate(t)` for dates); `bookmark(doc,
  page, y, title, level)` builds a nesting outline. Standard-14 base fonts;
  coordinates are PDF points (origin bottom-left, ints), colour 0-255 RGB. For
  non-Latin text, **embed a TrueType font** (`loadFont` / `addFont` /
  `textUnicode`, Type0 / CIDFontType2 over the `font` module; `.otf`/CFF throws).
  **Embed raster images** (`loadImage` / `addImage` / `drawImage`): PNG
  (greyscale / RGB / palette / alpha via `/SMask`) and JPEG (`DCTDecode`).
  **Text layout**: `measureText` / `measureTextUnicode` -> width in points,
  `wrapText(...) -> list of string`, `textBlock(pg, x, y, width, font, size,
  leading, str, align)` (`textBlockUnicode`) flows a column ("left" / "right" /
  "center" / "justify"). Output is **byte-identical** (no auto timestamp), so a
  render is golden-safe; `qpdf`-clean, `pdftotext`-extractable. Pure `.j` over
  `strings` / `lists` / `maps` / `convert` / `compress` / `binary` / `math` /
  `time` / `encoding` + `font`; **both binaries**.
- **`dot`** - Graphviz DOT graph description: build a graph and render it to `.dot`
  text for an external Graphviz tool (`dot -Tsvg graph.dot > graph.svg`).
  `dot.digraph(name)` (directed) / `dot.graph(name)` (undirected) start a `Graph`;
  `node(g, id)` / `nodeWith(g, id, attrs)` and `edge(g, src, dst)` / `edgeWith(...)`
  add nodes / edges (`attrs` a `map of string to string`); `graphAttr` / `nodeAttr`
  / `edgeAttr` set default blocks; `render(g) -> string`. Every builder returns a
  fresh `Graph`; labels / attrs DOT-escaped. Text description only (layout is
  Graphviz's job). Pure `.j` over `strings` / `lists`; **both binaries**.
- **`plot`** - data plotting to SVG. `plot.chart(series, opts)` renders a `list of
  plot.Series` (`plot.series(name, xs, ys)`; each carries a `mark` "line" /
  "points" / "both" / "area", optional `dash`, error bars `yErr`, a scatter
  `shape`) on shared axes with a legend; `plot.line` / `scatter` / `bar(labels,
  values, opts)` / `histogram(data, bins, opts)` are wrappers, and `plot.bars`
  draws grouped / stacked multi-series bars. Automatic "nice" ticks, gridded frame,
  title, labels. `plot.defaults() -> Options` carries `width` / `height` / `title`
  / `xLabel` / `yLabel` / `color` / fonts / margins / `legendPos`, log scales
  (`xLog` / `yLog`), a date axis (`xDate` / `dateFormat`, x = Unix seconds), hover
  tooltips, and reference lines (`plot.hline` / `vline` -> `RefLine`).
  `plot.floats(ints)` lifts a `list of int`; `plot.save($svg, path)` writes over
  `fs`. Bad input throws `Error{kind: "plot"}`. The visual companion to `stats` /
  `ml`, pure `.j` over `math` / `time` / `fs` / `strings` / `lists` / `convert`;
  **both binaries**.
- **`statsd`** - a fire-and-forget StatsD metrics client over UDP.
  `statsd.client(host)` (port 8125) / `clientWith(address, prefix)` open a `Client`
  (copies share the socket). Each verb sends one `[prefix.]name:value|type`
  datagram: `count(c, name, value)` / `increment` / `decrement` (counter),
  `gauge(c, name, value)` / `timing(c, name, ms)` / `set(c, name, value)`;
  `close(c)`. UDP means no reply and no error when no agent listens (metrics, not
  must-keep data). Extensions: `countRate` / `timingRate` (`|@rate`), `*Tagged`
  verbs (DogStatsD `|#k:v`), `countFloat` / `gaugeFloat`, and a value-semantic
  `Batch` (`batch` / `add*` / `flush`). Every line is control-character validated.
  **Default `jennifer` binary only** (`net`).
- **`orm`** - a relational mapper over the `sql` library. **Data Mapper**, not
  Active Record (structs have no methods). Declare an `orm.Schema`
  (`orm.schema(table, pk, dialect)` + `orm.column(s, name, kind)`, dialect
  `orm.Dialect.Mysql` / `Postgres`, kind `orm.ColumnKind.Int` / `String` /
  `Float` / `Bool` / `Bytes` - closed enums; fluent column attributes `orm.notNull`
  / `unique` / `autoIncrement` / `withDefault`), then CRUD through an `orm.Session`
  (`orm.session(conn)` / `orm.transaction(tx)`): `orm.insert` / `find` / `update`
  / `delete` / `all`. Records are `map of string to string`. Non-mutating
  **functional query builder** (each step returns a fresh `orm.Query`):
  `orm.from($schema)` -> `select` / `count` / `aggregate` -> `where` / `orWhere` /
  `whereIn` / `whereNotIn` / `whereNull` / `whereBetween` -> `join` / `leftJoin` /
  `rightJoin` -> `groupBy` + `having` -> `orderBy` / `limit` / `offset` / `page` ->
  `orm.toSql($q)` -> `Rendered{sql, params}` (placeholders per dialect). Identifiers
  / operators / join-kinds are allowlist-checked at build **and** render time, so a
  hand-built literal cannot inject. Plus DDL builders (`createTable` / `dropTable`
  / `addColumn` / `createIndex` / `addForeignKey` / ...); relations (`belongsTo` /
  `hasOne` / `hasMany` / `manyToMany` + `joinRelation`) with **eager loading**
  (`orm.with` marks a relation, `orm.load -> Result` fetches parents + relations in
  1 + R queries, walked by `rows` / `related` / `relatedOne`); and a write path
  (`upsert` / `insertMany` / `insertReturning` / `updateWhere` / `deleteWhere` /
  `save`) and finders (`first` / `exists` / `findBy` / `pluck`). Migrations are the
  separate `sqlmigrate` module. Needs the default binary.
- **`sqlmigrate`** - version-tracked schema migrations over the `sql` library,
  decoupled from `orm`: `sqlmigrate.Migration{version, description, up, down}` whose
  `up` / `down` are plain DDL strings. `sqlmigrate.migrate(conn, migrations)`
  applies pending versions in lexical order (each in its own transaction, recorded
  in `schema_migrations`; idempotent); `rollbackMigrations(conn, migrations, steps)`
  reverses the newest N; `migrationStatus(...)` -> `list of MigrationStatus`. Takes
  a raw `sql.Connection`. Version allowlisted + description escaped. Needs the
  default binary.
- **`password`** - generate, validate, and score passwords against a policy schema.
  `password.schema()` is a strong default (16 chars, all four classes, min 1 each);
  copy-on-write builders `withLength(s, lo, hi)` / `withClasses(...)` /
  `withMinimums(...)` / `withSymbolSet(s, chars)` / `withoutAmbiguous(s)` each return
  a fresh `Schema`. `generate(schema) -> string` (throws `Error{kind: "password"}`
  on an infeasible schema); `validate(schema, pw) -> Report{valid, reasons}` checks
  length + per-class minimums; `complexity(pw) -> Strength{length, classes,
  poolSize, entropy, label}` estimates bits (banded very weak .. very strong).
  Randomness is `crypto`-grade, so a generated password is safe as a real
  credential. Pure `.j` over `crypto` / `strings` / `convert`; **both binaries**.
- **`influxdb`** - an InfluxDB time-series client over `http`, both the 1.x and
  2.x / 3.x generation (a `Version` enum `{V1, V2}` on the `Client`; `write`
  dispatches, line protocol shared). `influxdb.client(url, db)` / `clientWith(url,
  db, user, password)` open a 1.x client; `client2(url, org, bucket, token)` a 2.x
  client (token redacted from errors). Build a `Point` value-semantically:
  `point(measurement)` then `tag` / `field(p, k, floatVal)` / `intField` /
  `stringField` / `boolField` / `at(p, unixNanos)` / `atTime(p, t)`. `line(p) ->
  string` renders one line-protocol line; `write(client, points)` posts a `list of
  Point` (throws `Error{kind: "influxdb"}` on failure). `query(client, influxql) ->
  Result{series}` parses the tabular JSON (each cell stringified); `queryFlux(client,
  flux)` runs a 2.x Flux query -> raw annotated-CSV. Over `http` + `json` + `time`
  + `encoding`. **Default `jennifer` binary only** (`net`).
- **`slack`** - post to a Slack Incoming Webhook over `http` (sibling of `gotify` /
  `discord`). `slack.send(webhookUrl, text)` posts a plain message. For a rich one,
  build a `Message` with `message()` then `text` / `section(m, markdown)` /
  `header` / `divider` / `contextBlock` / `fieldsSection(m, fields)` /
  `actionsBlock(m, buttons)` (+ `button(text, url)`; each returns a fresh
  `Message`), and post with `sendMessage(webhookUrl, m)` (`render(m)` gives the
  JSON). Text is JSON-escaped for you; both return the `http.Response`. Over `http`
  + `json`. **Default `jennifer` binary only** (`net`).
- **`discord`** - post to a Discord channel Webhook over `http` (sibling of
  `gotify` / `slack`). `discord.send(webhookUrl, content)` posts a plain message.
  For a rich one, build a `Message` with `message()` then `content(m, s)` /
  `embed(m, title, description, color)`, decorate the latest embed with
  `embedField(m, name, value, inline)` / `embedFooter` / `embedAuthor`, override
  identity with `username(m, name)` / `avatar(m, url)` (each returns a fresh
  `Message`), and post with `sendMessage(webhookUrl, m)` (`render(m)` gives the
  JSON). Text is JSON-escaped for you; both return the `http.Response`. Over `http`
  + `json`. **Default `jennifer` binary only** (`net`).
- **`telegram`** - a Telegram Bot API client over `http` + `json`.
  `telegram.bot(token)` (or `botWith(token, baseUrl)`) -> `Bot`. Send with
  `sendMessage(bot, chatId, text)` / `sendMessageWith(..., parseMode)` /
  `sendPhoto(bot, chatId, photo, caption)` / `sendChatAction`; `getMe(bot) -> User`
  checks the token. Each returns a parsed struct (`Message` has `messageId` /
  `chatId` / `text` / `date`); an API error throws `Error{kind: "telegram"}`.
  Receive with `getUpdates(bot, offset, timeout) -> list of Update` (long-poll) -
  the stateful loop advances `offset` to `updateId + 1` each pass (check
  `Update.hasMessage` first). `chatId` is a 64-bit `int`. Inline keyboards via
  `sendMessageWithKeyboard` + `parseCallbackQuery` / `answerCallbackQuery`; local
  uploads via `sendPhotoFile` / `sendDocumentFile`. Token redacted from errors.
  **Default `jennifer` binary only** (`net`).
- **`websocket`** - an RFC 6455 WebSocket client over `net`.
  `websocket.connect(url)` (or `connectWith(url, timeoutMs)`) does the HTTP Upgrade
  handshake to a `ws://` / `wss://` URL and verifies `Sec-WebSocket-Accept`,
  returning a `Conn`. `send(c, text)` / `sendBytes(c, data)` write masked frames;
  `receive(c) -> Message{kind, text, data}` (kind "text" / "binary" / "close" /
  "pong"; auto-answers a ping, reassembles fragments); `ping(c)` / `close(c)`. The
  mask + handshake nonce use `crypto`-grade random. A protocol error throws
  `Error{kind: "websocket"}`. Client only. **Default `jennifer` binary only**
  (`net`).
- **`amqp`** - an AMQP 0-9-1 client for RabbitMQ over `net`.
  `amqp.connect(amqp.options(host, user, password))` (tweak with `withPort` /
  `withVhost`) runs the full handshake and returns a `Conn`. `declareQueue(c, name,
  durable) -> QueueInfo{name, messageCount, consumerCount}` or `declareQuorumQueue`;
  `publish(c, exchange, routingKey, bytesBody)` / `publishText`; `get(c, queue,
  autoAck) -> Message{empty, deliveryTag, exchange, routingKey, body}` (loop until
  `empty`); `ack(c, deliveryTag)`; `close(c)`. Also server-pushed `Basic.Consume`
  via blocking `receiveDelivery`, `declareExchange` / `bindQueue`, `Properties` on
  publish, `nack` / requeue, and publisher confirms (`confirmSelect` /
  `waitConfirm`). Frames hand-built from `bytes` + bitwise ops. Single channel,
  SASL PLAIN, optional TLS (`Options.security = "tls"`). Throws `Error{kind:
  "amqp"}`. **Default `jennifer` binary only** (`net`).
- **`multipart`** - build and parse `multipart/form-data` (RFC 7578), the
  file-upload counterpart to `mime`. `multipart.field(name, value)` /
  `multipart.file(name, filename, contentType, dataBytes)` build `Part{name,
  filename, contentType, data}` values; `multipart.build(parts)` (fresh boundary) /
  `buildWith(parts, boundary)` -> `Built{contentType, body}` (POST it with header
  `Content-Type: contentType`); `multipart.parse(contentType, body) -> list of
  Part` reads it back (`text(part)` / `isFile(part)`). Bodies are `bytes`, so binary
  content round-trips intact. Pure `.j` over `strings` + `bytes`; **both binaries**.
- **`barcode`** - generate scannable barcodes / QR codes as images (the complement
  to `label`, which emits printer commands). `barcode.encode(data, symbology, opts)
  -> Symbol` encodes 2D `"qr"` (EC levels L/M/Q/H via `opts.ecLevel`, auto version
  1-40) and `"datamatrix"` (ECC200), plus 1D `"code128"` / `"code93"` / `"ean13"` /
  `"ean8"` / `"upca"` / `"upce"` / `"itf"` / `"code39"` / `"gs1-128"`. Render with
  `barcode.svg(sym, opts) -> string` / `png(sym, opts) -> bytes` (monochrome PNG
  over `compress` + `crc`) / `terminal(sym) -> string` (2D only) / `matrix(sym) ->
  list of list of bool`. `barcode.defaults()` gives an `Options` (scale / height /
  quiet / ecLevel / colours / humanReadable). The GF(256) / Reed-Solomon math is a
  private `include`d `barcode_ecc.inc.j`. Pure `.j`; **both binaries**.
- **`bloom`** - a Bloom filter (probabilistic set). `bloom.new(size, hashes) ->
  Filter` (or `bloom.optimal(n, fpr)` to size for a target false-positive rate);
  `bloom.add(f, item)` / `addAll` return a fresh filter (value-semantic, so `$f =
  bloom.add($f, x)`); `bloom.mightContain(f, item) -> bool` has no false negatives
  but possible false positives. `bloom.serialize(f)` / `deserialize(b)` round-trip;
  `bloom.union(a, b)` / `merge` combine same-shape filters. Strings only. Over
  `hash` + `strings` + `binary`; **both binaries**.
- **`ringbuffer`** - a fixed-capacity ring buffer of strings (bounded FIFO,
  overwrite-oldest when full). `ringbuffer.new(capacity) -> RingBuffer`;
  `ringbuffer.push(rb, item)` appends (dropping the oldest at capacity),
  `ringbuffer.pop(rb)` removes the oldest - both return a fresh buffer (value-semantic),
  so read the oldest with `ringbuffer.first(rb)` before you `pop` it (a value-semantic
  pop can't return both the item and the new buffer). Plus `last` / `size` / `capacity`
  / `isEmpty` / `isFull` / `toList` (oldest-first). Strings only. Over `lists`;
  **both binaries**.
- **`mikrotik`** - a MikroTik RouterOS API client over `net` (the binary API, not
  SSH). `mikrotik.connect(mikrotik.options(host, user, password))` (or `optionsTLS`
  for api-ssl on 8729) logs in (plaintext for RouterOS 6.43+/v7, MD5
  challenge-response fallback for older) -> `Session`. `talk(s, command, attrs) ->
  list of map of string to string` sends a command with `=key=value` attributes,
  folding each `!re` reply into a row map; `print(s, path)` is read sugar; `run(s,
  command, attrs) -> string` (add / set / remove) returns the `!done` `=ret=`.
  `talkQuery` / `printWhere` add raw `?...` query words to filter on the router.
  Also `.tag`-correlated commands and `/listen` streaming (`listen` /
  `receiveReply` / `cancel`). Sentence-based wire protocol hand-built from `bytes`
  + bitwise ops. A `!trap` / `!fatal` throws `Error{kind: "mikrotik"}`. Over `net`
  + `hash` + `encoding`. **Default `jennifer` binary only** (`net`).

Full per-module reference: the hosted
[module docs](https://jennifer-lang.dev/modules/index.html).

## Two complete programs

Hello, with a helper and a loop:

```jennifer
use io;

func fib(n as int) {
    if ($n < 2) { return $n; }
    return fib($n - 1) + fib($n - 2);
}

for (def i as int init 0; $i < 10; $i = $i + 1) {
    io.printf("fib(%d) = %d\n", $i, fib($i));
}
```

Structs, a list, and JSON:

```jennifer
use io;
use json;

def struct User {
    name as string,
    age as int
};

def users as list of User init [User{name: "ada", age: 36}, User{name: "bob", age: 41}];

for (def u in $users) {
    io.printf("%s is %d\n", $u.name, $u.age);
}

io.printf("%s\n", json.encode($users));   # [{"name":"ada","age":36},...]
```

## Common mistakes checklist (for the assistant)

- Referenced a variable without `$`? -> add it (`$x`, not `x`).
- Put `$` on a constant or a `def` name? -> remove it.
- Used `//` for a comment? -> that is floor division; use `#`.
- Expected `5 / 2` to be `2`? -> it is `2.5`; use `//`.
- Used `&&`/`||`/`!`? -> use `and`/`or`/`not`.
- Used a digit or `_` in a variable name? -> not allowed (only constants take
  `_`).
- Used `x += 1` or `x++`? -> write `$x = $x + 1;`.
- Called `int(x)` / `string(x)`? -> use `convert.toInt(x)` / `toString`.
- Read a map key that might be absent? -> guard with `maps.has($m, key)`.
- Forgot `use io;` before `io.printf`? -> every library must be imported.
- Expected a mutated copy to change the original? -> value semantics; it will
  not.
