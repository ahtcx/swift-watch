#if os(Linux)
	import Glibc
#else
	import Darwin
#endif

public enum AsyncSupport {
	public static func sleep(for duration: Duration, context: String)
		async throws(SwiftWatchError)
	{
		do {
			try await Task.sleep(for: duration)
		} catch is CancellationError {
			throw .cancelled
		} catch {
			throw .watcherStopped(context)
		}
	}

	/// Sleeps without honouring cooperative cancellation.
	///
	/// Teardown paths still need to make progress after the surrounding task has
	/// been cancelled, where `Task.sleep` would return immediately and spin.
	public static func sleepIgnoringCancellation(for duration: Duration) async {
		do {
			try await Task.sleep(for: duration)
		} catch {
			let nanoseconds = max(0, duration.nanoseconds)
			var requested = timespec(
				tv_sec: Int(nanoseconds / 1_000_000_000),
				tv_nsec: Int(nanoseconds % 1_000_000_000)
			)
			while true {
				var remaining = timespec()
				if nanosleep(&requested, &remaining) == 0 {
					break
				}
				guard errno == EINTR else {
					break
				}
				requested = remaining
			}
		}
	}

	public static func checkCancellation() throws(SwiftWatchError) {
		if Task.isCancelled {
			throw .cancelled
		}
	}
}
