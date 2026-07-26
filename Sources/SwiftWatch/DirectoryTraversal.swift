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
		var queue = roots.map(\.standardizedFileURL)
		var visited = Set<URL>()

		while let next = queue.popLast() {
			let directory = next.standardizedFileURL
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

			let children = try FileSystemSupport.perform(
				operation: "contentsOfDirectory",
				path: directory
			) {
				try fileManager.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: [
						.isDirectoryKey, .contentModificationDateKey,
						.fileSizeKey,
					],
					options: [.skipsPackageDescendants]
				)
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
					queue.append(child)
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
		var directories: [URL] = []
		try walk(
			roots: roots,
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
		var files: Set<URL> = []
		try walk(
			roots: roots,
			graph: graph,
			fileManager: fileManager,
			onDirectory: { _ in },
			onFile: { file in
				if graph.isRelevantChange(file) {
					files.insert(file.standardizedFileURL)
				}
			}
		)
		return files.sorted { $0.path < $1.path }
	}
}
