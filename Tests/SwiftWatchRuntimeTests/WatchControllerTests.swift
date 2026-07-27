import SwiftWatch
import Testing

import class Foundation.NSLock

@testable import SwiftWatchRuntime

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

private let manifest = URL(fileURLWithPath: "/root/Package.swift")
private let source = URL(fileURLWithPath: "/root/Sources/App/main.swift")

@Test
func `build loop reuses the package graph until a manifest changes`() async throws {
	let harness = Harness(changeScript: [[source], [source]])

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 3
	)

	#expect(harness.log.count(of: .build) == 3)
	#expect(harness.log.count(of: .describe) == 1)
	#expect(harness.log.count(of: .startSession) == 1)
}

@Test
func `build loop rediscovers the package graph when the manifest changes`() async throws {
	let harness = Harness(changeScript: [[manifest], [source]])

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 3
	)

	#expect(harness.log.count(of: .describe) == 2)
	#expect(harness.log.count(of: .startSession) == 2)
}

@Test
func `build loop starts watching before the first build runs`() async throws {
	let harness = Harness(changeScript: [[]])

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 1
	)

	// Starting the session after the build would leave a window in which
	// edits are dropped, so the ordering is the behaviour under test.
	let firstObserved = harness.log.events.first {
		$0 == .startSession || $0 == .build
	}
	#expect(firstObserved == Event.startSession)
}

@Test
func `build loop refreshes the graph when a build changes its inputs`() async throws {
	// A build tool plugin's inputs only appear once a build has written the
	// manifest, so the first build of a clean checkout leaves the graph stale.
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(
		at: root.appendingPathComponent("Sources/App", isDirectory: true),
		withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }
	let manifestPath = root.appendingPathComponent("debug.yaml")
	let proto = root.appendingPathComponent("Sources/App/Protos/a.proto")

	let harness = Harness(
		changeScript: [[], []],
		packageRoot: root,
		buildManifestPath: manifestPath,
		onBuild: {
			try? #"  "Gen":\#n    inputs: ["\#(proto.path)"]"#
				.write(to: manifestPath, atomically: true, encoding: .utf8)
		}
	)

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 3
	)

	// One refresh, then quiet: a manifest whose inputs stop changing must not
	// keep restarting the watch, or the loop would never reach a build it waits
	// on.
	#expect(harness.log.count(of: .startSession) == 2)
	#expect(harness.log.count(of: .build) == 3)
	// The package did not change, only what the build reads, so the refresh
	// rebuilds the graph from the description it already had. Describing again
	// would be a subprocess — and SwiftPM's scratch lock — spent to learn
	// nothing.
	#expect(harness.log.count(of: .describe) == 1)
}

@Test
func `build loop stops refreshing when the build inputs never settle`() async throws {
	// A manifest reporting a different input set on every build would, left
	// unbounded, rebuild forever without ever waiting on a change.
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(
		at: root.appendingPathComponent("Sources/App", isDirectory: true),
		withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }
	let manifestPath = root.appendingPathComponent("debug.yaml")
	let builds = Counter()

	let harness = Harness(
		changeScript: [[], [], [], [], []],
		packageRoot: root,
		buildManifestPath: manifestPath,
		onBuild: {
			let input = root.appendingPathComponent(
				"Sources/App/Protos/\(builds.next()).proto")
			try? #"  "Gen":\#n    inputs: ["\#(input.path)"]"#
				.write(to: manifestPath, atomically: true, encoding: .utf8)
		}
	)

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 6
	)

	// One refresh per cycle, no more: the loop reaches its wait every time
	// instead of rebuilding on the spot forever. Six builds across three cycles
	// of build-refresh-build-wait, and a session start for each refresh.
	#expect(harness.log.count(of: .build) == 6)
	#expect(harness.log.count(of: .startSession) == 4)
}

