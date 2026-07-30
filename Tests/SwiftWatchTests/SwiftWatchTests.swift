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
func `planned build graph follows exact inputs and local packages`() throws {
	let container = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let root = container.appendingPathComponent("root", isDirectory: true)
	let dependency = container.appendingPathComponent("dependency", isDirectory: true)
	let scratch = container.appendingPathComponent("scratch", isDirectory: true)
	let app = root.appendingPathComponent("Sources/App", isDirectory: true)
	let assets = app.appendingPathComponent("Assets", isDirectory: true)
	let used = dependency.appendingPathComponent("Sources/Used", isDirectory: true)
	let unused = dependency.appendingPathComponent("Sources/Unused", isDirectory: true)
	for directory in [app, assets, used, unused, scratch] {
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true)
	}
	defer { try? FileManager.default.removeItem(at: container) }
	for package in [root, dependency, scratch] {
		try "// package\n".write(
			to: package.appendingPathComponent("Package.swift"),
			atomically: true,
			encoding: .utf8)
	}

	let main = app.appendingPathComponent("main.swift")
	let dependencySource = used.appendingPathComponent("Used.swift")
	let pluginInput = app.appendingPathComponent("Protos/model.proto")
	let remoteInput = scratch.appendingPathComponent("Remote.swift")
	let graph = PlannedBuildGraph().graph(
		packagePath: root,
		inputs: [main, dependencySource, pluginInput, remoteInput],
		inputDirectories: [app, used, assets],
		excludedPaths: [scratch]
	)

	#expect(graph.packageRoots == [root.standardizedFileURL, dependency.standardizedFileURL])
	#expect(graph.sourceRoots == [app.standardizedFileURL, used.standardizedFileURL])
	#expect(graph.trackedFiles.contains(main.standardizedFileURL))
	#expect(graph.trackedFiles.contains(dependencySource.standardizedFileURL))
	#expect(
		graph.isRelevantChange(
			app.appendingPathComponent("New.swift")))
	#expect(
		!graph.isRelevantChange(
			unused.appendingPathComponent("Unused.swift")))
	#expect(
		graph.isRelevantChange(
			dependency.appendingPathComponent("Package.swift")))
	#expect(
		graph.isRelevantChange(
			app.appendingPathComponent("Protos/new.graphql")))
	#expect(
		graph.isRelevantChange(
			assets.appendingPathComponent("new-file-without-an-extension")))
	#expect(!graph.packageRoots.contains(scratch.standardizedFileURL))
}

@Test
func `planned directory nodes recover a custom target root`() throws {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let target = root.appendingPathComponent("CustomTarget", isDirectory: true)
	let nested = target.appendingPathComponent("Nested", isDirectory: true)
	try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }
	try "// package\n".write(
		to: root.appendingPathComponent("Package.swift"),
		atomically: true,
		encoding: .utf8)

	let graph = PlannedBuildGraph().graph(
		packagePath: root,
		inputs: [nested.appendingPathComponent("Only.swift")],
		inputDirectories: [target]
	)

	#expect(graph.sourceRoots == [target.standardizedFileURL])
	#expect(graph.isRelevantChange(target.appendingPathComponent("Sibling.swift")))
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
	#expect(
		NativeBuildManifest().readDirectories(at: path) == [
			"/pkg/Sources/App"
		])
	// Directory nodes are retained separately. Virtual nodes and outputs are
	// not filesystem inputs.
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
	try #"commands:\#n  "Gen":\#n    inputs: ["/pkg/Sources/App/Protos/a.proto"]"#
		.write(
			to: triple.appendingPathComponent("debug.yaml"), atomically: true,
			encoding: .utf8)
	let stale = scratch.appendingPathComponent("debug.yaml")
	try #"commands:\#n  "Gen":\#n    inputs: ["/pkg/Sources/Stale/stale.swift"]"#
		.write(to: stale, atomically: true, encoding: .utf8)
	try FileManager.default.setAttributes(
		[.modificationDate: Date(timeIntervalSince1970: 1)],
		ofItemAtPath: stale.path)

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

