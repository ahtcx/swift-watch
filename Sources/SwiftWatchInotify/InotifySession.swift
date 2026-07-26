import Dispatch
import SwiftWatch
import Synchronization

import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif
#if os(Linux)
	import Glibc

	struct InotifyWatchState {
		var watchDescriptorsByPath: [URL: Int32] = [:]
		var pathsByWatchDescriptor: [Int32: URL] = [:]
		var pending = Set<URL>()
		var stopped = false
		var terminalError: SwiftWatchError?
	}

	/// inotify observation of a `WatchGraph`.
	///
	/// Watches are installed when the session is created, so changes that land
	/// while a build is running are buffered rather than lost.
	final class InotifySession: FileWatcherSession {
		private let graph: WatchGraph
		private let fileDescriptor: Int32
		private let queue = DispatchQueue(label: "swift-watch.inotify")
		private let state = Mutex(InotifyWatchState())
		private let continuation: AsyncStream<Void>.Continuation
		private var signalIterator: AsyncStream<Void>.Iterator

		init(graph: WatchGraph) throws(SwiftWatchError) {
			self.graph = graph
			let fileDescriptor = inotify_init1(Int32(IN_CLOEXEC))
			guard fileDescriptor >= 0 else {
				throw SwiftWatchError.watcherStartFailed(
					backend: "inotify",
					message: String(cString: strerror(errno))
				)
			}
			self.fileDescriptor = fileDescriptor

			let signalStream = AsyncStream.makeStream(
				of: Void.self,
				bufferingPolicy: .bufferingNewest(1)
			)
			self.continuation = signalStream.continuation
			self.signalIterator = signalStream.stream.makeAsyncIterator()

			do {
				try refreshWatches()
			} catch {
				_ = close(fileDescriptor)
				throw error
			}
			start()
		}

		func waitForChange(debounce: Duration) async throws(SwiftWatchError) -> [URL] {
			while true {
				try AsyncSupport.checkCancellation()

				if !hasPending {
					try await waitForSignal()
					try AsyncSupport.checkCancellation()
				}

				try await AsyncSupport.sleep(for: debounce, context: "inotify")
				let changes = try drainPending()
				if !changes.isEmpty {
					return changes.sorted { $0.path < $1.path }
				}
			}
		}

		private var hasPending: Bool {
			state.withLock { !$0.pending.isEmpty }
		}

		private func waitForSignal() async throws(SwiftWatchError) {
			_ = await signalIterator.next()
			if let terminalError = state.withLock({ $0.terminalError }) {
				throw terminalError
			}
			if state.withLock({ $0.stopped }) {
				throw .watcherStopped("inotify")
			}
		}

		private func drainPending() throws(SwiftWatchError) -> [URL] {
			try refreshWatches()
			return state.withLock { state in
				defer { state.pending.removeAll() }
				return Array(state.pending)
			}
		}

		func stop() {
			let shouldStop = state.withLock {
				guard !$0.stopped else {
					return false
				}
				$0.stopped = true
				return true
			}
			guard shouldStop else {
				return
			}
			let descriptors = state.withLock { Array($0.pathsByWatchDescriptor.keys) }
			for descriptor in descriptors {
				_ = inotify_rm_watch(fileDescriptor, descriptor)
			}
			state.withLock {
				$0.pathsByWatchDescriptor.removeAll()
				$0.watchDescriptorsByPath.removeAll()
			}
			_ = close(fileDescriptor)
			continuation.finish()
		}

		private func start() {
			let sessionToken = InotifyInterop.makeSessionToken(self)
			queue.async {
				let session = InotifyInterop.eventSession(from: sessionToken)
				session.eventLoop()
			}
		}

		private func refreshWatches() throws(SwiftWatchError) {
			let directories = try DirectoryTraversal.directories(
				under: graph.watchedDirectories,
				graph: graph,
				fileManager: FileManager.default
			)
			let nextDirectories = Set(directories)
			let existingWatches = state.withLock { $0.watchDescriptorsByPath }

			for (path, descriptor) in existingWatches
			where !nextDirectories.contains(path) {
				_ = inotify_rm_watch(fileDescriptor, descriptor)
				state.withLock {
					$0.watchDescriptorsByPath.removeValue(forKey: path)
					$0.pathsByWatchDescriptor.removeValue(forKey: descriptor)
				}
			}

			for directory in directories
			where state.withLock({ $0.watchDescriptorsByPath[directory] == nil }) {
				let descriptor = directory.path.withCString { pathPointer in
					inotify_addWatch(
						fileDescriptor: fileDescriptor, path: pathPointer)
				}
				guard descriptor >= 0 else {
					// The directory may have been removed between listing
					// and watching; that is not a fatal condition.
					if errno == ENOENT {
						continue
					}
					throw SwiftWatchError.watcherStartFailed(
						backend: "inotify",
						message:
							"failed to watch \(directory.path): \(String(cString: strerror(errno)))"
					)
				}
				state.withLock {
					$0.watchDescriptorsByPath[directory] = descriptor
					$0.pathsByWatchDescriptor[descriptor] = directory
				}
			}
		}

		private func eventLoop() {
			while !state.withLock({ $0.stopped }) {
				do {
					try processEvents()
				} catch let error {
					if state.withLock({ $0.stopped }) {
						return
					}
					state.withLock {
						$0.terminalError = error
					}
					stop()
					return
				}
			}
		}

		private func processEvents() throws(SwiftWatchError) {
			var buffer = [UInt8](repeating: 0, count: 64 * 1024)
			let bytesRead = read(fileDescriptor, &buffer, buffer.count)
			if bytesRead < 0 {
				if errno == EINTR {
					return
				}
				if errno == EBADF && state.withLock({ $0.stopped }) {
					return
				}
				throw SwiftWatchError.watcherStopped(
					"inotify: \(String(cString: strerror(errno)))"
				)
			}
			guard bytesRead > 0 else {
				return
			}

			var offset = 0
			var didOverflow = false
			while offset < bytesRead,
				let event = InotifyInterop.decodeEvent(
					from: buffer, limit: bytesRead, offset: &offset)
			{
				if event.isQueueOverflow {
					didOverflow = true
					continue
				}

				let basePath = state.withLock {
					$0.pathsByWatchDescriptor[event.watchDescriptor]
				}
				guard let basePath else {
					continue
				}
				let candidate =
					event.name.isEmpty
					? basePath
					: basePath.appendingPathComponent(event.name)
						.standardizedFileURL

				if event.isDirectory {
					// A newly created subtree may already contain sources
					// that never produced their own events.
					try refreshWatches()
					for discovered in try DirectoryTraversal.relevantFiles(
						under: [candidate],
						graph: graph,
						fileManager: FileManager.default
					) {
						insertPending(discovered)
					}
				}
				if graph.isRelevantChange(candidate) {
					insertPending(candidate)
				}
			}

			if didOverflow {
				try resynchronise()
			}

			if state.withLock({ !$0.pending.isEmpty }) {
				continuation.yield(())
			}
		}

		/// Recovers from a dropped-event queue overflow by treating every
		/// currently relevant file as changed.
		private func resynchronise() throws(SwiftWatchError) {
			try refreshWatches()
			for file in try DirectoryTraversal.relevantFiles(
				under: graph.watchedDirectories,
				graph: graph,
				fileManager: FileManager.default
			) {
				insertPending(file)
			}
		}

		private func insertPending(_ url: URL) {
			state.withLock {
				_ = $0.pending.insert(url)
			}
		}
	}

	private func inotify_addWatch(
		fileDescriptor: Int32,
		path: UnsafePointer<CChar>
	) -> Int32 {
		inotify_add_watch(
			fileDescriptor,
			path,
			UInt32(
				IN_ATTRIB
					| IN_CREATE
					| IN_DELETE
					| IN_DELETE_SELF
					| IN_MODIFY
					| IN_MOVE_SELF
					| IN_MOVED_FROM
					| IN_MOVED_TO
			)
		)
	}
#endif
