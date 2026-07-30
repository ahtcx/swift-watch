import struct Foundation.Date
import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Reads the llbuild manifest Swift Build writes when it plans a build:
/// `<scratch>/<arena>/Intermediates.noindex/XCBuildData/<hash>.xcbuilddata/manifest.json`.
///
/// Swift Build plans through a PIF, but it drives the same llbuild underneath
/// and records the same thing the native build system does — every command with
/// the exact paths it reads — as JSON rather than YAML. A build tool plugin's
/// scanned inputs appear there in full, including on a build that failed to
/// compile, because planning precedes compilation.
///
/// Three differences from the native manifest shape the code below. The arena
/// directory has been spelled both `out` and the target triple across 6.x
/// releases, so it is found on disk rather than computed. The plan directory
/// carries a hash rather than the configuration, and those hashed directories
/// accumulate — Swift Build can reuse an older cached plan without touching it,
/// so the configured targets in each plan's build request disambiguate the
/// selection. And because the file is JSON, a torn read fails to decode outright
/// instead of yielding a convincing subset, so partial input sets never reach
/// the graph.
public struct SwiftBuildManifest: BuildManifestReading {
	public init() {}

	public var buildSystemName: String { BuildSystem.swiftBuild.name }

	/// The whole build tree, because neither component below it can be computed.
	///
	/// The configuration is folded into the plan's hash rather than its path, so
	/// every configuration lands in the same place. The arena directory above it
	/// is not fixed either: Swift 6.0 and 6.3 write `out`, while 6.2 wrote the
	/// target triple. Both are found by looking rather than by naming, the same
	/// way the native reader finds a cross-compiled plan.
	public func manifestLocation(scratchPath: URL, configuration: String) -> URL {
		scratchPath
	}

	/// Every `Intermediates.noindex/XCBuildData` directly below the build tree.
	///
	/// More than one can exist — a package built by two toolchains keeps both —
	/// and they are pooled rather than chosen between, leaving the plan
	/// selection to judge the plans themselves.
	private func buildDataDirectories(
		in scratchPath: URL, fileManager: FileManager
	) -> [URL] {
		let children =
			(try? fileManager.contentsOfDirectory(
				at: scratchPath,
				includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles]
			)) ?? []
		return
			children
			.map {
				$0
					.appendingPathComponent(
						"Intermediates.noindex", isDirectory: true
					)
					.appendingPathComponent("XCBuildData", isDirectory: true)
			}
			.filter { fileManager.fileExists(atPath: $0.path) }
	}

	public func read(
		at location: URL,
		selection: WatchSelection?,
		fileManager: FileManager
	) -> PlannedBuild {
		guard
			let manifest = selectedManifest(
				in: location,
				selection: selection,
				fileManager: fileManager)
		else {
			return .unwritten
		}
		guard let contents = try? Data(contentsOf: manifest) else {
			return .unreadable(reason: "\(manifest.path) could not be read")
		}
		guard !contents.isEmpty else {
			return .unwritten
		}
		guard
			let planned = try? JSONDecoder().decode(
				PlannedCommands.self, from: contents)
		else {
			// A torn read looks like this too, so it is not certain the format
			// changed — but a manifest that never decodes is exactly how that
			// would present, and staying quiet about it would leave plugin
			// inputs silently unwatched.
			return .unreadable(
				reason:
					"\(manifest.path) is not a build manifest swift-watch understands"
			)
		}
		var files = Set<URL>()
		var directories = Set<URL>()
		for input in planned.inputs {
			switch BuildInputNode.path(input) {
			case .file(let url):
				files.insert(url)
			case .directory(let url):
				directories.insert(url)
			case nil:
				continue
			}
		}
		return .inputs(collected: files, directories: directories)
	}

	public func modificationDate(at location: URL, fileManager: FileManager) -> Date? {
		var dates: [Date] = []
		if let manifest = selectedManifest(
			in: location, selection: nil, fileManager: fileManager)
		{
			dates.append(modificationDate(of: manifest))
		}
		for directory in buildDataDirectories(in: location, fileManager: fileManager) {
			let database = directory.appendingPathComponent("build.db")
			if fileManager.fileExists(atPath: database.path) {
				dates.append(modificationDate(of: database))
			}
		}
		return dates.max()
	}

	/// The manifest used by the active llbuild iteration.
	///
	/// Swift Build reuses a cached hashed directory without touching it. The
	/// newest directory can therefore describe a different target built just
	/// before the current invocation. The `build-request.json` beside each
	/// manifest names its configured targets, so the plan matching the forwarded
	/// target or product is preferred. Recency breaks otherwise equal matches.
	private func selectedManifest(
		in location: URL,
		selection: WatchSelection?,
		fileManager: FileManager
	) -> URL? {
		let manifests = buildDataDirectories(in: location, fileManager: fileManager)
			.flatMap { directory in
				(try? fileManager.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: [.contentModificationDateKey],
					options: [.skipsHiddenFiles]
				)) ?? []
			}
			.filter { $0.pathExtension == Self.planDirectoryExtension }
			.map { $0.appendingPathComponent(Self.manifestName) }
			.filter { fileManager.fileExists(atPath: $0.path) }
		let newest = manifests.max {
			(modificationDate(of: $0), $0.path)
				< (modificationDate(of: $1), $1.path)
		}
		guard let selection else {
			return newest
		}
		return manifests.min {
			let lhs = requestDistance(at: $0, from: selection)
			let rhs = requestDistance(at: $1, from: selection)
			if lhs.missing != rhs.missing {
				return lhs.missing < rhs.missing
			}
			if lhs.extra != rhs.extra {
				return lhs.extra < rhs.extra
			}
			return
				(modificationDate(of: $0), $0.path)
				> (modificationDate(of: $1), $1.path)
		} ?? newest
	}

	/// How far a cached plan is from the one the forwarded arguments asked for,
	/// as the targets it fails to cover and the ones it covers needlessly.
	///
	/// Lower is better on both counts, `missing` first: a plan that covers the
	/// selection too broadly still records everything the selection reads, while
	/// one that misses it does not.
	private func requestDistance(
		at manifest: URL,
		from selection: WatchSelection
	) -> (missing: Int, extra: Int) {
		let request = manifest.deletingLastPathComponent()
			.appendingPathComponent("build-request.json")
		guard let contents = try? Data(contentsOf: request),
			let planned = try? JSONDecoder().decode(
				BuildRequest.self, from: contents)
		else {
			return (.max, .max)
		}
		let requested = Set(selection.names)
		let wantsTests = selection.action == .test
		switch planned.coverage {
		case .wholePackage(let includingTests):
			guard requested.isEmpty else {
				// A whole-package plan does record what the named target
				// reads, along with the rest of the package. Usable, but
				// beaten by a plan configured for that target alone.
				return (0, includingTests ? 2 : 1)
			}
			// With no name forwarded, the invocation asked for exactly this
			// breadth — so the plan that drew the same test line is the one it
			// ran, and the other is a near miss rather than a wrong answer.
			return (
				wantsTests && !includingTests ? 1 : 0,
				includingTests == wantsTests ? 0 : 1
			)
		case .targets(let configured):
			guard !requested.isEmpty else {
				// A plan for one named target cannot stand in for the whole
				// package the bare invocation asked for.
				return (1, 0)
			}
			return (
				requested.filter { name in
					!configured.contains { $0.denotes(name) }
				}.count,
				configured.filter { configured in
					!requested.contains { configured.denotes($0) }
				}.count
			)
		}
	}

	private func modificationDate(of url: URL) -> Date {
		// Asked through a URL made here and thrown away, because a URL caches
		// every resource value it has been asked for. The location this reader is
		// built around outlives the session, so reading it directly would report
		// the first plan it ever saw for every cycle after — and the loop decides
		// a plan is this invocation's by seeing that date advance.
		(try? URL(fileURLWithPath: url.path)
			.resourceValues(forKeys: [.contentModificationDateKey]))?
			.contentModificationDate ?? .distantPast
	}

	private static let planDirectoryExtension = "xcbuilddata"
	private static let manifestName = "manifest.json"
}

