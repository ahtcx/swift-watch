import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Reads the llbuild manifest SwiftPM's native build system writes when it
/// plans a build: `<scratch>/<configuration>.yaml`.
///
/// The file is YAML, but the reader only names its target roots, default root,
/// command keys, and the JSON flow sequences following `inputs:` and `outputs:`.
/// That is enough to traverse the selected target's command closure without a
/// YAML dependency. Nothing is treated as an error at line level: an unfamiliar
/// line is skipped rather than costing every familiar command.
public struct NativeBuildManifest: BuildManifestReading {
	public init() {}

	public var buildSystemName: String { BuildSystem.native.name }

	/// A cross-compiled build nests the manifest one level deeper, under the
	/// triple it is building for. That is not resolved here — the triple comes
	/// from flags swift-watch forwards without parsing, `--triple` and
	/// `--swift-sdk` among them — so `read(at:fileManager:)` chooses the newest
	/// matching plan on disk.
	public func manifestLocation(scratchPath: URL, configuration: String) -> URL {
		scratchPath.appendingPathComponent("\(configuration).yaml")
	}

	public func read(
		at location: URL,
		selection: WatchSelection?,
		fileManager: FileManager
	) -> PlannedBuild {
		guard let candidate = candidate(for: location, fileManager: fileManager)
		else {
			return .unwritten
		}
		guard let contents = try? String(contentsOf: candidate.manifest, encoding: .utf8)
		else {
			// Present but unreadable: a permissions problem, or bytes that
			// are not UTF-8. Either is worth saying out loud, because the
			// path was found and the content was not.
			return .unreadable(
				reason: "\(candidate.manifest.path) could not be read as UTF-8 text"
			)
		}
		let parsed = parse(contents, selection: selection)
		return .inputs(
			collected: parsed.files,
			directories: parsed.directories,
			unbuiltDirectories: parsed.unbuilt)
	}

	public func modificationDate(at location: URL, fileManager: FileManager) -> Date? {
		candidate(for: location, fileManager: fileManager)?.activityDate
	}

	/// The manifest and llbuild state used by the most recent invocation.
	///
	/// A cross-compiled build puts the same manifest name under its triple.
	/// Normal and cross-compiled plans can coexist, and llbuild may reuse either
	/// without rewriting it. Each plan is therefore paired with the `build.db`
	/// beside it; the candidate whose manifest or database advanced most
	/// recently is the invocation that just ran.
	private func candidate(for location: URL, fileManager: FileManager) -> Candidate? {
		let name = location.lastPathComponent
		let children =
			(try? fileManager.contentsOfDirectory(
				at: location.deletingLastPathComponent(),
				includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles]
			)) ?? []
		var manifests =
			children
			.filter {
				(try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
					== true
			}
			.map { $0.appendingPathComponent(name) }
			.filter { fileManager.fileExists(atPath: $0.path) }
		if fileManager.fileExists(atPath: location.path) {
			manifests.append(location)
		}
		return manifests.map { manifest in
			let database =
				manifest.deletingLastPathComponent()
				.appendingPathComponent("build.db")
			let activityDate =
				[
					modificationDate(of: manifest),
					fileManager.fileExists(atPath: database.path)
						? modificationDate(of: database) : nil,
				].compactMap { $0 }.max() ?? .distantPast
			return Candidate(manifest: manifest, activityDate: activityDate)
		}.max {
			($0.activityDate, $0.manifest.path)
				< ($1.activityDate, $1.manifest.path)
		}
	}

	private struct Candidate {
		let manifest: URL
		let activityDate: Date
	}

