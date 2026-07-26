import PackagePlugin

import class Foundation.FileHandle
import class Foundation.Process

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

@main
struct SwiftWatchPlugin: CommandPlugin {
	func performCommand(context: PluginContext, arguments: [String]) async throws {
		let tool = try context.tool(named: "swift-watch")
		let process = Process()
		process.executableURL = tool.url
		process.arguments = arguments
		process.currentDirectoryURL = context.package.directoryURL
		process.standardInput = FileHandle.standardInput
		process.standardOutput = FileHandle.standardOutput
		process.standardError = FileHandle.standardError
		try process.run()
		process.waitUntilExit()
		if process.terminationStatus != 0 {
			throw PluginError.failed(status: process.terminationStatus)
		}
	}
}

private enum PluginError: LocalizedError {
	case failed(status: Int32)

	var errorDescription: String? {
		switch self {
		case .failed(let status):
			return "swift-watch exited with status \(status)."
		}
	}
}
