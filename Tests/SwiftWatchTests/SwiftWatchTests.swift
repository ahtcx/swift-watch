import Testing

import class Foundation.Process

@testable import SwiftWatch
@testable import swift_watch

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

@Test
func `describe JSON decodes local dependency and sources`() throws {
	let json = """
		{
		  "path": "/tmp/root",
		  "dependencies": [
		    {
		      "type": "fileSystem",
		      "identity": "dep",
		      "path": "../dep"
		    }
		  ],
		  "products": [
		    {
		      "name": "App",
		      "targets": ["App"],
		      "type": { "executable": null }
		    }
		  ],
		  "targets": [
		    {
		      "name": "App",
		      "path": "Sources/App",
		      "sources": ["main.swift", "Helper.swift"],
		      "target_dependencies": ["Core"],
		      "product_dependencies": ["Dep"]
		    },
		    {
		      "name": "Core",
		      "path": "Sources/Core",
		      "sources": ["Core.swift"]
		    }
		  ]
		}
		"""

	let package = try JSONDecoder().decode(DescribedPackage.self, from: Data(json.utf8))
	#expect(package.path == "/tmp/root")
	#expect(package.targets.count == 2)
	#expect(package.targets[0].name == "App")
	#expect(package.targets[0].sources == ["main.swift", "Helper.swift"])
	#expect(package.targets[0].targetDependencies == ["Core"])
	#expect(package.targets[0].productDependencies == ["Dep"])
	#expect(package.targets[1].targetDependencies.isEmpty)
	#expect(package.products.count == 1)
	#expect(package.products[0].targets == ["App"])
	#expect(package.dependencies.count == 1)
	#expect(package.dependencies[0].location == .fileSystem(path: "../dep"))
}

@Test
func `package discovery recurses through local dependencies`() async throws {
	let runner = MockRunner(descriptions: [
		"/root": DescribedPackage(
			path: "/root",
			dependencies: [
				.init(identity: "dep", location: .fileSystem(path: "/dep"))
			],
			targets: [
				.init(
					name: "App", path: "Sources/App", sources: ["main.swift"],
					productDependencies: ["Dep"])
			]
		),
		"/dep": DescribedPackage(
			path: "/dep",
			dependencies: [],
			products: [.init(name: "Dep", targets: ["Dep"])],
			targets: [.init(name: "Dep", path: "Sources/Dep", sources: ["dep.swift"])]
		),
	])

	let graph = try await PackageDiscovery(runner: runner).discover(
		from: URL(fileURLWithPath: "/root", isDirectory: true),
		swiftBinDirectory: nil
	)

	#expect(graph.packageRoots.map(\.path).contains("/root"))
	#expect(graph.packageRoots.map(\.path).contains("/dep"))
	#expect(graph.trackedFiles.map(\.path).contains("/dep/Sources/Dep/dep.swift"))
}

@Test
func `package discovery prunes dependency targets outside the closure`() async throws {
	let runner = MockRunner(descriptions: [
		"/root": DescribedPackage(
			path: "/root",
			dependencies: [
				.init(identity: "dep", location: .fileSystem(path: "/dep"))
			],
			targets: [
				.init(
					name: "App", path: "Sources/App", sources: ["main.swift"],
					productDependencies: ["Used"])
			]
		),
		"/dep": DescribedPackage(
			path: "/dep",
			dependencies: [],
			products: [
				.init(name: "Used", targets: ["Used"]),
				.init(name: "Unused", targets: ["Unused"]),
			],
			targets: [
				.init(name: "Used", path: "Sources/Used", sources: ["used.swift"]),
				.init(
					name: "Unused", path: "Sources/Unused",
					sources: ["unused.swift"]),
				.init(
					name: "UsedTests", path: "Tests/UsedTests",
					sources: ["tests.swift"],
					targetDependencies: ["Used"]),
			]
		),
	])

	let graph = try await PackageDiscovery(runner: runner).discover(
		from: URL(fileURLWithPath: "/root", isDirectory: true),
		swiftBinDirectory: nil
	)

	let tracked = graph.trackedFiles.map(\.path)
	#expect(tracked.contains("/dep/Sources/Used/used.swift"))
	#expect(!tracked.contains("/dep/Sources/Unused/unused.swift"))
	#expect(!tracked.contains("/dep/Tests/UsedTests/tests.swift"))
	let sourceRoots = graph.sourceRoots.map(\.path)
	#expect(sourceRoots.contains("/dep/Sources/Used"))
	#expect(!sourceRoots.contains("/dep/Sources/Unused"))
	// The pruned package's manifest still triggers rediscovery.
	#expect(tracked.contains("/dep/Package.swift"))
	#expect(graph.requiresRediscovery(for: [URL(fileURLWithPath: "/dep/Package.swift")]))
}