@Test
func `native build database advances a reused plan`() throws {
	let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: scratch) }

	let plan = scratch.appendingPathComponent("debug.yaml")
	let database = scratch.appendingPathComponent("build.db")
	try #"commands:\#n  "Compile":\#n    inputs: ["/pkg/Sources/App/main.swift"]"#
		.write(to: plan, atomically: true, encoding: .utf8)
	try Data().write(to: database)
	let planDate = Date(timeIntervalSince1970: 1_000)
	let databaseDate = Date(timeIntervalSince1970: 2_000)
	try FileManager.default.setAttributes(
		[.modificationDate: planDate], ofItemAtPath: plan.path)
	try FileManager.default.setAttributes(
		[.modificationDate: databaseDate], ofItemAtPath: database.path)

	let reader = NativeBuildManifest()
	let location = reader.manifestLocation(
		scratchPath: scratch, configuration: "debug")

	// llbuild advances build.db on a no-op invocation while reusing debug.yaml.
	// That still proves the exact invocation selected this readable plan.
	#expect(reader.modificationDate(at: location) == databaseDate)
}

@Test
func `native plan traversal narrows the reusable plan to the invoked target`() throws {
	let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(
		at: scratch, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: scratch) }

	let plan = scratch.appendingPathComponent("debug.yaml")
	let yaml = [
		"targets:",
		#"  "Selected-arm64.module": ["<Selected>"]"#,
		#"  "Unrelated-arm64.module": ["<Unrelated>"]"#,
		#"default: "Unrelated-arm64.module""#,
		"commands:",
		#"  "SelectedCommand":"#,
		#"    inputs: ["/pkg/Sources/Selected/main.swift","<Dependency>"]"#,
		#"    outputs: ["<Selected>"]"#,
		#"  "DependencyCommand":"#,
		#"    inputs: ["/pkg/Sources/Dependency/lib.swift"]"#,
		#"    outputs: ["<Dependency>"]"#,
		#"  "UnrelatedCommand":"#,
		#"    inputs: ["/pkg/Sources/Unrelated/main.swift"]"#,
		#"    outputs: ["<Unrelated>"]"#,
	].joined(separator: "\n")
	try yaml.write(to: plan, atomically: true, encoding: .utf8)

	#expect(
		NativeBuildManifest().readPaths(
			at: plan,
			selection: WatchSelection(
				action: .build, names: ["Selected"]))
			== [
				"/pkg/Sources/Dependency/lib.swift",
				"/pkg/Sources/Selected/main.swift",
			])
}

@Test
func `a test selection that resolves to nothing widens instead of defaulting`() throws {
	// The default target is the one a bare `swift build` uses, so it is exactly
	// the target that excludes tests. Were SwiftPM to rename its `test`
	// aggregate, falling back to the default would leave `swift-watch test` not
	// watching a single test file — a silent narrowing, and the one direction a
	// watcher must never fail in.
	let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: scratch) }

	let plan = scratch.appendingPathComponent("debug.yaml")
	try [
		"targets:",
		#"  "main": ["<App>"]"#,
		#"  "renamed-tests": ["<AppTests>"]"#,
		#"default: "main""#,
		"commands:",
		#"  "AppCommand":"#,
		#"    inputs: ["/pkg/Sources/App/main.swift"]"#,
		#"    outputs: ["<App>"]"#,
		#"  "AppTestsCommand":"#,
		#"    inputs: ["/pkg/Tests/AppTests/T.swift"]"#,
		#"    outputs: ["<AppTests>"]"#,
	].joined(separator: "\n").write(to: plan, atomically: true, encoding: .utf8)

	let reader = NativeBuildManifest()
	#expect(
		reader.readPaths(at: plan, selection: WatchSelection(action: .test))
			== ["/pkg/Sources/App/main.swift", "/pkg/Tests/AppTests/T.swift"])
	// A build still narrows to the default, which is the right breadth for it.
	#expect(
		reader.readPaths(at: plan, selection: WatchSelection(action: .build))
			== ["/pkg/Sources/App/main.swift"])
}

