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

- `--scratch-path <path>`, `--build-path <path>`, `--cache-path <path>` — excluded from watching, so redirected build output cannot retrigger the loop, and used to find the plan under a relocated build tree
- `--build-system <name>`, `-c`/`--configuration <name>` — used to find the matching planned-build manifest
- `--target <name>`, `--product <name>`, and the executable named to `run` — used to pick the plan's dependency closure out of a manifest broader than one invocation

No forwarded argument is reconstructed for a second SwiftPM command. The real
`build`, `test`, or `run` invocation receives the original argument vector, and
the plan it writes defines the watch graph. A name that matches nothing in the
plan leaves the watch at that plan's full breadth.

## What gets watched

What the exact invocation planned, plus narrow rules for files a later plan
would discover:

- Every file the compiler or another planned command reads. Target/product selection, destination, traits, configuration, resolver state, and other SwiftPM options are already reflected because this is the plan from the command that actually ran.
- Local `.package(path:)` dependencies that participated in that plan. Their roots are recovered from planned source paths, so unused dependency targets do not trigger rebuilds.
- Whatever build tool plugins actually read. Plugins like grpc-swift's can discover `.proto` files by scanning; the planned build records those paths. A directory a plugin reads from is watched whole, so a new file or subdirectory wakes the loop too. A directory holding nothing but compiler sources is widened only by the file types the build read there.
- Planned directory inputs, including resource directories, are watched recursively.
- Build tool plugins' own sources, under `--build-system native`. SwiftPM compiles plugins in a separate arena, so no command of the plan that consumes their output reads them — they are recognised instead as target directories the plan names but never reads from, and watched like any other target's sources. Not yet under `swiftbuild`, whose plan names no target directories; see the quirk below.
- `Package.swift` and an existing `Package.resolved` for the root and every inferred local package.

A non-source file that is neither declared as a resource nor `exclude:`d, and that no build tool plugin reads, is not watched — that is the same state SwiftPM warns about with "found N file(s) which are unhandled", so declaring it fixes both at once.

### Build systems

Both build systems are read, because both plan through llbuild and record what they planned:

| `--build-system` | Read from |
| --- | --- |
| `native` (default) | `<scratch>/<configuration>.yaml` |
| `swiftbuild` | the active `<scratch>/<arena>/Intermediates.noindex/XCBuildData/<hash>.xcbuilddata/manifest.json` |

The native manifest is a reusable full-package plan. Its target and command
graphs let swift-watch start from the target or product passed to the real
invocation and follow only that target's command dependency closure. It also
covers cross-compiled builds: `--triple` and `--swift-sdk` are forwarded without
being parsed, so the plan they nest under a triple is found rather than
computed.

Neither part of the Swift Build path is computed. The arena directory has been
spelled the target triple in 6.2 and `out` in 6.3, so it is found rather than
named — hardcoding one spelling loses the plan entirely on the other, which looks
exactly like a package that has not been built yet. Swift Build also
leaves hashed plans behind and may reuse an older one without touching it, so
the newest is not reliably the active one either. The
`build-request.json` beside each cached manifest is matched against the same
selection instead: SwiftPM configures either a whole-package aggregate, which is
what a bare invocation asks for and which records whether tests are in it, or
the named targets themselves, whose identifiers carry a hash swift-watch matches
by prefix rather than whole. The closest plan wins, a broader one beats one that
misses the selection, and recency only breaks ties. If no supported plan can be
read, swift-watch falls back to source-shaped files in the root package until a
later invocation produces one.

These files are the build systems' own intermediate output rather than a public interface, so each reader names as little of the format as it can: target roots, command inputs and outputs, directory nodes, and—for Swift Build—the configured targets in its build request. Every failure is soft. A manifest that is absent or caught mid-write uses the root-package fallback. One that exists but cannot be understood does the same and prints a warning once.

Failing soft is not the same as failing quietly, and the two failures that would otherwise be silent are handled by name. A selection that resolves to nothing widens rather than narrowing — notably `test`, where falling back to the plan's default target would leave the test files themselves unwatched, since the default is the one a bare `swift build` uses. And when nothing at all can be found where a build system is supposed to record, two invocations running with no plan ever read says so, because that is indistinguishable from a clean checkout until you are told.

Never watched: `.build`, `.git`, `.swiftpm`, hidden files and directories (SwiftPM never compiles them), and any `--scratch-path`/`--build-path`/`--cache-path` you forward — a build's own output can't retrigger it.

Only the directories the graph can match a change in are watched: the target
sources, plugin input and resource directories, and — read but not descended
into — the directories holding `Package.swift`, `Package.resolved`, and any
build input sitting outside a target. A `--target` build on this repository
watches 3 directories rather than the 16 in the package.

Watching starts once the plan is readable, because only that exact plan can define the graph — after the invocation returns for `build` and `test`, and partway through it for `run`, which builds and runs in one step. swift-watch records when the invocation began, starts the watcher, then scans the new graph for files modified in the gap, reaching a second further back to cover filesystems that stamp whole seconds. Any such edit causes an immediate follow-up cycle rather than being lost.

### Toolchain compatibility

`native` is read from Swift 6.0 onwards, and `swiftbuild` from wherever SwiftPM
offers it — 6.2 onwards, since 6.0 and 6.1 offer only `native` and `xcode`.
Every minor release through 6.3 was checked by building the same package with
that toolchain and running the readers over what it produced, on macOS arm64
throughout and Linux aarch64 on 6.1, 6.2 and 6.3.

Both formats moved within that range, and both are located rather than named for
exactly that reason — the quirks below are what that costs. Untested:
cross-compilation against a real SDK, and Windows. A build system with no
reader, `xcode` included, warns on startup and falls back to the root package.

Known quirks:

- Native target names embed the target triple, spelled `arm64-apple-macosx16.0`
  through 6.1, `arm64-apple-macosx26.0` in 6.2, and `arm64-apple-macosx` in 6.3.
  `--target` and `--product` are matched against the start of a target name
  rather than the whole of it, so all three resolve.
- Swift Build's build data sits under `<scratch>/<triple>/Intermediates.noindex/XCBuildData`
  in 6.2 and `<scratch>/out/Intermediates.noindex/XCBuildData` in 6.3. The
  directory is located on disk rather than computed, and a package carrying both
  layouts is read from both.
- A plan that cannot be found is indistinguishable from a package that has not
  been built yet. Two invocations with no plan read print a `no build plan has
  been read` warning naming the path searched.
- Build tool plugin sources appear in no command of the plan that consumes their
  output, because SwiftPM compiles plugins separately. Under `native` they are
  recovered as the target directories the plan names but never reads from. Swift
  Build's manifest names no such directories, so editing a plugin's own source
  does not yet rebuild under `swiftbuild`. The files a plugin *reads* are
  recorded there as usual, so this costs you nothing unless you are developing
  the plugin itself rather than using one.
  `<scratch>/plugins/cache/<name>-state.json` names those sources under both
  build systems and is the intended fix.
- The inotify backend takes one watch per directory in scope, so a narrow plan
  costs fewer watches than a broad one and the root-package fallback costs the
  whole tree. Under a low `fs.inotify.max_user_watches` registering one fails and
  swift-watch stops with `failed to watch <path>: No space left on device`, which
  is `ENOSPC` and not a full disk. Raise the limit or pass `--watcher polling`.
- Unchanged across every version tested: the manifest section layout, the
  `default` target, the `PackageStructure` command, and Swift Build's
  `ALL-EXCLUDING-TESTS`, `ALL-INCLUDING-TESTS` and `PACKAGE-TARGET:<name>-<hash>`
  target identifiers.

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
