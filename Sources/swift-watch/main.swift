import ArgumentParser
import SwiftWatch
import SwiftWatchPolling
import SwiftWatchRuntime

import class Foundation.FileHandle

#if canImport(SwiftWatchFSEvents)
	import SwiftWatchFSEvents
#endif

#if canImport(SwiftWatchInotify)
	import SwiftWatchInotify
#endif

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

struct CommonOptions: ParsableArguments {
	@Option(help: "Debounce window for file changes in milliseconds.")
	var debounce: Int = 300

	@Option(help: "Interval between scans for the polling watcher, in milliseconds.")
	var pollInterval: Int = 150

	@Option(
		help:
			"Watcher implementation to use. Available: \(Self.availableWatcherNames.joined(separator: ", "))."
	)
	var watcher: String?

	@Option(
		help:
			"Directory containing the swift executable to invoke. By default, swift-watch resolves `swift` from PATH."
	)
	var swiftBinDir: String?

	@Option(help: "Path to the package to watch.")
	var packagePath: String = "."

	@Option(
		name: .customLong("disable-rule"),
		help:
			"Turn off a rule for judging changes, repeatable. Available: \(WatchRules.allNames.joined(separator: ", ")). Paths the build itself reports reading are always watched."
	)
	var disabledRules: [String] = []

	@Flag(help: "Report which rule made each change count.")
	var explain: Bool = false

	func validate() throws {
		guard debounce >= 0 else {
			throw ValidationError("--debounce must not be negative.")
		}
		guard pollInterval > 0 else {
			throw ValidationError("--poll-interval must be greater than zero.")
		}
		for name in disabledRules where WatchRules(name: name) == nil {
			throw ValidationError(
				"Unknown rule '\(name)'. Available: \(WatchRules.allNames.joined(separator: ", "))."
			)
		}
	}

	func executionOptions() -> ExecutionOptions {
		// Every name is spellable by the time this runs: `validate()` rejects
		// the ones that are not.
		let rules = disabledRules.compactMap(WatchRules.init(name:))
			.reduce(into: WatchRules.default) { $0.remove($1) }
		return ExecutionOptions(
			debounceMilliseconds: debounce,
			pollIntervalMilliseconds: pollInterval,
			watcherName: watcher,
			swiftBinDirectory: swiftBinDir.map {
				URL(fileURLWithPath: $0, isDirectory: true)
			},
			packagePath: URL(fileURLWithPath: packagePath, isDirectory: true),
			rules: rules,
			explain: explain
		)
	}

	/// The platform's native watcher, where it has one.
	///
	/// Conditioned on the operating system, not on `canImport`: both backend
	/// modules exist on every platform and compile to nothing off theirs, so a
	/// build that happens to have one in scope — a test build, which builds
	/// every target — would otherwise select a watcher that isn't there.
	#if os(macOS)
		private static let nativeWatchers: [FileWatcherImplementation] = [.fsevents]
	#elseif os(Linux)
		private static let nativeWatchers: [FileWatcherImplementation] = [.inotify]
	#else
		private static let nativeWatchers: [FileWatcherImplementation] = []
	#endif

	/// Polling runs anywhere and claims no default, so it is the fallback both
	/// when a platform has no native watcher and when the caller names none.
	fileprivate static let supportedWatcherImplementations: [FileWatcherImplementation] =
		nativeWatchers + [.polling]

	fileprivate static let availableWatcherNames =
		supportedWatcherImplementations
		.map(\.name)
		.sorted()

	/// Built on demand so a misconfigured registry surfaces as a diagnostic
	/// rather than a trap during static initialisation.
	fileprivate static func makeWatcherRegistry() throws(SwiftWatchError)
		-> FileWatcherRegistry
	{
		try FileWatcherRegistry(implementations: supportedWatcherImplementations)
	}
}

@main
struct SwiftWatchCommand: AsyncParsableCommand {
	static let configuration = CommandConfiguration(
		commandName: "swift-watch",
		abstract: "Watch Swift packages and rerun build, run, or test when inputs change.",
		subcommands: [Build.self, Run.self, Test.self]
	)
}

