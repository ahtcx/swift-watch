import SwiftWatch

import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

enum PollingScanner {
	static func scan(
		graph: WatchGraph,
		fileManager: FileManager
	) throws(SwiftWatchError) -> [URL: FileSignature] {
		var result: [URL: FileSignature] = [:]
		try DirectoryTraversal.walk(
			scope: graph.watchScope,
			graph: graph,
			fileManager: fileManager,
			onDirectory: { _ in },
			onFile: { file in
				guard graph.isRelevantChange(file) else {
					return
				}
				if let signature = FileSignature(url: file) {
					result[file.standardizedFileURL] = signature
				}
			}
		)
		return result
	}
}
