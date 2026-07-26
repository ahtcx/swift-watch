import SwiftWatch

import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct PollingWatcher: FileWatcher {
	private let fileManager: FileManager
	private let pollInterval: Duration

	public init(
		fileManager: FileManager = .default,
		pollInterval: Duration = .milliseconds(150)
	) {
		self.fileManager = fileManager
		self.pollInterval = pollInterval
	}

	public func startSession(for graph: WatchGraph) throws(SwiftWatchError)
		-> any FileWatcherSession
	{
		try PollingSession(
			graph: graph,
			fileManager: fileManager,
			pollInterval: pollInterval
		)
	}
}

extension FileWatcherImplementation {
	public static let polling = Self(name: "polling") { options in
		PollingWatcher(pollInterval: options.pollInterval)
	}
}
