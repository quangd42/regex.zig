# Testing Guide

This document is the operational standard for tests in this repository.

## Layout

1. Unit/module tests stay close to implementation in `src/`.
2. Suite-backed tests live under `tests/`.
   a. Public API integration tests: `tests/api_integration.zig`
   b. Harness support in `tests/harness.zig` + `tests/runner.zig`.
   c. Test suites: `tests/cases/*.zig`.
   d. Fowler test suites: `tests/fowler/*.zig`.

## Test Flow

1. Put parser/compiler/VM unit tests near the feature code in `src/`.
2. Put public API smoke tests in `tests/api_integration.zig`.
3. Put end-to-end feature test cases in `tests/cases/*.zig`.

## Test commands

1. `zig build test`: runs all tests
2. `zig build test-unit`: runs unit/module tests rooted at `src/` plus public API smoke tests
3. `zig build test-suite -- args`: runs suite-backed tests with the explicit suite runner
4. `zig build test-bin`: builds the suite test binary for debugger use

## Suite Runner Args

Suite tests accept runtime args through the explicit suite runner:

1. `--case=<exact-case-name>` or `--case <exact-case-name>`
   a. `--case=basic133` matches the exact test case name.
   b. `--case=fowler/basic/basic133` matches the exact test name in corpus.
   c. Otherwise reports a runtime error.
2. `--contains=<substring>` or `--contains <substring>`
   a. Matches a substring of the canonical `suite/case` test name.
   b. Ignored when `--case` is also provided.
3. `--trace`: useful for hard panics.
4. `--verbose`: enables per-case pass lines and summary output.

## Debugging Suite Cases

```sh
# Build suite test binary to use with debugger
zig build test-bin

# Launch it with runtime args:
./zig-out/bin/suite-tests --contains=restore --trace
```

Notes:

1. `.zed/debug.json` is set up to build `test-bin` and launch `suite-tests` with CodeLLDB.