extension SwiftWatchCommand {
	struct Build: AsyncParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Run `swift build` in a watch loop.",
			discussion: """
				Pass swift-watch's own options before any argument meant for \
				`swift build`: everything from the first unrecognized argument \
				onwards is forwarded untouched.

				The exact plan written by that invocation defines what is watched. \
				Forwarded --scratch-path, --build-path, and --cache-path are \
				excluded so build output cannot retrigger the loop.
				"""
		)

		@OptionGroup var options: CommonOptions

		@Argument(
			parsing: .captureForPassthrough,
			help: "Arguments forwarded to `swift build`.")
		var swiftArgs: [String] = []

		mutating func run() async throws {
			try exitIfHelpRequested(swiftArgs, for: self)
			let registry = try CommonOptions.makeWatcherRegistry()
			var executionOptions = options.executionOptions()
			let forwarded = normalizedPassthrough(self.swiftArgs)
			executionOptions.selection = forwardedBuildSelection(in: forwarded)
			executionOptions.excludedPaths = resolvedDirectoryOverrides(
				in: forwarded,
				stopAtFirstPositional: false,
				packagePath: executionOptions.packagePath
			)
			executionOptions.buildManifest = resolvedBuildManifest(
				in: forwarded,
				stopAtFirstPositional: false,
				packagePath: executionOptions.packagePath
			)
			warnAboutForwardedBuildSystem(in: forwarded, stopAtFirstPositional: false)
			let options = executionOptions
			try await runUntilInterrupted {
				try await WatchController(watcherRegistry: registry)
					.runBuildLoop(
						options: options,
						swiftArgs: forwarded
					)
			}
		}
	}

	struct Test: AsyncParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Run `swift test` in a watch loop."
		)

		@OptionGroup var options: CommonOptions
		@Argument(
			parsing: .captureForPassthrough,
			help: "Arguments forwarded to `swift test`.")
		var swiftArgs: [String] = []

		mutating func run() async throws {
			try exitIfHelpRequested(swiftArgs, for: self)
			let registry = try CommonOptions.makeWatcherRegistry()
			var executionOptions = options.executionOptions()
			executionOptions.selection = WatchSelection(action: .test)
			let swiftArgs = normalizedPassthrough(self.swiftArgs)
			// `swift test` takes no user-supplied executable, so every
			// argument is safe to scan for redirected build output.
			executionOptions.excludedPaths = resolvedDirectoryOverrides(
				in: swiftArgs,
				stopAtFirstPositional: false,
				packagePath: executionOptions.packagePath
			)
			executionOptions.buildManifest = resolvedBuildManifest(
				in: swiftArgs,
				stopAtFirstPositional: false,
				packagePath: executionOptions.packagePath
			)
			warnAboutForwardedBuildSystem(in: swiftArgs, stopAtFirstPositional: false)
			let options = executionOptions
			try await runUntilInterrupted {
				try await WatchController(watcherRegistry: registry)
					.runTestLoop(
						options: options,
						swiftArgs: swiftArgs
					)
			}
		}
	}

	struct Run: AsyncParsableCommand {
		static let configuration = CommandConfiguration(
			abstract: "Run `swift run` in a watch loop."
		)

		@OptionGroup var options: CommonOptions
		@Argument(
			parsing: .captureForPassthrough, help: "Arguments forwarded to `swift run`."
		)
		var swiftArgs: [String] = []

		mutating func run() async throws {
			try exitIfHelpRequested(swiftArgs, for: self)
			let registry = try CommonOptions.makeWatcherRegistry()
			var executionOptions = options.executionOptions()
			let swiftArgs = normalizedPassthrough(self.swiftArgs)
			let invocation = forwardedRunInvocation(in: swiftArgs)
			executionOptions.selection = WatchSelection(
				action: .run,
				names: invocation.executable.map { [$0] } ?? [])
			executionOptions.excludedPaths = resolvedDirectoryOverrides(
				in: invocation.optionArguments,
				stopAtFirstPositional: false,
				packagePath: executionOptions.packagePath
			)
			executionOptions.buildManifest = resolvedBuildManifest(
				in: invocation.optionArguments,
				stopAtFirstPositional: false,
				packagePath: executionOptions.packagePath
			)
			warnAboutForwardedBuildSystem(
				in: invocation.optionArguments,
				stopAtFirstPositional: false)
			let options = executionOptions
			try await runUntilInterrupted {
				try await WatchController(watcherRegistry: registry)
					.runRunLoop(
						options: options,
						swiftArgs: swiftArgs
					)
			}
		}
	}
}

func forwardedBuildSelection(in args: [String]) -> WatchSelection {
	WatchSelection(
		action: .build,
		names: ["--target", "--product"].compactMap { flag in
			forwardedFlagValue(
				of: [flag], in: args,
				stopAtFirstPositional: false)
		})
}

struct ForwardedRunInvocation: Equatable {
	let optionArguments: [String]
	let executable: String?
}

