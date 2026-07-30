#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

/// The directories a watcher has to observe, split by how deep it has to go.
///
/// A watch graph judges changes far more narrowly than the package tree it sits
/// in, and the two used to be conflated: every backend watched whole packages
/// and threw away most of what came back. Separating them is what lets the
/// planned graph cost what it claims — a `--target` build watches that target's
/// sources rather than the repository around them.
///
/// The split exists because the two kinds of root are asked different questions.
/// A recursive root answers "does anything under here count", which is how the
/// containment rules work. A shallow root answers only "did one of these exact
/// files change", which needs the directory read but nothing below it.
public struct WatchScope: Sendable, Equatable {
	/// Watched along with everything beneath them.
	public let recursiveRoots: Set<URL>

	/// Watched for the entries directly inside them, no deeper.
	public let shallowRoots: Set<URL>

	public init(recursiveRoots: Set<URL>, shallowRoots: Set<URL> = []) {
		self.recursiveRoots = Set(recursiveRoots.map(\.standardizedFileURL))
		self.shallowRoots = Set(shallowRoots.map(\.standardizedFileURL))
	}

	/// Every root, for backends with no way to say "this one only".
	///
	/// FSEvents is the case: its stream recurses in the kernel, so a shallow root
	/// costs the subtree below it in delivered events. It stays correct because
	/// the graph filters what arrives, and it costs nothing to register, which is
	/// why the distinction is not worth pushing further down.
	public var allRoots: [URL] {
		recursiveRoots.union(shallowRoots).sorted { $0.path < $1.path }
	}

	public var isEmpty: Bool {
		recursiveRoots.isEmpty && shallowRoots.isEmpty
	}
}
