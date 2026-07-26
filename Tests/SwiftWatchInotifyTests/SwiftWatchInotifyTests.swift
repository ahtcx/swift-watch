import SwiftWatch
import Testing

import class Foundation.FileManager

@testable import SwiftWatchInotify

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

#if os(Linux)
	import Glibc
#endif

@Test(.timeLimit(.minutes(1)))
func `inotify watcher detects manifest edits and added sources`() async throws {
	#if os(Linux)
		let fixture = try PackageFixture()
		defer { fixture.remove() }

		let session = try InotifyWatcher().startSession(for: fixture.graph)
		defer { session.stop() }

		try Data("// updated\n".utf8).write(to: fixture.manifest)
		let manifestChanges = try await session.waitForChange(debounce: .milliseconds(10))
		#expect(manifestChanges.contains(fixture.manifest.standardizedFileURL))

		let added = fixture.sourceRoot.appendingPathComponent("added.swift")
		try Data("print(2)\n".utf8).write(to: added)
		let sourceChanges = try await session.waitForChange(debounce: .milliseconds(10))
		#expect(sourceChanges.contains(added.standardizedFileURL))
	#endif
}

@Test(.timeLimit(.minutes(1)))
func `inotify watcher detects newly created nested source directories`() async throws {
	#if os(Linux)
		let fixture = try PackageFixture()
		defer { fixture.remove() }

		let session = try InotifyWatcher().startSession(for: fixture.graph)
		defer { session.stop() }

		let nestedDirectory = fixture.sourceRoot.appendingPathComponent(
			"Generated/Nested", isDirectory: true)
		try FileManager.default.createDirectory(
			at: nestedDirectory,
			withIntermediateDirectories: true
		)
		let added = nestedDirectory.appendingPathComponent("generated.swift")
		try Data("print(3)\n".utf8).write(to: added)

		let changes = try await session.waitForChange(debounce: .milliseconds(10))
		#expect(changes.contains(added.standardizedFileURL))
	#endif
}

@Test
func `inotify event decoding stops at the number of bytes read`() throws {
	#if os(Linux)
		let headerSize = MemoryLayout<inotify_event>.size
		var buffer = [UInt8](repeating: 0, count: 4096)

		var event = inotify_event()
		event.wd = 7
		event.mask = UInt32(IN_MODIFY)
		event.cookie = 0
		event.len = 0
		withUnsafeBytes(of: event) { raw in
			for (index, byte) in raw.enumerated() {
				buffer[index] = byte
			}
		}

		// Only one event was actually read. The rest of the buffer is zeroed
		// padding and must not decode into phantom records.
		var offset = 0
		let decoded = InotifyInterop.decodeEvent(
			from: buffer, limit: headerSize, offset: &offset)
		#expect(decoded?.watchDescriptor == 7)
		#expect(offset == headerSize)

		let trailing = InotifyInterop.decodeEvent(
			from: buffer, limit: headerSize, offset: &offset)
		#expect(trailing == nil)
	#endif
}

#if os(Linux)
	private struct PackageFixture {
		let root: URL
		let sourceRoot: URL
		let manifest: URL
		let graph: WatchGraph

		init() throws {
			root = FileManager.default.temporaryDirectory.appendingPathComponent(
				UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(
				at: root, withIntermediateDirectories: true)

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
#endif
