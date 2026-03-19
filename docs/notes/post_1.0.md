# Post-1.0: VM Layout Experiment (SoA vs Tagged Union)

This note captures a potential performance experiment: comparing a Structure-of-Arrays
layout (MultiArrayList/SoA) against a tagged-union state layout for the Thompson VM.
It includes the rationale, candidate layouts, and guidance for when/why to try it.

## Goal

Explore whether a SoA layout can outperform a tagged-union layout for the byte-oriented
Thompson VM, once the minimal engine is correct and stable.

## Context

- We plan to follow Rust's approach long-term: byte-oriented VM with Unicode support
  implemented by compiling Unicode classes into UTF-8 byte automata.
- For now, Unicode is out of scope, but the layout decision should not block it.

## Baseline: Tagged Union (Rust-style)

Conceptual Zig model:

```zig
const State = union(enum) {
    ByteRange: Transition,
    Sparse:    []Transition,
    Dense:     [256]StateID,
    Union:     []StateID,
    BinaryUnion: struct { alt1: StateID, alt2: StateID },
    Look:      struct { look: Look, next: StateID },
    Capture:   struct { next: StateID, slot: u32, pattern_id: u32, group_index: u32 },
    Match:     PatternID,
    Fail:      void,
};

const NFA = struct {
    states: []State,
    start_anchored: StateID,
    start_unanchored: StateID,
};
```

Example: literal `'a'` is `State::ByteRange` with `start=0x61`, `end=0x61`, `next=...`.

### Pros

- Opcode and payload live together (fewer cache misses in many cases).
- Simpler compiler and VM implementation.
- Easy to extend with new variants.

### Cons

- Larger per-state footprint.
- Potentially worse data locality for hot fields (depending on variant sizes).

## Candidate: SoA / MultiArrayList (opcode stream + payload tables)

Core idea: keep `opcodes[pc]` as a compact byte stream and store payloads in
separate arrays indexed by `pc` (or by spans into tables).

### Minimal SoA layout (byte-oriented)

```zig
const Op = enum(u8) {
    Char,
    Class,
    Split,
    Jump,
    Match,
    Fail,
};

const Program = struct {
    ops: []Op,

    // Payload arrays
    char_byte: []u8,           // valid when ops[pc] == .Char
    class_range_index: []u32,  // index into class_ranges table

    split_out1: []u32,
    split_out2: []u32,
    jump_out: []u32,

    // Class data
    class_ranges: []Range,
};
```

### SoA with packed payload tables (recommended if trying SoA)

Avoid pointers and per-state slices. Use indices/spans into compact tables.

```zig
const Program = struct {
    ops: []Op,

    // Common targets
    out1: []u32, // Split/Jump
    out2: []u32, // Split

    // Literal and class
    char_byte: []u8,
    class_span_start: []u32,
    class_span_len: []u16,

    // Tables
    class_ranges: []Range, // Range = { start: u8, end: u8 }
};
```

### Long-term SoA (covers future features)

```zig
const Op = enum(u8) {
    Char,
    ByteRange,
    Class,
    Split,
    Jump,
    Match,
    Fail,
    Look,
    Capture,
    Union,
    BinaryUnion,
    Dense,
};

const Program = struct {
    ops: []Op,

    // Hot payloads
    char_byte: []u8,
    br_start: []u8,
    br_end: []u8,
    br_next: []u32,

    split_out1: []u32,
    split_out2: []u32,
    jump_out: []u32,

    // Class payload
    class_span_start: []u32,
    class_span_len: []u16,
    class_next: []u32,

    // Cold payloads
    union_span_start: []u32,
    union_span_len: []u16,

    look_kind: []Look,
    look_next: []u32,

    capture_slot: []u32,
    capture_next: []u32,

    // Tables
    class_ranges: []Range,
    union_targets: []u32,
    dense_tables: []u32, // flattened [256] table per dense entry
    dense_index: []u32,
};
```

## Performance expectations

### Where SoA can win

- Opcode stream is tiny and cache-resident.
- Tight dispatch loop with predictable branches.
- Hot fields packed in dense arrays (minimal cache misses).

### Where SoA can lose

- Two+ loads per instruction: `ops[pc]` + payload arrays.
- Payload arrays can be far apart in memory.
- Variable-length data (class ranges, alternates) still needs indirection.

### Why tagged union may remain best

- Opcode and payload live together in one cache line.
- Simpler to implement and maintain.
- Often "fast enough" once literal/prefix optimizations are in.

## Recommendation

- Start with the tagged-union layout for correctness and velocity.
- Consider a SoA experiment only if profiling shows the VM dispatch loop is
  a real bottleneck.
- If experimenting, prefer a hybrid: keep hot ops in SoA and keep rare/complex
  ops in a tagged-union slow path.

## Benchmark sketch (future)

Compare tagged-union vs SoA using identical regex workloads:

- Literal-heavy: `foo`, `foobar`, `a|b|c`.
- Class-heavy: `\d+`, `[A-Za-z0-9_]+`.
- Alternation-heavy: `(foo|bar|baz|quux)+`.
- Mixed: `a(b|c)\d` on large inputs.

Measure: throughput (MB/s), allocations, cache misses if available.
