import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct PackageDiscovery {
	private let runner: SwiftToolRunning
	private let fileManager: FileManager
	/// Mirrors SwiftPM's own compile, header, and module map rules, which are
	/// the file kinds it consumes without being told to. Everything else it
	/// builds has to be declared, and declared inputs are tracked by path.
	///
	/// Matched case-insensitively, so SwiftPM's `S` and `H` need no entry here.
	private static let defaultSourceExtensions: Set<String> = [
		"swift", "c", "m", "mm", "cc", "cpp", "cxx", "s",
		"h", "hh", "hpp", "h++", "hp", "hxx", "ipp", "def",
		"modulemap", "metal",
	]

	public init(runner: SwiftToolRunning, fileManager: FileManager = .default) {
		self.runner = runner
		self.fileManager = fileManager
	}

	/// - Parameter buildManifest: How to read the build being watched, when the
	///   caller knows where it lands. Absent or unwritten, the graph is exactly
	///   what `swift package describe` reports; present, it also covers the
	///   inputs build tool plugins resolve for themselves.
	public func discover(
		from root: URL,
		swiftBinDirectory: URL?,
		selection: WatchSelection = WatchSelection(),
		excludedPaths: [URL] = [],
		buildManifest: BuildManifestSource? = nil,
		rules: WatchRules = .default
	) async throws(SwiftWatchError)
		-> WatchGraph
	{
		graph(
			for: try await describePackages(
				from: root, swiftBinDirectory: swiftBinDirectory),
			selection: selection,
			excludedPaths: excludedPaths,
			buildInputs: buildManifest?.read(fileManager: fileManager).readInputs ?? [],
			rules: rules
		)
	}

	/// Asks `swift package describe` about the package and its local
	/// dependencies, transitively.
	///
	/// Kept separate from `graph(for:…)` because this is the expensive half —
	/// a subprocess per package, which takes SwiftPM's lock on the scratch
	/// directory — while the graph it feeds can be rebuilt for free. Only a
	/// manifest edit invalidates what this returns.
	public func describePackages(from root: URL, swiftBinDirectory: URL?)
		async throws(SwiftWatchError) -> DiscoveredPackages
	{
		var visited = Set<URL>()
		var packages: [URL: DescribedPackage] = [:]
		var rootPackageRoot: URL?
		var manifestFiles = Set<URL>()
		var resolvedFiles = Set<URL>()
		var queue = [root.standardizedFileURL]

		while let next = queue.popLast() {
			guard visited.insert(next).inserted else {
				continue
			}
			let package = try await runner.describe(
				packagePath: next, swiftBinDirectory: swiftBinDirectory)
			let packageRoot = URL(fileURLWithPath: package.path, isDirectory: true)
				.standardizedFileURL
			if rootPackageRoot == nil {
				rootPackageRoot = packageRoot
			}
			packages[packageRoot] = package

			// Manifests stay watched for every discovered package, even ones
			// the closure prunes entirely: a manifest edit can change the
			// product-to-target mapping and therefore the closure itself.
			manifestFiles.insert(packageRoot.appendingPathComponent("Package.swift"))

			let resolved = packageRoot.appendingPathComponent("Package.resolved")
			if fileManager.fileExists(atPath: resolved.path) {
				resolvedFiles.insert(resolved)
			}

			for dependency in package.dependencies {
				switch dependency.location {
				case .fileSystem(let rawPath), .localSourceControl(let rawPath):
					queue.append(
						resolvedPath(
							rawPath, relativeTo: packageRoot,
							isDirectory: true))
				case .unsupported:
					continue
				}
			}
		}

		return DiscoveredPackages(
			packages: packages,
			rootPackageRoot: rootPackageRoot,
			manifestFiles: manifestFiles,
			resolvedFiles: resolvedFiles
		)
	}

	/// Builds the watch graph from an existing description.
	///
	/// Everything here is derived from what `describePackages` already reported
	/// and from `buildInputs`, so a graph can be rebuilt when only the build
	/// manifest changed — which is most refreshes — without paying for another
	/// round of subprocesses.
	///
	/// - Parameter buildInputs: What the caller read out of the build manifest.
	///   Taken rather than read here so a caller that has already compared a
	///   reading against a graph builds the next graph from that same reading,
	///   which is what keeps two reads of a manifest being written concurrently
	///   from disagreeing.
	public func graph(
		for described: DiscoveredPackages,
		selection: WatchSelection = WatchSelection(),
		excludedPaths: [URL] = [],
		buildInputs: Set<URL> = [],
		rules: WatchRules = .default
	) -> WatchGraph {
		let packages = described.packages
		var trackedFiles = described.manifestFiles.union(described.resolvedFiles)
		var sourceRoots = Set<URL>()
		var trackedRoots = Set<URL>()
		if let rootPackageRoot = described.rootPackageRoot {
			let reached = TargetClosure.reachedTargets(
				from: rootPackageRoot, in: packages, selection: selection)
			for (packageRoot, package) in packages {
				guard let reachedNames = reached[packageRoot] else {
					continue
				}
				for target in package.targets
				where reachedNames.contains(target.name) {
					let targetRoot = packageRoot.appendingPathComponent(
						target.path, isDirectory: true
					).standardizedFileURL
					sourceRoots.insert(targetRoot)
					for source in target.sources {
						trackedFiles.insert(
							targetRoot.appendingPathComponent(source)
								.standardizedFileURL)
					}
					for resource in target.resources {
						let url = resolvedPath(
							resource.path, relativeTo: targetRoot,
							isDirectory: false)
						// A directory resource is reported as the directory
						// alone, so its contents can only be reached by prefix.
						// An entry that no longer exists is treated as a file:
						// tracking the exact path still catches its recreation.
						let values = try? url.resourceValues(forKeys: [
							.isDirectoryKey
						])
						if values?.isDirectory == true {
							trackedRoots.insert(url)
						} else {
							trackedFiles.insert(url)
						}
					}
				}
			}
		}

		return WatchGraph(
			packageRoots: Set(packages.keys),
			sourceRoots: sourceRoots,
			trackedFiles: trackedFiles,
			trackedRoots: trackedRoots,
			manifestFiles: described.manifestFiles,
			resolvedFiles: described.resolvedFiles,
			sourceExtensions: Self.defaultSourceExtensions,
			buildInputs: buildInputs,
			excludedRoots: Set(excludedPaths),
			rules: rules
		)
	}

	/// Resolves a path `describe` reported, which may be absolute — resource
	/// paths always are — or relative to the directory it was reported under.
	private func resolvedPath(
		_ rawPath: String, relativeTo base: URL, isDirectory: Bool
	) -> URL {
		guard isRelativePath(rawPath) else {
			return URL(fileURLWithPath: rawPath, isDirectory: isDirectory)
				.standardizedFileURL
		}
		return base.appendingPathComponent(rawPath, isDirectory: isDirectory)
			.standardizedFileURL
	}
}
