import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Builds a watch graph from the inputs of the invocation swift-watch actually
/// ran.
public struct PlannedBuildGraph {
	private let fileManager: FileManager

	public init(fileManager: FileManager = .default) {
		self.fileManager = fileManager
	}

	public func graph(
		packagePath: URL,
		inputs: Set<URL>,
		inputDirectories: Set<URL> = [],
		unbuiltDirectories: Set<URL> = [],
		excludedPaths: [URL] = [],
		rules: WatchRules = .default
	) -> WatchGraph {
		let root = packagePath.standardizedFileURL
		let excluded = Set(excludedPaths.map(\.standardizedFileURL))
		var packageRoots: Set<URL> = [root]
		var inputPackages: [URL: URL] = [:]

		// A plan names thousands of inputs and only a handful of directories
		// hold them, so the walk to each enclosing package is answered once per
		// directory rather than once per input.
		var packagesByDirectory: [URL: URL?] = [:]
		func packageRoot(containing directory: URL) -> URL? {
			if let known = packagesByDirectory[directory] {
				return known
			}
			let found = enclosingPackage(startingAt: directory)
			packagesByDirectory[directory] = found
			return found
		}

		for input in inputs {
			let input = input.standardizedFileURL
			guard !isExcluded(input, excludedRoots: excluded),
				let packageRoot = packageRoot(
					containing: input.deletingLastPathComponent())
			else {
				continue
			}
			packageRoots.insert(packageRoot)
			inputPackages[input] = packageRoot
		}

		// Targets this plan builds nothing from — a build tool plugin, compiled
		// into its own arena — are watched as source roots in their own right.
		// Nothing else can reach them: no command reads their sources, so no
		// input places them and no later plan would reveal them either.
		var unbuiltRoots = Set<URL>()
		for directory in unbuiltDirectories {
			let directory = directory.standardizedFileURL
			guard !isExcluded(directory, excludedRoots: excluded),
				let packageRoot = packageRoot(containing: directory)
			else {
				continue
			}
			packageRoots.insert(packageRoot)
			unbuiltRoots.insert(directory)
		}

		let manifestFiles = Set(
			packageRoots.map { $0.appendingPathComponent("Package.swift") })
		// SwiftPM resolves the graph from the root package. A local dependency's
		// lockfile does not participate in this invocation.
		let resolved = root.appendingPathComponent("Package.resolved")
		let resolvedFiles: Set<URL> =
			fileManager.fileExists(atPath: resolved.path) ? [resolved] : []

		var sourceRoots = unbuiltRoots
		for (input, packageRoot) in inputPackages
		where Self.defaultSourceExtensions.contains(input.pathExtension.lowercased()) {
			sourceRoots.insert(
				sourceRoot(
					for: input,
					in: packageRoot,
					inputDirectories: inputDirectories))
		}
		let trackedRoots = Set(
			inputDirectories.map(\.standardizedFileURL).filter { directory in
				sourceRoots.contains {
					directory != $0 && directory.isWithin($0)
				}
			})

		return WatchGraph(
			packageRoots: packageRoots,
			sourceRoots: sourceRoots,
			trackedFiles: [],
			trackedRoots: trackedRoots,
			manifestFiles: manifestFiles,
			resolvedFiles: resolvedFiles,
			sourceExtensions: Self.defaultSourceExtensions,
			buildInputs: inputs,
			excludedRoots: excluded,
			rules: rules
		)
	}

	/// A useful degradation when a command fails before writing a build plan.
	public func fallbackGraph(
		packagePath: URL,
		excludedPaths: [URL] = [],
		rules: WatchRules = .default
	) -> WatchGraph {
		let root = packagePath.standardizedFileURL
		let resolved = root.appendingPathComponent("Package.resolved")
		return WatchGraph(
			packageRoots: [root],
			sourceRoots: [root],
			trackedFiles: [],
			manifestFiles: [root.appendingPathComponent("Package.swift")],
			resolvedFiles: fileManager.fileExists(atPath: resolved.path)
				? [resolved] : [],
			sourceExtensions: Self.defaultSourceExtensions,
			excludedRoots: Set(excludedPaths),
			rules: rules
		)
	}

	/// Finds the nearest package at or above a directory. This discovers local
	/// path dependencies without evaluating or parsing Package.swift.
	private func enclosingPackage(startingAt directory: URL) -> URL? {
		var candidate = directory.standardizedFileURL
		while candidate.path != "/" {
			if fileManager.fileExists(
				atPath: candidate.appendingPathComponent("Package.swift").path)
			{
				return candidate
			}
			let parent = candidate.deletingLastPathComponent().standardizedFileURL
			guard parent != candidate else {
				break
			}
			candidate = parent
		}
		return nil
	}

	/// SwiftPM's conventional target layouts are unambiguous. A custom target
	/// path is not represented in either build manifest, so its nearest input
	/// directory is the conservative fallback.
	private func sourceRoot(
		for input: URL,
		in packageRoot: URL,
		inputDirectories: Set<URL>
	) -> URL {
		if let planned =
			inputDirectories
			.map(\.standardizedFileURL)
			.filter({ input.isWithin($0) && $0.isWithin(packageRoot) })
			.max(by: { $0.pathComponents.count < $1.pathComponents.count })
		{
			return planned
		}
		let relative = Array(
			input.pathComponents.dropFirst(packageRoot.pathComponents.count))
		if relative.count >= 3,
			relative[0] == "Sources" || relative[0] == "Tests"
				|| relative[0] == "Plugins"
		{
			return
				packageRoot
				.appendingPathComponent(relative[0], isDirectory: true)
				.appendingPathComponent(relative[1], isDirectory: true)
				.standardizedFileURL
		}
		return input.deletingLastPathComponent().standardizedFileURL
	}

	private func isExcluded(_ input: URL, excludedRoots: Set<URL>) -> Bool {
		let components = input.pathComponents
		if components.contains(".build") || components.contains(".git")
			|| components.contains(".swiftpm")
		{
			return true
		}
		return excludedRoots.contains { input.isWithin($0) }
	}

	/// Mirrors SwiftPM's compile, header, and module-map rules.
	public static let defaultSourceExtensions: Set<String> = [
		"swift", "c", "m", "mm", "cc", "cpp", "cxx", "s",
		"h", "hh", "hpp", "h++", "hp", "hxx", "ipp", "def",
		"modulemap", "metal",
	]
}
