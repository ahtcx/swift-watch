import SwiftWatch

import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

struct PollingSnapshot {
	var entries: [URL: FileSignature]

	static func make(graph: WatchGraph, fileManager: FileManager)
		throws(SwiftWatchError) -> PollingSnapshot
	{
		PollingSnapshot(
			entries: try PollingScanner.scan(graph: graph, fileManager: fileManager))
	}

	func diff(from previous: PollingSnapshot) -> [URL] {
		let previousKeys = Set(previous.entries.keys)
		let currentKeys = Set(entries.keys)
		var changed = currentKeys.symmetricDifference(previousKeys)
		for key in currentKeys.intersection(previousKeys)
		where entries[key] != previous.entries[key] {
			changed.insert(key)
		}
		return Array(changed)
	}
}
