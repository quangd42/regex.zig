# Testing Guide

This document is the operational standard for tests in this repository.

## Layout

1. Unit/module tests stay close to implementation in `src/`.
2. Suite-backed conformance tests live under `tests/`.
3. Harness components live in `tests/harness/`:
   - `execute.zig`: case execution and corpus-specific fail/skip reporting.
   - `adapters.zig`: backend type dispatch and type-shape assertions.
   - `capabilities.zig`: capability enum (with doc comments) and backend support matrix.
   - prelude: `tests/harness.zig`.
4. End-to-end coverage:
   - Public API smoke tests: `tests/api_integration.zig`
   - Fowler suites: `tests/fowler/*.zig`
   - Future Rust suite files: `tests/rust-regex/`
   - Suite entrypoint: `tests/suite.zig`
   - Custom simple runner: `tests/test_runner.zig`
5. Corpus tooling and generated data:
   - Tools: `tools/tests/`
   - Generated Fowler suites: `tests/fowler/*.zig`
   - Fowler source TOML + licenses: `tests/fowler/data/`

## Test Writing Standards

1. Prefer readable expectations:
   - alias `expect` / `expectEqual` from `std.testing`,
   - avoid noisy casts when Zig can infer type.
2. Prefer table-driven cases with stable `name` fields.
3. For suite-backed work, use harness `Case` + `execute`.
4. On new syntax/features:
   - add unit tests in parser/compiler/engine files first,
   - add at least one integration or corpus case,
   - gate unsupported behavior with capabilities, never silent pass.
5. Generated corpus cases intentionally omit baseline capabilities
   (`literal`, `escaped_literal`, `concat`, `capture_group`, leftmost semantics,
   and core `api_*` calls); harness enforces this baseline per backend at comptime.
6. Keep `src/Regex.zig` tests usage-oriented and small.

## Build Steps

1. `zig build test`
   - runs all tests
2. `zig build test-unit`
   - runs unit/module tests rooted at `src/` plus public API smoke tests
3. `zig build test-suite`
   - runs suite-backed tests with the custom simple runner
   - accepts runtime runner args after `--`
4. `zig build test-bin`
   - builds the suite test binary for debugger use

## Suite Runner Args

Suite tests accept runtime args through the custom runner:

1. `--case=<exact-case-name>` or `--case <exact-case-name>`
2. `--trace`
3. `--verbose`

Filter matching details:

1. `--case=basic133` matches the exact last segment of a canonical corpus test name.
2. `--case=fowler/basic/basic133` matches the exact canonical corpus test name.
3. Unknown case names fail at runtime with an explicit runner error.

Examples:

```sh
zig build test
zig build test-unit
zig build test-suite
zig build test-suite -- --case=basic133 --trace
zig build test-suite -- --case=repetition35 --verbose
```

## Debugging Suite Cases

Use the stable suite test binary for debugger workflows:

```sh
zig build test-bin
```

This emits:

```sh
zig-out/bin/suite-tests
```

Launch it directly with runtime args:

```sh
./zig-out/bin/suite-tests --case=basic133 --trace
```

Notes:

1. The suite test binary uses `tests/test_runner.zig`.
2. `--trace` is useful for hard panics.
3. `--verbose` enables summary output.
4. Changing the selected case does not require a rebuild.

Zed is wired through `.zed/debug.json` to build `test-bin` and launch `suite-tests` with CodeLLDB.

## Generator Examples

```sh
zig build gen-tests -- all
zig build gen-tests -- fowler
```
