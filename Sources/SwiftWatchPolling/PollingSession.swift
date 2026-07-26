import SwiftWatch

import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Polling observation of a `WatchGraph`.
///
/// The baseline snapshot is taken when the session is created rather than when
/// the first `waitForChange` runs, so edits made while a build is in flight are
/// still reported.
final class PollingSession: FileWatcherSession {
	private let graph: WatchGraph
	private let fileManager: FileManager
	private let pollInterval: Duration
	private var snapshot: PollingSnapshot

	init(
		graph: WatchGraph,
		fileManager: FileManager,
		pollInterval: Duration
	) throws(SwiftWatchError) {
		self.graph = graph
		self.fileManager = fileManager
		self.pollInterval = pollInterval
		self.snapshot = try PollingSnapshot.make(graph: graph, fileManager: fileManager)
	}

	func waitForChange(debounce: Duration) async throws(SwiftWatchError) -> [URL] {
		while true {
			try AsyncSupport.checkCancellation()

			let next = try PollingSnapshot.make(graph: graph, fileManager: fileManager)
			let changed = next.diff(from: snapshot).filter(graph.isRelevantChange)
			guard !changed.isEmpty else {
				snapshot = next
				try await AsyncSupport.sleep(
					for: pollInterval, context: "polling")
				continue
			}

			try await AsyncSupport.sleep(for: debounce, context: "polling")
			let settled = try PollingSnapshot.make(
				graph: graph, fileManager: fileManager)
			let union = Set(changed).union(
				settled.diff(from: next).filter(graph.isRelevantChange)
			)
			snapshot = settled
			return union.sorted { $0.path < $1.path }
		}
	}

	func stop() {}
}
