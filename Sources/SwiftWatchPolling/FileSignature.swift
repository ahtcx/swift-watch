import SwiftWatch

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

struct FileSignature: Equatable {
	let modificationDate: Date
	let size: Int

	/// Returns `nil` when the file has disappeared between listing and stat.
	init?(url: URL) {
		guard
			let values = try? url.resourceValues(forKeys: [
				.contentModificationDateKey, .fileSizeKey,
			])
		else {
			return nil
		}
		self.modificationDate = values.contentModificationDate ?? .distantPast
		self.size = values.fileSize ?? 0
	}
}
