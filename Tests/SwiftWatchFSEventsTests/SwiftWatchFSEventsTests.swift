import SwiftWatch
import SwiftWatchFSEvents
import Testing

import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

@Test
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

		let changes = try await session.waitForChange(debounce: .milliseconds(10))
		#expect(changes.contains(manifest.standardizedFileURL))
	#endif
}
