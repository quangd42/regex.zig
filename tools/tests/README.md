# TOML Test Generation

This tooling converts rust-regex's style `[[test]]` TOML files into generated
Zig tests under `tests/generated/`.

Files:

- generator entrypoint: `tools/tests/main.zig`
- generator implementation: `tools/tests/gen_toml_tests.zig`
- suite entrypoint: `tests/suite.zig`

The generator is configured by `SourceConfig` values. Each source declares:

- `command`
- `source_dir`
- `output_dir`
- `suite_prefix`
- `files`
- `matches_format`

For each file stem, the generator derives:

- source: `{source_dir}/{stem}.toml`
- output: `{output_dir}/{stem}.zig`
- suite name: `{suite_prefix}/{stem}`

`files` is explicit so generation order stays deterministic and new test files
files do not silently change the test matrix. Multiple `SourceConfig` values
may share the same command and directories when they need different
`matches_format` values.

Supported TOML fields:

- required: `name`, `regex`, `haystack`, `matches`
- optional: `match-limit`, `compiles`, `anchored`, `unescape`, `case-insensitive`, `multi-line`, `dot-matches-new-line`, `swap-greed`, `unicode`

`matches_format` chooses one TOML shape per source:

- `.matches`: `[[start, end]]`
- `.captures`: `[[[start, end], [start, end], []]]`

Both normalize to the harness's first-match capture view.

## Adding A New Source

1. Add a `.toml` file under `tests/data/`.

2. Add a `SourceConfig` in `tools/tests/gen_toml_tests.zig`. If local files use
   different `matches` shapes, split them into separate configs.

```zig
const local_matches: SourceConfig = .{
    .command = "local",
    .source_dir = "tests/data",
    .output_dir = "tests/generated",
    .suite_prefix = "local",
    .files = &.{ "flags-local" },
    .matches_format = .matches,
};
```

3. Hook it into `runAll()`. Add a dedicated run such as `runLocal()`/`zig build gen-tests -- local`
   if you want a dedicated local command.

4. Import the generated file in `tests/suite.zig`.

```zig
comptime {
    _ = @import("generated/flags-local.zig");
}
```

5. Regenerate and run the suite:

```sh
zig build gen-tests -- all
zig build test-suite
```

Notes:

- If a new TOML source needs fields not present in `ParsedCase`, extend the
  generator first.
- If it needs new execution semantics, update `tests/harness/` first.