@Test
func `a target the plan never reads from is watched, one merely unselected is not`() throws {
	// SwiftPM compiles build tool plugins in a separate arena, so no command of
	// the plan that consumes a plugin's output reads the plugin's own sources.
	// A test target left out of this selection looks nothing like that: its
	// sources are still recorded, by the closure it does belong to.
	let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: scratch) }

	let plan = scratch.appendingPathComponent("debug.yaml")
	try [
		"targets:",
		#"  "main": ["<App>"]"#,
		#"  "test": ["<AppTests>"]"#,
		#"default: "main""#,
		"nodes:",
		#"  "/pkg/Sources/App/":"#,
		"    is-directory-structure: true",
		"commands:",
		#"  "AppCommand":"#,
		#"    inputs: ["/pkg/Sources/App/main.swift"]"#,
		#"    outputs: ["<App>"]"#,
		#"  "AppTestsCommand":"#,
		#"    inputs: ["/pkg/Tests/AppTests/T.swift"]"#,
		#"    outputs: ["<AppTests>"]"#,
		#"  "PackageStructure":"#,
		#"    inputs: ["/pkg/Sources/App/","/pkg/Plugins/Gen/","/pkg/Tests/AppTests/","/pkg/Package.swift"]"#,
		#"    outputs: ["<PackageStructure>"]"#,
	].joined(separator: "\n").write(to: plan, atomically: true, encoding: .utf8)

	let reading = NativeBuildManifest().read(
		at: plan,
		selection: WatchSelection(action: .build),
		fileManager: .default)
	#expect(reading.readInputs?.map(\.path).sorted() == ["/pkg/Sources/App/main.swift"])
	#expect(reading.readUnbuiltDirectories?.map(\.path) == ["/pkg/Plugins/Gen"])
	// The node entry is keyed and indented exactly like a command, and must not
	// be read as one.
	#expect(
		reading.readInputDirectories?.map(\.path).sorted() == [
			"/pkg/Plugins/Gen", "/pkg/Sources/App", "/pkg/Tests/AppTests",
		])
}

@Test
func `an unbuilt target directory becomes a source root of its own package`() throws {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let plugin = root.appendingPathComponent("Plugins/Gen", isDirectory: true)
	let app = root.appendingPathComponent("Sources/App", isDirectory: true)
	try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
	try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }
	try "// package\n".write(
		to: root.appendingPathComponent("Package.swift"),
		atomically: true,
		encoding: .utf8)

	let graph = PlannedBuildGraph().graph(
		packagePath: root,
		inputs: [app.appendingPathComponent("main.swift")],
		inputDirectories: [app, plugin],
		unbuiltDirectories: [plugin])

	#expect(graph.sourceRoots == [app.standardizedFileURL, plugin.standardizedFileURL])
	#expect(graph.isRelevantChange(plugin.appendingPathComponent("plugin.swift")))
	#expect(graph.isRelevantChange(plugin.appendingPathComponent("Added.swift")))
	#expect(!graph.isRelevantChange(plugin.appendingPathComponent("notes.md")))
}

