import SwiftWatch
import Testing

import class Foundation.NSLock
import class Foundation.Process

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
	let runner: MockRunner
	let watcher: MockWatcher
	let options = ExecutionOptions(
		packagePath: URL(fileURLWithPath: "/root", isDirectory: true))

	init(changeScript: [[URL]]) {
		self.runner = MockRunner(
			log: log,
			descriptions: [
				"/root": DescribedPackage(
					path: "/root",
					dependencies: [],
					targets: [
						.init(
							name: "App", path: "Sources/App",
							sources: ["main.swift"])
					]
				)
			]
		)
		self.watcher = MockWatcher(log: log, changeScript: changeScript)
	}

	func controller() throws -> WatchController {
		let watcher = self.watcher
		let registry = try FileWatcherRegistry(implementations: [
			FileWatcherImplementation(name: "mock", isDefault: true) { _ in watcher }
		])
		return WatchController(
			watcherRegistry: registry,
			runner: runner,
			output: { _ in }
		)
	}
}

private enum Event: Equatable {
	case describe
	case startSession
	case build
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
	private let lock = NSLock()
	private var recordedRunArguments: [[String]] = []

	init(log: EventLog, descriptions: [String: DescribedPackage]) {
		self.log = log
		self.descriptions = descriptions
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

	func runBuild(packagePath: URL, swiftBinDirectory: URL?, args: [String])
		async throws(SwiftWatchError) -> Int32
	{
		log.record(.build)
		return 0
	}

	func launchRun(packagePath: URL, swiftBinDirectory: URL?, args: [String])
		async throws(SwiftWatchError) -> Process
	{
		log.record(.launchRun)
		lock.withLock { recordedRunArguments.append(args) }

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/sh")
		process.arguments = ["-c", "exec sleep 30"]
		do {
			try process.run()
		} catch {
			throw SwiftWatchError.processLaunchFailed(
				executable: "/bin/sh",
				message: error.localizedDescription
			)
		}
		return process
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
