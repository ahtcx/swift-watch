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
		var iteration = 0
		var reporter = BuildManifestReporter(output: output)
		var triggeringChanges: Set<URL> = []
		while iterationLimit.map({ iteration < $0 }) ?? true {
			iteration += 1
			try AsyncSupport.checkCancellation()
			let startedAt = Date()
			let previousPlanDate = options.buildManifest?.modificationDate(
				fileManager: fileManager)

			_ = try await runner.runSwift(
				subcommand: subcommand,
				packagePath: options.packagePath,
				swiftBinDirectory: options.swiftBinDirectory,
				args: swiftArgs
			)

			// The command has finished, so a plan no newer than the one it
			// started with means planning never got that far — a manifest that
			// does not compile, most often. The root-package fallback is the
			// deliberately broad answer there, since whatever the user changes
			// to fix it may be somewhere the last good plan never named.
			let planDate = options.buildManifest?.modificationDate(
				fileManager: fileManager)
			let planIsFresh = planDate != previousPlanDate
			reporter.noteCycle(
				foundPlan: planDate != nil, from: options.buildManifest?.location)
			let watch = try startWatching(
				options: options,
				reporter: &reporter,
				acceptBuildPlan: planIsFresh)
			let changes = try await waitForRelevantChange(
				startedAt: startedAt,
				plannedAt: planIsFresh ? planDate : nil,
				watch: watch,
				options: options,
				triggeredBy: triggeringChanges,
				reporter: &reporter)
			// A cycle that ended with nothing leaves the previous set standing:
			// the paths already accounted for are still the ones sitting in the
			// rounding window, and forgetting them would let one refire.
			if !changes.isEmpty {
				triggeringChanges = Set(changes.map(\.standardizedFileURL))
				output(restartMessage)
			}
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
		var iteration = 0
		var reporter = BuildManifestReporter(output: output)
		var triggeringChanges: Set<URL> = []
		while iterationLimit.map({ iteration < $0 }) ?? true {
			iteration += 1
			try AsyncSupport.checkCancellation()
			let startedAt = Date()
			let previousPlanDate = options.buildManifest?.modificationDate(
				fileManager: fileManager)

			// `swift run` builds and runs in one step, so the arguments are
			// forwarded verbatim rather than split across two invocations.
			//
			// The executable stays up for exactly as long as the wait below,
			// and the runner shuts it down on the way out — including when
			// cancellation or a watcher failure unwinds through here, which
			// must not leave it running.
			let changes = try await runner.withRun(
				packagePath: options.packagePath,
				swiftBinDirectory: options.swiftBinDirectory,
				args: swiftArgs
			) { () throws(SwiftWatchError) -> [URL] in
				try await awaitBuildManifest(
					options: options,
					newerThan: previousPlanDate,
					reporter: &reporter)
				let planDate = options.buildManifest?.modificationDate(
					fileManager: fileManager)
				let planIsFresh = planDate != previousPlanDate
				reporter.noteCycle(
					foundPlan: planDate != nil,
					from: options.buildManifest?.location)
				// Unlike the build loop there is no return to wait on, so a
				// plan that has not arrived may only be late. The last one
				// readable still describes this package under this build
				// system, which is a closer graph than its whole root.
				let watch = try startWatching(
					options: options,
					reporter: &reporter,
					acceptBuildPlan: true)
				defer { watch.session.stop() }
				let changesDuringBuild = try relevantChanges(
					since: startedAt,
					plannedAt: planIsFresh ? planDate : nil,
					graph: watch.graph,
					triggeredBy: triggeringChanges,
					reporter: &reporter)
				if !changesDuringBuild.isEmpty {
					explain(
						changesDuringBuild, graph: watch.graph,
						options: options)
					return changesDuringBuild
				}
				output("Watching for source changes...")
				let changes = try await watch.session.waitForChange(
					debounce: options.debounce)
				explain(changes, graph: watch.graph, options: options)
				return changes
			}

			guard !changes.isEmpty else {
				continue
			}
			triggeringChanges = Set(changes.map(\.standardizedFileURL))

			output("Source change detected. Rebuilding and restarting...")
		}
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

	/// Waits for the invocation in flight to write a readable plan newer than
	/// the one it started with.
	///
	/// `swift run` builds and runs in one step, so the plan lands partway
	/// through a call that does not return until the executable is shut down.
	/// Waiting is what keeps the graph from being built out of the previous
	/// cycle's plan, or out of a manifest caught mid-write.
	private func awaitBuildManifest(
		options: ExecutionOptions,
		newerThan previousDate: Date?,
		reporter: inout BuildManifestReporter
	) async throws(SwiftWatchError) {
		guard let source = options.buildManifest else {
			return
		}
		let deadline = ContinuousClock.now + Self.planDeadline
		while ContinuousClock.now < deadline {
			if source.modificationDate(fileManager: fileManager) != previousDate,
				reporter.inputs(
					of: source.read(
						selection: options.selection,
						fileManager: fileManager)) != nil
			{
				return
			}
			try await AsyncSupport.sleep(
				for: .milliseconds(100), context: "build manifest")
		}
	}

	/// How long `runRunLoop` waits for a plan before watching from whatever it
	/// can already read.
	///
	/// Planning precedes compilation, so this bounds manifest evaluation and
	/// dependency resolution rather than build time. It stays short because an
	/// invocation whose planning failed outright never writes one at all, and
	/// every second past that point is a second of not watching anything.
	private static let planDeadline: Duration = .seconds(30)

	/// How far back the scan for edits made during an invocation reaches past
	/// its start.
	///
	/// Filesystems that stamp whole seconds — HFS+, SMB and NFS mounts — round
	/// a modification time down, so an edit made just after an invocation began
	/// can carry a timestamp from just before it. Reaching back one second
	/// covers the rounding.
	private static let timestampGranularity: TimeInterval = 1

	private struct Watch {
		let graph: WatchGraph
		let session: any FileWatcherSession
	}

	private func waitForRelevantChange(
		startedAt: Date,
		plannedAt planDate: Date?,
		watch: Watch,
		options: ExecutionOptions,
		triggeredBy triggeringChanges: Set<URL>,
		reporter: inout BuildManifestReporter
	) async throws(SwiftWatchError) -> [URL] {
		defer { watch.session.stop() }
		let changesDuringBuild = try relevantChanges(
			since: startedAt,
			plannedAt: planDate,
			graph: watch.graph,
			triggeredBy: triggeringChanges,
			reporter: &reporter)
		if !changesDuringBuild.isEmpty {
			explain(changesDuringBuild, graph: watch.graph, options: options)
			return changesDuringBuild
		}
		output("Watching for source changes...")
		let changes = try await watch.session.waitForChange(
			debounce: options.debounce)
		explain(changes, graph: watch.graph, options: options)
		return changes
	}

	private func startWatching(
		options: ExecutionOptions,
		reporter: inout BuildManifestReporter,
		acceptBuildPlan: Bool
	) throws(SwiftWatchError) -> Watch {
		let reading =
			acceptBuildPlan
			? options.buildManifest?.read(
				selection: options.selection,
				fileManager: fileManager) : nil
		let inputs = reading.flatMap { reporter.inputs(of: $0) }
		let inputDirectories = reading?.readInputDirectories ?? []
		let unbuiltDirectories = reading?.readUnbuiltDirectories ?? []
		let builder = PlannedBuildGraph(fileManager: fileManager)
		let graph =
			inputs.map {
				builder.graph(
					packagePath: options.packagePath,
					inputs: $0,
					inputDirectories: inputDirectories,
					unbuiltDirectories: unbuiltDirectories,
					excludedPaths: options.excludedPaths,
					rules: options.rules)
			}
			?? builder.fallbackGraph(
				packagePath: options.packagePath,
				excludedPaths: options.excludedPaths,
				rules: options.rules)
		let watcher = try watcherRegistry.makeWatcher(
			named: options.watcherName,
			options: options.watcherOptions
		)
		return Watch(
			graph: graph,
			session: try watcher.startSession(for: graph)
		)
	}

	/// Closes the gap between starting the exact Swift invocation and starting
	/// a watcher derived from the plan that invocation produced.
	///
	/// - Parameter triggeringChanges: The paths that started this cycle. They
	///   are held to the invocation's own start time rather than the rounding
	///   window before it, since their timestamps sit in that window by
	///   definition and would otherwise retrigger the build they caused,
	///   forever. An edit to one of them *during* the invocation is later than
	///   the start and still counts.
	///
	/// - Parameter planDate: When the plan this cycle accepted was written, if
	///   this cycle produced a fresh one. Planning inputs are reconciled to that
	///   moment instead of to the invocation's start, because planning both
	///   reads and writes them: SwiftPM updating `Package.resolved` while
	///   resolving dependencies lands after the invocation began and would
	///   otherwise read as an edit the invocation missed. The plan is written
	///   after resolution finishes, so a lockfile no newer than the plan is
	///   already accounted for by it, and only a write past the plan is a change
	///   the plan does not describe. Compilation inputs keep the invocation's
	///   own start: the compiler reads them partway through, and an edit after
	///   that must still count.
	private func relevantChanges(
		since date: Date,
		plannedAt planDate: Date?,
		graph: WatchGraph,
		triggeredBy triggeringChanges: Set<URL>,
		reporter: inout BuildManifestReporter
	) throws(SwiftWatchError) -> [URL] {
		let rounded = date.addingTimeInterval(-Self.timestampGranularity)
		// This scan covers the same scope the watcher was just started for, so
		// what it cannot read is what the watcher cannot see either.
		var unreadable: [URL] = []
		let present = try DirectoryTraversal.relevantFiles(
			in: graph.watchScope,
			graph: graph,
			fileManager: fileManager,
			onUnreadableDirectory: { unreadable.append($0) }
		).filter { url in
			guard
				let modified =
					(try? url.resourceValues(
						forKeys: [.contentModificationDateKey]))?
					.contentModificationDate
			else {
				return false
			}
			// Strictly later, so a lockfile stamped in the same instant as the
			// plan that consumed it — the ordinary outcome on a filesystem
			// stamping whole seconds — stays the plan's own write.
			if let planDate, graph.isPlanningInput(url) {
				return modified > planDate
			}
			if modified >= date {
				return true
			}
			return !triggeringChanges.contains(url.standardizedFileURL)
				&& modified >= rounded
		}
		reporter.noteUnreadableDirectories(unreadable)
		let missing = graph.trackedFiles.filter {
			!fileManager.fileExists(atPath: $0.path)
		}
		return Array(Set(present).union(missing)).sorted { $0.path < $1.path }
	}
}