@Test
func `cross-compiled database selects a reused older native plan`() throws {
	let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let triple = scratch.appendingPathComponent(
		"aarch64-unknown-linux-gnu", isDirectory: true)
	try FileManager.default.createDirectory(at: triple, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: scratch) }

	let hostPlan = scratch.appendingPathComponent("debug.yaml")
	let crossPlan = triple.appendingPathComponent("debug.yaml")
	let crossDatabase = triple.appendingPathComponent("build.db")
	try #"commands:\#n  "Host":\#n    inputs: ["/pkg/Sources/Host/main.swift"]"#
		.write(to: hostPlan, atomically: true, encoding: .utf8)
	try #"commands:\#n  "Cross":\#n    inputs: ["/pkg/Sources/Cross/main.swift"]"#
		.write(to: crossPlan, atomically: true, encoding: .utf8)
	try Data().write(to: crossDatabase)
	try FileManager.default.setAttributes(
		[.modificationDate: Date(timeIntervalSince1970: 3_000)],
		ofItemAtPath: hostPlan.path)
	try FileManager.default.setAttributes(
		[.modificationDate: Date(timeIntervalSince1970: 2_000)],
		ofItemAtPath: crossPlan.path)
	let databaseDate = Date(timeIntervalSince1970: 4_000)
	try FileManager.default.setAttributes(
		[.modificationDate: databaseDate],
		ofItemAtPath: crossDatabase.path)

	let reader = NativeBuildManifest()
	let location = reader.manifestLocation(
		scratchPath: scratch, configuration: "debug")

	#expect(reader.modificationDate(at: location) == databaseDate)
	#expect(reader.readPaths(at: location) == ["/pkg/Sources/Cross/main.swift"])
}

extension BuildManifestReading {
	/// The input paths read at `location`, as strings, so assertions read as
	/// the manifests do.
	func readPaths(at location: URL) -> [String] {
		(read(at: location, fileManager: .default).readInputs ?? []).map(\.path).sorted()
	}

	func readPaths(at location: URL, selection: WatchSelection) -> [String] {
		(read(
			at: location, selection: selection,
			fileManager: .default
		).readInputs ?? []).map(\.path).sorted()
	}

	func readDirectories(at location: URL) -> [String] {
		(read(at: location, fileManager: .default).readInputDirectories ?? [])
			.map(\.path).sorted()
	}
}

/// Writes an `XCBuildData` tree holding one plan directory per entry, oldest
/// first, so the newest is unambiguous.
///
/// - Parameter arena: The directory Swift Build puts its build data under, which
///   has been spelled both `out` and the target triple across 6.x releases.
private func writeSwiftBuildManifests(
	_ manifests: [(hash: String, json: String)],
	under scratch: URL,
	arena: String = "out"
) throws -> URL {
	let location = swiftBuildData(under: scratch, arena: arena)
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
	// The reader is handed the whole build tree, since it finds the arena rather
	// than naming it.
	return scratch
}

private func swiftBuildData(under scratch: URL, arena: String = "out") -> URL {
	scratch
		.appendingPathComponent(arena, isDirectory: true)
		.appendingPathComponent("Intermediates.noindex", isDirectory: true)
		.appendingPathComponent("XCBuildData", isDirectory: true)
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
	#expect(
		SwiftBuildManifest().readDirectories(at: location) == [
			"/pkg/Sources/App"
		])
}

@Test
func `swift build request selects a reused older plan`() throws {
	let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	defer { try? FileManager.default.removeItem(at: scratch) }

	let location = try writeSwiftBuildManifests(
		[
			(
				"selected",
				#"{"commands":{"SelectedCommand":{"inputs":["/pkg/selected.swift"]}}}"#
			),
			(
				"newer-but-different",
				#"{"commands":{"OtherCommand":{"inputs":["/pkg/wrong.swift"]}}}"#
			),
		],
		under: scratch
	)
	// The guid SwiftPM configures for a forwarded --target carries a hash and
	// may carry a `-testable` suffix, neither of which the caller spelled, so
	// the name is matched by prefix rather than compared whole.
	for (hash, guid) in [
		("selected", "PACKAGE-TARGET:SelectedCommand-1DA2DD44-testable"),
		("newer-but-different", "PACKAGE-TARGET:OtherCommand-9F110C21"),
	] {
		try writeBuildRequest(guids: [guid], forPlan: hash, under: location)
	}

	#expect(
		SwiftBuildManifest().readPaths(
			at: location,
			selection: WatchSelection(
				action: .build, names: ["SelectedCommand"]))
			== ["/pkg/selected.swift"])
}

