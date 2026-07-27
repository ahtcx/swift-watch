import SwiftWatch

import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct WatchController {
	private let runner: SwiftToolRunning
	private let watcherRegistry: FileWatcherRegistry
	private let fileManager: FileManager
	private let output: @Sendable (String) -> Void

	public init(
		watcherRegistry: FileWatcherRegistry,
		runner: SwiftToolRunning = SwiftToolRunner(),
		fileManager: FileManager = .default,
		output: @escaping @Sendable (String) -> Void = { print($0) }
	) {
		self.watcherRegistry = watcherRegistry
		self.runner = runner
		self.fileManager = fileManager
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
		var refreshed = false
		var reporter = BuildManifestReporter(output: output)
		while iterationLimit.map({ iteration < $0 }) ?? true {
			iteration += 1
			try AsyncSupport.checkCancellation()

			_ = try await runner.runSwift(
				subcommand: subcommand,
				packagePath: options.packagePath,
				swiftBinDirectory: options.swiftBinDirectory,
				args: swiftArgs
			)

			// At most one refresh per cycle. One is all a settling package needs
			// — the first build of a clean checkout reveals the inputs no
			// manifest declares — and the bound is what stops a package whose
			// planned inputs never settle from rebuilding forever without ever
			// reaching the wait below.
			if !refreshed,
				let inputs = changedBuildInputs(
					from: watch.graph, options: options, reporter: &reporter)
			{
				output("Build inputs changed. Refreshing the watch graph...")
				watch.session.stop()
				watch = try startWatching(
					packages: watch.packages, options: options,
					buildInputs: inputs)
				refreshed = true
				// Rebuilding immediately, rather than waiting on the fresh
				// session, is what keeps the restart from dropping an edit made
				// during the build that just finished.
				continue
			}

			refreshed = false
			output("Watching for source changes...")
			let changes = try await watch.session.waitForChange(
				debounce: options.debounce)
			guard !changes.isEmpty else {
				continue
			}

			explain(changes, graph: watch.graph, options: options)
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
		var refreshed = false
		var reporter = BuildManifestReporter(output: output)
		while iterationLimit.map({ iteration < $0 }) ?? true {
			iteration += 1
			try AsyncSupport.checkCancellation()

			// `swift run` builds and runs in one step, so the arguments are
			// forwarded verbatim rather than split across two invocations.
			//
			// The executable stays up for exactly as long as the wait below,
			// and the runner shuts it down on the way out — including when
			// cancellation or a watcher failure unwinds through here, which
			// must not leave it running.
			let session = watch.session
			let graph = watch.graph
			let isFirstIteration = iteration == 1
			let hasRefreshed = refreshed
			let outcome = try await runner.withRun(
				packagePath: options.packagePath,
				swiftBinDirectory: options.swiftBinDirectory,
				args: swiftArgs
			) { () throws(SwiftWatchError) -> RunOutcome in
				// `swift run` builds and runs in one step, so unlike the build
				// loop there is no return to wait on: the manifest lands partway
				// through the launched invocation. Only the first pass waits — a
				// package whose planning fails never writes one, and every later
				// pass has the previous build's manifest to read.
				if isFirstIteration {
					try await awaitBuildManifest(
						options: options, reporter: &reporter)
				}
				if !hasRefreshed,
					let inputs = changedBuildInputs(
						from: graph, options: options, reporter: &reporter)
				{
					output(
						"Build inputs changed. Refreshing the watch graph..."
					)
					return .buildInputsChanged(inputs)
				}

				output("Watching for source changes...")
				return .changed(
					try await session.waitForChange(debounce: options.debounce))
			}

			let changes: [URL]
			switch outcome {
			case .buildInputsChanged(let inputs):
				watch.session.stop()
				watch = try startWatching(
					packages: watch.packages, options: options,
					buildInputs: inputs)
				refreshed = true
				continue
			case .changed(let waited):
				refreshed = false
				changes = waited
			}

			guard !changes.isEmpty else {
				continue
			}

			explain(changes, graph: watch.graph, options: options)
			if watch.graph.requiresRediscovery(for: changes) {
				output("Package manifest changed. Reloading package graph...")
				watch.session.stop()
				watch = try await startWatching(options: options)
			}
			output("Source change detected. Rebuilding and restarting...")
		}
	}

	/// Why a run cycle ended, since the executable is only shut down once the
	/// reason is known.
	private enum RunOutcome {
		/// The build read inputs the watch graph was not built from.
		case buildInputsChanged(Set<URL>)
		/// The watcher reported these paths.
		case changed([URL])
	}

	/// Reports why each change counted, one line per path.
	///
	/// The rules that widen past the build's own inputs are the ones that
	/// surprise: a rebuild triggered by a README in a plugin's directory looks
	/// arbitrary until it names the rule that matched.
	private func explain(_ changes: [URL], graph: WatchGraph, options: ExecutionOptions) {
		guard options.explain else {
			return
		}
		let limit = 10
		for change in changes.prefix(limit) {
			let reason =
				graph.matchedRule(for: change)?.explanation
				?? "no longer matches any rule"
			output("  \(change.path): \(reason)")
		}
		if changes.count > limit {
			output("  ...and \(changes.count - limit) more")
		}
	}

	/// Waits, briefly, for a manifest that has not been written yet.
	///
	/// Only the very first run in a clean checkout reaches this: with no
	/// manifest, the graph cannot see a build tool plugin's inputs, and if the
	/// user's next edit is to one of those inputs nothing would wake the loop to
	/// notice. SwiftPM writes the manifest while planning, before it compiles
	/// anything, so the wait resolves in about the time planning takes and is
	/// skipped entirely once a manifest reads.
	///
	/// Timing out is not a failure: it costs the plugin inputs for one cycle,
	/// and the next build reports them.
	private func awaitBuildManifest(
		options: ExecutionOptions, reporter: inout BuildManifestReporter
	) async throws(SwiftWatchError) {
		guard let source = options.buildManifest,
			reporter.inputs(of: source.read(fileManager: fileManager)) == nil
		else {
			return
		}
		let deadline = ContinuousClock.now + .seconds(10)
		while ContinuousClock.now < deadline {
			try await AsyncSupport.sleep(
				for: .milliseconds(100), context: "build manifest")
			if reporter.inputs(of: source.read(fileManager: fileManager)) != nil {
				return
			}
		}
	}

	/// The build inputs the build that just ran reads, when they differ from the
	/// set the graph was built from, and `nil` when nothing changed.
	///
	/// A build tool plugin resolves its inputs while the build is planned, so
	/// they only become visible once a build has written the manifest. That
	/// makes the first build of a clean checkout, and any build that changes a
	/// plugin's inputs, the two moments the watch graph goes stale.
	///
	/// The inputs are returned rather than just the verdict so the caller can
	/// build the next graph from the very read it compared, rather than going
	/// back to disk for the same answer.
	private func changedBuildInputs(
		from graph: WatchGraph,
		options: ExecutionOptions,
		reporter: inout BuildManifestReporter
	) -> Set<URL>? {
		// Nothing read means the manifest is unwritten, was caught mid-rewrite,
		// or could not be understood. None is evidence that this build's inputs
		// changed, so all three leave the graph as it stands.
		guard let source = options.buildManifest,
			let inputs = reporter.inputs(of: source.read(fileManager: fileManager))
		else {
			return nil
		}
		// Filtered the same way the graph filters, so the paths a graph would
		// discard cannot masquerade as a change.
		let current = WatchGraph.relevantBuildInputs(
			inputs,
			packageRoots: graph.packageRoots,
			excludedRoots: graph.excludedRoots
		)
		return current == graph.buildInputs ? nil : inputs
	}

	private struct Watch {
		let graph: WatchGraph
		let session: any FileWatcherSession

		/// Kept so a graph can be rebuilt without describing the package again.
		let packages: DiscoveredPackages
	}

	/// Discovers the package graph and begins observing it.
	///
	/// Observation starts before the caller builds, so edits that land during a
	/// build are reported by the following `waitForChange` instead of being lost.
	private func startWatching(options: ExecutionOptions) async throws(SwiftWatchError)
		-> Watch
	{
		let packages = try await discovery.describePackages(
			from: options.packagePath,
			swiftBinDirectory: options.swiftBinDirectory
		)
		return try startWatching(packages: packages, options: options)
	}

	/// Rebuilds the graph and restarts observation from a description already
	/// in hand.
	///
	/// A build that changed only its own inputs has not changed the package, so
	/// describing it again would be a subprocess spent to learn nothing. The
	/// manifest edits that would invalidate the description are the ones that
	/// trigger a full rediscovery instead.
	///
	/// - Parameter buildInputs: A manifest reading the caller already has, which
	///   spares this a second read of the same file. Absent, the manifest is
	///   read here.
	private func startWatching(
		packages: DiscoveredPackages,
		options: ExecutionOptions,
		buildInputs: Set<URL>? = nil
	) throws(SwiftWatchError) -> Watch {
		let graph = discovery.graph(
			for: packages,
			selection: options.selection,
			excludedPaths: options.excludedPaths,
			buildInputs: buildInputs
				?? options.buildManifest?.read(fileManager: fileManager).readInputs
				?? [],
			rules: options.rules
		)
		let watcher = try watcherRegistry.makeWatcher(
			named: options.watcherName,
			options: options.watcherOptions
		)
		return Watch(
			graph: graph,
			session: try watcher.startSession(for: graph),
			packages: packages
		)
	}

	private var discovery: PackageDiscovery {
		PackageDiscovery(runner: runner, fileManager: fileManager)
	}
}

/// Turns readings into inputs, telling the user once about a manifest that
/// exists but cannot be understood.
///
/// Once, because the loop re-reads after every build: a format swift-watch has
/// stopped recognising would otherwise print on every cycle, for the whole
/// session. The warning is worth making at all because the degradation is
/// silent — the build keeps working, and only the inputs no manifest declares
/// quietly stop being watched.
private struct BuildManifestReporter {
	private let output: @Sendable (String) -> Void
	private var reported: Set<String> = []

	init(output: @escaping @Sendable (String) -> Void) {
		self.output = output
	}

	/// The inputs `reading` found, or `nil` when it found none for any reason.
	mutating func inputs(of reading: PlannedBuild) -> Set<URL>? {
		if let reason = reading.unreadableReason, reported.insert(reason).inserted {
			output(
				"""
				warning: \(reason). Build tool plugin inputs will not be watched; \
				everything your package manifest declares still is.
				"""
			)
		}
		return reading.readInputs
	}
}