/// Splits SwiftPM's options from `swift run`'s executable and its arguments.
///
/// Values belonging to SwiftPM options are skipped even when they look
/// positional or flag-shaped. Once the executable is found, everything after
/// it belongs to that executable. An option this version does not understand
/// leaves the selection broad instead of risking narrowing to the option's
/// value.
func forwardedRunInvocation(in args: [String]) -> ForwardedRunInvocation {
	var index = 0
	while index < args.count {
		let argument = args[index]
		if argument == "--" {
			let executableIndex = index + 1
			return ForwardedRunInvocation(
				optionArguments: Array(args[..<index]),
				executable: executableIndex < args.count
					? args[executableIndex] : nil)
		}
		if !argument.hasPrefix("-") {
			return ForwardedRunInvocation(
				optionArguments: Array(args[..<index]),
				executable: argument)
		}
		if SelfClosingRunOptions.names.contains(argument) {
			index += 1
			continue
		}
		if RunValueOptions.names.contains(argument) {
			guard index + 1 < args.count else {
				return ForwardedRunInvocation(
					optionArguments: args, executable: nil)
			}
			index += 2
			continue
		}
		if let equals = argument.firstIndex(of: "="),
			RunValueOptions.names.contains(String(argument[..<equals]))
		{
			index += 1
			continue
		}
		return ForwardedRunInvocation(
			optionArguments: Array(args[..<index]),
			executable: nil)
	}
	return ForwardedRunInvocation(optionArguments: args, executable: nil)
}

private enum RunValueOptions {
	static let names: Set<String> = [
		"--package-path", "--cache-path", "--config-path", "--security-path",
		"--scratch-path", "--swift-sdks-path", "--toolset", "--pkg-config-path",
		"--manifest-cache", "--netrc-file", "--resolver-fingerprint-checking",
		"--resolver-signing-entity-checking", "--default-registry-url",
		"-c", "--configuration", "-Xcc", "-Xswiftc", "-Xlinker", "-Xcxx",
		"--triple", "--sdk", "--toolchain", "--swift-sdk", "--sanitize",
		"-j", "--jobs", "--explicit-target-dependency-import-check",
		"--build-system", "-debug-info-format", "--traits",
	]
}

private enum SelfClosingRunOptions {
	static let names: Set<String> = [
		"-v", "--verbose", "--very-verbose", "--vv", "-q", "--quiet",
		"--enable-dependency-cache", "--disable-dependency-cache",
		"--enable-build-manifest-caching", "--disable-build-manifest-caching",
		"--enable-experimental-prebuilts", "--disable-experimental-prebuilts",
		"--color-diagnostics", "--no-color-diagnostics", "--disable-sandbox",
		"--netrc", "--enable-netrc", "--disable-netrc", "--enable-keychain",
		"--disable-keychain", "--enable-signature-validation",
		"--disable-signature-validation", "--enable-prefetching",
		"--disable-prefetching", "--force-resolved-versions",
		"--disable-automatic-resolution", "--only-use-versions-from-resolved-file",
		"--skip-update", "--disable-scm-to-registry-transformation",
		"--use-registry-identity-for-scm", "--replace-scm-with-registry",
		"--auto-index-store", "--enable-index-store", "--disable-index-store",
		"--enable-parseable-module-interfaces", "--use-integrated-swift-driver",
		"--enable-dead-strip", "--disable-dead-strip", "--disable-local-rpath",
		"--enable-all-traits", "--disable-default-traits", "--repl", "--debugger",
		"--run", "--skip-build", "--build-tests", "--version",
		"-h", "-help", "--help",
	]
}

/// `captureForPassthrough` swallows `--help` before ArgumentParser can act on
/// it, which would otherwise start a watch loop instead of printing help.
///
/// Only a leading help flag is claimed. Anything later belongs to the command
/// being wrapped — `swift-watch run MyExecutable --help` asks the executable
/// for its help — and an explicit `--` separator forwards it as well.
func exitIfHelpRequested(_ args: [String], for command: some ParsableCommand) throws {
	guard args.first == "--help" || args.first == "-h" else {
		return
	}
	throw CleanExit.helpRequest(command)
}

/// `captureForPassthrough` keeps a leading `--` separator in the captured
/// arguments. `swift build` takes no positionals, so forwarding the separator
/// would make it reject everything after it.
func normalizedPassthrough(_ args: [String]) -> [String] {
	args.first == "--" ? Array(args.dropFirst()) : args
}

/// Directory-redirect values found in forwarded arguments (`--scratch-path`
/// and friends). The resulting trees are build output and must be excluded
/// from watching, or every build's own writes would be scanned and could
/// look like changes.
///
/// With `stopAtFirstPositional`, scanning ends at the first argument that is
/// not flag-shaped: for `swift run` that is the executable name, and
/// anything after it belongs to the launched executable, where the same
/// spelling must not be misread. A flag value can end the scan early, which
/// only means a forwarded redirect goes unexcluded — never that a wrong
/// directory gets excluded.
func forwardedDirectoryOverrides(
	in args: [String], stopAtFirstPositional: Bool
) -> [String] {
	forwardedFlagValues(
		of: ["--scratch-path", "--build-path", "--cache-path"],
		in: args,
		stopAtFirstPositional: stopAtFirstPositional
	)
}

