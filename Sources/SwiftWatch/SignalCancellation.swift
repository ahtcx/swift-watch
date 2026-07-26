import Dispatch

#if os(Linux)
	import Glibc
#else
	import Darwin
#endif

/// Runs `operation`, cancelling it when one of `signals` is delivered.
///
/// Terminal interrupts have to be turned into cooperative cancellation so the
/// watch loop can shut down child processes instead of being killed outright.
public func withCancellationOnSignals<T: Sendable>(
	_ signals: [Int32] = [SIGINT, SIGTERM],
	operation: @escaping @Sendable () async throws -> T
) async throws -> T {
	let task = Task { try await operation() }
	let queue = DispatchQueue(label: "swift-watch.signals")
	var sources: [DispatchSourceSignal] = []

	for signalNumber in signals {
		// The dispatch source only observes the signal; the default
		// disposition still has to be suppressed or the process dies first.
		_ = signal(signalNumber, SIG_IGN)
		let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
		source.setEventHandler {
			task.cancel()
		}
		source.resume()
		sources.append(source)
	}

	defer {
		for source in sources {
			source.cancel()
		}
	}

	return try await task.value
}
