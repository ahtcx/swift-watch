import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Shared, exclusion-aware directory walking used by every watcher backend.
///
/// The backends previously each carried their own near-identical traversal.
public enum DirectoryTraversal {
	/// Walks `roots` breadth-first, skipping anything the graph excludes.
	///
	/// `onDirectory` is invoked for each visited directory, `onFile` for each
	/// non-directory entry encountered inside those directories. A root that is
	/// not a directory is reported through `onFile`.
	public static func walk(
		roots: some Sequence<URL>,
		graph: WatchGraph,
		fileManager: FileManager,
		onDirectory: (URL) throws(SwiftWatchError) -> Void,
		onFile: (URL) throws(SwiftWatchError) -> Void
	) throws(SwiftWatchError) {
		try walk(
			scope: WatchScope(recursiveRoots: Set(roots)),
			graph: graph,
			fileManager: fileManager,
			onDirectory: onDirectory,
			onFile: onFile
		)
	}

	/// Walks `scope`, descending only from its recursive roots.
	///
	/// A shallow root is still visited and its own entries still reported; only
	/// the directories inside it are left unopened. A directory reachable both
	/// ways is descended into, since the recursive claim is the stronger one and
	/// the roots are visited before their contents.
	///
	/// `onUnreadableDirectory` is invoked for each directory walked past because
	/// its contents could not be listed. Callers with somewhere to report are
	/// expected to say so: skipping is the right behaviour, and doing it in
	/// silence would leave a source directory unwatched with nothing to show for
	/// it.
	public static func walk(
		scope: WatchScope,
		graph: WatchGraph,
		fileManager: FileManager,
		onDirectory: (URL) throws(SwiftWatchError) -> Void,
		onFile: (URL) throws(SwiftWatchError) -> Void,
		onUnreadableDirectory: (URL) -> Void = { _ in }
	) throws(SwiftWatchError) {
		var queue =
			scope.shallowRoots.map { (url: $0, descends: false) }
			+ scope.recursiveRoots.map { (url: $0, descends: true) }
		var visited = Set<URL>()

		while let next = queue.popLast() {
			let directory = next.url.standardizedFileURL
			guard visited.insert(directory).inserted else {
				continue
			}
			guard !graph.prunesTraversal(directory) else {
				continue
			}

			// A path can disappear between discovery and inspection; treat an
			// unreadable entry as absent rather than as a hard failure.
			guard
				let values = try? directory.resourceValues(forKeys: [
					.isDirectoryKey
				])
			else {
				continue
			}
			guard values.isDirectory == true else {
				try onFile(directory)
				continue
			}

			try onDirectory(directory)

			// A directory that cannot be listed is treated as empty, which is
			// the case above one level down. SwiftPM enumerates sources as the
			// same user, so a directory this process may not read holds nothing
			// the build could have read either — and one directory somewhere in
			// scope that the user does not own must not take the whole watch
			// down with it. It is reported rather than passed over in silence.
			guard
				let children = try? fileManager.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: [
						.isDirectoryKey, .contentModificationDateKey,
						.fileSizeKey,
					],
					options: [.skipsPackageDescendants]
				)
			else {
				onUnreadableDirectory(directory)
				continue
			}

			// Hidden entries are skipped because SwiftPM's source enumeration
			// never reads them. Only discovered children are judged, not the
			// explicit roots: a package or target root may itself live under
			// a hidden path and is walked regardless.
			for child in children
			where !graph.prunesTraversal(child)
				&& !child.lastPathComponent.hasPrefix(".")
			{
				guard
					let childValues = try? child.resourceValues(forKeys: [
						.isDirectoryKey
					])
				else {
					continue
				}
				if childValues.isDirectory == true {
					if next.descends {
						queue.append((url: child, descends: true))
					}
				} else {
					try onFile(child)
				}
			}
		}
	}

	/// Every directory reachable from `roots`, sorted by path.
	public static func directories(
		under roots: some Sequence<URL>,
		graph: WatchGraph,
		fileManager: FileManager
	) throws(SwiftWatchError) -> [URL] {
		try directories(
			in: WatchScope(recursiveRoots: Set(roots)),
			graph: graph,
			fileManager: fileManager)
	}

	/// Every directory `scope` reaches, sorted by path.
	public static func directories(
		in scope: WatchScope,
		graph: WatchGraph,
		fileManager: FileManager
	) throws(SwiftWatchError) -> [URL] {
		var directories: [URL] = []
		try walk(
			scope: scope,
			graph: graph,
			fileManager: fileManager,
			onDirectory: { directories.append($0) },
			onFile: { _ in }
		)
		return directories.sorted { $0.path < $1.path }
	}

	/// Every file reachable from `roots` that the graph considers relevant.
	public static func relevantFiles(
		under roots: some Sequence<URL>,
		graph: WatchGraph,
		fileManager: FileManager
	) throws(SwiftWatchError) -> [URL] {
		try relevantFiles(
			in: WatchScope(recursiveRoots: Set(roots)),
			graph: graph,
			fileManager: fileManager)
	}

	/// Every file `scope` reaches that the graph considers relevant.
	public static func relevantFiles(
		in scope: WatchScope,
		graph: WatchGraph,
		fileManager: FileManager,
		onUnreadableDirectory: (URL) -> Void = { _ in }
	) throws(SwiftWatchError) -> [URL] {
		var files: Set<URL> = []
		try walk(
			scope: scope,
			graph: graph,
			fileManager: fileManager,
			onDirectory: { _ in },
			onFile: { file in
				if graph.isRelevantChange(file) {
					files.insert(file.standardizedFileURL)
				}
			},
			onUnreadableDirectory: onUnreadableDirectory
		)
		return files.sorted { $0.path < $1.path }
	}
}
