import Dispatch

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct ExecutionOptions: Sendable {
	public var debounceMilliseconds: Int
	public var pollIntervalMilliseconds: Int
	public var watcherName: String?
	public var swiftBinDirectory: URL?
	public var packagePath: URL
	public var selection: WatchSelection

	/// Directories that must never be watched, such as a custom scratch path
	/// forwarded to the underlying `swift` invocation.
	public var excludedPaths: [URL]

	public init(
		debounceMilliseconds: Int = 300,
		pollIntervalMilliseconds: Int = 150,
		watcherName: String? = nil,
		swiftBinDirectory: URL? = nil,
		packagePath: URL,
		selection: WatchSelection = WatchSelection(),
		excludedPaths: [URL] = []
	) {
		self.debounceMilliseconds = debounceMilliseconds
		self.pollIntervalMilliseconds = pollIntervalMilliseconds
		self.watcherName = watcherName
		self.swiftBinDirectory = swiftBinDirectory?.standardizedFileURL
		self.packagePath = packagePath.standardizedFileURL
		self.selection = selection
		self.excludedPaths = excludedPaths.map(\.standardizedFileURL)
	}

	public var debounce: Duration {
		.milliseconds(debounceMilliseconds)
	}

	public var watcherOptions: WatcherOptions {
		WatcherOptions(pollInterval: .milliseconds(pollIntervalMilliseconds))
	}
}