/// Turns readings into inputs, telling the user once about a manifest that
/// exists but cannot be understood.
///
/// Once, because the loop re-reads after every build: a format swift-watch has
/// stopped recognising would otherwise print on every cycle, for the whole
/// session. The warning is worth making at all because the degradation is
/// silent — the build keeps working while the graph falls back to the root.
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
				warning: \(reason). Falling back to source-shaped files in the \
				root package until SwiftPM writes a readable build plan.
				"""
			)
		}
		return reading.readInputs
	}

	/// Names each directory in scope that could not be listed, once each.
	///
	/// Walking past one is right — nothing under a directory this process cannot
	/// read was read by the build either, and failing there would end the loop
	/// over a directory it has no use for. But the cost is that a source
	/// directory stops being watched, which is the same silent narrowing the
	/// warnings above exist for.
	mutating func noteUnreadableDirectories(_ directories: [URL]) {
		for directory in directories.sorted(by: { $0.path < $1.path })
		where reported.insert("\(Self.unreadableDirectory)\(directory.path)").inserted {
			output(
				"""
				warning: \(directory.path) is in the watch scope but cannot be \
				listed, so changes inside it will not be noticed. Its permissions \
				are what decide this, and SwiftPM cannot read it either.
				"""
			)
		}
	}

	/// Records how a cycle ended, and says so once when enough of them have
	/// ended with nothing.
	///
	/// A manifest that cannot be parsed announces itself. One that is never
	/// found does not: absent reads exactly like the clean checkout whose first
	/// build has yet to write a plan, so the loop would go on watching the whole
	/// root package without ever saying why. That is what a build system moving
	/// its output looks like from here — Swift Build spelled the directory above
	/// its plans `out` in 6.0, the target triple in 6.2, and `out` again in 6.3
	/// — and the cost is silent, since the build itself keeps working.
	///
	/// `foundPlan` asks only whether the build system has left *anything* at the
	/// location — a plan, or the database beside it. That is the question worth
	/// asking: a manifest that exists but reads badly reports itself above, and
	/// a build that failed before rewriting its plan still leaves the last one
	/// behind. Nothing at all, invocation after invocation, is the signature of
	/// looking in the wrong place.
	///
	/// Waiting for the second such cycle keeps the first build of a clean
	/// checkout, which legitimately has nothing to find until it finishes, from
	/// being reported as a missing build system.
	mutating func noteCycle(foundPlan: Bool, from location: URL?) {
		guard !foundPlan else {
			cyclesWithoutAPlan = 0
			return
		}
		guard let location else {
			return
		}
		cyclesWithoutAPlan += 1
		guard cyclesWithoutAPlan >= 2, reported.insert(Self.noPlanFound).inserted else {
			return
		}
		output(
			"""
			warning: no build plan has been read under \(location.path) after \
			\(cyclesWithoutAPlan) invocations, so swift-watch is watching \
			source-shaped files in the whole root package. A build system that \
			has moved where it records its plans looks like this.
			"""
		)
	}

	private var cyclesWithoutAPlan = 0
	private static let noPlanFound = "no build plan found"
	private static let unreadableDirectory = "unreadable directory: "
}
