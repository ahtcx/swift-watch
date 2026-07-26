import SwiftWatch

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif
#if canImport(CoreServices)
	@preconcurrency import CoreServices

	let fseventsCallback: FSEventStreamCallback = {
		_, info, eventCount, eventPaths, _, _ in
		guard
			let info,
			let session = FSEventsInterop.eventSession(from: info)
		else {
			return
		}
		let paths = FSEventsInterop.decodePaths(
			from: eventPaths,
			eventCount: Int(eventCount)
		)
		session.record(paths)
	}

	enum FSEventsInterop {
		static func makeInfo(_ session: FSEventsSession) -> UnsafeMutableRawPointer {
			UnsafeMutableRawPointer(Unmanaged.passUnretained(session).toOpaque())
		}

		static func eventSession(from info: UnsafeMutableRawPointer) -> FSEventsSession? {
			Unmanaged<FSEventsSession>.fromOpaque(info).takeUnretainedValue()
		}

		static func decodePaths(
			from rawEventPaths: UnsafeMutableRawPointer,
			eventCount: Int
		) -> [URL] {
			let rawPaths =
				unsafeBitCast(rawEventPaths, to: NSArray.self) as? [String] ?? []
			return rawPaths.prefix(eventCount).map {
				URL(fileURLWithPath: $0).standardizedFileURL
			}
		}
	}
#endif
