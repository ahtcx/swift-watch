#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public enum FileSystemSupport {
	public static func perform<T>(
		operation: String,
		path: URL,
		_ body: () throws -> T
	) throws(SwiftWatchError) -> T {
		do {
			return try body()
		} catch {
			throw .fileSystemOperationFailed(
				operation: operation,
				path: path.path,
				message: error.localizedDescription
			)
		}
	}
}
