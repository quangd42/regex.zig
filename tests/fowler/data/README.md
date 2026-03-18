# Fowler Upstream Data

These files are vendored from Rust's `regex` repository:

- Repository: https://github.com/rust-lang/regex
- Path: `testdata/fowler/`
- Commit: `d8761c00ed25c5899e3dcfb0f17e827b8e41530a`
- Retrieved: 2026-03-18

Included upstream files:

- `basic.toml`
- `repetition.toml`
- `nullsubexpr.toml`
- `dat/`

License:

- Dual-licensed under MIT and Apache-2.0.
- See `LICENSE-MIT` and `LICENSE-APACHE` in this directory.

Transformation:

- `zig build gen-tests -- fowler` reads these TOML files and generates
  Zig case tables under `tests/fowler/`.
