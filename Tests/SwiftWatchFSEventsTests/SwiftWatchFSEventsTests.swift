import SwiftWatch
import SwiftWatchFSEvents
import Testing

import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

@Test(.timeLimit(.minutes(1)))
func `FSEvents watcher detects manifest changes`() async throws {
	#if canImport(CoreServices)
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }

		let sourceRoot = root.appendingPathComponent("Sources/App", isDirectory: true)
		try FileManager.default.createDirectory(
			at: sourceRoot, withIntermediateDirectories: true)
		let manifest = root.appendingPathComponent("Package.swift")
		try Data("// swift-tools-version: 6.0\n".utf8).write(to: manifest)
		let source = sourceRoot.appendingPathComponent("main.swift")
		try Data("print(1)\n".utf8).write(to: source)

		let graph = WatchGraph(
			packageRoots: [root],
			sourceRoots: [sourceRoot],
			trackedFiles: [manifest, source],
			manifestFiles: [manifest],
			resolvedFiles: [],
			sourceExtensions: ["swift"]
		)

		let session = try FSEventsWatcher().startSession(for: graph)
		defer { session.stop() }

		// The stream is live from session creation, so this change is buffered
		// even though nothing is awaiting it yet.
		try await Task.sleep(for: .milliseconds(200))
		try Data("// updated\n".utf8).write(to: manifest)

		// A stream created `SinceNow` can still deliver events from just before
		// it started, so the first batch may be carrying the fixture's own setup
		// writes rather than the edit under test. Reading until the manifest
		// arrives is what makes this deterministic; reading once made it fail
		// about one run in eight. Completing the loop is the assertion, and the
		// time limit bounds a watcher that never reports the edit at all.
		var seen = Set<URL>()
		while !seen.contains(manifest.standardizedFileURL) {
			seen.formUnion(try await session.waitForChange(debounce: .milliseconds(10)))
		}
	#endif
}
