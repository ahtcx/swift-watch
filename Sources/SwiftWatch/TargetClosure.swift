#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// Computes which targets are reachable from the root package through target
/// and product dependency edges, so unrelated targets in local dependency
/// packages do not need to be watched.
enum TargetClosure {
	/// Returns the reachable target names per package root.
	///
	/// By default every target of the root package is a seed, regardless of
	/// which product or target `swift build`/`swift run` was asked for:
	/// forwarded arguments are opaque to swift-watch, so narrowing the seeds
	/// could silently miss edits. An explicit selection narrows the seeds to
	/// the named targets or products only when every name resolves; anything
	/// unresolved falls back to the broad default. Product names that resolve
	/// to more than one local package broaden to all matches for the same
	/// reason.
	static func reachedTargets(
		from rootPackageRoot: URL,
		in packages: [URL: DescribedPackage],
		selection: WatchSelection = WatchSelection()
	) -> [URL: Set<String>] {
		guard let rootPackage = packages[rootPackageRoot] else {
			return packages.mapValues { Set($0.targets.map(\.name)) }
		}

		var productIndex: [String: [(packageRoot: URL, targets: [String])]] = [:]
		var targetIndex: [URL: [String: DescribedPackage.Target]] = [:]
		for (packageRoot, package) in packages {
			for product in package.products {
				productIndex[product.name, default: []].append(
					(packageRoot, product.targets))
			}
			targetIndex[packageRoot] = Dictionary(
				package.targets.map { ($0.name, $0) },
				uniquingKeysWith: { first, _ in first })
		}

		// A name may denote a target in any package or a product; both
		// interpretations are seeded, so a coincidental match only widens.
		func seedNodes(named name: String) -> [(packageRoot: URL, targetName: String)] {
			var nodes: [(packageRoot: URL, targetName: String)] = []
			for packageRoot in packages.keys
			where targetIndex[packageRoot]?[name] != nil {
				nodes.append((packageRoot, name))
			}
			for entry in productIndex[name] ?? [] {
				for targetName in entry.targets {
					nodes.append((entry.packageRoot, targetName))
				}
			}
			return nodes
		}

		var queue: [(packageRoot: URL, targetName: String)] = []
		var narrowed = !selection.explicitNames.isEmpty
		for name in selection.explicitNames {
			let nodes = seedNodes(named: name)
			if nodes.isEmpty {
				narrowed = false
			}
			queue.append(contentsOf: nodes)
		}
		for name in selection.candidateNames {
			queue.append(contentsOf: seedNodes(named: name))
		}
		if !narrowed {
			queue.append(
				contentsOf: rootPackage.targets.map { (rootPackageRoot, $0.name) })
		}

		var reached: [URL: Set<String>] = [:]

		func appendProductTargets(named name: String) {
			for entry in productIndex[name] ?? [] {
				for targetName in entry.targets {
					queue.append((entry.packageRoot, targetName))
				}
			}
		}

		while let node = queue.popLast() {
			guard
				reached[node.packageRoot, default: []].insert(node.targetName)
					.inserted
			else {
				continue
			}
			guard let target = targetIndex[node.packageRoot]?[node.targetName] else {
				continue
			}
			for name in target.targetDependencies {
				if targetIndex[node.packageRoot]?[name] != nil {
					queue.append((node.packageRoot, name))
				} else {
					// A by-name dependency that `describe` did not
					// resolve to a sibling target names a product.
					appendProductTargets(named: name)
				}
			}
			for name in target.productDependencies {
				appendProductTargets(named: name)
			}
		}
		return reached
	}
}
