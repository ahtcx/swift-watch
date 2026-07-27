import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Reads the inputs of a planned build out of whatever the build system leaves
/// behind when it plans one.
///
/// This is the only place a build tool plugin's inputs can be resolved. A
/// plugin declares them at planning time, in code, so `swift package describe`
/// cannot report them — plugins such as grpc-swift's discover their `.proto`
/// files by scanning the source tree, and nothing about them appears in the
/// manifest the package author writes. The planned build, on the other hand,
/// records every command with the exact paths it reads.
///
/// Every conformance reads a build system's own intermediate output rather than
/// a public interface, so all of them share one discipline: name as little of
/// the format as the inputs can be found with, skip anything unrecognised
/// instead of failing, and report a file that exists but cannot be understood
/// so the user hears about it once. A read that comes up short leaves the watch
/// graph exactly as `swift package describe` built it, which is a watcher that
/// misses plugin inputs rather than one that breaks.
public protocol BuildManifestReading: Sendable {
	/// The `--build-system` spelling this reads for, used in diagnostics.
	var buildSystemName: String { get }

	/// Where this build system records the build it plans, for an invocation
	/// with `scratchPath` and `configuration`.
	///
	/// `scratchPath` is the forwarded `--scratch-path`/`--build-path` when the
	/// caller redirected build output, and the package's own `.build`
	/// otherwise. Conformances that encode the configuration elsewhere are free
	/// to ignore it.
	func manifestLocation(scratchPath: URL, configuration: String) -> URL

	/// What `location` says the planned build reads.
	func read(at location: URL, fileManager: FileManager) -> PlannedBuild
}

extension BuildManifestReading {
	/// Reads through the process-wide file manager, for callers with no reason
	/// to substitute one.
	public func read(at location: URL) -> PlannedBuild {
		read(at: location, fileManager: .default)
	}
}

/// What a reader made of the manifest on disk.
///
/// The distinction that matters is between having no information and having
/// learned that a build reads nothing. Only the first ever happens, so the
/// cases below carve up the ways it happens rather than offering an empty
/// input set: a caller that saw `unwritten` must leave the graph alone, not
/// rebuild it as though the plugin inputs had gone away.
public enum PlannedBuild: Equatable, Sendable {
	/// Nothing to read yet.
	///
	/// The normal state before the first build of a clean checkout, and also
	/// what a torn read looks like: build systems rewrite these files in place
	/// rather than renaming a finished one over them, so a reader can catch one
	/// mid-write. Every real planned build has inputs, so finding none is the
	/// whole signal that a read came up short.
	case unwritten

	/// A manifest that exists but could not be understood, carrying a reason to
	/// report. Treated as `unwritten` for the graph, and worth telling the user
	/// about once: it means a format changed underneath swift-watch.
	case unreadable(reason: String)

	/// The file paths the planned build records as inputs. Never empty.
	case inputs(Set<URL>)

	/// The inputs read, or `nil` when there was nothing to learn.
	public var readInputs: Set<URL>? {
		guard case .inputs(let inputs) = self else {
			return nil
		}
		return inputs
	}

	/// The reason a manifest could not be understood, when that is what
	/// happened.
	public var unreadableReason: String? {
		guard case .unreadable(let reason) = self else {
			return nil
		}
		return reason
	}

	/// The reading for a set of paths that may be empty, which is how every
	/// reader reports what it collected: nothing collected is `unwritten`.
	static func inputs(collected paths: Set<URL>) -> PlannedBuild {
		paths.isEmpty ? .unwritten : .inputs(paths)
	}
}

/// A reader bound to the place its build system will write.
///
/// Resolved once by the CLI, from the same forwarded arguments it hands to
/// `swift`, so the watch loop can ask what the last build read without knowing
/// which build system produced it.
public struct BuildManifestSource: Sendable {
	public let reader: any BuildManifestReading
	public let location: URL

	public init(reader: any BuildManifestReading, location: URL) {
		self.reader = reader
		self.location = location
	}

	/// Resolves where `buildSystem` writes, or `nil` for a build system that
	/// records nothing swift-watch knows how to read.
	public init?(
		buildSystem: BuildSystem,
		scratchPath: URL,
		configuration: String
	) {
		guard let reader = buildSystem.reader else {
			return nil
		}
		self.init(
			reader: reader,
			location: reader.manifestLocation(
				scratchPath: scratchPath, configuration: configuration)
		)
	}

	public func read(fileManager: FileManager = .default) -> PlannedBuild {
		reader.read(at: location, fileManager: fileManager)
	}
}

/// The llbuild node kinds a manifest names, which both readers share because
/// both describe llbuild builds.
enum BuildInputNode {
	/// The file `path` names, or `nil` when it names something that is not a
	/// file on disk: virtual nodes are angle-bracketed (`<PackageStructure>`),
	/// and directory nodes carry a trailing separator. Directories are dropped
	/// because they name whole target trees, which the watch graph already
	/// covers through its source roots.
	static func fileURL(_ path: String) -> URL? {
		guard !path.isEmpty, !path.hasPrefix("<"), !path.hasSuffix("/") else {
			return nil
		}
		return URL(fileURLWithPath: path).standardizedFileURL
	}
}
