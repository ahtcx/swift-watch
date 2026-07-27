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

	/// How to read what the underlying `swift` invocation planned, which is
	/// where a build tool plugin's inputs become visible. Depends on the
	/// forwarded build system, scratch path, and configuration together, so the
	/// CLI resolves it from the same arguments it forwards.
	///
	/// Absent when the forwarded build system records nothing swift-watch can
	/// read, which costs only the inputs no manifest declares.
	public var buildManifest: BuildManifestSource?

	/// Which widening rules apply when judging a change.
	public var rules: WatchRules

	/// Whether to report the rule behind each change that triggers a rerun.
	public var explain: Bool

	public init(
		debounceMilliseconds: Int = 300,
		pollIntervalMilliseconds: Int = 150,
		watcherName: String? = nil,
		swiftBinDirectory: URL? = nil,
		packagePath: URL,
		selection: WatchSelection = WatchSelection(),
		excludedPaths: [URL] = [],
		buildManifest: BuildManifestSource? = nil,
		rules: WatchRules = .default,
		explain: Bool = false
	) {
		self.debounceMilliseconds = debounceMilliseconds
		self.pollIntervalMilliseconds = pollIntervalMilliseconds
		self.watcherName = watcherName
		self.swiftBinDirectory = swiftBinDirectory?.standardizedFileURL
		self.packagePath = packagePath.standardizedFileURL
		self.selection = selection
		self.excludedPaths = excludedPaths.map(\.standardizedFileURL)
		self.buildManifest = buildManifest
		self.rules = rules
		self.explain = explain
	}

	public var debounce: Duration {
		.milliseconds(debounceMilliseconds)
	}

	public var watcherOptions: WatcherOptions {
		WatcherOptions(pollInterval: .milliseconds(pollIntervalMilliseconds))
	}
}