/// The whole of the manifest format this names: a `commands` object whose
/// values may carry an `inputs` array of paths.
///
/// Everything else the manifest holds — `client`, `targets`, `nodes`, each
/// command's tool, outputs, arguments and environment — goes undeclared, so it
/// can change freely without costing swift-watch the inputs. A command that
/// does not decode is skipped for the same reason: one unfamiliar entry should
/// not discard the inputs of every familiar one.
private struct PlannedCommands: Decodable {
	let inputs: Set<String>

	init(from decoder: any Decoder) throws {
		let root = try decoder.container(keyedBy: RootKey.self)
		let commands = try root.nestedContainer(
			keyedBy: CommandKey.self, forKey: .commands)
		var collected = Set<String>()
		for key in commands.allKeys {
			guard let command = try? commands.decode(Command.self, forKey: key)
			else {
				continue
			}
			collected.formUnion(command.inputs ?? [])
		}
		self.inputs = collected
	}

	private enum RootKey: String, CodingKey {
		case commands
	}

	/// Command names are arbitrary strings, so the container is keyed by
	/// whatever the manifest happens to hold.
	private struct CommandKey: CodingKey {
		let stringValue: String
		var intValue: Int? { nil }

		init(stringValue: String) {
			self.stringValue = stringValue
		}

		init?(intValue: Int) {
			nil
		}
	}

	private struct Command: Decodable {
		let inputs: [String]?
	}
}

/// The configured targets of a cached plan, which is all this reader names of
/// `build-request.json`.
///
/// Swift Build identifies a target by an opaque guid, and SwiftPM builds those
/// guids in two shapes. A bare `swift build` or `swift test` configures one
/// aggregate — `ALL-EXCLUDING-TESTS` or `ALL-INCLUDING-TESTS` — while a
/// forwarded `--target`/`--product` configures the target itself, spelled
/// `PACKAGE-TARGET:<name>-<hash>` and sometimes suffixed `-testable`. Neither
/// the hash nor the suffix is predictable, so a configured target is matched by
/// the name it starts with rather than compared whole.
private struct BuildRequest: Decodable {
	let configuredTargets: [ConfiguredTarget]

	enum Coverage {
		/// Every target of the package, tests included or not.
		case wholePackage(includingTests: Bool)
		/// Only the targets named.
		case targets([ConfiguredTarget])
	}

	var coverage: Coverage {
		for target in configuredTargets {
			switch target.guid {
			case Self.allExcludingTests:
				return .wholePackage(includingTests: false)
			case Self.allIncludingTests:
				return .wholePackage(includingTests: true)
			default:
				continue
			}
		}
		return .targets(configuredTargets)
	}

	struct ConfiguredTarget: Decodable {
		let guid: String

		/// The guid with any `PACKAGE-TARGET:`-style qualifier removed, which is
		/// where the target name begins.
		var name: String {
			guid.split(separator: ":").last.map(String.init) ?? guid
		}

		/// Whether this configured target is the one `name` asked for. The
		/// trailing hash and `-testable` suffix are what the prefix allows for.
		func denotes(_ name: String) -> Bool {
			self.name == name || self.name.hasPrefix("\(name)-")
		}
	}

	private static let allExcludingTests = "ALL-EXCLUDING-TESTS"
	private static let allIncludingTests = "ALL-INCLUDING-TESTS"
}
