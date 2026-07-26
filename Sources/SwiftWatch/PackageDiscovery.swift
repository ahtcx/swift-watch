import class Foundation.FileManager

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct PackageDiscovery {
	private let runner: SwiftToolRunning
	private let fileManager: FileManager
	private static let defaultSourceExtensions: Set<String> = [
		"swift", "c", "m", "mm", "cc", "cpp", "cxx", "s", "S",
		"h", "hh", "hpp", "hxx", "modulemap", "metal",
	]

	public init(runner: SwiftToolRunning, fileManager: FileManager = .default) {
		self.runner = runner
		self.fileManager = fileManager
	}

	public func discover(
		from root: URL,
		swiftBinDirectory: URL?,
		selection: WatchSelection = WatchSelection(),
		excludedPaths: [URL] = []
	) async throws(SwiftWatchError)
		-> WatchGraph
	{
		var visited = Set<URL>()
		var packages: [URL: DescribedPackage] = [:]
		var rootPackageRoot: URL?
		var trackedFiles = Set<URL>()
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
			let manifest = packageRoot.appendingPathComponent("Package.swift")
			manifestFiles.insert(manifest)
			trackedFiles.insert(manifest)

			let resolved = packageRoot.appendingPathComponent("Package.resolved")
			if fileManager.fileExists(atPath: resolved.path) {
				resolvedFiles.insert(resolved)
				trackedFiles.insert(resolved)
			}

			for dependency in package.dependencies {
				switch dependency.location {
				case .fileSystem(let rawPath), .localSourceControl(let rawPath):
					queue.append(
						resolvedDependencyPath(
							rawPath, packageRoot: packageRoot))
				case .unsupported:
					continue
				}
			}
		}

		var sourceRoots = Set<URL>()
		if let rootPackageRoot {
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
				}
			}
		}

		return WatchGraph(
			packageRoots: Set(packages.keys),
			sourceRoots: sourceRoots,
			trackedFiles: trackedFiles,
			manifestFiles: manifestFiles,
			resolvedFiles: resolvedFiles,
			sourceExtensions: Self.defaultSourceExtensions,
			excludedRoots: Set(excludedPaths)
		)
	}

	private func resolvedDependencyPath(_ rawPath: String, packageRoot: URL) -> URL {
		if rawPath.hasPrefix("/") {
			return URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
		}
		return packageRoot.appendingPathComponent(rawPath, isDirectory: true)
			.standardizedFileURL
	}
}
