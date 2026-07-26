import SwiftWatch

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif
#if os(Linux)
	public struct InotifyWatcher: FileWatcher {
		public init() {}

		public func startSession(for graph: WatchGraph) throws(SwiftWatchError)
			-> any FileWatcherSession
		{
			try InotifySession(graph: graph)
		}
	}

	extension FileWatcherImplementation {
		public static let inotify = Self(name: "inotify", isDefault: true) { _ in
			InotifyWatcher()
		}
	}
#endif
