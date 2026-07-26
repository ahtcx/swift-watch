import Dispatch
import SwiftWatch

import class Foundation.NSLock

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif
#if canImport(CoreServices)
	@preconcurrency import CoreServices

	struct FSEventsSessionState {
		var pending = Set<URL>()
		var stopped = false
		var terminalError: SwiftWatchError?
	}

	/// FSEvents observation of a `WatchGraph`.
	///
	/// The stream is started when the session is created, so changes that land
	/// while a build is running are buffered rather than lost.
	final class FSEventsSession: FileWatcherSession {
		private let graph: WatchGraph
		private let queue = DispatchQueue(label: "swift-watch.fsevents")
		private let lock = NSLock()
		private var state = FSEventsSessionState()
		private let continuation: AsyncStream<Void>.Continuation
		private var signalIterator: AsyncStream<Void>.Iterator
		private var stream: FSEventStreamRef?

		init(graph: WatchGraph) {
			self.graph = graph
			let signalStream = AsyncStream.makeStream(
				of: Void.self,
				bufferingPolicy: .bufferingNewest(1)
			)
			self.continuation = signalStream.continuation
			self.signalIterator = signalStream.stream.makeAsyncIterator()
		}

		func start() throws(SwiftWatchError) {
			let paths = graph.watchedDirectories.map(\.path)
			guard !paths.isEmpty else {
				throw SwiftWatchError.watcherStartFailed(
					backend: "FSEvents",
					message: "the watch graph contains no directories"
				)
			}

			var streamContext = FSEventStreamContext(
				version: 0,
				info: FSEventsInterop.makeInfo(self),
				retain: nil,
				release: nil,
				copyDescription: nil
			)
			guard
				let stream = FSEventStreamCreate(
					kCFAllocatorDefault,
					fseventsCallback,
					&streamContext,
					paths as CFArray,
					FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
					0.05,
					FSEventStreamCreateFlags(
						kFSEventStreamCreateFlagFileEvents
							| kFSEventStreamCreateFlagUseCFTypes
							| kFSEventStreamCreateFlagNoDefer
					)
				)
			else {
				throw SwiftWatchError.watcherStartFailed(
					backend: "FSEvents",
					message: "FSEventStreamCreate returned no stream"
				)
			}

			self.stream = stream
			FSEventStreamSetDispatchQueue(stream, queue)
			if !FSEventStreamStart(stream) {
				stop()
				throw SwiftWatchError.watcherStartFailed(
					backend: "FSEvents",
					message: "FSEventStreamStart failed"
				)
			}
		}

		func waitForChange(debounce: Duration) async throws(SwiftWatchError) -> [URL] {
			while true {
				try AsyncSupport.checkCancellation()

				if !hasPending {
					try await waitForSignal()
					try AsyncSupport.checkCancellation()
				}

				try await AsyncSupport.sleep(for: debounce, context: "FSEvents")
				let changes = drainPending()
				if !changes.isEmpty {
					return changes.sorted { $0.path < $1.path }
				}
			}
		}

		private var hasPending: Bool {
			lock.withLock { !state.pending.isEmpty }
		}

		private func waitForSignal() async throws(SwiftWatchError) {
			_ = await signalIterator.next()
			let terminalError = lock.withLock { state.terminalError }
			if let terminalError {
				throw terminalError
			}
			let stopped = lock.withLock { state.stopped }
			if stopped {
				throw .watcherStopped("FSEvents")
			}
		}

		private func drainPending() -> [URL] {
			lock.withLock {
				defer { state.pending.removeAll() }
				return Array(state.pending)
			}
		}

		func stop() {
			guard let stream else {
				return
			}
			lock.withLock {
				state.stopped = true
			}
			self.stream = nil
			FSEventStreamStop(stream)
			FSEventStreamInvalidate(stream)
			FSEventStreamRelease(stream)
			continuation.finish()
		}

		func record(_ candidates: [URL]) {
			let relevant = candidates.filter(graph.isRelevantChange)
			guard !relevant.isEmpty else {
				return
			}
			lock.withLock {
				for path in relevant {
					state.pending.insert(path)
				}
			}
			continuation.yield(())
		}
	}

	extension NSLock {
		func withLock<T>(_ body: () -> T) -> T {
			lock()
			defer { unlock() }
			return body()
		}
	}
#endif
