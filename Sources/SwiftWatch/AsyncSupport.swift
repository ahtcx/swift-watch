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

	public static func checkCancellation() throws(SwiftWatchError) {
		if Task.isCancelled {
			throw .cancelled
		}
	}
}
