# regex.zig

[![CI](https://github.com/quangd42/regex.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/quangd42/regex.zig/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](LICENSE)

`regex.zig` provides a native regular expression engine for Zig in the RE2
family. It guarantees a worst-case `O(m * n)` search time, where `m` is proportional
to the size of the regex and `n` is proportional to the size of the input being
searched. As such, it intentionally omits features that would compromise predictable
search behavior, such as look-around and backreferences.

## Status

This project is pre-1.0. The library is already usable, but syntax coverage, compile
flags, API ergonomics and performance features are still evolving quickly.

## Why

Zig does not yet have an established native regex engine. This is also a way to test
Zig's design and philosophy on a more serious project.

## What Works Today

The current implementation includes:

- a Pike VM execution engine
- literals, concatenation, alternation
- grouping and captures
- repetition operators
- Perl classes and bracket classes
- leftmost-first search semantics

Support is still incomplete. The current syntax and backend matrix is tracked in
[docs/supported-syntax.md](docs/supported-syntax.md).

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

For more examples, see [src/main.zig](src/main.zig).

## Documentation

See [docs/README.md](docs/README.md).

## License

This project is available under either of:

- Apache License, Version 2.0, in [LICENSE-APACHE](LICENSE-APACHE)
- MIT license, in [LICENSE-MIT](LICENSE-MIT)

You may choose either license.