@Test
func `swift build aggregates are matched by the test line they drew`() throws {
	// A bare `swift build` or `swift test` configures one aggregate rather than
	// naming targets, and the two differ only in whether tests are in them. The
	// build plan is written first here, so recency alone would answer wrongly
	// every time.
	let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	defer { try? FileManager.default.removeItem(at: scratch) }

	let location = try writeSwiftBuildManifests(
		[
			(
				"build",
				#"{"commands":{"C":{"inputs":["/pkg/Sources/App/main.swift"]}}}"#
			),
			("test", #"{"commands":{"C":{"inputs":["/pkg/Tests/AppTests/T.swift"]}}}"#),
			(
				"target",
				#"{"commands":{"C":{"inputs":["/pkg/Sources/App/one.swift"]}}}"#
			),
		],
		under: scratch
	)
	try writeBuildRequest(guids: ["ALL-EXCLUDING-TESTS"], forPlan: "build", under: location)
	try writeBuildRequest(guids: ["ALL-INCLUDING-TESTS"], forPlan: "test", under: location)
	try writeBuildRequest(
		guids: ["PACKAGE-TARGET:App-1DA2DD44"], forPlan: "target", under: location)

	let reader = SwiftBuildManifest()
	#expect(
		reader.readPaths(at: location, selection: WatchSelection(action: .build))
			== ["/pkg/Sources/App/main.swift"])
	#expect(
		reader.readPaths(at: location, selection: WatchSelection(action: .test))
			== ["/pkg/Tests/AppTests/T.swift"])
	#expect(
		reader.readPaths(
			at: location,
			selection: WatchSelection(action: .build, names: ["App"]))
			== ["/pkg/Sources/App/one.swift"])
}

private func writeBuildRequest(
	guids: [String], forPlan hash: String, under scratch: URL
) throws {
	let encoded = guids.map { #"{"guid":"\#($0)"}"# }.joined(separator: ",")
	try #"{"configuredTargets":[\#(encoded)]}"#
		.write(
			to:
				swiftBuildData(under: scratch)
				.appendingPathComponent("\(hash).xcbuilddata")
				.appendingPathComponent("build-request.json"),
			atomically: true,
			encoding: .utf8)
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
	defer {
		for scratch in scratches {
			try? FileManager.default.removeItem(at: scratch)
		}
	}

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

	// Swift Build folds the configuration into a hash rather than the path, and
	// the arena directory holding its plans is not fixed across releases, so the
	// reader is pointed at the build tree and finds the rest itself.
	let debug = SwiftBuildManifest().manifestLocation(
		scratchPath: scratch, configuration: "debug")
	#expect(debug.path == "/pkg/.build")
	#expect(
		SwiftBuildManifest().manifestLocation(
			scratchPath: scratch, configuration: "release") == debug)
}

