#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct WatchGraph: Sendable {
	public let packageRoots: Set<URL>
	public let sourceRoots: Set<URL>
	public let trackedFiles: Set<URL>
	public let manifestFiles: Set<URL>
	public let resolvedFiles: Set<URL>
	public let sourceExtensions: Set<String>

	/// Directories the caller knows are build output, such as a custom
	/// `--scratch-path` forwarded to `swift build`. Watching them would make
	/// every build's own writes look like changes.
	public let excludedRoots: Set<URL>

	public init(
		packageRoots: Set<URL>,
		sourceRoots: Set<URL>,
		trackedFiles: Set<URL>,
		manifestFiles: Set<URL>,
		resolvedFiles: Set<URL>,
		sourceExtensions: Set<String>,
		excludedRoots: Set<URL> = []
	) {
		self.packageRoots = Set(packageRoots.map(\.standardizedFileURL))
		self.sourceRoots = Set(sourceRoots.map(\.standardizedFileURL))
		self.trackedFiles = Set(trackedFiles.map(\.standardizedFileURL))
		self.manifestFiles = Set(manifestFiles.map(\.standardizedFileURL))
		self.resolvedFiles = Set(resolvedFiles.map(\.standardizedFileURL))
		self.sourceExtensions = sourceExtensions
		self.excludedRoots = Set(excludedRoots.map(\.standardizedFileURL))
	}

	public var watchedDirectories: [URL] {
		Array(packageRoots.union(sourceRoots)).sorted { $0.path < $1.path }
	}

	/// Whether any of `changes` invalidates the discovered package graph.
	///
	/// Only manifest and resolved-file edits can change the set of watched
	/// inputs, so only those justify rerunning `swift package describe`.
	public func requiresRediscovery(for changes: some Sequence<URL>) -> Bool {
		changes.contains { change in
			let url = change.standardizedFileURL
			return manifestFiles.contains(url) || resolvedFiles.contains(url)
		}
	}

	/// Whether `candidate` is a directory no watcher should enter: SwiftPM
	/// scratch state, SCM metadata, or a caller-supplied excluded root.
	///
	/// Pruning these keeps recursive watchers from registering watches on,
	/// and the polling backend from rescanning, entire build trees.
	public func prunesTraversal(_ candidate: URL) -> Bool {
		let components = candidate.pathComponents
		if components.contains(".build") || components.contains(".git")
			|| components.contains(".swiftpm")
		{
			return true
		}
		let url = candidate.standardizedFileURL
		return excludedRoots.contains { root in
			url == root || url.path.hasPrefix(root.path + "/")
		}
	}

	public func isRelevantChange(_ candidate: URL) -> Bool {
		let url = candidate.standardizedFileURL
		// Exact matches come from `swift package describe` and the manifest
		// scan, so they outrank the name-based heuristics below.
		if trackedFiles.contains(url) || manifestFiles.contains(url)
			|| resolvedFiles.contains(url)
		{
			return true
		}
		guard !prunesTraversal(url) else {
			return false
		}
		for sourceRoot in sourceRoots
		where url.path.hasPrefix(sourceRoot.path + "/") || url == sourceRoot {
			// SwiftPM's source enumeration skips hidden files and hidden
			// directories, so a change under one can never affect the build,
			// however source-like its name (emacs lock files such as
			// `.#main.swift` carry a real source extension). Only components
			// below the source root are judged: the root itself is part of
			// the described target path and may legitimately be hidden.
			let relative = url.path.dropFirst(sourceRoot.path.count)
			guard
				!relative.split(separator: "/").contains(where: {
					$0.hasPrefix(".")
				})
			else {
				return false
			}
			return sourceExtensions.contains(url.pathExtension.lowercased())
		}
		return false
	}
}
