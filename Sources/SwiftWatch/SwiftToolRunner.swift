import Subprocess

import class Foundation.FileHandle
import class Foundation.Process

#if canImport(System)
	import System
#else
	import SystemPackage
#endif

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public protocol SwiftToolRunning {
	func describe(packagePath: URL, swiftBinDirectory: URL?) async throws(SwiftWatchError)
		-> DescribedPackage
	func runBuild(packagePath: URL, swiftBinDirectory: URL?, args: [String])
		async throws(SwiftWatchError)
		-> Int32
	func launchRun(packagePath: URL, swiftBinDirectory: URL?, args: [String])
		async throws(SwiftWatchError)
		-> Process
}

public struct SwiftToolRunner: SwiftToolRunning {
	public init() {}

	public func describe(packagePath: URL, swiftBinDirectory: URL?)
		async throws(SwiftWatchError)
		-> DescribedPackage
	{
		let result: ExecutionResult<Void, StringOutput<UTF8>, StringOutput<UTF8>>
		do {
			result = try await run(
				Self.executable(swiftBinDirectory: swiftBinDirectory),
				arguments: ["package", "describe", "--type", "json"],
				workingDirectory: FilePath(packagePath.path),
				output: .string(limit: 10 * 1024 * 1024),
				error: .string(limit: 10 * 1024 * 1024)
			)
		} catch {
			throw Self.launchError(for: "swift", error: error)
		}
		guard result.terminationStatus.isSuccess else {
			throw SwiftWatchError.packageDescribeFailed(result.standardError ?? "")
		}
		let data = Data((result.standardOutput ?? "").utf8)
		do {
			return try JSONDecoder().decode(DescribedPackage.self, from: data)
		} catch {
			throw SwiftWatchError.decodingFailed(
				context: "swift package describe output",
				message: error.localizedDescription
			)
		}
	}

	public func runBuild(packagePath: URL, swiftBinDirectory: URL?, args: [String])
		async throws(SwiftWatchError) -> Int32
	{
		do {
			let result = try await run(
				Self.executable(swiftBinDirectory: swiftBinDirectory),
				arguments: Arguments(["build"] + args),
				workingDirectory: FilePath(packagePath.path),
				output: .currentStandardOutput,
				error: .currentStandardError
			)
			return Self.exitCode(for: result.terminationStatus)
		} catch {
			throw Self.launchError(for: "swift", error: error)
		}
	}

	/// Launches `swift run` with the caller's arguments verbatim.
	///
	/// `swift run` performs its own build, so the arguments are never split
	/// between a build invocation and the executable being run. Splitting them
	/// is not possible in general: `swift-watch run MyExecutable --flag value`
	/// carries flags that belong to the executable, not to `swift build`.
	public func launchRun(packagePath: URL, swiftBinDirectory: URL?, args: [String])
		async throws(SwiftWatchError) -> Process
	{
		let resolvedExecutable: String
		do {
			resolvedExecutable = try await Self.executable(
				swiftBinDirectory: swiftBinDirectory
			)
			.resolveExecutablePath(in: .inherit).string
		} catch {
			throw Self.launchError(for: "swift", error: error)
		}
		let process = Process()
		process.executableURL = URL(fileURLWithPath: resolvedExecutable)
		process.arguments = ["run"] + args
		process.currentDirectoryURL = packagePath
		process.standardInput = FileHandle.standardInput
		process.standardOutput = FileHandle.standardOutput
		process.standardError = FileHandle.standardError
		do {
			try process.run()
		} catch {
			throw SwiftWatchError.processLaunchFailed(
				executable: resolvedExecutable,
				message: error.localizedDescription
			)
		}
		RunSupervisor.detachProcessGroup(for: process.processIdentifier)
		return process
	}

	private static func executable(swiftBinDirectory: URL?) -> Executable {
		guard let swiftBinDirectory else {
			return .name("swift")
		}
		return .path(FilePath(swiftBinDirectory.appendingPathComponent("swift").path))
	}

	private static func launchError(for executable: String, error: any Error) -> SwiftWatchError
	{
		.processLaunchFailed(
			executable: executable,
			message: String(describing: error)
		)
	}

	private static func exitCode(for status: TerminationStatus) -> Int32 {
		switch status {
		case .exited(let code):
			return Int32(code)
		#if !os(Windows)
			case .signaled(let signal):
				return Int32(signal)
		#endif
		}
	}
}
