# Testing Guide

This document is the operational standard for tests in this repository.

## Layout

1. Unit/module tests stay close to implementation in `src/`.
2. Integration suites live under `tests/`.
3. Harness components live in `tests/harness/`:
   - `runner.zig`: suite loop, fail/skip reporting, filters.
   - `adapters.zig`: backend adapter dispatch and type-shape assertions.
   - `capabilities.zig`: capability enum (with doc comments) and backend support matrix.
   - `Config.zig`: env-based test filtering and verbosity controls.
   - prelude: `tests/harness.zig`.
4. End-to-end suites:
   - API integration: `tests/api_integration.zig`
   - Fowler suites: `tests/fowler/*.zig`
   - Future Rust corpus suites: `tests/rust-regex/`
   - Entrypoint: `tests/tests.zig` (wired by `build.zig`).
5. Corpus tooling and generated data:
   - Tools: `tools/tests/`
   - Generated Fowler suites: `tests/fowler/*.zig`
   - Fowler source TOML + licenses: `tests/fowler/data/`

## Test Writing Standards

1. Prefer readable expectations:
   - alias `expect` / `expectEqual` from `std.testing`,
   - avoid noisy casts when Zig can infer type.
2. Prefer table-driven cases with stable `name` fields.
3. For integration/corpus work, use harness `Case` + `runSuite`.
4. On new syntax/features:
   - add unit tests in parser/compiler/engine files first,
   - add at least one integration or corpus case,
   - gate unsupported behavior with capabilities, never silent pass.
5. Generated corpus cases intentionally omit baseline capabilities
   (`literal`, `escaped_literal`, `concat`, `capture_group`, leftmost semantics,
   and core `api_*` calls); harness enforces this baseline per backend at comptime.
6. Keep `src/Regex.zig` tests usage-oriented and small.

## Environment Controls

Harness filtering and diagnostics are configured by env vars:

1. `REGEX_SUITE=<substring>`
2. `REGEX_CASE=<exact-case-name>` or `<exact-suite-name>/<exact-case-name>`
3. `REGEX_MAX_FAILURES=<n>` (`n >= 1`)
4. `REGEX_VERBOSE=1|true|yes|on` (also supports false forms)
5. `REGEX_TRACE=1|true|yes|on`

Examples:

```sh
REGEX_SUITE=fowler REGEX_CASE=basic133 zig build test
REGEX_CASE=fowler_basic/basic133 REGEX_TRACE=1 zig build test
REGEX_VERBOSE=1 REGEX_MAX_FAILURES=5 zig build test
```

Generator examples:

```sh
zig build gen-tests -- all
zig build gen-tests -- fowler
```
