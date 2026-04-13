# regex.zig

[![CI](https://github.com/quangd42/regex.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/quangd42/regex.zig/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](#license)

`regex.zig` provides a native regular expression engine for Zig in the RE2
family. It guarantees worst-case `O(m * n)` search time, where `m` is
proportional to the size of the regex and `n` is proportional to the size of
the input being searched. Certain Perl/PCRE features are omitted, most notably
backreferences and arbitrary lookahead or lookbehind assertions.

## Status

This project is pre-1.0. The library is already usable, but syntax coverage, compile flags,
API ergonomics, and performance features are still evolving quickly.

## Why

Zig does not yet have an established native regex engine. This is also a way to test
Zig's design and philosophy on a more serious project.

## What Works Today

The current implementation includes:

- a Pike VM execution engine
- literals, concatenation, alternation
- grouping and captures
- repetition operators (`?`, `*`, `+`, `{m}`, `{m,}`, `{m,n}`) including lazy forms
- Perl classes (`\d`, `\w`, `\s`) and bracket classes (including POSIX classes)
- assertions and boundaries (`^`, `$`, `\A`, `\z`, `\b`, `\B`)
- global flags via compile options (`Regex.compile(..., .{ .syntax = ... })`):
  - case-insensitive (`i`)
  - multi-line (`m`)
  - dot-matches-new-line (`s`)
  - swap-greed (`U`)
- leftmost-first search semantics

Support is ASCII only. The source-of-truth syntax/backend capability matrix is
in [tests/harness/capabilities.zig](tests/harness/capabilities.zig).

## Using the Package

Fetch the dependency:

```sh
zig fetch --save git+https://github.com/quangd42/regex.zig.git
```

Wire it into your `build.zig`:

```zig
const regex_dep = b.dependency("regex", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("regex", regex_dep.module("regex"));
```

The package name is `regex`, as declared in [build.zig.zon](build.zig.zon).

## Choosing the Query API

The three main search APIs do different amounts of work:

- `match()` answers only "does this regex match anywhere?" and is the cheapest query.
- `find()` returns the start/end of the leftmost match and tracks only group 0.
- `findCaptures()` returns subgroup locations and does the full capture-slot work.

If you only need a boolean, prefer `match()`. If you only need the match span,
prefer `find()`. Use `findCaptures()` only when you actually need subgroup
locations.

`findCaptures()` uses caller-managed storage. Use `captureCount()` to determine
the required buffer length, then either reuse a stack buffer or allocate a
`[]?Regex.Match` on the heap. The returned `Captures` value is a small view over
that buffer.

```zig
const n = re.captureCount();

if (n <= stack_buf.len) {
    var stack_buf: [8]?Regex.Match = undefined;
    const captures = try re.findCaptures(haystack, stack_buf[0..n])
    // use captures...
} else {
    const heap_buf = try gpa.alloc(?Regex.Match, n);
    defer gpa.free(heap_buf);
    const captures = try re.findCaptures(haystack, heap_buf);
    // use captures...
};
```

For unanchored searches, the engine also uses a small literal-prefix fast path
when the pattern begins with a required literal byte.

## Example

```zig
const std = @import("std");
const Regex = @import("regex");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var re = try Regex.compile(gpa, "(\\d\\d)/(\\d\\d)/(\\d\\d\\d\\d)", .{});
    defer re.deinit();

    if (re.find("date=03/18/2026")) |m| {
        std.debug.print("match at [{}, {})\n", .{ m.start, m.end });
    }
}
```

Inline flag syntax is not supported yet. For the currently supported global
flags, compile options let you set the equivalent top-level defaults you would
otherwise express with a leading inline flag such as `(?imsU)`:

```zig
const std = @import("std");
const Regex = @import("regex");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var re = try Regex.compile(gpa, "abc", .{
        .syntax = .{ .case_insensitive = true },
    });
    defer re.deinit();

    std.debug.assert(re.match("ABC"));
}
```

For more examples, see [src/main.zig](src/main.zig).

## Documentation

See:

- [docs/optimizations.md](docs/optimizations.md) for current compile-time and runtime optimizations
- [docs/supported-syntax.md](docs/supported-syntax.md) for the syntax support entrypoint
- [docs/testing.md](docs/testing.md) for the corpus/testing setup

## Acknowledgements

As this project is a RE2-family regex engine, Go's [`regexp` package](https://github.com/golang/go/tree/master/src/regexp)
and Rust's [`regex` repo](https://github.com/rust-lang/regex)
are frequently used as references, including but not limited to API design,
testing strategy, and general project structure.

## License

This project is available under either of:

- Apache License, Version 2.0, in [LICENSE-APACHE](LICENSE-APACHE)
- MIT license, in [LICENSE-MIT](LICENSE-MIT)

You may choose either license.
