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
	@Option(
		name: .customLong("debounce"),
		help: "Debounce window for file changes in milliseconds.")
	var debounce: Int = 300

	@Option(
		name: .customLong("poll-interval"),
		help: "Interval between scans for the polling watcher, in milliseconds.")
	var pollInterval: Int = 150

	@Option(
		name: .customLong("watcher"),
		help:
			"Watcher implementation to use. Available: \(Self.availableWatcherNames.joined(separator: ", "))."
	)
	var watcher: String?

	@Option(
		name: .customLong("swift-bin-dir"),
		help:
			"Directory containing the swift executable to invoke. By default, swift-watch resolves `swift` from PATH."
	)
	var swiftBinDir: String?

	@Option(name: .customLong("package-path"), help: "Path to the package to watch.")
	var packagePath: String = "."

	func validate() throws {
		guard debounce >= 0 else {
			throw ValidationError("--debounce must not be negative.")
		}
		guard pollInterval > 0 else {
			throw ValidationError("--poll-interval must be greater than zero.")
		}
	}

	func executionOptions() -> ExecutionOptions {
		ExecutionOptions(
			debounceMilliseconds: debounce,
			pollIntervalMilliseconds: pollInterval,
			watcherName: watcher,
			swiftBinDirectory: swiftBinDir.map {
				URL(fileURLWithPath: $0, isDirectory: true)
			},
			packagePath: URL(fileURLWithPath: packagePath, isDirectory: true)
		)
	}

	fileprivate static let supportedWatcherImplementations: [FileWatcherImplementation] = {
		var implementations: [FileWatcherImplementation] = []
		#if os(macOS)
			implementations.append(.fsevents)
		#endif
		#if os(Linux)
			implementations.append(.inotify)
		#endif
		implementations.append(.polling)
		return implementations
	}()

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
			abstract: "Run `swift build` in a watch loop."
		)

		@OptionGroup var options: CommonOptions

		@Option(
			help:
				"Build the specified target and scope watching to its dependency closure."
		)
		var target: String?

		@Option(
			help:
				"Build the specified product and scope watching to its dependency closure."
		)
		var product: String?

		@Argument(
			parsing: .captureForPassthrough,
			help: "Arguments forwarded to `swift build`.")
		var swiftArgs: [String] = []

		mutating func run() async throws {
			try exitIfHelpRequested(swiftArgs, for: self)
			let registry = try CommonOptions.makeWatcherRegistry()
			var executionOptions = options.executionOptions()
			executionOptions.selection = WatchSelection(
				explicitNames: [target, product].compactMap { $0 })
			warnAboutForwardedSelectionFlags(in: swiftArgs)
			let forwarded = normalizedPassthrough(self.swiftArgs)
			executionOptions.excludedPaths = resolvedDirectoryOverrides(
				in: forwarded,
				stopAtFirstPositional: false,
				packagePath: executionOptions.packagePath
			)
			let swiftArgs =
				(target.map { ["--target", $0] } ?? [])
				+ (product.map { ["--product", $0] } ?? [])
				+ forwarded
			let options = executionOptions
			try await runUntilInterrupted {
				try await WatchController(watcherRegistry: registry)
					.runBuildLoop(
						options: options,
						swiftArgs: swiftArgs
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
			let swiftArgs = normalizedPassthrough(self.swiftArgs)
			// `swift test` takes no user-supplied executable, so every
			// argument is safe to scan for redirected build output.
			executionOptions.excludedPaths = resolvedDirectoryOverrides(
				in: swiftArgs,
				stopAtFirstPositional: false,
				packagePath: executionOptions.packagePath
			)
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
			// The first non-flag argument is `swift run`'s executable name
			// when one is given. It only ever broadens the watch, so a flag
			// value misread as a name resolves to nothing and changes nothing.
			executionOptions.selection = WatchSelection(
				candidateNames: swiftArgs.first { !$0.hasPrefix("-") }
					.map { [$0] } ?? [])
			let swiftArgs = normalizedPassthrough(self.swiftArgs)
			executionOptions.excludedPaths = resolvedDirectoryOverrides(
				in: swiftArgs,
				stopAtFirstPositional: true,
				packagePath: executionOptions.packagePath
			)
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
	let flags = ["--scratch-path", "--build-path", "--cache-path"]
	var paths: [String] = []
	var index = 0
	while index < args.count {
		let arg = args[index]
		if flags.contains(arg) {
			if index + 1 < args.count {
				paths.append(args[index + 1])
				index += 2
				continue
			}
		} else if let flag = flags.first(where: { arg.hasPrefix($0 + "=") }) {
			paths.append(String(arg.dropFirst(flag.count + 1)))
		} else if stopAtFirstPositional, !arg.hasPrefix("-") {
			break
		}
		index += 1
	}
	return paths
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

/// Selection flags hidden inside passthrough arguments still reach
/// `swift build`, but swift-watch cannot see them, so watching stays scoped
/// to the root package and can miss edits to the selected module.
func forwardedSelectionFlags(in args: [String]) -> [String] {
	args.filter { arg in
		arg == "--target" || arg == "--product"
			|| arg.hasPrefix("--target=") || arg.hasPrefix("--product=")
	}
}

private func warnAboutForwardedSelectionFlags(in args: [String]) {
	let flags = forwardedSelectionFlags(in: args)
	guard !flags.isEmpty else {
		return
	}
	FileHandle.standardError.write(
		Data(
			"""
			warning: \(flags.joined(separator: ", ")) is being forwarded to `swift build` unseen, so watching stays scoped to the whole root package and may miss edits to the selected module. Pass --target/--product to swift-watch itself, immediately after `build`.

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
