import struct Foundation.Date
import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Reads the inputs of a planned build out of whatever the build system leaves
/// behind when it plans one.
///
/// This is the source of truth for the watch graph. The planned build has
/// already applied the exact arguments the user supplied and records every
/// command with the paths it reads, including inputs a plugin discovers at
/// planning time.
///
/// Every conformance reads a build system's own intermediate output rather than
/// a public interface, so all of them share one discipline: name as little of
/// the format as the inputs can be found with, skip anything unrecognised
/// instead of failing, and report a file that exists but cannot be understood
/// so the user hears about it once. A read that comes up short falls back to a
/// broad root-package source watch rather than breaking the loop.
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

	/// What `location` says the planned build reads, narrowed to `selection`
	/// when the build system stores a reusable plan broader than one invocation.
	func read(
		at location: URL,
		selection: WatchSelection?,
		fileManager: FileManager
	) -> PlannedBuild

	/// The newest plan or build-system state backing a reading, used to
	/// distinguish the build just started from an earlier invocation. Build
	/// systems may reuse a plan without rewriting it, while their database still
	/// advances for every build.
	func modificationDate(at location: URL, fileManager: FileManager) -> Date?
}

extension BuildManifestReading {
	/// Reads through the process-wide file manager, for callers with no reason
	/// to substitute one.
	public func read(at location: URL) -> PlannedBuild {
		read(at: location, selection: nil, fileManager: .default)
	}

	public func read(at location: URL, fileManager: FileManager) -> PlannedBuild {
		read(at: location, selection: nil, fileManager: fileManager)
	}

	public func modificationDate(at location: URL) -> Date? {
		modificationDate(at: location, fileManager: .default)
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

	/// The paths the planned build records as inputs. At least one of `files`
	/// and `directories` is nonempty.
	case inputs(
		files: Set<URL>,
		directories: Set<URL>,
		unbuiltDirectories: Set<URL>)

	/// The inputs read, or `nil` when there was nothing to learn.
	public var readInputs: Set<URL>? {
		guard case .inputs(let inputs, _, _) = self else {
			return nil
		}
		return inputs
	}

	/// Directory-structure nodes recorded by the plan.
	public var readInputDirectories: Set<URL>? {
		guard case .inputs(_, let directories, _) = self else {
			return nil
		}
		return directories
	}

	/// Target directories the plan names but reads nothing from, at any
	/// selection.
	///
	/// The shape of a target another plan builds. A build tool plugin is the
	/// case that matters: SwiftPM compiles plugins into the separate
	/// `plugin-tools` arena, so a plugin's own sources appear in no command of
	/// the manifest that consumes its output, while its directory is still
	/// listed among the package's structure. Watching them is what makes
	/// editing a plugin rebuild the targets it generates for.
	///
	/// A target merely left out of *this* selection is not among these: its
	/// sources are still recorded by the commands of the closure it does belong
	/// to, which is what keeps `swift-watch build` from watching test targets.
	public var readUnbuiltDirectories: Set<URL>? {
		guard case .inputs(_, _, let directories) = self else {
			return nil
		}
		return directories
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
	static func inputs(
		collected paths: Set<URL>,
		directories: Set<URL> = [],
		unbuiltDirectories: Set<URL> = []
	) -> PlannedBuild {
		paths.isEmpty && directories.isEmpty
			? .unwritten
			: .inputs(
				files: paths,
				directories: directories,
				unbuiltDirectories: unbuiltDirectories)
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

	public func read(
		selection: WatchSelection? = nil,
		fileManager: FileManager = .default
	) -> PlannedBuild {
		reader.read(
			at: location, selection: selection,
			fileManager: fileManager)
	}

	public func modificationDate(fileManager: FileManager = .default) -> Date? {
		reader.modificationDate(at: location, fileManager: fileManager)
	}
}

/// The llbuild node kinds a manifest names, which both readers share because
/// both describe llbuild builds.
enum BuildInputNode {
	enum Path {
		case file(URL)
		case directory(URL)
	}

	static func path(_ path: String) -> Path? {
		guard !path.isEmpty, !path.hasPrefix("<") else {
			return nil
		}
		let url = URL(fileURLWithPath: path).standardizedFileURL
		return path.hasSuffix("/") ? .directory(url) : .file(url)
	}
}
