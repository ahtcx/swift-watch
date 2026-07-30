import SwiftWatch
import Testing

import class Foundation.NSLock

@testable import SwiftWatchRuntime

#if canImport(Darwin)
	import Darwin
#elseif canImport(Glibc)
	import Glibc
#endif

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// A package path chosen so that nothing is there to walk.
///
/// These tests script the loop rather than a filesystem, so the graphs they
/// build must not reach a real directory. A path that does not exist is skipped
/// by the traversal outright; one that exists but cannot be listed is a hard
/// error, which is what `/root` turned out to be when the suite runs on Linux
/// as anyone but root.
private let absentPackage = URL(fileURLWithPath: "/nonexistent-swift-watch", isDirectory: true)
private let manifest = absentPackage.appendingPathComponent("Package.swift")
private let source = absentPackage.appendingPathComponent("Sources/App/main.swift")

@Test
func `build loop derives a fresh graph from every exact invocation`() async throws {
	let harness = Harness(changeScript: [[source], [source]])

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 3
	)

	#expect(harness.log.count(of: .build) == 3)
	#expect(harness.log.count(of: .startSession) == 3)
}

@Test
func `manifest changes are handled by the following exact invocation`() async throws {
	let harness = Harness(changeScript: [[manifest], [source]])

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 3
	)

	#expect(harness.log.count(of: .build) == 3)
	#expect(harness.log.count(of: .startSession) == 3)
}

@Test
func `build loop plans before starting its watcher`() async throws {
	let harness = Harness(changeScript: [[]])

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 1
	)

	// Only the real invocation can produce the authoritative graph. A
	// post-build reconciliation closes the gap before this session starts.
	let firstObserved = harness.log.events.first {
		$0 == .startSession || $0 == .build
	}
	#expect(firstObserved == Event.build)
}

@Test
func `build loop uses the inputs each build just planned`() async throws {
	// A build tool plugin's inputs come from the exact plan this build writes.
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
			try? #"commands:\#n  "Gen":\#n    inputs: ["\#(proto.path)"]"#
				.write(to: manifestPath, atomically: true, encoding: .utf8)
		}
	)

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 3
	)

	#expect(harness.log.count(of: .startSession) == 3)
	#expect(harness.log.count(of: .build) == 3)
}

@Test
func `changing planned inputs do not add extra build cycles`() async throws {
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
			try? #"commands:\#n  "Gen":\#n    inputs: ["\#(input.path)"]"#
				.write(to: manifestPath, atomically: true, encoding: .utf8)
		}
	)

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 6
	)

	#expect(harness.log.count(of: .build) == 6)
	#expect(harness.log.count(of: .startSession) == 6)
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
			// again. The empty read must use the fallback rather than look like
			// an authoritative plan that reads nothing.
			let contents =
				builds.next() == 2
				? "" : #"commands:\#n  "Gen":\#n    inputs: ["\#(proto.path)"]"#
			try? contents.write(to: manifestPath, atomically: true, encoding: .utf8)
		}
	)

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 4
	)

	#expect(harness.log.count(of: .startSession) == 4)
	#expect(harness.output.filter { $0.hasPrefix("Build inputs changed") }.isEmpty)
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
	// Warned, not broken: every cycle uses the root-package fallback graph.
	#expect(harness.log.count(of: .startSession) == 4)
	#expect(harness.log.count(of: .build) == 4)
}

/// Whether file permissions can deny this process anything.
///
/// Root is not refused, so an unreadable directory is not one there and the
/// test below would have nothing to observe. Containers commonly run the suite
/// that way.
private var permissionsApply: Bool { getuid() != 0 }

@Test(.enabled(if: permissionsApply))
func `build loop warns once about a directory it cannot list`() async throws {
	// Walking past an unreadable directory keeps the loop alive, which is right,
	// but it leaves whatever is inside it unwatched for the session. Nothing else
	// would ever say so.
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let unreadable = root.appendingPathComponent("Sources/App/Private", isDirectory: true)
	try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
	defer {
		try? FileManager.default.setAttributes(
			[.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
		try? FileManager.default.removeItem(at: root)
	}
	try FileManager.default.setAttributes(
		[.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

	let harness = Harness(changeScript: [[], [], []], packageRoot: root)

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 4
	)

	let warnings = harness.output.filter { $0.hasPrefix("warning:") }
	#expect(warnings.count == 1)
	#expect(warnings.first?.contains(unreadable.path) == true)
	#expect(warnings.first?.contains("cannot be listed") == true)
	// Warned, not broken: the loop kept running over everything else.
	#expect(harness.log.count(of: .build) == 4)
}

@Test
func `build loop says so when it never finds a plan where it is looking`() async throws {
	// A build system that moves where it records its plans reads exactly like a
	// clean checkout whose first build has yet to write one — Swift Build spelled
	// that directory `out`, then the target triple, then `out` again across 6.x.
	// Nothing else would ever say why the watch went coarse.
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }

	// Configured, and nothing is ever written there.
	let harness = Harness(
		changeScript: [[], [], []],
		packageRoot: root,
		buildManifestPath: root.appendingPathComponent("nowhere/debug.yaml")
	)

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 4
	)

	let warnings = harness.output.filter { $0.hasPrefix("warning:") }
	#expect(warnings.count == 1)
	#expect(warnings.first?.contains("no build plan has been read") == true)
	// Said once, and not at the first invocation, which a clean checkout owns.
	#expect(harness.log.count(of: .build) == 4)
}

@Test
func `an edit stamped just before the build counts once, not forever`() async throws {
	// Filesystems that stamp whole seconds round an edit made just after an
	// invocation began down to just before it, so the scan for edits during a
	// build reaches back past its own start. The path that triggered the build
	// sits in that window by definition: counting it would rebuild on its own
	// timestamp for as long as the loop ran.
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
	try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }
	let edited = sources.appendingPathComponent("main.swift")
	try "// edited\n".write(to: edited, atomically: true, encoding: .utf8)

	// Stamped just before the loop starts, and never touched again. The first
	// cycle finds it in the rounding window and rebuilds without ever waiting;
	// from the second it is the trigger, and the loop waits instead.
	let harness = Harness(changeScript: [[], [], []], packageRoot: root)

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 3
	)

	#expect(harness.log.count(of: .build) == 3)
	// One immediate follow-up, then the loop settles onto the watcher rather
	// than spinning on the same timestamp.
	#expect(harness.output.filter { $0 == "Watching for source changes..." }.count == 2)
}

@Test
func `build loop leaves the graph alone when no manifest path is known`() async throws {
	let harness = Harness(changeScript: [[], []])

	try await harness.controller().runBuildLoop(
		options: harness.options,
		swiftArgs: [],
		iterationLimit: 3
	)

	#expect(harness.log.count(of: .startSession) == 3)
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
		packageRoot: URL = absentPackage,
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
	private let onBuild: (@Sendable () -> Void)?
	private let lock = NSLock()
	private var recordedRunArguments: [[String]] = []

	init(
		log: EventLog,
		onBuild: (@Sendable () -> Void)? = nil
	) {
		self.log = log
		self.onBuild = onBuild
	}

	var runArguments: [[String]] { lock.withLock { recordedRunArguments } }

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