@Test
func `package discovery follows product edges through transitive local packages`() async throws {
	let runner = MockRunner(descriptions: [
		"/root": DescribedPackage(
			path: "/root",
			dependencies: [
				.init(identity: "a", location: .fileSystem(path: "/a"))
			],
			targets: [
				.init(
					name: "App", path: "Sources/App", sources: ["main.swift"],
					productDependencies: ["A"])
			]
		),
		"/a": DescribedPackage(
			path: "/a",
			dependencies: [
				.init(identity: "b", location: .fileSystem(path: "/b"))
			],
			products: [.init(name: "A", targets: ["A"])],
			targets: [
				.init(
					name: "A", path: "Sources/A", sources: ["a.swift"],
					productDependencies: ["B"]),
				.init(name: "AExtra", path: "Sources/AExtra", sources: ["x.swift"]),
			]
		),
		"/b": DescribedPackage(
			path: "/b",
			dependencies: [],
			products: [.init(name: "B", targets: ["B"])],
			targets: [
				.init(name: "B", path: "Sources/B", sources: ["b.swift"]),
				.init(name: "BExtra", path: "Sources/BExtra", sources: ["y.swift"]),
			]
		),
	])

	let graph = try await PackageDiscovery(runner: runner).discover(
		from: URL(fileURLWithPath: "/root", isDirectory: true),
		swiftBinDirectory: nil
	)

	let tracked = graph.trackedFiles.map(\.path)
	#expect(tracked.contains("/a/Sources/A/a.swift"))
	#expect(tracked.contains("/b/Sources/B/b.swift"))
	#expect(!tracked.contains("/a/Sources/AExtra/x.swift"))
	#expect(!tracked.contains("/b/Sources/BExtra/y.swift"))
}

@Test
func `target closure resolves by-name dependencies and ambiguous products broadly`() {
	let root = URL(fileURLWithPath: "/root", isDirectory: true)
	let depA = URL(fileURLWithPath: "/a", isDirectory: true)
	let depB = URL(fileURLWithPath: "/b", isDirectory: true)
	let packages: [URL: DescribedPackage] = [
		root: DescribedPackage(
			path: "/root",
			dependencies: [],
			targets: [
				// "Shared" is not a sibling target, so it must resolve
				// as a by-name product dependency.
				.init(
					name: "App", path: "Sources/App", sources: [],
					targetDependencies: ["Shared"])
			]
		),
		depA: DescribedPackage(
			path: "/a",
			dependencies: [],
			products: [.init(name: "Shared", targets: ["SharedA"])],
			targets: [.init(name: "SharedA", path: "Sources/SharedA", sources: [])]
		),
		depB: DescribedPackage(
			path: "/b",
			dependencies: [],
			products: [.init(name: "Shared", targets: ["SharedB"])],
			targets: [.init(name: "SharedB", path: "Sources/SharedB", sources: [])]
		),
	]

	let reached = TargetClosure.reachedTargets(from: root, in: packages)

	#expect(reached[root] == ["App"])
	#expect(reached[depA] == ["SharedA"])
	#expect(reached[depB] == ["SharedB"])
}

