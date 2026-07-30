import Subprocess

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
	/// Runs a `swift` subcommand to completion, inheriting the terminal so its
	/// output reaches the user unbuffered.
	func runSwift(
		subcommand: String, packagePath: URL, swiftBinDirectory: URL?, args: [String]
	)
		async throws(SwiftWatchError)
		-> Int32
	/// Runs `swift run` for as long as `whileRunning` takes, then shuts the
	/// launched executable down before returning.
	func withRun<Result: Sendable>(
		packagePath: URL,
		swiftBinDirectory: URL?,
		args: [String],
		whileRunning: () async throws(SwiftWatchError) -> Result
	) async throws(SwiftWatchError) -> Result
}

public struct SwiftToolRunner: SwiftToolRunning {
	/// How long a watched executable gets to exit after `SIGINT` before it is
	/// killed.
	public var terminationTimeout: Duration

	public init(terminationTimeout: Duration = .seconds(30)) {
		self.terminationTimeout = terminationTimeout
	}

	public func runSwift(
		subcommand: String, packagePath: URL, swiftBinDirectory: URL?, args: [String]
	)
		async throws(SwiftWatchError) -> Int32
	{
		do {
			let result = try await run(
				Self.executable(swiftBinDirectory: swiftBinDirectory),
				arguments: Arguments([subcommand] + args),
				workingDirectory: FilePath(packagePath.path),
				output: .currentStandardOutput,
				error: .currentStandardError
			)
			return Self.exitCode(for: result.terminationStatus)
		} catch {
			throw Self.launchError(for: "swift", error: error)
		}
	}

	/// Runs `swift run` with the caller's arguments verbatim.
	///
	/// `swift run` performs its own build, so the arguments are never split
	/// between a build invocation and the executable being run. Splitting them
	/// is not possible in general: `swift-watch run MyExecutable --flag value`
	/// carries flags that belong to the executable, not to `swift build`.
	///
	/// The executable gets its own process group, so `SIGINT` can be sent to the
	/// group — reaching the binary `swift run` spawns as a grandchild — without
	/// swift-watch signalling itself. Anything still alive after
	/// `terminationTimeout` is killed.
	///
	/// The group is all it gets: keeping the session means it keeps the
	/// controlling terminal, and so behaves as it would if it had been run
	/// directly.
	public func withRun<Result: Sendable>(
		packagePath: URL,
		swiftBinDirectory: URL?,
		args: [String],
		whileRunning: () async throws(SwiftWatchError) -> Result
	) async throws(SwiftWatchError) -> Result {
		let teardown: [TeardownStep] = [
			.send(
				signal: .interrupt,
				toProcessGroup: true,
				allowedDurationToNextStep: terminationTimeout
			)
		]
		var platformOptions = PlatformOptions()
		platformOptions.processGroupID = 0
		// Covers the throwing and cancelled paths. A `whileRunning` that
		// returns normally tears the executable down itself, below.
		platformOptions.teardownSequence = teardown

		do {
			let result = try await run(
				Self.executable(swiftBinDirectory: swiftBinDirectory),
				arguments: Arguments(["run"] + args),
				workingDirectory: FilePath(packagePath.path),
				platformOptions: platformOptions,
				input: .standardInput,
				output: .currentStandardOutput,
				error: .currentStandardError
			) { execution in
				let value = try await whileRunning()
				// Once the body returns, `run` waits for the executable to exit
				// on its own, which a watched executable never does.
				await execution.teardown(using: teardown)
				return value
			}
			return result.closureResult
		} catch let error as SwiftWatchError {
			throw error
		} catch {
			throw Self.launchError(for: "swift", error: error)
		}
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
