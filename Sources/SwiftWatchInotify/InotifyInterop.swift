import SwiftWatch

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif
#if os(Linux)
	import Glibc

	struct InotifyEventRecord {
		let watchDescriptor: Int32
		let mask: UInt32
		let name: String

		var isDirectory: Bool {
			mask & UInt32(IN_ISDIR) != 0
		}

		/// The kernel dropped events; the caller has to resynchronise by
		/// rescanning instead of trusting the event stream.
		var isQueueOverflow: Bool {
			mask & UInt32(IN_Q_OVERFLOW) != 0
		}
	}

	enum InotifyInterop {
		static func makeSessionToken(_ session: InotifySession) -> UInt {
			UInt(bitPattern: Unmanaged.passUnretained(session).toOpaque())
		}

		static func eventSession(from token: UInt) -> InotifySession {
			Unmanaged<InotifySession>.fromOpaque(
				UnsafeMutableRawPointer(bitPattern: token)!
			).takeUnretainedValue()
		}

		/// Decodes one event from `buffer`, bounded by `limit`.
		///
		/// `limit` must be the byte count actually returned by `read`. The
		/// buffer is longer than the data it holds, and decoding past `limit`
		/// yields spurious zero-filled records.
		static func decodeEvent(
			from buffer: [UInt8],
			limit: Int,
			offset: inout Int
		) -> InotifyEventRecord? {
			let bound = min(limit, buffer.count)
			let eventHeaderSize = MemoryLayout<inotify_event>.size
			guard offset >= 0, offset + eventHeaderSize <= bound else {
				return nil
			}

			// The kernel only guarantees natural alignment within its own
			// buffer, so load without asserting alignment.
			let event = buffer.withUnsafeBytes { rawBuffer in
				rawBuffer.loadUnaligned(
					fromByteOffset: offset, as: inotify_event.self)
			}

			let nameOffset = offset + eventHeaderSize
			let nameLength = Int(event.len)
			guard nameLength >= 0, nameOffset + nameLength <= bound else {
				// Truncated record: stop rather than read out of bounds.
				offset = bound
				return nil
			}

			let nameBytes = Array(
				buffer[nameOffset..<(nameOffset + nameLength)]
					.prefix { $0 != 0 }
			)
			let name = String(bytes: nameBytes, encoding: .utf8) ?? ""
			offset = nameOffset + nameLength

			return InotifyEventRecord(
				watchDescriptor: event.wd,
				mask: event.mask,
				name: name
			)
		}
	}
#endif