@Test
func `explicit selection narrows the closure to the named module`() {
	let root = URL(fileURLWithPath: "/root", isDirectory: true)
	let dep = URL(fileURLWithPath: "/dep", isDirectory: true)
	let packages: [URL: DescribedPackage] = [
		root: DescribedPackage(
			path: "/root",
			dependencies: [],
			targets: [
				.init(name: "App", path: "Sources/App", sources: []),
				.init(name: "AppTests", path: "Tests/AppTests", sources: []),
			]
		),
		dep: DescribedPackage(
			path: "/dep",
			dependencies: [],
			products: [.init(name: "Lib", targets: ["Lib"])],
			targets: [
				.init(
					name: "Lib", path: "Sources/Lib", sources: [],
					targetDependencies: ["LibCore"]),
				.init(name: "LibCore", path: "Sources/LibCore", sources: []),
			]
		),
	]

	// A dependency's target selected by name: only its closure is watched.
	let byTarget = TargetClosure.reachedTargets(
		from: root, in: packages,
		selection: WatchSelection(explicitNames: ["Lib"]))
	#expect(byTarget[root] == nil)
	#expect(byTarget[dep] == ["Lib", "LibCore"])

	// An unresolvable name falls back to the broad root seeding.
	let unresolved = TargetClosure.reachedTargets(
		from: root, in: packages,
		selection: WatchSelection(explicitNames: ["Nope"]))
	#expect(unresolved[root] == ["App", "AppTests"])

	// Candidates broaden the root seeding without replacing it.
	let candidate = TargetClosure.reachedTargets(
		from: root, in: packages,
		selection: WatchSelection(candidateNames: ["Lib"]))
	#expect(candidate[root] == ["App", "AppTests"])
	#expect(candidate[dep] == ["Lib", "LibCore"])
}

@Test
func `target closure falls back to all targets when the root is unknown`() {
	let dep = URL(fileURLWithPath: "/dep", isDirectory: true)
	let packages: [URL: DescribedPackage] = [
		dep: DescribedPackage(
			path: "/dep",
			dependencies: [],
			targets: [
				.init(name: "A", path: "Sources/A", sources: []),
				.init(name: "B", path: "Sources/B", sources: []),
			]
		)
	]

	let reached = TargetClosure.reachedTargets(
		from: URL(fileURLWithPath: "/missing", isDirectory: true),
		in: packages
	)

	#expect(reached[dep] == ["A", "B"])
}

@Test
func `watch graph filters excluded paths and accepts relevant inputs`() {
	let graph = WatchGraph(
		packageRoots: [URL(fileURLWithPath: "/tmp/pkg", isDirectory: true)],
		sourceRoots: [URL(fileURLWithPath: "/tmp/pkg/Sources/App", isDirectory: true)],
		trackedFiles: [URL(fileURLWithPath: "/tmp/pkg/Package.swift")],
		manifestFiles: [URL(fileURLWithPath: "/tmp/pkg/Package.swift")],
		resolvedFiles: [URL(fileURLWithPath: "/tmp/pkg/Package.resolved")],
		sourceExtensions: ["swift"]
	)

	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift")))
	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/tmp/pkg/Package.swift")))
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/tmp/pkg/.build/debug/App")))
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/tmp/pkg/README.md")))
	// SwiftPM's source enumeration skips hidden files and directories, so
	// changes under them can never affect a build — even emacs lock files
	// like `.#main.swift`, whose names carry a real source extension. Other
	// editor temp conventions already fail the extension allowlist.
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/tmp/pkg/Sources/App/.#main.swift")))
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/tmp/pkg/Sources/App/.hidden.swift")))
	#expect(
		!graph.isRelevantChange(URL(fileURLWithPath: "/tmp/pkg/Sources/App/.gen/gen.swift"))
	)
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift~")))
	#expect(
		!graph.isRelevantChange(
			URL(fileURLWithPath: "/tmp/pkg/Sources/App/.main.swift.swp")))
}