@Test
func `build loop ignores a manifest caught between truncate and rewrite`() async throws {
	// SwiftPM rewrites the manifest in place, so a reader can catch it empty.
	// Reading that as "this build reads nothing" would throw the graph's plugin
	// inputs away and restart the watch on the wreckage.
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(
		at: root.appendingPathComponent("Sources/App", isDirectory: true),
		withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }
	let manifestPath = root.appendingPathComponent("debug.yaml")
	let proto = root.appendingPathComponent("Sources/App/Protos/a.proto")
	let builds = Counter()

	let harness = Harness(
		changeScript: [[], [], []],
		packageRoot: root,
		buildManifestPath: manifestPath,
		onBuild: {
			// A real manifest, then the empty window, then the same manifest
			// again. Only the first build may refresh; the empty read must not
			// look like the inputs going away.
			let contents =
				builds.next() == 2
				? "" : #"  "Gen":\#n    inputs: ["\#(proto.path)"]"#
			try? contents.write(to: manifestPath, atomically: true, encoding: .utf8)
		}
	)

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 4
	)

	// The first build's refresh, and nothing after it: the empty read is not a
	// change, and the third build agrees with the graph it already has.
	#expect(harness.log.count(of: .startSession) == 2)
	#expect(harness.output.filter { $0.hasPrefix("Build inputs changed") }.count == 1)
}

@Test
func `build loop warns once about a manifest it cannot understand`() async throws {
	// A manifest swift-watch stops recognising degrades silently — the build
	// keeps working and only the undeclared plugin inputs quietly stop being
	// watched — so it is worth saying. Once: the loop re-reads after every
	// build, and a format that has changed will not change back this session.
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }
	let manifestPath = root.appendingPathComponent("debug.yaml")

	let harness = Harness(
		changeScript: [[], [], []],
		packageRoot: root,
		buildManifestPath: manifestPath,
		onBuild: {
			// Bytes that are not UTF-8 at all: present, and not readable.
			try? Data([0xff, 0xfe, 0xfd]).write(to: manifestPath)
		}
	)

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 4
	)

	let warnings = harness.output.filter { $0.hasPrefix("warning:") }
	#expect(warnings.count == 1)
	#expect(warnings.first?.contains("could not be read as UTF-8 text") == true)
	// Warned, not broken: an unreadable manifest is not a changed input set, so
	// the watch stands on what `describe` reported and never restarts.
	#expect(harness.log.count(of: .startSession) == 1)
	#expect(harness.log.count(of: .build) == 4)
}

@Test
func `build loop leaves the graph alone when no manifest path is known`() async throws {
	let harness = Harness(changeScript: [[], []])

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 3
	)

	#expect(harness.log.count(of: .describe) == 1)
	#expect(harness.log.count(of: .startSession) == 1)
}

@Test
func `test loop runs swift test and forwards its arguments`() async throws {
	let harness = Harness(changeScript: [[source]])

	try await harness.controller().runTestLoop(
		options: harness.options,
		swiftArgs: ["--filter", "MyTests"],
		iterationLimit: 2
	)

	#expect(harness.log.count(of: .test) == 2)
	#expect(harness.log.count(of: .build) == 0)
	#expect(
		harness.runner.runArguments == [
			["test", "--filter", "MyTests"],
			["test", "--filter", "MyTests"],
		])
	// A source edit reuses the discovered graph, same as the build loop.
	#expect(harness.log.count(of: .describe) == 1)
}

@Test
func `run loop forwards arguments to swift run without a separate build`() async throws {
	let harness = Harness(changeScript: [[]])

	try await harness.controller().runRunLoop(
		options: harness.options,
		swiftArgs: ["MyExecutable", "--flag", "value"],
		iterationLimit: 1
	)

	#expect(harness.log.count(of: .build) == 0)
	#expect(harness.runner.runArguments == [["MyExecutable", "--flag", "value"]])
}

private struct Harness {
	let log = EventLog()
	let lines = OutputLog()
	let runner: MockRunner
	let watcher: MockWatcher
	let options: ExecutionOptions

	/// Everything the controller reported, so a test can assert on what the
	/// user was told and not only on what the loop did.
	var output: [String] { lines.lines }

	init(
		changeScript: [[URL]],
		packageRoot: URL = URL(fileURLWithPath: "/root", isDirectory: true),
		buildManifestPath: URL? = nil,
		onBuild: (@Sendable () -> Void)? = nil
	) {
		let root = packageRoot.standardizedFileURL
		var options = ExecutionOptions(packagePath: root)
		// The fixtures write native-format manifests at an exact path, so the
		// reader is bound directly rather than asked where its build system
		// would put one.
		options.buildManifest = buildManifestPath.map {
			BuildManifestSource(reader: NativeBuildManifest(), location: $0)
		}
		self.options = options
		self.runner = MockRunner(
			log: log,
			descriptions: [
				root.path: DescribedPackage(
					path: root.path,
					dependencies: [],
					targets: [
						.init(
							name: "App", path: "Sources/App",
							sources: ["main.swift"])
					]
				)
			],
			onBuild: onBuild
		)
		self.watcher = MockWatcher(log: log, changeScript: changeScript)
	}

