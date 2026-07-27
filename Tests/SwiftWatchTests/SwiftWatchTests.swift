import ArgumentParser
import Testing

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
func `describe JSON decodes declared resources`() throws {
	let json = """
		{
		  "path": "/tmp/root",
		  "dependencies": [],
		  "targets": [
		    {
		      "name": "App",
		      "path": "Sources/App",
		      "sources": ["main.swift"],
		      "resources": [
		        {
		          "path": "/tmp/root/Sources/App/model.proto",
		          "rule": { "copy": {} }
		        },
		        {
		          "path": "/tmp/root/Sources/App/Config.json",
		          "rule": { "process": { "localization": null } }
		        }
		      ]
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
	// Both rules mark a build input, so the rule itself is not modelled.
	#expect(
		package.targets[0].resources.map(\.path) == [
			"/tmp/root/Sources/App/model.proto",
			"/tmp/root/Sources/App/Config.json",
		])
	// A target without resources omits the key entirely.
	#expect(package.targets[1].resources.isEmpty)
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
func `package discovery tracks declared resources by kind`() async throws {
	// Resources are classified against the real file system, so this fixture
	// has to exist on disk rather than living at a synthetic path.
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let target = root.appendingPathComponent("Sources/App", isDirectory: true)
	let protos = target.appendingPathComponent("Protos", isDirectory: true)
	try FileManager.default.createDirectory(at: protos, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }
	try "{}".write(
		to: target.appendingPathComponent("Config.json"), atomically: true, encoding: .utf8)

	let runner = MockRunner(descriptions: [
		root.standardizedFileURL.path: DescribedPackage(
			path: root.standardizedFileURL.path,
			dependencies: [],
			targets: [
				.init(
					name: "App", path: "Sources/App", sources: ["main.swift"],
					resources: [
						.init(path: protos.standardizedFileURL.path),
						.init(
							path: target.appendingPathComponent(
								"Config.json"
							)
							.path),
						// An entry that no longer exists is tracked exactly,
						// which still catches its recreation.
						.init(
							path: target.appendingPathComponent(
								"Gone.json"
							)
							.path),
					])
			]
		)
	])

	let graph = try await PackageDiscovery(runner: runner).discover(
		from: root, swiftBinDirectory: nil)

	#expect(graph.trackedRoots.map(\.path) == [protos.standardizedFileURL.path])
	// Resource paths arrive absolute, and a Windows one must not be read as
	// relative and appended to the target root.
	#expect(
		isRelativePath(#"C:\pkg\Sources\App\Config.json"#) == false)
	#expect(isRelativePath("/pkg/Sources/App/Config.json") == false)
	#expect(isRelativePath("Config.json") == true)
	#expect(isRelativePath("Protos/model.proto") == true)
	let tracked = graph.trackedFiles.map(\.path)
	#expect(tracked.contains(target.appendingPathComponent("Config.json").path))
	#expect(tracked.contains(target.appendingPathComponent("Gone.json").path))
	#expect(!tracked.contains(protos.standardizedFileURL.path))
}

@Test
func `watch graph accepts anything inside a declared resource directory`() {
	let protos = URL(fileURLWithPath: "/tmp/pkg/Sources/App/Protos", isDirectory: true)
	let graph = WatchGraph(
		packageRoots: [URL(fileURLWithPath: "/tmp/pkg", isDirectory: true)],
		sourceRoots: [URL(fileURLWithPath: "/tmp/pkg/Sources/App", isDirectory: true)],
		trackedFiles: [],
		trackedRoots: [protos],
		manifestFiles: [],
		resolvedFiles: [],
		sourceExtensions: ["swift"]
	)

	// The extension allowlist does not apply: declaring a resource directory
	// is the statement that its contents are build inputs. Without this, a
	// build tool plugin's inputs would never retrigger a build.
	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/tmp/pkg/Sources/App/Protos/a.proto")))
	#expect(
		graph.isRelevantChange(
			URL(fileURLWithPath: "/tmp/pkg/Sources/App/Protos/nested/b.graphql")))
	// Hidden entries stay excluded, matching SwiftPM's own enumeration.
	#expect(
		!graph.isRelevantChange(
			URL(fileURLWithPath: "/tmp/pkg/Sources/App/Protos/.#a.proto")))
	// A sibling that merely shares the prefix is not inside the directory, so
	// it falls back to the source-root rules and fails the allowlist.
	#expect(
		!graph.isRelevantChange(
			URL(fileURLWithPath: "/tmp/pkg/Sources/App/ProtosOld/a.proto")))
	// Build output nested under a resource directory is still pruned.
	#expect(
		!graph.isRelevantChange(
			URL(fileURLWithPath: "/tmp/pkg/Sources/App/Protos/.build/a.proto")))
}

@Test
func `build manifest parsing keeps file inputs and drops other node kinds`() throws {
	// Shaped like the llbuild manifest SwiftPM writes: one-line JSON flow
	// sequences, virtual nodes in angle brackets, directory nodes with a
	// trailing separator.
	let yaml = """
		client:
		  name: swift-build
		commands:
		  "C.App-debug.module":
		    tool: shell
		    inputs: ["/pkg/Sources/App/main.swift","/pkg/.build/debug/App.build/sources"]
		    outputs: ["/pkg/.build/debug/App.build/main.swift.o"]
		  "Generating from protos":
		    tool: shell
		    inputs: ["/pkg/Sources/App/Protos/a.proto","/pkg/Sources/App/Protos/config.json"]
		  "PackageStructure":
		    tool: package-structure-tool
		    inputs: ["/pkg/Sources/App/","/pkg/Package.swift","<virtual-node>"]
		    outputs: ["<PackageStructure>"]
		"""
	let base = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: base) }
	let path = base.appendingPathComponent("debug.yaml")
	try yaml.write(to: path, atomically: true, encoding: .utf8)

	let inputs = Set(NativeBuildManifest().readPaths(at: path))

	#expect(inputs.contains("/pkg/Sources/App/Protos/a.proto"))
	#expect(inputs.contains("/pkg/Sources/App/Protos/config.json"))
	#expect(inputs.contains("/pkg/Sources/App/main.swift"))
	#expect(inputs.contains("/pkg/Package.swift"))
	// Directory and virtual nodes are not files to watch, and outputs are not
	// inputs at all.
	#expect(!inputs.contains("/pkg/Sources/App"))
	#expect(!inputs.contains("<virtual-node>"))
	#expect(!inputs.contains("/pkg/.build/debug/App.build/main.swift.o"))
	// SwiftPM rewrites the manifest in place rather than renaming a finished one
	// over it, so a reader can catch the file between the truncate and the
	// write — but only ever at zero bytes, because the content goes out in one
	// burst. That and an unwritten manifest are the same answer, and `unwritten`
	// says so: neither is a build that reads nothing.
	let empty = base.appendingPathComponent("empty.yaml")
	try "".write(to: empty, atomically: true, encoding: .utf8)
	#expect(NativeBuildManifest().read(at: empty) == .unwritten)
	#expect(
		NativeBuildManifest().read(at: base.appendingPathComponent("absent.yaml"))
			== .unwritten)
}

@Test
func `a cross-compiled manifest is found under the triple it built for`() throws {
	// `--triple` and `--swift-sdk` are forwarded without being parsed, so the
	// subdirectory they produce is found on disk rather than computed.
	let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let triple = scratch.appendingPathComponent(
		"aarch64-unknown-linux-gnu", isDirectory: true)
	try FileManager.default.createDirectory(at: triple, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: scratch) }
	try #"  "Gen":\#n    inputs: ["/pkg/Sources/App/Protos/a.proto"]"#
		.write(
			to: triple.appendingPathComponent("debug.yaml"), atomically: true,
			encoding: .utf8)

	let reader = NativeBuildManifest()
	let inputs = reader.readPaths(
		at: reader.manifestLocation(scratchPath: scratch, configuration: "debug"))

	#expect(inputs == ["/pkg/Sources/App/Protos/a.proto"])
	// A configuration nobody built still reads as absent, not as a stray match.
	#expect(
		reader.read(
			at: reader.manifestLocation(
				scratchPath: scratch, configuration: "release")) == .unwritten)
}

extension BuildManifestReading {
	/// The input paths read at `location`, as strings, so assertions read as
	/// the manifests do.
	func readPaths(at location: URL) -> [String] {
		(read(at: location, fileManager: .default).readInputs ?? []).map(\.path).sorted()
	}
}

/// Writes an `XCBuildData` tree holding one plan directory per entry, oldest
/// first, so the newest is unambiguous.
private func writeSwiftBuildManifests(
	_ manifests: [(hash: String, json: String)], under scratch: URL
) throws -> URL {
	let location = SwiftBuildManifest().manifestLocation(
		scratchPath: scratch, configuration: "debug")
	for (offset, manifest) in manifests.enumerated() {
		let directory = location.appendingPathComponent(
			"\(manifest.hash).xcbuilddata", isDirectory: true)
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true)
		let file = directory.appendingPathComponent("manifest.json")
		try manifest.json.write(to: file, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes(
			[.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(offset))],
			ofItemAtPath: file.path)
	}
	return location
}

@Test
func `swift build manifests are read from the newest plan`() throws {
	// Swift Build writes a new hashed directory whenever the plan changes and
	// leaves the old one in place, so the stale plan is still on disk holding
	// the input set of a build that no longer describes anything.
	let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	defer { try? FileManager.default.removeItem(at: scratch) }

	let location = try writeSwiftBuildManifests(
		[
			(
				"stale",
				#"{"commands":{"Gen":{"inputs":["/pkg/Sources/App/Protos/a.proto"]}}}"#
			),
			(
				"current",
				#"""
				{
				  "client": {"name": "basic"},
				  "targets": {"": ["<all>"]},
				  "nodes": {"/pkg": {"is-directory": true}},
				  "commands": {
				    "CustomTask Generating from 2 scanned inputs": {
				      "tool": "shell",
				      "description": "Generating",
				      "inputs": [
				        "/bin/sh",
				        "/pkg/Sources/App/Protos/a.proto",
				        "/pkg/Sources/App/Protos/b.proto",
				        "/pkg/Sources/App/",
				        "<target-App-ModuleVerifierTaskProducer>"
				      ],
				      "outputs": ["/pkg/.build-swiftbuild/out/Generated.swift"]
				    },
				    "P0:::Gate": {"tool": "phony", "inputs": [], "outputs": ["<gate>"]}
				  }
				}
				"""#
			),
		],
		under: scratch
	)

	let inputs = SwiftBuildManifest().readPaths(at: location)

	// The newest plan alone: the stale directory's a.proto happens to be listed
	// here too, but b.proto proves which one was read.
	#expect(
		inputs == [
			"/bin/sh",
			"/pkg/Sources/App/Protos/a.proto",
			"/pkg/Sources/App/Protos/b.proto",
		])
	// Same llbuild node kinds as the native manifest: directory nodes carry a
	// trailing separator and virtual nodes are angle-bracketed. Paths outside
	// the package, `/bin/sh` here, are dropped later by the graph rather than
	// by the reader, which knows nothing about package roots.
	#expect(!inputs.contains("/pkg/Sources/App"))
	#expect(!inputs.contains("<target-App-ModuleVerifierTaskProducer>"))
	#expect(!inputs.contains("/pkg/.build-swiftbuild/out/Generated.swift"))
}

@Test
func `swift build manifest reading names as little of the format as it can`() throws {
	let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	defer { try? FileManager.default.removeItem(at: scratch) }

	// Only `commands` and `inputs` are contractual. A command carrying an
	// `inputs` of some shape this does not expect is skipped rather than
	// costing every other command its inputs, and keys that come and go are
	// never named at all.
	let location = try writeSwiftBuildManifests(
		[
			(
				"drift",
				#"""
				{
				  "commands": {
				    "Understood": {"inputs": ["/pkg/Sources/App/Protos/a.proto"]},
				    "ShapeChanged": {"inputs": [{"path": "/pkg/Sources/App/b.proto"}]},
				    "NoInputsAtAll": {"tool": "phony"},
				    "FieldsAdded": {
				      "inputs": ["/pkg/Sources/App/Protos/c.proto"],
				      "something-new": {"nested": [1, 2, 3]}
				    }
				  },
				  "an-entirely-new-top-level-key": [1, 2, 3]
				}
				"""#
			)
		],
		under: scratch
	)

	#expect(
		SwiftBuildManifest().readPaths(at: location) == [
			"/pkg/Sources/App/Protos/a.proto",
			"/pkg/Sources/App/Protos/c.proto",
		])
}

@Test
func `an unreadable swift build manifest reports rather than reading empty`() throws {
	// A scratch directory each, so every case is judged on its own newest plan
	// rather than on whichever fixture happened to be written last.
	let scratches = (0..<3).map { _ in
		FileManager.default.temporaryDirectory.appendingPathComponent(
			UUID().uuidString, isDirectory: true)
	}
	defer { scratches.forEach { try? FileManager.default.removeItem(at: $0) } }

	// Nothing written yet is the normal state of a clean checkout, and says so
	// silently.
	#expect(
		SwiftBuildManifest().read(
			at: SwiftBuildManifest().manifestLocation(
				scratchPath: scratches[0], configuration: "debug")) == .unwritten)

	// A file caught mid-write is the same answer: JSON either decodes whole or
	// not at all, so a torn read can never contribute a convincing subset.
	let torn = try writeSwiftBuildManifests([("torn", "")], under: scratches[1])
	#expect(SwiftBuildManifest().read(at: torn) == .unwritten)

	// Content that is not a manifest at all is how a format change would
	// present, and that is worth saying out loud once rather than degrading in
	// silence.
	let changed = try writeSwiftBuildManifests(
		[("changed", "not json at all")], under: scratches[2])
	let reason = SwiftBuildManifest().read(at: changed).unreadableReason
	#expect(reason?.contains("swift-watch understands") == true)
	#expect(reason?.contains("changed.xcbuilddata") == true)
}

@Test
func `each reader knows where its build system writes`() {
	let scratch = URL(fileURLWithPath: "/pkg/.build", isDirectory: true)

	// The native manifest is named for the configuration.
	#expect(
		NativeBuildManifest().manifestLocation(
			scratchPath: scratch, configuration: "debug"
		).path == "/pkg/.build/debug.yaml")
	#expect(
		NativeBuildManifest().manifestLocation(
			scratchPath: scratch, configuration: "release"
		).path == "/pkg/.build/release.yaml")

	// Swift Build folds the configuration into a hash inside one directory, so
	// the location is the same whatever was asked for, and the newest manifest
	// in it is the build that just ran.
	let debug = SwiftBuildManifest().manifestLocation(
		scratchPath: scratch, configuration: "debug")
	#expect(debug.path == "/pkg/.build/out/Intermediates.noindex/XCBuildData")
	#expect(
		SwiftBuildManifest().manifestLocation(
			scratchPath: scratch, configuration: "release") == debug)
}

@Test
func `the build system is read from the forwarded arguments`() {
	// `native` is what `swift build` uses when nobody says otherwise.
	#expect(forwardedBuildSystem(in: [], stopAtFirstPositional: false) == .native)
	#expect(
		forwardedBuildSystem(
			in: ["--build-system", "swiftbuild"], stopAtFirstPositional: false)
			== .swiftBuild)
	#expect(
		forwardedBuildSystem(
			in: ["--build-system=swiftbuild"], stopAtFirstPositional: false)
			== .swiftBuild)
	// Past the executable name of `swift run`, the words belong to it.
	#expect(
		forwardedBuildSystem(
			in: ["MyExecutable", "--build-system", "swiftbuild"],
			stopAtFirstPositional: true) == .native)
	// A build system a later toolchain adds is carried by name rather than
	// rejected, and simply has no reader.
	let unknown = forwardedBuildSystem(
		in: ["--build-system", "future"], stopAtFirstPositional: false)
	#expect(unknown == .unrecognised(name: "future"))
	#expect(unknown.name == "future")
	#expect(unknown.reader == nil)
	#expect(BuildSystem.native.reader is NativeBuildManifest)
	#expect(BuildSystem.swiftBuild.reader is SwiftBuildManifest)
}

@Test
func `forwarded flag values are read in both spellings`() {
	#expect(
		forwardedFlagValue(
			of: ["-c", "--configuration"], in: ["-c", "release"],
			stopAtFirstPositional: false) == "release")
	#expect(
		forwardedFlagValue(
			of: ["-c", "--configuration"], in: ["--configuration=release"],
			stopAtFirstPositional: false) == "release")
	#expect(
		forwardedFlagValue(
			of: ["--scratch-path"], in: ["--verbose"],
			stopAtFirstPositional: false) == nil)
	// `swift` acts on the last spelling of a repeated flag, so the manifest
	// lands where that one says.
	#expect(
		forwardedFlagValue(
			of: ["-c", "--configuration"], in: ["-c", "debug", "-c", "release"],
			stopAtFirstPositional: false) == "release")
	// Past the executable name of `swift run`, the words belong to it.
	#expect(
		forwardedFlagValue(
			of: ["-c"], in: ["MyExecutable", "-c", "release"],
			stopAtFirstPositional: true) == nil)
}

@Test
func `build inputs cover plugin inputs and their undiscovered siblings`() {
	let root = URL(fileURLWithPath: "/pkg", isDirectory: true)
	let graph = WatchGraph(
		packageRoots: [root],
		sourceRoots: [URL(fileURLWithPath: "/pkg/Sources/App", isDirectory: true)],
		trackedFiles: [],
		manifestFiles: [],
		resolvedFiles: [],
		sourceExtensions: ["swift"],
		buildInputs: [
			URL(fileURLWithPath: "/pkg/Sources/App/Protos/a.proto"),
			URL(fileURLWithPath: "/pkg/Sources/App/Protos/config.json"),
			// Build output and toolchain paths share the manifest with real
			// inputs and must not be watched.
			URL(fileURLWithPath: "/pkg/.build/debug/App.build/sources"),
			URL(fileURLWithPath: "/toolchain/usr/lib/swift/Swift.swiftmodule"),
		]
	)

	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/Protos/a.proto")))
	#expect(
		graph.isRelevantChange(
			URL(fileURLWithPath: "/pkg/Sources/App/Protos/config.json")))
	// A plugin that scans for its inputs picks up new files silently, and
	// nothing would wake the loop to notice, so the directory counts whole:
	// new files, new file types, and new subdirectories alike.
	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/Protos/c.proto")))
	#expect(
		graph.isRelevantChange(
			URL(fileURLWithPath: "/pkg/Sources/App/Protos/schema.graphql")))
	#expect(
		graph.isRelevantChange(
			URL(fileURLWithPath: "/pkg/Sources/App/Protos/deep/f.proto")))
	// The cost of that: a README in the same directory rebuilds once.
	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/Protos/README.md")))
	#expect(
		!graph.isRelevantChange(
			URL(fileURLWithPath: "/pkg/Sources/App/Protos/.#a.proto")))
	// The directory is what widens, not the extension everywhere.
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/other.proto")))
	#expect(
		!graph.isRelevantChange(URL(fileURLWithPath: "/pkg/.build/debug/App.build/sources"))
	)
	#expect(
		!graph.isRelevantChange(
			URL(fileURLWithPath: "/toolchain/usr/lib/swift/Swift.swiftmodule")))
	// Only the paths worth watching form the comparison set, so a rewritten
	// manifest that only moved build output does not look like a change.
	#expect(
		graph.buildInputs.map(\.path).sorted() == [
			"/pkg/Sources/App/Protos/a.proto",
			"/pkg/Sources/App/Protos/config.json",
		])
	#expect(graph.buildInputRoots.map(\.path) == ["/pkg/Sources/App/Protos"])
}

@Test
func `a subdirectory of nothing but sources is the target's, not a plugin's`() {
	// Every compiled file is an input of the build, so a target's own
	// subdirectories are indistinguishable from a plugin's by the manifest
	// alone. What they hold tells them apart.
	let graph = WatchGraph(
		packageRoots: [URL(fileURLWithPath: "/pkg", isDirectory: true)],
		sourceRoots: [URL(fileURLWithPath: "/pkg/Sources/App", isDirectory: true)],
		trackedFiles: [],
		manifestFiles: [],
		resolvedFiles: [],
		sourceExtensions: ["swift", "h"],
		buildInputs: [
			URL(fileURLWithPath: "/pkg/Sources/App/Models/User.swift"),
			URL(fileURLWithPath: "/pkg/Sources/App/Protos/a.proto"),
			// A directory holding both is still the plugin's: the test errs
			// towards watching more.
			URL(fileURLWithPath: "/pkg/Sources/App/Mixed/Generated.swift"),
			URL(fileURLWithPath: "/pkg/Sources/App/Mixed/schema.proto"),
		]
	)

	#expect(
		graph.buildInputRoots.map(\.path).sorted() == [
			"/pkg/Sources/App/Mixed", "/pkg/Sources/App/Protos",
		])
	// A note beside a module's sources is not a build input, whoever put it
	// there.
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/Models/notes.txt")))
	// The narrower rule still covers the directory, so a new source file in it
	// counts.
	let addedSource = URL(fileURLWithPath: "/pkg/Sources/App/Models/New.swift")
	#expect(graph.isRelevantChange(addedSource))
	#expect(graph.matchedRule(for: addedSource)?.ruleName == "plugin-input-extensions")
	// A directory the build reads anything else from keeps its whole-directory
	// watch.
	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/Protos/README.md")))
	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/Mixed/notes.txt")))
}

@Test
func `a build input above a target root does not widen to the whole tree`() {
	// `Sources` is nobody's target root, but it contains every target. Watching
	// it whole would resurrect the targets the closure deliberately pruned.
	let graph = WatchGraph(
		packageRoots: [URL(fileURLWithPath: "/pkg", isDirectory: true)],
		sourceRoots: [
			URL(fileURLWithPath: "/pkg/Sources/App", isDirectory: true),
			URL(fileURLWithPath: "/pkg/Sources/Used", isDirectory: true),
		],
		trackedFiles: [],
		manifestFiles: [],
		resolvedFiles: [],
		sourceExtensions: ["swift"],
		buildInputs: [URL(fileURLWithPath: "/pkg/Sources/shared.txt")]
	)

	#expect(graph.buildInputRoots.isEmpty)
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/Used/README.md")))
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/Pruned/other.txt")))
	// The input itself is still watched, by path.
	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/shared.txt")))
}

@Test
func `disabling a rule narrows the graph to what the build reported`() {
	let protos = URL(fileURLWithPath: "/pkg/Sources/App/Protos/a.proto")
	let resources = URL(fileURLWithPath: "/pkg/Sources/App/Assets", isDirectory: true)
	let makeGraph = { (rules: WatchRules) in
		WatchGraph(
			packageRoots: [URL(fileURLWithPath: "/pkg", isDirectory: true)],
			sourceRoots: [URL(fileURLWithPath: "/pkg/Sources/App", isDirectory: true)],
			trackedFiles: [],
			trackedRoots: [resources],
			manifestFiles: [],
			resolvedFiles: [],
			sourceExtensions: ["swift"],
			buildInputs: [protos],
			rules: rules
		)
	}

	let all = makeGraph(.default)
	#expect(all.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/Protos/new.proto")))
	#expect(all.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/Assets/logo.png")))
	#expect(all.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/new.swift")))

	var narrowed = WatchRules.default
	narrowed.remove(.pluginInputDirectories)
	narrowed.remove(.declaredResourceDirectories)
	narrowed.remove(.sourceExtensions)
	let strict = makeGraph(narrowed)
	#expect(!strict.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/Protos/new.proto")))
	#expect(!strict.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/Assets/logo.png")))
	#expect(!strict.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/new.swift")))
	// What the build reported reading is not a rule and cannot be turned off,
	// or the watcher would stop catching what it exists for.
	#expect(strict.isRelevantChange(protos))
	#expect(strict.matchedRule(for: protos) == .trackedPath)
	// A disabled rule leaves no widened state behind for anything else to read.
	#expect(strict.buildInputRoots.isEmpty)
	#expect(strict.trackedRoots.isEmpty)
}

@Test
func `rule names round-trip and reject unknown spellings`() {
	#expect(WatchRules(name: "plugin-input-directories") == .pluginInputDirectories)
	#expect(WatchRules(name: "source-extensions") == .sourceExtensions)
	#expect(WatchRules(name: "no-such-rule") == nil)
	#expect(WatchRules.allNames.count == 4)
	// Every rule the default set carries is spellable on the command line.
	for (_, rule) in WatchRules.named {
		#expect(WatchRules.default.contains(rule))
	}
}

@Test
func `matched rules name the reason a change counted`() {
	let graph = WatchGraph(
		packageRoots: [URL(fileURLWithPath: "/pkg", isDirectory: true)],
		sourceRoots: [URL(fileURLWithPath: "/pkg/Sources/App", isDirectory: true)],
		trackedFiles: [],
		trackedRoots: [URL(fileURLWithPath: "/pkg/Sources/App/Assets", isDirectory: true)],
		manifestFiles: [],
		resolvedFiles: [],
		sourceExtensions: ["swift"],
		buildInputs: [
			URL(fileURLWithPath: "/pkg/Sources/App/Protos/a.proto"),
			URL(fileURLWithPath: "/pkg/Sources/App/schema.json"),
		]
	)

	#expect(
		graph.matchedRule(for: URL(fileURLWithPath: "/pkg/Sources/App/Protos/README.md"))
			== .pluginInputDirectory(root: "/pkg/Sources/App/Protos"))
	#expect(
		graph.matchedRule(for: URL(fileURLWithPath: "/pkg/Sources/App/other.json"))
			== .pluginInputExtension(root: "/pkg/Sources/App"))
	#expect(
		graph.matchedRule(for: URL(fileURLWithPath: "/pkg/Sources/App/Assets/logo.png"))
			== .declaredResourceDirectory(root: "/pkg/Sources/App/Assets"))
	#expect(
		graph.matchedRule(for: URL(fileURLWithPath: "/pkg/Sources/App/new.swift"))
			== .sourceExtension(root: "/pkg/Sources/App"))
	#expect(graph.matchedRule(for: URL(fileURLWithPath: "/pkg/README.md")) == nil)
	// The reported reason names the rule that would be spelled on the command
	// line, so a surprising rebuild points at the flag that would stop it.
	let match = graph.matchedRule(
		for: URL(fileURLWithPath: "/pkg/Sources/App/Protos/README.md"))
	#expect(match?.ruleName == "plugin-input-directories")
	#expect(WatchRules.allNames.contains(match?.ruleName ?? ""))
	#expect(match?.explanation.contains("/pkg/Sources/App/Protos") == true)
}

@Test
func `build inputs beside a target's sources widen only by extension`() {
	// Prefix-watching here would swallow the target: the directory holds the
	// module's sources, not just a plugin's inputs.
	let target = URL(fileURLWithPath: "/pkg/Sources/App", isDirectory: true)
	let graph = WatchGraph(
		packageRoots: [URL(fileURLWithPath: "/pkg", isDirectory: true)],
		sourceRoots: [target],
		trackedFiles: [],
		manifestFiles: [],
		resolvedFiles: [],
		sourceExtensions: ["swift"],
		buildInputs: [
			URL(fileURLWithPath: "/pkg/Sources/App/schema.json"),
			// A package-root input must not widen the package either.
			URL(fileURLWithPath: "/pkg/Package.swift"),
		]
	)

	#expect(graph.buildInputRoots.isEmpty)
	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/schema.json")))
	#expect(graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/other.json")))
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/pkg/Sources/App/README.md")))
	#expect(!graph.isRelevantChange(URL(fileURLWithPath: "/pkg/README.md")))
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

/// Writes a directory holding a `swift` stand-in that behaves like a watched
/// executable: it stays up until signalled.
private func makeStubSwiftBinDirectory(script: String) throws -> URL {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	let executable = root.appendingPathComponent("swift")
	try "#!/bin/sh\n\(script)\n".write(to: executable, atomically: true, encoding: .utf8)
	try FileManager.default.setAttributes(
		[.posixPermissions: 0o755], ofItemAtPath: executable.path)
	return root
}

@Test
func `swift run is interrupted before it is killed`() async throws {
	let root = try makeStubSwiftBinDirectory(
		script: """
			trap 'touch "$0.interrupted"; exit 0' INT
			while :
			do
				sleep 1
			done
			"""
	)
	defer { try? FileManager.default.removeItem(at: root) }

	try await SwiftToolRunner().withRun(
		packagePath: root,
		swiftBinDirectory: root,
		args: []
	) {
		// Leaves the shell time to install its trap before shutdown starts.
		try? await Task.sleep(for: .milliseconds(300))
	}

	// The marker only exists if the trap ran, so the executable was interrupted
	// rather than killed outright.
	#expect(
		FileManager.default.fileExists(
			atPath: root.appendingPathComponent("swift.interrupted").path))
}

/// Guards against the executable inheriting a signal mask that blocks `SIGINT`.
/// That left it deaf to everything but `SIGKILL`, so every shutdown waited out
/// the full termination timeout — stalling each rebuild by 30 seconds.
@Test
func `swift run is shut down promptly`() async throws {
	let root = try makeStubSwiftBinDirectory(script: "exec sleep 30")
	defer { try? FileManager.default.removeItem(at: root) }

	let start = ContinuousClock.now
	try await SwiftToolRunner().withRun(packagePath: root, swiftBinDirectory: root, args: []) {}

	#expect(ContinuousClock.now - start < .seconds(5))
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
func `build command keeps target and product in forwarded arguments`() throws {
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

	#expect(
		build.swiftArgs == [
			"--target", "Foo",
			"--product", "Bar",
			"--configuration", "release",
		])
}

@Test
func `forwarded build selection is read from forwarded arguments`() {
	#expect(
		forwardedBuildSelection(in: ["--target", "Foo", "-v"]).explicitNames
			== ["Foo"])
	#expect(
		forwardedBuildSelection(in: ["--product=Bar"]).explicitNames
			== ["Bar"])
	#expect(
		forwardedBuildSelection(
			in: ["--target", "Old", "--configuration", "release", "--target=New"]
		).explicitNames == ["New"])
	#expect(
		forwardedBuildSelection(
			in: ["--target", "Foo", "--product", "Bar"]
		).explicitNames == ["Foo", "Bar"])
	#expect(
		forwardedBuildSelection(in: ["--configuration", "release"]).explicitNames
			.isEmpty)
}

@Test
func `a malformed selection flag selects nothing rather than failing`() {
	// `swift build` reports its own argument errors, and an unresolved name
	// would fall back to watching the whole root package anyway.
	#expect(forwardedBuildSelection(in: ["--target"]).explicitNames.isEmpty)
	#expect(
		forwardedBuildSelection(in: ["--target="]).explicitNames == [""])
	#expect(
		forwardedBuildSelection(in: ["--product", "--configuration", "release"])
			.explicitNames == ["--configuration"])
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
func `a leading help flag is claimed, a later one is forwarded`() throws {
	// `.captureForPassthrough` hides `--help` from ArgumentParser, so the
	// subcommands claim a leading one themselves rather than start watching.
	for argv in [["build", "--help"], ["run", "-h"], ["test", "--help"]] {
		let command = try SwiftWatchCommand.parseAsRoot(argv)
		#expect(throws: CleanExit.self) {
			try exitIfHelpRequested(
				argv.count > 1 ? Array(argv.dropFirst()) : [], for: command)
		}
	}

	// An executable's own help must still reach it.
	let run = try SwiftWatchCommand.parseAsRoot(["run", "MyExecutable", "--help"])
	guard let runCommand = run as? SwiftWatchCommand.Run else {
		Issue.record("Expected Run command.")
		return
	}
	#expect(runCommand.swiftArgs == ["MyExecutable", "--help"])
	try exitIfHelpRequested(runCommand.swiftArgs, for: runCommand)
}

@Test
func `test command captures trailing arguments for swift test`() throws {
	let command = try SwiftWatchCommand.parseAsRoot([
		"test",
		"--package-path", "/tmp/pkg",
		"--filter", "MyTests",
		"--parallel",
	])

	guard let test = command as? SwiftWatchCommand.Test else {
		Issue.record("Expected Test command.")
		return
	}

	#expect(test.swiftArgs == ["--filter", "MyTests", "--parallel"])
	#expect(test.options.packagePath == "/tmp/pkg")
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

	func runSwift(
		subcommand: String, packagePath: URL, swiftBinDirectory: URL?, args: [String]
	)
		async throws(SwiftWatchError) -> Int32
	{
		0
	}

	func withRun<Result: Sendable>(
		packagePath: URL,
		swiftBinDirectory: URL?,
		args: [String],
		whileRunning: () async throws(SwiftWatchError) -> Result
	) async throws(SwiftWatchError) -> Result {
		fatalError("unused")
	}
}