@Test
func `directory traversal skips hidden children but walks hidden roots`() throws {
	let base = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	// The source root deliberately lives under a hidden directory: explicit
	// roots are walked regardless, only discovered children are judged.
	let sources = base.appendingPathComponent(".vendored/Sources/App", isDirectory: true)
	try FileManager.default.createDirectory(
		at: sources.appendingPathComponent(".gen", isDirectory: true),
		withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: base) }
	try "let a = 1".write(
		to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
	try "let b = 2".write(
		to: sources.appendingPathComponent(".gen/gen.swift"), atomically: true,
		encoding: .utf8)
	try "let c = 3".write(
		to: sources.appendingPathComponent(".#main.swift"), atomically: true,
		encoding: .utf8)

	let graph = WatchGraph(
		packageRoots: [],
		sourceRoots: [sources],
		trackedFiles: [],
		manifestFiles: [],
		resolvedFiles: [],
		sourceExtensions: ["swift"]
	)

	let files = try DirectoryTraversal.relevantFiles(
		under: [sources], graph: graph, fileManager: .default)

	#expect(files.map(\.lastPathComponent) == ["main.swift"])
}

@Test
func `watch graph prunes traversal of infrastructure and excluded roots`() {
	let graph = WatchGraph(
		packageRoots: [URL(fileURLWithPath: "/tmp/pkg", isDirectory: true)],
		sourceRoots: [URL(fileURLWithPath: "/tmp/pkg/Sources/App", isDirectory: true)],
		trackedFiles: [],
		manifestFiles: [URL(fileURLWithPath: "/tmp/pkg/Package.swift")],
		resolvedFiles: [],
		sourceExtensions: ["swift"],
		excludedRoots: [URL(fileURLWithPath: "/tmp/pkg/scratch", isDirectory: true)]
	)

	#expect(graph.prunesTraversal(URL(fileURLWithPath: "/tmp/pkg/.build", isDirectory: true)))
	#expect(
		graph.prunesTraversal(
			URL(fileURLWithPath: "/tmp/pkg/.git/objects", isDirectory: true)))
	#expect(graph.prunesTraversal(URL(fileURLWithPath: "/tmp/pkg/scratch", isDirectory: true)))
	#expect(graph.prunesTraversal(URL(fileURLWithPath: "/tmp/pkg/scratch/debug/gen.swift")))
	#expect(
		!graph.prunesTraversal(
			URL(fileURLWithPath: "/tmp/pkg/Sources/App", isDirectory: true)))
	// Excluded roots also veto relevance, even for source-shaped files.
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/tmp/pkg/scratch/debug/gen.swift")))
	// A directory that merely shares a prefix with an excluded root is kept.
	#expect(
		!graph.prunesTraversal(
			URL(fileURLWithPath: "/tmp/pkg/scratchpad", isDirectory: true)))
}

@Test
func `tracked files outrank the exclusion heuristics`() {
	// Exact paths from `swift package describe` are authoritative, so a
	// name-based heuristic must not silence them.
	let tracked = URL(fileURLWithPath: "/tmp/pkg/.gen/.#odd.swift")
	let graph = WatchGraph(
		packageRoots: [URL(fileURLWithPath: "/tmp/pkg", isDirectory: true)],
		sourceRoots: [],
		trackedFiles: [tracked],
		manifestFiles: [],
		resolvedFiles: [],
		sourceExtensions: ["swift"]
	)

	#expect(graph.isRelevantChange(tracked))
}

@Test
func `watch graph only requires rediscovery for manifest inputs`() {
	let manifest = URL(fileURLWithPath: "/tmp/pkg/Package.swift")
	let resolved = URL(fileURLWithPath: "/tmp/pkg/Package.resolved")
	let source = URL(fileURLWithPath: "/tmp/pkg/Sources/App/main.swift")

	let graph = WatchGraph(
		packageRoots: [URL(fileURLWithPath: "/tmp/pkg", isDirectory: true)],
		sourceRoots: [URL(fileURLWithPath: "/tmp/pkg/Sources/App", isDirectory: true)],
		trackedFiles: [manifest, resolved, source],
		manifestFiles: [manifest],
		resolvedFiles: [resolved],
		sourceExtensions: ["swift"]
	)

	#expect(!graph.requiresRediscovery(for: [source]))
	#expect(graph.requiresRediscovery(for: [source, manifest]))
	#expect(graph.requiresRediscovery(for: [resolved]))
	#expect(!graph.requiresRediscovery(for: [URL]()))
}

