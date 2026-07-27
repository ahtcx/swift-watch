import struct Foundation.Date
import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Reads the llbuild manifest Swift Build writes when it plans a build:
/// `<scratch>/out/Intermediates.noindex/XCBuildData/<hash>.xcbuilddata/manifest.json`.
///
/// Swift Build plans through a PIF, but it drives the same llbuild underneath
/// and records the same thing the native build system does — every command with
/// the exact paths it reads — as JSON rather than YAML. A build tool plugin's
/// scanned inputs appear there in full, including on a build that failed to
/// compile, because planning precedes compilation.
///
/// Two differences from the native manifest shape the code below. The path
/// carries a hash rather than the configuration, and those hashed directories
/// *accumulate*: a build whose plan changed writes a new one and leaves the old
/// one in place, holding the input set of a build that is no longer current.
/// Only the newest is read, since older ones are the stale plans. And because
/// the file is JSON, a torn read fails to decode outright instead of yielding a
/// convincing subset, so partial input sets never reach the watch graph.
public struct SwiftBuildManifest: BuildManifestReading {
	public init() {}

	public var buildSystemName: String { BuildSystem.swiftBuild.name }

	/// The configuration is ignored: Swift Build folds it into the hash rather
	/// than the path, so every configuration's manifest lands in this one
	/// directory and the newest is the one that just ran.
	public func manifestLocation(scratchPath: URL, configuration: String) -> URL {
		scratchPath
			.appendingPathComponent("out", isDirectory: true)
			.appendingPathComponent("Intermediates.noindex", isDirectory: true)
			.appendingPathComponent("XCBuildData", isDirectory: true)
	}

	public func read(at location: URL, fileManager: FileManager) -> PlannedBuild {
		guard let manifest = newestManifest(in: location, fileManager: fileManager)
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
		return .inputs(
			collected: Set(planned.inputs.compactMap(BuildInputNode.fileURL)))
	}

	/// The most recently written manifest under `location`.
	///
	/// Ties are broken by path so the choice is deterministic, which matters
	/// only for the tests that write several at once — a real build leaves the
	/// one it just planned newest on its own.
	private func newestManifest(in location: URL, fileManager: FileManager) -> URL? {
		guard
			let children = try? fileManager.contentsOfDirectory(
				at: location,
				includingPropertiesForKeys: [.contentModificationDateKey],
				options: [.skipsHiddenFiles]
			)
		else {
			return nil
		}
		return
			children
			.filter { $0.pathExtension == Self.planDirectoryExtension }
			.map { $0.appendingPathComponent(Self.manifestName) }
			.filter { fileManager.fileExists(atPath: $0.path) }
			.max {
				(modificationDate(of: $0), $0.path)
					< (modificationDate(of: $1), $1.path)
			}
	}

	private func modificationDate(of url: URL) -> Date {
		(try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
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
