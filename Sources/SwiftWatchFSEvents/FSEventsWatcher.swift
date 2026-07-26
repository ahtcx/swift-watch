import SwiftWatch

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif
#if canImport(CoreServices)
	public struct FSEventsWatcher: FileWatcher {
		public init() {}

		public func startSession(for graph: WatchGraph) throws(SwiftWatchError)
			-> any FileWatcherSession
		{
			let session = FSEventsSession(graph: graph)
			try session.start()
			return session
		}
	}

	extension FileWatcherImplementation {
		public static let fsevents = Self(name: "fsevents", isDefault: true) { _ in
			FSEventsWatcher()
		}
	}
#endif