@Test
func `watcher registry reports duplicate and unknown watchers`() throws {
	let makeImplementation = { (name: String) in
		FileWatcherImplementation(name: name) { _ in StubWatcher() }
	}

	#expect(throws: SwiftWatchError.self) {
		try FileWatcherRegistry(implementations: [
			makeImplementation("a"), makeImplementation("a"),
		])
	}

	#expect(throws: SwiftWatchError.self) {
		try FileWatcherRegistry(implementations: [])
	}

	let registry = try FileWatcherRegistry(implementations: [makeImplementation("a")])
	#expect(registry.defaultWatcherName == "a")
	#expect(throws: SwiftWatchError.self) {
		try registry.makeWatcher(named: "missing")
	}
}

@Test
func `run supervisor sends SIGINT before SIGKILL`() async throws {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }

	let process = Process()
	process.executableURL = URL(fileURLWithPath: "/bin/sh")
	process.arguments = [
		"-c",
		"""
		trap 'exit 0' INT
		while :
		do
			sleep 1
		done
		""",
	]
	try process.run()

	await RunSupervisor().terminate(process, timeout: .seconds(2))

	#expect(!process.isRunning)
}

@Test
func `build command captures trailing arguments for swift build`() throws {
	let command = try SwiftWatchCommand.parseAsRoot([
		"build",
		"--debounce", "500",
		"--watcher", "polling",
		"--swift-bin-dir", "/opt/swift/bin",
		"--package-path", "/tmp/pkg",
		"--configuration", "release",
		"-Xswiftc", "-DDEBUG",
		"--build-tests",
	])

	guard let build = command as? SwiftWatchCommand.Build else {
		Issue.record("Expected Build command.")
		return
	}

	#expect(
		build.swiftArgs == [
			"--configuration", "release",
			"-Xswiftc", "-DDEBUG",
			"--build-tests",
		])
	#expect(build.options.debounce == 500)
	#expect(build.options.pollInterval == 150)
	#expect(build.options.watcher == "polling")
	#expect(build.options.swiftBinDir == "/opt/swift/bin")
	#expect(build.options.packagePath == "/tmp/pkg")
}

@Test
func `build command parses explicit target and product selection`() throws {
	let command = try SwiftWatchCommand.parseAsRoot([
		"build",
		"--target", "Foo",
		"--product", "Bar",
		"--configuration", "release",
	])

	guard let build = command as? SwiftWatchCommand.Build else {
		Issue.record("Expected Build command.")
		return
	}

	#expect(build.target == "Foo")
	#expect(build.product == "Bar")
	#expect(build.swiftArgs == ["--configuration", "release"])
}

@Test
func `forwarded selection flags are detected for the warning`() {
	#expect(
		forwardedSelectionFlags(in: ["--target", "Foo", "-v"]) == ["--target"])
	#expect(
		forwardedSelectionFlags(in: ["--product=Bar"]) == ["--product=Bar"])
	#expect(
		forwardedSelectionFlags(in: ["--configuration", "release"]).isEmpty)
	// Flags after `swift-watch build`'s first unrecognized argument land in
	// the passthrough list rather than in the parsed options, so the scan
	// must see them there.
	#expect(
		forwardedSelectionFlags(in: ["--configuration", "release", "--target", "Foo"])
			== ["--target"])
}

@Test
func `a leading passthrough separator is not forwarded`() throws {
	// `captureForPassthrough` keeps the `--` separator in the captured
	// arguments, and `swift build` rejects everything after a literal `--`.
	let command = try SwiftWatchCommand.parseAsRoot([
		"build", "--", "--configuration", "release",
	])
	guard let build = command as? SwiftWatchCommand.Build else {
		Issue.record("Expected Build command.")
		return
	}
	#expect(build.swiftArgs == ["--", "--configuration", "release"])

	#expect(
		normalizedPassthrough(["--", "--configuration", "release"])
			== ["--configuration", "release"])
	// A separator the user placed mid-stream keeps `swift build`'s own
	// semantics and is forwarded untouched.
	#expect(normalizedPassthrough(["-v", "--", "x"]) == ["-v", "--", "x"])
	#expect(normalizedPassthrough([]).isEmpty)
}

