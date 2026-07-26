import class Foundation.Process

#if os(Linux)
	import Glibc
#else
	import Darwin
#endif

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct RunSupervisor {
	public init() {}

	public func terminate(_ process: Process, timeout: Duration = .seconds(30)) async {
		guard process.isRunning else {
			return
		}
		let pid = process.processIdentifier
		Self.signal(SIGINT, to: pid)

		let deadline = Date().addingTimeInterval(timeout.timeInterval)
		while process.isRunning && Date() < deadline {
			await AsyncSupport.sleepIgnoringCancellation(for: .milliseconds(100))
		}

		if process.isRunning {
			Self.signal(SIGKILL, to: pid)
		}

		while process.isRunning {
			await AsyncSupport.sleepIgnoringCancellation(for: .milliseconds(50))
		}
	}

	/// Signals the child's process group when it has one of its own, so that
	/// grandchildren spawned by `swift run` are not orphaned.
	///
	/// Falls back to signalling the process directly when the child still shares
	/// our group, which would otherwise mean signalling ourselves.
	static func signal(_ code: Int32, to pid: pid_t) {
		let childGroup = getpgid(pid)
		let ownGroup = getpgid(0)
		if childGroup > 0 && childGroup != ownGroup {
			if kill(-childGroup, code) == 0 {
				return
			}
		}
		_ = kill(pid, code)
	}

	/// Moves a freshly launched child into its own process group.
	///
	/// Best effort: the child may already have `exec`'d, in which case the
	/// caller simply keeps signalling the process directly.
	static func detachProcessGroup(for pid: pid_t) {
		_ = setpgid(pid, pid)
	}
}
