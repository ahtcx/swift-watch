import SwiftWatch
import SwiftWatchPolling
import Testing

import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

@Test
func `polling watcher detects manifest edits and added sources`() async throws {
	let fixture = try PackageFixture()
	defer { fixture.remove() }

	let session = try PollingWatcher(pollInterval: .milliseconds(20))
		.startSession(for: fixture.graph)
	defer { session.stop() }

	try Data("// updated\n".utf8).write(to: fixture.manifest)
	let manifestChanges = try await session.waitForChange(debounce: .milliseconds(10))
	#expect(manifestChanges.contains(fixture.manifest.standardizedFileURL))

	let added = fixture.sourceRoot.appendingPathComponent("added.swift")
	try Data("print(2)\n".utf8).write(to: added)
	let sourceChanges = try await session.waitForChange(debounce: .milliseconds(10))
	#expect(sourceChanges.contains(added.standardizedFileURL))
}

@Test
func `polling watcher reports changes made before the first wait`() async throws {
	let fixture = try PackageFixture()
	defer { fixture.remove() }

	// The session baseline is taken at creation, so a change landing here —
	// standing in for an edit made while a build is still running — is not lost.
	let session = try PollingWatcher(pollInterval: .milliseconds(20))
		.startSession(for: fixture.graph)
	defer { session.stop() }

	try Data("// edited during the build\n".utf8).write(to: fixture.manifest)

	let changes = try await session.waitForChange(debounce: .milliseconds(10))
	#expect(changes.contains(fixture.manifest.standardizedFileURL))
}

private struct PackageFixture {
	let root: URL
	let sourceRoot: URL
	let manifest: URL
	let graph: WatchGraph

	init() throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent(
			UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

		sourceRoot = root.appendingPathComponent("Sources/App", isDirectory: true)
		try FileManager.default.createDirectory(
			at: sourceRoot, withIntermediateDirectories: true)

		manifest = root.appendingPathComponent("Package.swift")
		try Data("// swift-tools-version: 6.0\n".utf8).write(to: manifest)
		let source = sourceRoot.appendingPathComponent("main.swift")
		try Data("print(1)\n".utf8).write(to: source)

		graph = WatchGraph(
			packageRoots: [root],
			sourceRoots: [sourceRoot],
			trackedFiles: [manifest, source],
			manifestFiles: [manifest],
			resolvedFiles: [],
			sourceExtensions: ["swift"]
		)
	}

	func remove() {
		try? FileManager.default.removeItem(at: root)
	}
}