@Test
func `a swift build plan is found whatever the arena above it is called`() throws {
	// Swift 6.0 and 6.3 write these under `out`; 6.2 wrote them under the target
	// triple. Naming one spelling leaves the other silently unwatched.
	for arena in ["out", "arm64-apple-macosx"] {
		let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
			UUID().uuidString, isDirectory: true)
		defer { try? FileManager.default.removeItem(at: scratch) }

		let location = try writeSwiftBuildManifests(
			[
				(
					"plan",
					#"{"commands":{"C":{"inputs":["/pkg/Sources/App/main.swift"]}}}"#
				)
			],
			under: scratch,
			arena: arena
		)

		#expect(
			SwiftBuildManifest().readPaths(at: location) == [
				"/pkg/Sources/App/main.swift"
			])
	}
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
func `a directory that cannot be listed is walked past, not fatal`() throws {
	let base = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let sources = base.appendingPathComponent("Sources/App", isDirectory: true)
	let unreadable = sources.appendingPathComponent("Private", isDirectory: true)
	try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
	defer {
		try? FileManager.default.setAttributes(
			[.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
		try? FileManager.default.removeItem(at: base)
	}
	try "let a = 1".write(
		to: sources.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
	// Nothing the graph would count either way, so the expectation below holds
	// whether or not the process is privileged enough to read the directory.
	try "notes".write(
		to: unreadable.appendingPathComponent("notes.txt"), atomically: true,
		encoding: .utf8)
	try FileManager.default.setAttributes(
		[.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

	let graph = WatchGraph(
		packageRoots: [],
		sourceRoots: [sources],
		trackedFiles: [],
		manifestFiles: [],
		resolvedFiles: [],
		sourceExtensions: ["swift"]
	)

	// A directory the user does not own can sit anywhere in scope. Failing the
	// walk on it would take down a loop that has no use for its contents.
	let files = try DirectoryTraversal.relevantFiles(
		under: [sources], graph: graph, fileManager: .default)

	#expect(files.map(\.lastPathComponent) == ["main.swift"])
}

@Test
func `the watch scope follows the rules, not the package tree`() {
	let pkg = URL(fileURLWithPath: "/tmp/pkg", isDirectory: true)
	let app = pkg.appendingPathComponent("Sources/App", isDirectory: true)
	let graph = WatchGraph(
		packageRoots: [pkg],
		sourceRoots: [app],
		trackedFiles: [],
		manifestFiles: [pkg.appendingPathComponent("Package.swift")],
		resolvedFiles: [],
		sourceExtensions: ["swift"],
		buildInputs: [
			app.appendingPathComponent("main.swift"),
			pkg.appendingPathComponent("Protos/a.proto"),
		]
	)
	let scope = graph.watchScope

	// The containment rules name a root to descend from: the target's sources,
	// and the directory a plugin reads its inputs from.
	#expect(
		scope.recursiveRoots == [
			app.standardizedFileURL,
			pkg.appendingPathComponent("Protos", isDirectory: true).standardizedFileURL,
		])
	// The manifest is matched by exact path, so its directory is read but not
	// descended into — which is what keeps the rest of the package unwatched.
	#expect(scope.shallowRoots == [pkg.standardizedFileURL])
}

@Test
func `a directory already watched whole is not repeated as a shallow root`() {
	let pkg = URL(fileURLWithPath: "/tmp/pkg", isDirectory: true)
	let graph = WatchGraph(
		packageRoots: [pkg],
		sourceRoots: [pkg],
		trackedFiles: [pkg.appendingPathComponent("Sources/App/main.swift")],
		manifestFiles: [pkg.appendingPathComponent("Package.swift")],
		resolvedFiles: [],
		sourceExtensions: ["swift"]
	)

	// The root-package fallback watches everything from one root, so every
	// tracked file's directory is already covered.
	#expect(graph.watchScope.recursiveRoots == [pkg.standardizedFileURL])
	#expect(graph.watchScope.shallowRoots.isEmpty)
}

@Test
func `a shallow root is read without being descended into`() throws {
	let pkg = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let app = pkg.appendingPathComponent("Sources/App", isDirectory: true)
	let nested = app.appendingPathComponent("Models", isDirectory: true)
	let unrelated = pkg.appendingPathComponent("Documentation/Guides", isDirectory: true)
	try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
	try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: pkg) }
	for file in [
		pkg.appendingPathComponent("Package.swift"),
		app.appendingPathComponent("main.swift"),
		nested.appendingPathComponent("Model.swift"),
		unrelated.appendingPathComponent("Buried.swift"),
	] {
		try "// file\n".write(to: file, atomically: true, encoding: .utf8)
	}

	let graph = WatchGraph(
		packageRoots: [pkg],
		sourceRoots: [app],
		trackedFiles: [],
		manifestFiles: [pkg.appendingPathComponent("Package.swift")],
		resolvedFiles: [],
		sourceExtensions: ["swift"]
	)

	let visited = try DirectoryTraversal.directories(
		in: graph.watchScope, graph: graph, fileManager: .default)

	// The package root is read for its manifest, and stops there. A source root
	// is followed all the way down.
	#expect(
		visited.map(\.lastPathComponent).sorted()
			== ["App", "Models", pkg.lastPathComponent].sorted())
	#expect(!visited.contains(unrelated.standardizedFileURL))
}

@Test
func `narrowing the scope does not lose a relevant file`() throws {
	// The scope is a performance claim resting on a correctness one: every path
	// a rule can match has to stay reachable. Walking the whole package and
	// filtering is the slow answer this replaces, so the two must agree.
	let pkg = FileManager.default.temporaryDirectory.appendingPathComponent(
		UUID().uuidString, isDirectory: true)
	let app = pkg.appendingPathComponent("Sources/App", isDirectory: true)
	let protos = pkg.appendingPathComponent("Protos", isDirectory: true)
	let unrelated = pkg.appendingPathComponent("Tests/AppTests", isDirectory: true)
	for directory in [
		app.appendingPathComponent("Models", isDirectory: true), protos, unrelated,
	] {
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true)
	}
	defer { try? FileManager.default.removeItem(at: pkg) }
	for file in [
		pkg.appendingPathComponent("Package.swift"),
		pkg.appendingPathComponent("Package.resolved"),
		pkg.appendingPathComponent("README.md"),
		app.appendingPathComponent("main.swift"),
		app.appendingPathComponent("Models/Model.swift"),
		protos.appendingPathComponent("a.proto"),
		protos.appendingPathComponent("notes.txt"),
		unrelated.appendingPathComponent("T.swift"),
	] {
		try "// file\n".write(to: file, atomically: true, encoding: .utf8)
	}

	let graph = PlannedBuildGraph().graph(
		packagePath: pkg,
		inputs: [
			app.appendingPathComponent("main.swift"),
			app.appendingPathComponent("Models/Model.swift"),
			protos.appendingPathComponent("a.proto"),
		],
		inputDirectories: [app]
	)

	let scoped = Set(
		try DirectoryTraversal.relevantFiles(
			in: graph.watchScope, graph: graph, fileManager: .default))
	let wholePackage = Set(
		try DirectoryTraversal.relevantFiles(
			under: [pkg], graph: graph, fileManager: .default))

	#expect(scoped == wholePackage)
	// And the point of it: the test target nobody selected is never walked.
	#expect(!scoped.contains(unrelated.appendingPathComponent("T.swift").standardizedFileURL))
	#expect(scoped.contains(protos.appendingPathComponent("notes.txt").standardizedFileURL))
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
	// Exact paths from the build plan are authoritative, so a name-based
	// heuristic must not silence them.
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
	#expect(
		forwardedBuildSelection(
			in: normalizedPassthrough(build.swiftArgs)
		).names == ["Foo", "Bar"])
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
func `swift run invocation finds the executable after SwiftPM options`() {
	#expect(
		forwardedRunInvocation(in: ["MyExecutable", "--app-flag", "value"])
			== ForwardedRunInvocation(
				optionArguments: [],
				executable: "MyExecutable"))
	#expect(
		forwardedRunInvocation(
			in: [
				"--configuration", "release",
				"--scratch-path=.scratch",
				"-Xswiftc", "-DFEATURE",
				"MyExecutable",
				"--configuration", "belongs-to-the-executable",
			])
			== ForwardedRunInvocation(
				optionArguments: [
					"--configuration", "release",
					"--scratch-path=.scratch",
					"-Xswiftc", "-DFEATURE",
				],
				executable: "MyExecutable"))
	#expect(
		forwardedRunInvocation(
			in: ["--configuration", "release", "--", "MyExecutable", "--app-flag"])
			== ForwardedRunInvocation(
				optionArguments: ["--configuration", "release"],
				executable: "MyExecutable"))
}

@Test
func `swift run invocation stays broad for unknown or absent executables`() {
	#expect(
		forwardedRunInvocation(in: ["--configuration", "release"])
			== ForwardedRunInvocation(
				optionArguments: ["--configuration", "release"],
				executable: nil))
	#expect(
		forwardedRunInvocation(in: ["--future-option", "value", "MyExecutable"])
			== ForwardedRunInvocation(
				optionArguments: [],
				executable: nil))
	#expect(
		forwardedRunInvocation(in: ["--configuration"])
			== ForwardedRunInvocation(
				optionArguments: ["--configuration"],
				executable: nil))
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