/// Every value forwarded for any of `flags`, in either the `--flag value` or
/// `--flag=value` spelling, in the order they appear.
func forwardedFlagValues(
	of flags: [String], in args: [String], stopAtFirstPositional: Bool
) -> [String] {
	var values: [String] = []
	var index = 0
	while index < args.count {
		let arg = args[index]
		if flags.contains(arg) {
			if index + 1 < args.count {
				values.append(args[index + 1])
				index += 2
				continue
			}
		} else if let flag = flags.first(where: { arg.hasPrefix($0 + "=") }) {
			values.append(String(arg.dropFirst(flag.count + 1)))
		} else if stopAtFirstPositional, !arg.hasPrefix("-") {
			break
		}
		index += 1
	}
	return values
}

/// Resolves forwarded directory overrides the way the `swift` invocation
/// will: relative to the package path it runs in.
private func resolvedDirectoryOverrides(
	in args: [String], stopAtFirstPositional: Bool, packagePath: URL
) -> [URL] {
	forwardedDirectoryOverrides(in: args, stopAtFirstPositional: stopAtFirstPositional)
		.map { path in
			URL(fileURLWithPath: path, isDirectory: true, relativeTo: packagePath)
				.absoluteURL.standardizedFileURL
		}
}

/// The last value forwarded for any of `flags`, which is the one `swift` will
/// act on when a flag is repeated.
func forwardedFlagValue(
	of flags: [String], in args: [String], stopAtFirstPositional: Bool
) -> String? {
	forwardedFlagValues(of: flags, in: args, stopAtFirstPositional: stopAtFirstPositional)
		.last
}

/// The build system the forwarded arguments select, defaulting to the one
/// `swift build` defaults to.
func forwardedBuildSystem(in args: [String], stopAtFirstPositional: Bool) -> BuildSystem {
	forwardedFlagValue(
		of: ["--build-system"], in: args, stopAtFirstPositional: stopAtFirstPositional
	).map(BuildSystem.init(name:)) ?? .default
}

/// How to read what the forwarded arguments will make `swift` plan, or `nil`
/// when that build system records nothing swift-watch understands.
///
/// Every part of the path is forwarded rather than acted on by swift-watch: the
/// build system chooses the reader, the scratch path moves the whole build tree,
/// and the configuration can name the file. An unrecognised configuration simply
/// resolves to a path that never exists, which reads as a package with no plugin
/// inputs.
///
/// Resolving through the build system is also what keeps a scratch directory
/// that has been used by both from being misread: the two leave their manifests
/// side by side, so a swiftbuild invocation must not fall back to the stale
/// `debug.yaml` a previous native build left behind.
private func resolvedBuildManifest(
	in args: [String], stopAtFirstPositional: Bool, packagePath: URL
) -> BuildManifestSource? {
	let scratchPath =
		forwardedFlagValue(
			of: ["--scratch-path", "--build-path"],
			in: args,
			stopAtFirstPositional: stopAtFirstPositional
		).map { path in
			URL(fileURLWithPath: path, isDirectory: true, relativeTo: packagePath)
				.absoluteURL.standardizedFileURL
		} ?? packagePath.appendingPathComponent(".build", isDirectory: true)
	let configuration =
		forwardedFlagValue(
			of: ["-c", "--configuration"],
			in: args,
			stopAtFirstPositional: stopAtFirstPositional
		) ?? "debug"
	return BuildManifestSource(
		buildSystem: forwardedBuildSystem(
			in: args, stopAtFirstPositional: stopAtFirstPositional),
		scratchPath: scratchPath,
		configuration: configuration
	)
}

/// Warns that a build system swift-watch has no reader for must use the
/// root-package fallback. A toolchain that adds a build system, or renames one,
/// lands here rather than failing.
private func warnAboutForwardedBuildSystem(in args: [String], stopAtFirstPositional: Bool) {
	let system = forwardedBuildSystem(
		in: args, stopAtFirstPositional: stopAtFirstPositional)
	guard system.reader == nil else {
		return
	}
	FileHandle.standardError.write(
		Data(
			"""
			warning: swift-watch cannot read what the '\(system.name)' build system plans, so it will watch source-shaped files in the root package. Use --build-system native or swiftbuild for an exact planned-input graph.

			""".utf8))
}

/// Runs a watch loop, treating an interrupt as an ordinary exit.
private func runUntilInterrupted(
	_ operation: @escaping @Sendable () async throws -> Void
) async throws {
	do {
		try await withCancellationOnSignals(operation: operation)
	} catch SwiftWatchError.cancelled {
		return
	} catch is CancellationError {
		return
	}
}
