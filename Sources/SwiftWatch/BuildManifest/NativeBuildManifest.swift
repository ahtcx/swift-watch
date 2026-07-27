import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Reads the llbuild manifest SwiftPM's native build system writes when it
/// plans a build: `<scratch>/<configuration>.yaml`.
///
/// The file is YAML, but only one line shape is named here — `inputs: ` and the
/// JSON flow sequence that follows it — so a manifest that grows keys, reorders
/// commands, or changes anything else keeps reading. Nothing is treated as an
/// error at line level: a line that does not decode is skipped, because one
/// unfamiliar command should not cost the inputs of every familiar one.
public struct NativeBuildManifest: BuildManifestReading {
	public init() {}

	public var buildSystemName: String { BuildSystem.native.name }

	/// A cross-compiled build nests the manifest one level deeper, under the
	/// triple it is building for. That is not resolved here — the triple comes
	/// from flags swift-watch forwards without parsing, `--triple` and
	/// `--swift-sdk` among them — so `read(at:fileManager:)` finds it on disk
	/// instead.
	public func manifestLocation(scratchPath: URL, configuration: String) -> URL {
		scratchPath.appendingPathComponent("\(configuration).yaml")
	}

	public func read(at location: URL, fileManager: FileManager) -> PlannedBuild {
		let candidates = candidatePaths(for: location, fileManager: fileManager)
		guard !candidates.isEmpty else {
			return .unwritten
		}
		var inputs = Set<URL>()
		for candidate in candidates {
			guard let contents = try? String(contentsOf: candidate, encoding: .utf8)
			else {
				// Present but unreadable: a permissions problem, or bytes that
				// are not UTF-8. Either is worth saying out loud, because the
				// path was found and the content was not.
				return .unreadable(
					reason: "\(candidate.path) could not be read as UTF-8 text")
			}
			inputs.formUnion(parse(contents))
		}
		return .inputs(collected: inputs)
	}

	/// The manifests to read for `location`.
	///
	/// Normally just `location` itself. When it does not exist, a build that was
	/// cross-compiled has put the manifest under the triple it built for, so the
	/// scratch directory's immediate children are searched for the same file
	/// name. Several are unioned rather than one being chosen: each names a
	/// build of the package that was actually planned, and watching the union
	/// costs nothing more than watching a little wider.
	private func candidatePaths(for location: URL, fileManager: FileManager) -> [URL] {
		if fileManager.fileExists(atPath: location.path) {
			return [location]
		}
		let name = location.lastPathComponent
		guard
			let children = try? fileManager.contentsOfDirectory(
				at: location.deletingLastPathComponent(),
				includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles]
			)
		else {
			return []
		}
		return
			children
			.filter {
				(try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
					== true
			}
			.map { $0.appendingPathComponent(name) }
			.filter { fileManager.fileExists(atPath: $0.path) }
			.sorted { $0.path < $1.path }
	}

	private func parse(_ contents: String) -> Set<URL> {
		var inputs = Set<URL>()
		for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
			// A CRLF manifest leaves a carriage return on the end of each line.
			var line = rawLine.drop(while: { $0 == " " || $0 == "\t" })
			if line.last == "\r" {
				line = line.dropLast()
			}
			guard line.hasPrefix(Self.key) else {
				continue
			}
			// SwiftPM emits each array as a single-line JSON flow sequence, so
			// the value can be decoded without a YAML parser.
			let array = line.dropFirst(Self.key.count)
			guard
				let paths = try? JSONDecoder().decode(
					[String].self, from: Data(array.utf8))
			else {
				continue
			}
			for path in paths {
				guard let url = BuildInputNode.fileURL(path) else {
					continue
				}
				inputs.insert(url)
			}
		}
		return inputs
	}

	private static let key = "inputs: "
}
