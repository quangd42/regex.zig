These files are taken from the Rust `regex` repository. As its Fowler README
notes, the test data was taken from the Go distribution, which was in turn
taken from the `testregex` test suite.

The LICENSE in this directory corresponds to the LICENSE that the data was
originally released under.

- Repository: https://github.com/rust-lang/regex
- Path: `testdata/fowler/`
- Commit: `d8761c00ed25c5899e3dcfb0f17e827b8e41530a`
- Retrieved: 2026-03-18

Usage:

- `zig build gen-tests -- fowler` reads these TOML files and generates
  Zig case tables under `tests/fowler/`.
