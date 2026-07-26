# swift-watch

Rerun `swift build` or `swift run` whenever your Swift package changes.

```sh
swift-watch run
```

Edit a file, and your executable is rebuilt and restarted.

## Usage

```sh
swift-watch build [options] [swift build args...]
swift-watch run [options] [swift run args...]
```

Anything swift-watch doesn't recognize is forwarded to `swift build` / `swift run`:

```sh
swift-watch build --configuration release
swift-watch run MyExecutable --flag value
swift-watch build --target MyLibrary
swift-watch run --package-path path/to/package
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

The package also ships a SwiftPM command plugin:

```sh
swift package swift-watch build
swift package swift-watch run
```
