---
name: Bug report
about: Report incorrect regex parsing, compilation, or matching behavior
title: ''
labels: bug
assignees: ''
---

### Version

- `regex.zig` version, tag, or commit:
- Zig version:
- OS and architecture:

If this is not the latest commit, please check whether the bug still reproduces there.

### Reproduction

Please include the smallest pattern, haystack, compile options, and code needed to reproduce the issue.

```zig
const Regex = @import("regex");

// pattern:
// haystack:
// options:
```

If a minimal reproduction is difficult, describe what you tried and where the issue appears.

### Actual vs Expected

What happened, and what did you expect instead? Include compile errors, diagnostics, match spans, captures, or output.

If you are comparing with another regex implementation, please name it and include the equivalent pattern/options.

Add any other details that may matter, such as Unicode mode (`u`), case-insensitive mode (`i`), anchors, captures, or whether this came from a corpus/suite case.
