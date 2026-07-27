import SwiftWatch

import class Foundation.FileManager
import class Foundation.Process

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct WatchController {
	private let runner: SwiftToolRunning
	private let watcherRegistry: FileWatcherRegistry
	private let fileManager: FileManager
	private let runSupervisor: RunSupervisor
	private let output: @Sendable (String) -> Void

	public init(
		watcherRegistry: FileWatcherRegistry,
		runner: SwiftToolRunning = SwiftToolRunner(),
		fileManager: FileManager = .default,
		runSupervisor: RunSupervisor = RunSupervisor(),
		output: @escaping @Sendable (String) -> Void = { print($0) }
	) {
		self.watcherRegistry = watcherRegistry
		self.runner = runner
		self.fileManager = fileManager
		self.runSupervisor = runSupervisor
		self.output = output
	}

	public func runBuildLoop(options: ExecutionOptions, swiftArgs: [String])
		async throws(SwiftWatchError)
	{
		try await runBuildLoop(
			options: options, swiftArgs: swiftArgs, iterationLimit: nil)
	}

	/// - Parameter iterationLimit: Stops after this many build cycles. Only used
	///   by tests; production callers watch indefinitely.
	func runBuildLoop(
		options: ExecutionOptions,
		swiftArgs: [String],
		iterationLimit: Int?
	) async throws(SwiftWatchError) {
		try await runSubcommandLoop(
			subcommand: "build",
			restartMessage: "Source change detected. Rebuilding...",
			options: options,
			swiftArgs: swiftArgs,
			iterationLimit: iterationLimit
		)
	}

	public func runTestLoop(options: ExecutionOptions, swiftArgs: [String])
		async throws(SwiftWatchError)
	{
		try await runTestLoop(
			options: options, swiftArgs: swiftArgs, iterationLimit: nil)
	}

	/// - Parameter iterationLimit: Stops after this many test cycles. Only used
	///   by tests; production callers watch indefinitely.
	func runTestLoop(
		options: ExecutionOptions,
		swiftArgs: [String],
		iterationLimit: Int?
	) async throws(SwiftWatchError) {
		try await runSubcommandLoop(
			subcommand: "test",
			restartMessage: "Source change detected. Retesting...",
			options: options,
			swiftArgs: swiftArgs,
			iterationLimit: iterationLimit
		)
	}

	/// Shared loop for subcommands that run to completion, unlike `swift run`
	/// which leaves a process to supervise.
	private func runSubcommandLoop(
		subcommand: String,
		restartMessage: String,
		options: ExecutionOptions,
		swiftArgs: [String],
		iterationLimit: Int?
	) async throws(SwiftWatchError) {
		var watch = try await startWatching(options: options)
		defer { watch.session.stop() }

		var iteration = 0
		while iterationLimit.map({ iteration < $0 }) ?? true {
			iteration += 1
			try AsyncSupport.checkCancellation()

			_ = try await runner.runSwift(
				subcommand: subcommand,
				packagePath: options.packagePath,
				swiftBinDirectory: options.swiftBinDirectory,
				args: swiftArgs
			)

			output("Watching for source changes...")
			let changes = try await watch.session.waitForChange(
				debounce: options.debounce)
			guard !changes.isEmpty else {
				continue
			}

			if watch.graph.requiresRediscovery(for: changes) {
				output("Package manifest changed. Reloading package graph...")
				watch.session.stop()
				watch = try await startWatching(options: options)
			}
			output(restartMessage)
		}
	}

	public func runRunLoop(options: ExecutionOptions, swiftArgs: [String])
		async throws(SwiftWatchError)
	{
		try await runRunLoop(options: options, swiftArgs: swiftArgs, iterationLimit: nil)
	}

	/// - Parameter iterationLimit: Stops after this many run cycles. Only used
	///   by tests; production callers watch indefinitely.
	func runRunLoop(
		options: ExecutionOptions,
		swiftArgs: [String],
		iterationLimit: Int?
	) async throws(SwiftWatchError) {
		var watch = try await startWatching(options: options)
		defer { watch.session.stop() }

		var iteration = 0
		while iterationLimit.map({ iteration < $0 }) ?? true {
			iteration += 1
			try AsyncSupport.checkCancellation()

			// `swift run` builds and runs in one step, so the arguments are
			// forwarded verbatim rather than split across two invocations.
			let process = try await runner.launchRun(
				packagePath: options.packagePath,
				swiftBinDirectory: options.swiftBinDirectory,
				args: swiftArgs
			)

			output("Watching for source changes...")
			let changes: [URL]
			do {
				changes = try await watch.session.waitForChange(
					debounce: options.debounce)
			} catch {
				// Cancellation and watcher failures must not leave the
				// launched executable running.
				await runSupervisor.terminate(process)
				throw error
			}
			await runSupervisor.terminate(process)

			guard !changes.isEmpty else {
				continue
			}

			if watch.graph.requiresRediscovery(for: changes) {
				output("Package manifest changed. Reloading package graph...")
				watch.session.stop()
				watch = try await startWatching(options: options)
			}
			output("Source change detected. Rebuilding and restarting...")
		}
	}

	private struct Watch {
		let graph: WatchGraph
		let session: any FileWatcherSession
	}

	/// Discovers the package graph and begins observing it.
	///
	/// Observation starts before the caller builds, so edits that land during a
	/// build are reported by the following `waitForChange` instead of being lost.
	private func startWatching(options: ExecutionOptions) async throws(SwiftWatchError)
		-> Watch
	{
		let graph = try await PackageDiscovery(
			runner: runner,
			fileManager: fileManager
		).discover(
			from: options.packagePath,
			swiftBinDirectory: options.swiftBinDirectory,
			selection: options.selection,
			excludedPaths: options.excludedPaths
		)
		let watcher = try watcherRegistry.makeWatcher(
			named: options.watcherName,
			options: options.watcherOptions
		)
		return Watch(graph: graph, session: try watcher.startSession(for: graph))
	}
}
