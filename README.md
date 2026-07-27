# swift-watch

Rerun `swift run`, `swift test`, or `swift build` whenever your Swift package changes. Edit a file, and your executable is rebuilt and restarted.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ahtcx/swift-watch/main/install.sh | sh
```

Downloads the latest binary to `~/.local/bin`. Run the same command again to update, and `rm ~/.local/bin/swift-watch` to uninstall.

If you use [mise](https://mise.jdx.dev): `mise use -g github:ahtcx/swift-watch`. Binaries are listed on the [releases page](https://github.com/ahtcx/swift-watch/releases).

## Usage

Take any `swift run`, `swift test`, or `swift build` command and swap `swift` for `swift-watch`:

```sh
swift test --filter MyTests # runs once
swift-watch test --filter MyTests # runs on every change
```

Anything swift-watch doesn't recognize is forwarded straight through:

```sh
swift-watch run MyExecutable --flag value
swift-watch build --target MyLibrary
swift-watch test --parallel
```

Pass swift-watch's own options first. Everything from the first argument it doesn't recognize onwards is forwarded untouched, so `swift-watch build --debounce 500 --configuration release` works while the reverse order sends `--debounce` to `swift build`.

Options:

- `--package-path <path>` — package to watch, default `.`
- `--watcher <name>` — file-watching backend: `fsevents` (macOS, default), `inotify` (Linux, default), `polling` (anywhere)
- `--debounce <ms>` — window for grouping rapid changes, default `300`
- `--poll-interval <ms>` — scan interval for the polling backend, default `150`
- `--swift-bin-dir <path>` — directory containing the `swift` executable to use, defaults to `swift` from `PATH`
- `--disable-rule <name>` — turn off one of the rules below, repeatable
- `--explain` — print which rule made each change count

Some forwarded flags are read on the way past. They are still forwarded unchanged — swift-watch only takes what it needs to watch the right files:

- `--scratch-path <path>`, `--build-path <path>`, `--cache-path <path>` — excluded from watching, so redirected build output cannot retrigger the loop
- `--build-system <name>` — used to find the matching planned-build manifest
- `--target <name>`, `--product <name>` (`build` only) — scope watching to that module's dependency closure

A name that resolves to nothing simply leaves the watch at its default breadth, which is the whole root package.

## What gets watched

Exactly what your build depends on, nothing else:

- Sources of every target reachable from your package, discovered via `swift package describe` — including local `.package(path:)` dependencies, transitively. Unused targets in local dependencies (their test targets included) never trigger rebuilds.
- Resources those targets declare, whatever their file type — including the non-Swift inputs a build tool plugin consumes, such as a directory of `.proto` files copied with `.copy("Protos")`. Everything inside a declared resource directory counts, since declaring it is the statement that its contents are build inputs.
- Whatever your build tool plugins actually read, taken from the build manifest SwiftPM writes when it plans a build. Plugins like grpc-swift's find their `.proto` files by scanning rather than through anything declared in `Package.swift`, and the planned build records the exact paths. A directory a plugin reads from is watched whole, so a new `.proto` — in that directory or a new subdirectory of it, and whatever its file type — rebuilds like an edit to an existing one. The cost is that an unrelated file dropped in there, a README say, rebuilds once too. A directory holding nothing but files the compiler itself consumes is your target's rather than a plugin's, so a note left beside a module's sources costs nothing; there, as in the target's own directory, a new file counts when its type is one the build already reads there. Because those inputs only exist once a build has been planned, the first build in a clean checkout is followed by one extra incremental build that picks them up. Cross-compiled builds are covered too: `--triple` and `--swift-sdk` are forwarded without being parsed, so the manifest they nest under a triple is found rather than computed.
- `Package.swift` and `Package.resolved` of every discovered local package. Manifest edits trigger rediscovery; plain source edits reuse the discovered graph.

A non-source file that is neither declared as a resource nor `exclude:`d, and that no build tool plugin reads, is not watched — that is the same state SwiftPM warns about with "found N file(s) which are unhandled", so declaring it fixes both at once.

### Build systems

Both build systems are read, because both plan through llbuild and record what they planned:

| `--build-system` | Read from |
| --- | --- |
| `native` (default) | `<scratch>/<configuration>.yaml` |
| `swiftbuild` | the newest `<scratch>/out/Intermediates.noindex/XCBuildData/<hash>.xcbuilddata/manifest.json` |

Swift Build writes a new hashed directory whenever the plan changes and leaves the old one behind, so the newest is the one that just ran. Forward a `--build-system` swift-watch has no reader for and it says so, then watches everything your manifest declares and nothing a plugin discovered for itself — declaring those inputs as target resources covers them under any build system.

These files are the build systems' own intermediate output rather than a public interface, so each reader names as little of the format as it can — the paths recorded as command inputs, and nothing else — and every failure is soft. A manifest that has not been written yet, or that is caught mid-write, leaves the watch graph exactly as `swift package describe` built it. One that exists but cannot be understood does the same and prints a warning once, since that is what a format changing underneath swift-watch would look like, and it would otherwise cost you plugin inputs in silence.

Never watched: `.build`, `.git`, `.swiftpm`, hidden files and directories (SwiftPM never compiles them), and any `--scratch-path`/`--build-path`/`--cache-path` you forward — a build's own output can't retrigger it.

Watching starts before each build, so edits made while a build is running are picked up on the next cycle rather than lost.

### Rules

Paths the build itself reported reading are always watched, and build output never is. Past that, four rules widen to files no build has read yet, so that adding one rebuilds instead of waiting for an unrelated edit. Each can be turned off with `--disable-rule <name>`:

| Rule | Widens to |
| --- | --- |
| `plugin-input-directories` | everything inside a directory a build tool plugin reads inputs from, at any depth — not directories holding only files the compiler consumes, which are the target's own |
| `plugin-input-extensions` | files among a target's sources whose type the build already reads there |
| `declared-resource-directories` | everything inside a directory declared as a target resource |
| `source-extensions` | files under a target's sources carrying a source extension |

`--explain` names the rule behind each rebuild, so a surprising one points at the flag that would stop it:

```
  Sources/App/Protos/README.md: plugin-input-directories (inside Sources/App/Protos, which the build reads inputs from)
```
