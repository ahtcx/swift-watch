# swift-watch

Rerun `swift build`, `swift run`, or `swift test` whenever your Swift package changes.

```sh
swift-watch run
```

Edit a file, and your executable is rebuilt and restarted.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ahtcx/swift-watch/main/install.sh | sh
```

Drops the latest binary in `~/.local/bin`. Run the same command again to update, and `rm ~/.local/bin/swift-watch` to uninstall.

If you use [mise](https://mise.jdx.dev): `mise use -g github:ahtcx/swift-watch`. Binaries are also on the [releases page](https://github.com/ahtcx/swift-watch/releases).

## Usage

Take any `swift build`, `swift run`, or `swift test` command and swap `swift` for `swift-watch`:

```sh
swift test --filter MyTests        # runs once
swift-watch test --filter MyTests  # runs on every change
```

Anything swift-watch doesn't recognize is forwarded straight through:

```sh
swift-watch run MyExecutable --flag value
swift-watch build --target MyLibrary
swift-watch test --parallel
```

Options:

- `--target <name>`, `--product <name>` (`build` only) — build just that module and watch only the files it depends on
- `--package-path <path>` — package to watch, default `.`
- `--watcher <name>` — file-watching backend: `fsevents` (macOS, default), `inotify` (Linux, default), `polling` (anywhere)
- `--debounce <ms>` — window for grouping rapid changes, default `300`
- `--poll-interval <ms>` — scan interval for the polling backend, default `150`
- `--swift-bin-dir <path>` — directory containing the `swift` executable to use, defaults to `swift` from `PATH`

Put `--target`/`--product` before any forwarded arguments. swift-watch can only scope the watch to flags it parses itself, and prints a warning if they land in the forwarded list instead.

## What gets watched

Exactly what your build depends on, nothing else:

- Sources of every target reachable from your package, discovered via `swift package describe` — including local `.package(path:)` dependencies, transitively. Unused targets in local dependencies (their test targets included) never trigger rebuilds.
- `Package.swift` and `Package.resolved` of every discovered local package. Manifest edits trigger rediscovery; plain source edits reuse the discovered graph.

Never watched: `.build`, `.git`, `.swiftpm`, hidden files and directories (SwiftPM never compiles them), and any `--scratch-path`/`--build-path`/`--cache-path` you forward — a build's own output can't retrigger it.

Watching starts before each build, so edits made while a build is running are picked up on the next cycle rather than lost.

## Plugin

Or skip installing and add it to your package:

```swift
dependencies: [
	.package(url: "https://github.com/ahtcx/swift-watch.git", from: "0.0.0")
]
```

```sh
swift package swift-watch build
swift package swift-watch run
```

SwiftPM will ask for permission to write to the package directory — pass `--allow-writing-to-package-directory` to skip the prompt.
