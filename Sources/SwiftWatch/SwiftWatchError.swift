#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public enum SwiftWatchError: LocalizedError {
	case cancelled
	case commandFailed(command: [String], status: Int32, stderr: String)
	case missingSwiftWatchBinary
	case noWatchersAvailable
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
		case .missingSwiftWatchBinary:
			return
				"swift-watch executable was not found in PATH. Install it first, then rerun the plugin command."
		case .noWatchersAvailable:
			return "no file watcher implementations are available on this platform"
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
