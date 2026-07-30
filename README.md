# swift-watch

Rerun `swift run`, `swift test`, or `swift build` whenever your Swift package changes. Edit a file, and your executable is rebuilt and restarted.

> [!WARNING]
> **Experimental.** Every release before v1 should be treated as such. This is not battle-tested yet: expect rough edges, and expect behaviour to change between releases.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ahtcx/swift-watch/main/install.sh | sh
```

Downloads the latest binary to `~/.local/bin`. Run it again to update, and `rm ~/.local/bin/swift-watch` to uninstall.

If you use [mise](https://mise.jdx.dev): `mise use -g github:ahtcx/swift-watch`. Binaries are on the [releases page](https://github.com/ahtcx/swift-watch/releases).

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

Pass swift-watch's own options first. Everything from the first unrecognized argument onwards is forwarded untouched, so `swift-watch build --debounce 500 --configuration release` works while the reverse order sends `--debounce` to `swift build`.

Options:

- `--package-path <path>` — package to watch, default `.`
- `--watcher <name>` — file-watching backend: `fsevents` (macOS, default), `inotify` (Linux, default), `polling` (anywhere)
- `--debounce <ms>` — window for grouping rapid changes, default `300`
- `--poll-interval <ms>` — scan interval for the polling backend, default `150`
- `--swift-bin-dir <path>` — directory containing the `swift` executable to use, defaults to `swift` from `PATH`
- `--disable-rule <name>` — turn off one of the rules below, repeatable
- `--explain` — print which rule made each change count

Some forwarded flags are read on the way past. They are still forwarded unchanged — swift-watch only takes what it needs to watch the right files:

- `--scratch-path <path>`, `--build-path <path>`, `--cache-path <path>` — excluded from watching, so redirected build output cannot retrigger the loop, and used to find the plan under a relocated build tree
- `--build-system <name>`, `-c`/`--configuration <name>` — used to find the matching planned-build manifest
- `--target <name>`, `--product <name>`, and the executable named to `run` — used to pick the plan's dependency closure out of a manifest broader than one invocation

No forwarded argument is reconstructed for a second SwiftPM command. The real `build`, `test`, or `run` invocation receives the original argument vector, and the plan it writes defines the watch graph. A name matching nothing in the plan leaves the watch at that plan's full breadth.

## What gets watched

What the exact invocation planned, plus narrow rules for files a later plan would discover:

- Every file the compiler or another planned command reads. Target and product selection, destination, traits, configuration and resolver state are already reflected, because this is the plan from the command that actually ran.
- Local `.package(path:)` dependencies that took part in that plan. Their roots come from planned source paths, so unused dependency targets do not trigger rebuilds.
- Whatever build tool plugins read. Plugins like grpc-swift's discover `.proto` files by scanning, and the plan records what they read. A directory a plugin reads from is watched whole, so a new file or subdirectory wakes the loop too; a directory holding nothing but compiler sources is widened only by the file types the build read there.
- Planned directory inputs, including resource directories, recursively.
- Build tool plugins' own sources, under `--build-system native`. SwiftPM compiles plugins in a separate arena, so no command of the plan reads them; they are recovered as target directories the plan names but never reads from. Not yet under `swiftbuild` — see the quirks below.
- `Package.swift` and an existing `Package.resolved`, for the root and every inferred local package.

A non-source file that is neither declared as a resource nor `exclude:`d, and that no build tool plugin reads, is not watched. That is the same state SwiftPM warns about with "found N file(s) which are unhandled", so declaring it fixes both at once.

### Build systems

Both build systems are read, because both plan through llbuild and record what they planned:

| `--build-system` | Read from |
| --- | --- |
| `native` (default) | `<scratch>/<configuration>.yaml` |
| `swiftbuild` | the active `<scratch>/<arena>/Intermediates.noindex/XCBuildData/<hash>.xcbuilddata/manifest.json` |

The native manifest is a reusable full-package plan. Its target and command graphs let swift-watch start from the target or product passed to the real invocation and follow only that target's command closure. It also covers cross-compiled builds: `--triple` and `--swift-sdk` are forwarded without being parsed, so the plan nested under a triple is found rather than computed.

Nothing on the Swift Build path is computed either. The arena directory has been spelled the target triple in 6.2 and `out` in 6.3, and hashed plans accumulate with older ones sometimes reused, so neither the path nor the newest file identifies the active plan. The `build-request.json` beside each cached manifest is matched against the same selection instead: the closest plan wins, a broader one beats one that misses the selection, and recency only breaks ties.

These files are the build systems' own intermediate output rather than a public interface, so each reader names as little of the format as it can and every failure is soft:

- A manifest that is absent or caught mid-write falls back to source-shaped files in the root package.
- One that exists but cannot be understood does the same, and warns once.
- Two invocations with no plan read at all also warn, since that is otherwise indistinguishable from a clean checkout.
- A selection resolving to nothing widens rather than narrows — notably for `test`, where falling back to the plan's default target would leave the test files themselves unwatched.

Never watched: `.build`, `.git`, `.swiftpm`, hidden files and directories (SwiftPM never compiles them), and any `--scratch-path`/`--build-path`/`--cache-path` you forward — a build's own output can't retrigger it.

Only the directories the graph can match a change in are watched: target sources, plugin input and resource directories, and — read but not descended into — the directories holding `Package.swift`, `Package.resolved`, and any build input sitting outside a target. A `--target` build on this repository watches 3 directories rather than the 16 in the package.

Watching starts once the plan is readable, because only that exact plan can define the graph — after the invocation returns for `build` and `test`, partway through it for `run`, which builds and runs in one step. swift-watch records when the invocation began, starts the watcher, then scans the new graph for files modified in the gap, reaching a second further back to cover filesystems that stamp whole seconds. Any such edit causes an immediate follow-up cycle rather than being lost. `Package.swift` and `Package.resolved` are reconciled against the plan's own timestamp instead, since SwiftPM writes the lockfile while planning and that write is already part of the plan.

### Toolchain compatibility

`native` is read from Swift 6.0 onwards, and `swiftbuild` from 6.2, since 6.0 and 6.1 offer only `native` and `xcode`. Every minor release through 6.3 was checked by building the same package with that toolchain and running the readers over what it produced — macOS arm64 throughout, Linux aarch64 on 6.1, 6.2 and 6.3. Untested: cross-compilation against a real SDK, and Windows. A build system with no reader, `xcode` included, warns on startup and falls back to the root package.

Known quirks:

- Editing a build tool plugin's own sources does not rebuild under `swiftbuild`, whose manifest names no target directories. The files a plugin *reads* are recorded as usual, so this costs you nothing unless you are developing the plugin itself. `<scratch>/plugins/cache/<name>-state.json` names those sources under both build systems and is the intended fix.
- The inotify backend takes one watch per directory in scope, so a narrow plan costs fewer watches than the root-package fallback. Under a low `fs.inotify.max_user_watches` registering one fails and swift-watch stops with `failed to watch <path>: No space left on device`, which is `ENOSPC` and not a full disk. Raise the limit or pass `--watcher polling`.
- A plan that cannot be found is indistinguishable from a package that has not been built yet. After two invocations with no plan read, swift-watch prints a `no build plan has been read` warning naming the path it searched.

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
