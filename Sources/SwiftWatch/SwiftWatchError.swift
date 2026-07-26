#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public enum SwiftWatchError: LocalizedError {
	case cancelled
	case commandFailed(command: [String], status: Int32, stderr: String)
	case decodingFailed(context: String, message: String)
	case fileSystemOperationFailed(operation: String, path: String?, message: String)
	case invalidUTF8
	case missingSwiftWatchBinary
	case noWatchersAvailable
	case packageDescribeFailed(String)
	case processLaunchFailed(executable: String, message: String)
	case unknownWatcher(String, available: [String])
	case duplicateWatcher(String)
	case watcherStartFailed(backend: String, message: String)
	case watcherStopped(String)

	public var errorDescription: String? {
		switch self {
		case .cancelled:
			return "swift-watch was cancelled"
		case .commandFailed(let command, let status, let stderr):
			let rendered = command.joined(separator: " ")
			return "command failed (\(status)): \(rendered)\n\(stderr)"
		case .decodingFailed(let context, let message):
			return "failed to decode \(context): \(message)"
		case .fileSystemOperationFailed(let operation, let path, let message):
			if let path {
				return
					"file system operation failed (\(operation)) at \(path): \(message)"
			}
			return "file system operation failed (\(operation)): \(message)"
		case .invalidUTF8:
			return "failed to decode command output as UTF-8"
		case .missingSwiftWatchBinary:
			return
				"swift-watch executable was not found in PATH. Install it first, then rerun the plugin command."
		case .noWatchersAvailable:
			return "no file watcher implementations are available on this platform"
		case .packageDescribeFailed(let message):
			return "failed to describe package graph: \(message)"
		case .processLaunchFailed(let executable, let message):
			return "failed to launch process \(executable): \(message)"
		case .unknownWatcher(let name, let available):
			let choices = available.joined(separator: ", ")
			return "unknown watcher '\(name)'. Available watchers: \(choices)"
		case .duplicateWatcher(let name):
			return "duplicate watcher registration for '\(name)'"
		case .watcherStartFailed(let backend, let message):
			return "failed to start the \(backend) watcher: \(message)"
		case .watcherStopped(let name):
			return "watcher stopped unexpectedly: \(name)"
		}
	}
}
