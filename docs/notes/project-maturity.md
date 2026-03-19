# Project Maturity Plan

This document captures the current plan for turning this repository into a
well-established open source project. It is intentionally concise: enough
context to resume work after interruption, without turning into a second
roadmap.

## Goal

Move the repository from "good code with internal context" to a project that
is predictable and trustworthy to outside users and contributors.

That means:

- clear legal status,
- a strong project front door,
- organized docs,
- explicit contributor workflow,
- basic CI and security posture,
- sane release/versioning expectations,
- clear attribution for vendored test corpus and dependencies.

## Current State

The codebase already has meaningful internals, tests, corpus tooling, and some
docs. The main gaps are in the public-facing repository surface:

- no root `README.md`,
- no root `LICENSE`,
- no `.github/` contributor/community layer,
- `build.zig.zon` package paths do not yet include public repo metadata files,
- docs exist, but are topic-specific and not yet organized as a deliberate docs
  system.

## Reference Patterns

Reference projects used for direction:

- `ghostty`: strong GitHub/community/project settings layer
- `jj`: strong README and contributor-facing documentation surface
- `ziglang`: high-signal project structure and seriousness
- `http.zig`: a smaller Zig package with a simple but recognizable OSS shape
- `rust-lang/regex`: useful baseline for README, issue routing, CI, and security
- `google/re2`: useful baseline for project stance, guarantees, and sharp scope

We should copy patterns selectively, not cargo-cult every file.

## Phased Checklist

### Phase 1: Public Package Surface

- [x] Add root `README.md`
- [x] Add root `LICENSE`
- [x] Update `build.zig.zon` package paths to include public metadata files
- [x] Decide project status wording (`pre-1.0`, support expectations, scope)
- [x] Decide package/repo metadata to surface publicly

Chosen for Phase 1:

- dual `MIT` / `Apache-2.0`
- fuller README, not a minimal placeholder
- keep `build.zig.zon` at `0.0.0` until the first real public release
- public tags/releases are deferred until PikeVM supports the intended syntax
  surface

### Phase 2: Documentation Architecture

- [x] Add `docs/README.md` as the docs index
- [x] Keep official/stable docs easy to reach from `docs/`
- [x] Move fast-changing development notes under `docs/notes/`
- [x] Move or rename scattered docs into that structure
- [x] Decide what belongs in root README vs docs vs code doc comments

Current direction:

- `docs/` root for official user-facing docs
- `docs/notes/` for in-progress design and planning notes
- `docs/README.md` as the index that explains the distinction

Comparative notes from reference projects:

- `jj`: public docs are strongly user-oriented and split into stable categories
  such as install, tutorial, configuration, CLI reference, glossary, and FAQ.
  Contributor/process docs live separately from end-user docs.
- `ghostty`: user docs and project/community docs are clearly separated. The
  project has strong repo-level contributor files (`CONTRIBUTING`, packaging,
  policy), while user documentation is treated as its own surface.
- `Go` / `regexp`: API reference, examples, and syntax reference are treated as
  first-class docs. The package overview is concise; deeper reference material
  is separate.
- `rust-lang/regex`: the repo separates concerns well. The root README is a
  concise front door with guarantees, examples, and links deeper into the API.
  Richer material lives in crate docs (`src/lib.rs`) and companion crates such
  as `regex-automata`, `regex-syntax`, and `regex-test`.
- `google/re2`: the README stays narrow and principled. It explains the safety
  and complexity contract, states what is intentionally unsupported, and keeps
  the syntax/API/reference details elsewhere. It is a good model for a
  high-signal project front door.
- smaller Zig packages such as `http.zig` tend to stay README-heavy, with
  examples carrying much of the user guidance. This works for smaller surfaces
  but does not scale once the project has syntax matrices, corpus tooling, and
  multiple backends.

Likely doc categories for this repository:

- overview / project entrypoint
- supported syntax and behavioral guarantees
- testing and corpus workflow
- package usage / integration
- contributor/process docs (later)
- internal notes and design sketches

### Phase 3: Contributor and Community Layer

- [ ] Add `CONTRIBUTING.md`
- [ ] Add pull request template
- [ ] Add issue forms/templates
- [ ] Add discussion guidance
- [ ] Decide whether to adopt a code of conduct now

Decisions needed:

- lightweight vs detailed contributing guide
- code of conduct: none, light community guidelines, or standard CoC
- how much to formalize GitHub Discussions initially

### Phase 4: CI, Security, and Release Posture

- [x] Add GitHub Actions CI
- [x] Start with `zig build check` and `zig build test`
- [x] Decide platform coverage for CI
- [ ] Add `SECURITY.md` before first public release
- [x] Decide release/versioning policy
- [x] Decide changelog policy

Chosen so far:

- CI on Linux, macOS, and Windows
- CI steps start with `zig build check` and `zig build test`
- defer `CHANGELOG.md` until the first tagged release
- do not publish tags or formal semver releases until PikeVM supports the
  intended syntax surface
- defer `SECURITY.md` until just before the project is published

### Phase 5: Polish and Repo Operations

- [x] Add README badges
- [ ] Set repo description/topics/homepage
- [ ] Configure GitHub Discussions categories
- [ ] Configure labels and branch protection
- [ ] Add generated-files freshness check in CI
- [ ] Verify vendored corpus attribution and license visibility

Decisions needed:

- feedback channel before opening to PRs:
  - Discussions for questions/design/feedback, Issues for concrete bugs/tasks
  - Issues only
  - Discussions only
- exact repo description
- exact repo topics
- homepage target:
  - repo URL
  - docs root
  - no homepage yet
- which labels are worth creating early
- when to enable branch protection
- when to enforce generated-file freshness in CI
- how much GitHub automation to add early

Chosen so far:

- add README badges for CI and license only
- add repo description/topics/homepage as part of polish
- generated-files freshness check is deferred until later
- GitHub Pages is not needed yet

Recommended repo metadata:

- description: `Native Zig regular expression engine in the RE2 family.`
- topics:
  - `zig`
  - `regex`
  - `regular-expressions`
  - `re2`
  - `compiler`
  - `virtual-machine`
  - `text-processing`
- homepage: no homepage yet

Current recommendation:

- use Discussions as the primary channel for general feedback, design threads,
  and questions once public interaction is wanted
- keep Issues for concrete bugs, regressions, and actionable tracking items
- if the project remains effectively closed to outside collaboration for a
  while, it is reasonable to defer both Discussions and Issues templates until
  just before publishing

## Recommended Order

1. Public package surface
2. Docs architecture
3. Contributor/community layer
4. CI/security/release layer
5. Polish and repo operations

This order minimizes rewrite risk: it is better to settle the public project
shape and docs structure before writing detailed contributor/process docs.

## Immediate Next Step

Phase 5 polish:

- decide the initial GitHub feedback channel (`Discussions`, `Issues`, or both)
- choose repo description/topics/homepage
- add minimal README badges (`CI`, `license`)
- decide whether labels/branch protection should wait until publication
