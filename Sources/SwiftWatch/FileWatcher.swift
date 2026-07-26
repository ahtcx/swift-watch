#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Tuning shared by every watcher backend.
public struct WatcherOptions: Sendable {
	public var pollInterval: Duration

	public init(pollInterval: Duration = .milliseconds(150)) {
		self.pollInterval = pollInterval
	}
}

/// An active observation of a `WatchGraph`.
///
/// A session begins observing as soon as it is created, so changes that land
/// while a build is in flight are still reported by the next `waitForChange`.
public protocol FileWatcherSession: AnyObject {
	func waitForChange(debounce: Duration) async throws(SwiftWatchError) -> [URL]
	func stop()
}

public protocol FileWatcher {
	func startSession(for graph: WatchGraph) throws(SwiftWatchError) -> any FileWatcherSession
}

public struct FileWatcherImplementation: Sendable {
	public let name: String
	public let isDefault: Bool
	private let makeFileWatcher: @Sendable (WatcherOptions) -> any FileWatcher

	public init(
		name: String,
		isDefault: Bool = false,
		makeFileWatcher: @escaping @Sendable (WatcherOptions) -> any FileWatcher
	) {
		self.name = name
		self.isDefault = isDefault
		self.makeFileWatcher = makeFileWatcher
	}

	public func makeWatcher(options: WatcherOptions = WatcherOptions()) -> any FileWatcher {
		makeFileWatcher(options)
	}
}

public struct FileWatcherRegistry: Sendable {
	private let implementationsByName: [String: FileWatcherImplementation]
	public let availableWatcherNames: [String]
	public let defaultWatcherName: String

	public init(implementations: [FileWatcherImplementation]) throws(SwiftWatchError) {
		guard let first = implementations.first else {
			throw SwiftWatchError.noWatchersAvailable
		}

		var implementationsByName: [String: FileWatcherImplementation] = [:]
		for implementation in implementations {
			if implementationsByName.updateValue(
				implementation, forKey: implementation.name) != nil
			{
				throw SwiftWatchError.duplicateWatcher(implementation.name)
			}
		}

		self.implementationsByName = implementationsByName
		self.availableWatcherNames = implementations.map(\.name).sorted()
		self.defaultWatcherName =
			implementations.first(where: \.isDefault)?.name ?? first.name
	}

	public func makeWatcher(
		named watcherName: String?,
		options: WatcherOptions = WatcherOptions()
	) throws(SwiftWatchError) -> any FileWatcher {
		let resolvedName = watcherName ?? defaultWatcherName
		guard let implementation = implementationsByName[resolvedName] else {
			throw SwiftWatchError.unknownWatcher(
				resolvedName,
				available: availableWatcherNames
			)
		}
		return implementation.makeWatcher(options: options)
	}
}