	func controller() throws -> WatchController {
		let watcher = self.watcher
		let lines = self.lines
		let registry = try FileWatcherRegistry(implementations: [
			FileWatcherImplementation(name: "mock", isDefault: true) { _ in watcher }
		])
		return WatchController(
			watcherRegistry: registry,
			runner: runner,
			output: { lines.record($0) }
		)
	}
}

private final class OutputLog: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: [String] = []

	var lines: [String] { lock.withLock { storage } }

	func record(_ line: String) {
		lock.withLock { storage.append(line) }
	}
}

/// A source of a fresh number per call, for fixtures that must differ each time
/// they are asked.
private final class Counter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0

	func next() -> Int {
		lock.withLock {
			value += 1
			return value
		}
	}
}

private enum Event: Equatable {
	case describe
	case startSession
	case build
	case test
	case launchRun
}

private final class EventLog: @unchecked Sendable {
	private let lock = NSLock()
	private var storage: [Event] = []

	var events: [Event] { lock.withLock { storage } }

	func record(_ event: Event) {
		lock.withLock { storage.append(event) }
	}

	func count(of event: Event) -> Int {
		events.filter { $0 == event }.count
	}
}

private final class MockRunner: SwiftToolRunning, @unchecked Sendable {
	private let log: EventLog
	private let descriptions: [String: DescribedPackage]
	private let onBuild: (@Sendable () -> Void)?
	private let lock = NSLock()
	private var recordedRunArguments: [[String]] = []

	init(
		log: EventLog,
		descriptions: [String: DescribedPackage],
		onBuild: (@Sendable () -> Void)? = nil
	) {
		self.log = log
		self.descriptions = descriptions
		self.onBuild = onBuild
	}

	var runArguments: [[String]] { lock.withLock { recordedRunArguments } }

	func describe(packagePath: URL, swiftBinDirectory: URL?) async throws(SwiftWatchError)
		-> DescribedPackage
	{
		log.record(.describe)
		guard let package = descriptions[packagePath.standardizedFileURL.path] else {
			throw SwiftWatchError.packageDescribeFailed(packagePath.path)
		}
		return package
	}

	func runSwift(
		subcommand: String, packagePath: URL, swiftBinDirectory: URL?, args: [String]
	)
		async throws(SwiftWatchError) -> Int32
	{
		log.record(subcommand == "test" ? .test : .build)
		lock.withLock { recordedRunArguments.append([subcommand] + args) }
		onBuild?()
		return 0
	}

	func withRun<Result: Sendable>(
		packagePath: URL,
		swiftBinDirectory: URL?,
		args: [String],
		whileRunning: () async throws(SwiftWatchError) -> Result
	) async throws(SwiftWatchError) -> Result {
		log.record(.launchRun)
		lock.withLock { recordedRunArguments.append(args) }
		// Launching and tearing down the executable is the runner's job, and is
		// covered there; this only has to keep the loop moving.
		return try await whileRunning()
	}
}

private final class MockWatcher: FileWatcher, @unchecked Sendable {
	private let log: EventLog
	private let lock = NSLock()
	private var changeScript: [[URL]]

	init(log: EventLog, changeScript: [[URL]]) {
		self.log = log
		self.changeScript = changeScript
	}

	func startSession(for graph: WatchGraph) throws(SwiftWatchError)
		-> any FileWatcherSession
	{
		log.record(.startSession)
		return MockSession { [weak self] in
			guard let self else {
				return []
			}
			return self.lock.withLock {
				self.changeScript.isEmpty ? [] : self.changeScript.removeFirst()
			}
		}
	}
}

private final class MockSession: FileWatcherSession {
	private let nextChanges: () -> [URL]

	init(nextChanges: @escaping () -> [URL]) {
		self.nextChanges = nextChanges
	}

	func waitForChange(debounce: Duration) async throws(SwiftWatchError) -> [URL] {
		nextChanges()
	}

	func stop() {}
}