	private func modificationDate(of url: URL) -> Date {
		(try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
			.contentModificationDate ?? .distantPast
	}

	/// The top-level sections this reader distinguishes.
	///
	/// `nodes` is named only so it can be skipped: its entries are keyed by path
	/// and indented exactly like command entries, so without the distinction
	/// every node would register as a command that reads nothing.
	private enum Section {
		case other
		case targets
		case nodes
		case commands
	}

	private func parse(
		_ contents: String,
		selection: WatchSelection?
	) -> (files: Set<URL>, directories: Set<URL>, unbuilt: Set<URL>) {
		var targets: [String: [String]] = [:]
		var defaultTarget: String?
		var commands: [String: Command] = [:]
		var currentCommand: String?
		var section = Section.other
		for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
			// A CRLF manifest leaves a carriage return on the end of each line.
			var line = rawLine
			if line.last == "\r" {
				line = line.dropLast()
			}
			// Every section is introduced by an unindented key, so the section
			// ends wherever the next one begins — including at sections this
			// reader has no name for.
			if let first = line.first, first != " ", first != "\t" {
				switch line {
				case "targets:": section = .targets
				case "nodes:": section = .nodes
				case "commands:": section = .commands
				default:
					if line.hasPrefix("default: ") {
						defaultTarget =
							try? JSONDecoder().decode(
								String.self,
								from: Data(
									line.dropFirst(
										"default: ".count
									)
									.utf8))
					}
					section = .other
				}
				currentCommand = nil
				continue
			}
			switch section {
			case .other, .nodes:
				continue
			case .targets:
				guard line.hasPrefix("  "),
					let entry = try? JSONDecoder().decode(
						[String: [String]].self,
						from: Data("{\(line.dropFirst(2))}".utf8))
				else {
					continue
				}
				targets.merge(entry, uniquingKeysWith: { _, latest in latest })
			case .commands:
				if line.hasPrefix("  "), !line.hasPrefix("    "),
					line.hasSuffix(":")
				{
					let encoded = line.dropFirst(2).dropLast()
					currentCommand =
						(try? JSONDecoder().decode(
							String.self, from: Data(encoded.utf8)))
					if let currentCommand {
						commands[currentCommand] = Command()
					}
					continue
				}
				guard let currentCommand else {
					continue
				}
				let attribute = line.drop(while: { $0 == " " || $0 == "\t" })
				let key: String
				if attribute.hasPrefix(Self.inputKey) {
					key = Self.inputKey
				} else if attribute.hasPrefix(Self.outputKey) {
					key = Self.outputKey
				} else {
					continue
				}
				guard
					let paths = try? JSONDecoder().decode(
						[String].self,
						from: Data(attribute.dropFirst(key.count).utf8))
				else {
					continue
				}
				if key == Self.inputKey {
					commands[currentCommand]?.inputs = paths
				} else {
					commands[currentCommand]?.outputs = paths
				}
			}
		}

		let selectedCommands: Set<String>
		if let selection {
			let targetNames: [String]
			switch selection.action {
			case .test:
				targetNames = ["test"]
			case .build, .run:
				targetNames = selection.names
			}
			var roots = targetNames.flatMap { requested in
				targets.filter { name, _ in
					name == requested || name.hasPrefix("\(requested)-")
				}.flatMap(\.value)
			}
			if roots.isEmpty {
				// A name that resolves to nothing leaves the watch at the plan's
				// default breadth — but only where the default is the right
				// breadth. It is not for `test`: the default target is the one a
				// bare `swift build` uses, which is precisely the one that
				// excludes the test targets. Falling back to it would leave
				// `swift-watch test` not watching tests, so the whole plan is
				// taken instead. Widening is always the safe direction to fail
				// in, and this is the case where the default narrows.
				switch selection.action {
				case .test:
					roots = []
				case .build, .run:
					roots = defaultTarget.flatMap { targets[$0] } ?? []
				}
			}
			guard !roots.isEmpty else {
				return collected(
					from: Set(commands.keys), commands: commands)
			}
			let producers = Dictionary(
				commands.flatMap { name, command in
					command.outputs.map { ($0, name) }
				},
				uniquingKeysWith: { first, _ in first })
			var reached = Set<String>()
			var queue = roots
			while let node = queue.popLast() {
				guard let command = producers[node],
					reached.insert(command).inserted
				else {
					continue
				}
				queue.append(contentsOf: commands[command]?.inputs ?? [])
			}
			selectedCommands = reached
		} else {
			selectedCommands = Set(commands.keys)
		}
		return collected(from: selectedCommands, commands: commands)
	}

	/// Splits the inputs of the selected commands into files and directories,
	/// and names the package directories nothing is built out of.
	private func collected(
		from selectedCommands: Set<String>,
		commands: [String: Command]
	) -> (files: Set<URL>, directories: Set<URL>, unbuilt: Set<URL>) {
		var inputs = Set<URL>()
		var directories = Set<URL>()
		for path in Set(selectedCommands.flatMap { commands[$0]?.inputs ?? [] }) {
			switch BuildInputNode.path(path) {
			case .file(let url):
				inputs.insert(url)
			case .directory(let url):
				directories.insert(url)
			case nil:
				continue
			}
		}

		// The package-structure command is outside every target's closure, and
		// its inputs are the package's own target directories plus its
		// manifests. Only the directories are taken: the manifests are tracked
		// by the graph itself, for every package it infers rather than only for
		// the ones this command happens to name.
		//
		// A directory no command in the whole manifest reads from is a target
		// this plan does not build at all, whatever was selected — the shape of
		// a build tool plugin, which SwiftPM compiles in a separate arena.
		let readPaths = Set(commands.values.flatMap(\.inputs))
		var unbuilt = Set<URL>()
		for path in commands[Self.packageStructureCommand]?.inputs ?? [] {
			guard case .directory(let url) = BuildInputNode.path(path) else {
				continue
			}
			directories.insert(url)
			// Strictly below the directory: the package-structure command reads
			// the directory node itself, and that says nothing about whether
			// anything is built out of what it holds.
			if !readPaths.contains(where: { $0.hasPrefix(path) && $0 != path }) {
				unbuilt.insert(url)
			}
		}
		return (inputs, directories, unbuilt)
	}

	private struct Command {
		var inputs: [String] = []
		var outputs: [String] = []
	}

	private static let inputKey = "inputs: "
	private static let outputKey = "outputs: "
	private static let packageStructureCommand = "PackageStructure"
}
