# AGENTS.md

Repo-specific guidance for automated agents working in this repository.

## Scope

This repository contains the standalone `swift-watch` tool, its optional SwiftPM plugin, platform-specific watcher backends, tests, and GitHub Actions workflows.

## Working conventions

- Keep the standalone CLI as the primary product. Do not couple core behavior to SwiftPM internals.
- Prefer public SwiftPM CLI surfaces such as `swift package describe --type json` over SwiftPM library APIs.
- Preserve the current modular split:
  - `SwiftWatch` for shared core logic
  - `SwiftWatchPolling`, `SwiftWatchFSEvents`, and `SwiftWatchInotify` for backend-specific logic
  - `SwiftWatchRuntime` for loop orchestration
  - `swift-watch` for CLI wiring
- Prefer typed throws with `SwiftWatchError` where the code owns the error boundary.
- Keep unsafe and C interop isolated to dedicated backend interop files where possible.

## Platform and compatibility expectations

- The package currently requires `.macOS(.v13)` because the implementation uses `Duration` and related async APIs with that availability floor.
- Linux support is expected through the inotify backend.
- Polling remains the portable fallback.

Do not remove or lower the macOS 13 floor without first refactoring the time/sleep abstractions away from the current `Duration`-based design.

## Formatting

- Use `swift format`, not `swiftformat`.
- Respect the repository formatting configuration in `.swift-format`.
- Tabs are required.

Recommended command:

```sh
mise run format
```

## Validation

Before finishing substantial changes, prefer:

```sh
mise run test
```

If the change affects Linux-specific behavior, also run a Linux validation path, for example via Docker.

## CI notes

- CI workflows live in `.github/workflows/`.
- The shared platform matrix lives in `.github/platform-matrix.json`. Keep CI and release workflows reading from that file instead of duplicating runner lists.
- The toolchain is installed with `jdx/mise-action`, driven by `mise.toml`.
- The matrix covers `ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-26`, and `macos-15-intel`. Runner labels are pinned deliberately — do not switch them back to `-latest` aliases. The arm64 Linux runner requires the repository to be public. The Intel macOS runner label is supported by GitHub until August 2027.
- The release workflow is tag-driven and lives in `.github/workflows/release.yml`.
- Release assets are built with a matrix job, then attached to a draft GitHub Release before publication.
- Current release assets are plain executable files.

## Tasks

Repository automation lives in `mise.toml` as inline tasks, not in shell scripts. Run `mise tasks ls` to see them. Prefer adding a task over adding a file under `scripts/`.
Platform-specific task overrides live in `mise.linux.toml` and `mise.macos.toml`. The repository enables `auto_env = true` in `.miserc.toml`, so mise loads the appropriate override automatically.