@Test
func `forwarded directory overrides are extracted for exclusion`() {
	#expect(
		forwardedDirectoryOverrides(
			in: ["--configuration", "release", "--scratch-path", ".scratch"],
			stopAtFirstPositional: false)
			== [".scratch"])
	#expect(
		forwardedDirectoryOverrides(
			in: ["--build-path=out", "--cache-path", "/tmp/cache"],
			stopAtFirstPositional: false)
			== ["out", "/tmp/cache"])
	// For `swift run`, scanning stops at the executable name so the launched
	// executable's own flags are never misread.
	#expect(
		forwardedDirectoryOverrides(
			in: ["--scratch-path", ".scratch", "Exe", "--scratch-path", "victim"],
			stopAtFirstPositional: true)
			== [".scratch"])
	#expect(
		forwardedDirectoryOverrides(
			in: ["Exe", "--scratch-path", "victim"],
			stopAtFirstPositional: true
		)
		.isEmpty)
	// A trailing flag with no value is left for `swift build` to reject.
	#expect(
		forwardedDirectoryOverrides(in: ["--scratch-path"], stopAtFirstPositional: false)
			.isEmpty)
}

@Test
func `run command captures trailing arguments for swift run`() throws {
	let command = try SwiftWatchCommand.parseAsRoot([
		"run",
		"--package-path", "/tmp/pkg",
		"MyExecutable",
		"--flag",
		"value",
		"--another-flag",
	])

	guard let run = command as? SwiftWatchCommand.Run else {
		Issue.record("Expected Run command.")
		return
	}

	#expect(
		run.swiftArgs == [
			"MyExecutable",
			"--flag",
			"value",
			"--another-flag",
		])
	#expect(run.options.packagePath == "/tmp/pkg")
}

@Test
func `swift tool runner resolves swift from PATH`() async throws {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString,
		isDirectory: true
	)
	let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
	try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }

	let manifest = """
		// swift-tools-version: 6.0
		import PackageDescription

		let package = Package(
			name: "TempPackage",
			targets: [
				.executableTarget(name: "App")
			]
		)
		"""
	try manifest.write(
		to: root.appendingPathComponent("Package.swift"),
		atomically: true,
		encoding: .utf8
	)
	try "print(\"hello\")\n".write(
		to: sources.appendingPathComponent("main.swift"),
		atomically: true,
		encoding: .utf8
	)

	let package = try await SwiftToolRunner().describe(
		packagePath: root,
		swiftBinDirectory: nil
	)

	#expect(
		URL(fileURLWithPath: package.path).standardizedFileURL
			== root.standardizedFileURL
	)
	#expect(package.targets.contains { $0.path == "Sources/App" })
}

private struct StubWatcher: FileWatcher {
	func startSession(for graph: WatchGraph) throws(SwiftWatchError) -> any FileWatcherSession {
		StubSession()
	}
}

private final class StubSession: FileWatcherSession {
	func waitForChange(debounce: Duration) async throws(SwiftWatchError) -> [URL] { [] }
	func stop() {}
}

private final class MockRunner: SwiftToolRunning {
	let descriptions: [String: DescribedPackage]

	init(descriptions: [String: DescribedPackage]) {
		self.descriptions = descriptions
	}

	func describe(packagePath: URL, swiftBinDirectory: URL?) async throws(SwiftWatchError)
		-> DescribedPackage
	{
		guard let package = descriptions[packagePath.standardizedFileURL.path] else {
			throw SwiftWatchError.packageDescribeFailed(packagePath.path)
		}
		return package
	}

	func runBuild(packagePath: URL, swiftBinDirectory: URL?, args: [String])
		async throws(SwiftWatchError) -> Int32
	{
		0
	}

	func launchRun(packagePath: URL, swiftBinDirectory: URL?, args: [String])
		async
		throws(SwiftWatchError) -> Process
	{
		fatalError("unused")
	}
}
