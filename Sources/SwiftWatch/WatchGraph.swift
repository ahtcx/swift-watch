#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public struct WatchGraph: Sendable {
	public let packageRoots: Set<URL>
	public let sourceRoots: Set<URL>
	public let trackedFiles: Set<URL>

	/// Directories declared as target resources, such as a `.copy` of a whole
	/// directory of build tool plugin inputs.
	///
	/// The planned build reports the directory itself rather than only its
	/// current contents, so these match by prefix. Everything inside one is a
	/// build input whatever it is named.
	///
	/// Note that SwiftPM's copy of a resource directory makes FSEvents report
	/// the copied files a second time, so an edit under one of these costs a
	/// single extra no-op build. It converges there — the follow-up build
	/// copies nothing and so reports nothing — and polling does not do it.
	public let trackedRoots: Set<URL>

	public let manifestFiles: Set<URL>
	public let resolvedFiles: Set<URL>
	public let sourceExtensions: Set<String>

	/// Build inputs read out of the llbuild build manifest, filtered to paths
	/// inside a package participating in the exact plan.
	///
	/// These are the authoritative inputs of the invocation swift-watch ran,
	/// including files a build tool plugin discovers for itself.
	public let buildInputs: Set<URL>

	/// Directories a build reads inputs from, watched whole.
	///
	/// A recorded input only covers files that existed when the build was
	/// planned, and a plugin that finds its inputs by scanning picks up new ones
	/// silently. Nothing would then wake the loop to notice: the new file is
	/// unwatched, so no build runs, so no manifest reveals it. Treating the
	/// directory a plugin reads from as wholly its own breaks that circle for
	/// new files, new file types, and new subdirectories alike.
	///
	/// A directory that is, or contains, a target or package root is excluded,
	/// since prefix-watching it would swallow the target's own sources or the
	/// pruned targets beside it. So is a directory whose inputs are all files
	/// the compiler consumes, which is the shape of a target's own subdirectory
	/// rather than a plugin's: a build reads every `.swift` file it compiles,
	/// so without that test every nested source directory would count as a
	/// plugin's, and a note left beside a module's sources would rebuild.
	/// Inputs sitting in either are covered by `buildInputExtensions` instead.
	public let buildInputRoots: Set<URL>

	/// For each directory the build reads inputs from that is not a plugin's to
	/// own, the extensions it reads there.
	///
	/// The narrow counterpart to `buildInputRoots`, for inputs that sit among a
	/// target's sources rather than in a directory of their own. A new file of a
	/// type the build already reads there counts; a README dropped beside it
	/// does not.
	public let buildInputExtensions: [URL: Set<String>]

	/// Directories the caller knows are build output, such as a custom
	/// `--scratch-path` forwarded to `swift build`. Watching them would make
	/// every build's own writes look like changes.
	public let excludedRoots: Set<URL>

	/// Which of the widening rules apply. Paths the build reported reading, and
	/// the pruning of build output, are not among them: those hold regardless.
	public let rules: WatchRules

	public init(
		packageRoots: Set<URL>,
		sourceRoots: Set<URL>,
		trackedFiles: Set<URL>,
		trackedRoots: Set<URL> = [],
		manifestFiles: Set<URL>,
		resolvedFiles: Set<URL>,
		sourceExtensions: Set<String>,
		buildInputs: Set<URL> = [],
		excludedRoots: Set<URL> = [],
		rules: WatchRules = .default
	) {
		self.rules = rules
		self.packageRoots = Set(packageRoots.map(\.standardizedFileURL))
		self.sourceRoots = Set(sourceRoots.map(\.standardizedFileURL))
		self.manifestFiles = Set(manifestFiles.map(\.standardizedFileURL))
		self.resolvedFiles = Set(resolvedFiles.map(\.standardizedFileURL))
		self.excludedRoots = Set(excludedRoots.map(\.standardizedFileURL))

		// Rules are applied here rather than at evaluation: a disabled rule
		// leaves the state it widens by empty, so nothing downstream has to
		// consult the rule set and the relevance chain stays a plain ordered
		// read. What they govern is reach past the build's own inputs — those
		// stay tracked by path whatever is switched off.
		self.trackedRoots =
			rules.contains(.declaredResourceDirectories)
			? Set(trackedRoots.map(\.standardizedFileURL)) : []
		self.sourceExtensions = rules.contains(.sourceExtensions) ? sourceExtensions : []

		let relevantInputs = Self.relevantBuildInputs(
			buildInputs,
			packageRoots: self.packageRoots,
			excludedRoots: self.excludedRoots
		)
		self.buildInputs = relevantInputs
		self.trackedFiles = Set(trackedFiles.map(\.standardizedFileURL))
			.union(relevantInputs)

		// Classified against the extension set as given, not `self`'s: which
		// directories a plugin owns is a fact about the build, and must not
		// change because `--disable-rule source-extensions` emptied the set the
		// graph judges by.
		let scopes = Self.buildInputScopes(
			relevantInputs,
			roots: self.sourceRoots.union(self.packageRoots),
			compiledExtensions: Set(sourceExtensions.map { $0.lowercased() }),
			rules: rules
		)
		self.buildInputRoots = scopes.roots
		self.buildInputExtensions = scopes.extensions
	}

	/// Splits build inputs into the directories worth watching whole and the
	/// roots worth watching by extension.
	///
	/// A directory holding build inputs is its plugin's to own, on two counts.
	///
	/// It must not be a root the graph already covers on other terms, or an
	/// ancestor of one: a target's own directory holds its sources, and watching
	/// `Sources` whole would resurrect every target the closure pruned.
	///
	/// And what it holds must not be exclusively files the compiler consumes.
	/// Every `.swift` file a target compiles is an input of the build, so a
	/// target's subdirectories look exactly like a plugin's from the manifest
	/// alone; judging them by extension is what separates `Protos`, which the
	/// build reads `.proto` from, from `Models`, which just holds more of the
	/// module. Directories holding an input of any other kind — including one
	/// with no extension at all — stay the plugin's, so the test errs towards
	/// watching more.
	///
	/// Both fall back to the narrower rule, which widens only to the file types
	/// read there. That leaves one gap, and it is the gap the target root itself
	/// has always had: a file type nothing has read yet, dropped in a directory
	/// of pure sources, waits for the next build from another cause to be
	/// recorded — at which point the directory is reclassified and watched
	/// whole.
	private static func buildInputScopes(
		_ inputs: Set<URL>,
		roots: Set<URL>,
		compiledExtensions: Set<String>,
		rules: WatchRules
	) -> (roots: Set<URL>, extensions: [URL: Set<String>]) {
		var readExtensions: [URL: Set<String>] = [:]
		for input in inputs {
			readExtensions[input.deletingLastPathComponent(), default: []]
				.insert(input.pathExtension.lowercased())
		}

		var inputRoots = Set<URL>()
		var extensions: [URL: Set<String>] = [:]
		for (directory, directoryExtensions) in readExtensions {
			let isPluginsOwn =
				!roots.contains(where: { $0.isWithin(directory) })
				&& !directoryExtensions.isSubset(of: compiledExtensions)
			guard !isPluginsOwn else {
				if rules.contains(.pluginInputDirectories) {
					inputRoots.insert(directory)
				}
				continue
			}
			// An extensionless input names no file type to widen by.
			let named = directoryExtensions.subtracting([""])
			guard rules.contains(.pluginInputExtensions), !named.isEmpty else {
				continue
			}
			extensions[directory] = named
		}
		return (inputRoots, extensions)
	}

	/// The manifest inputs worth watching: those inside a planned package and
	/// not pruned.
	///
	/// A build manifest also records the build's own output, the toolchain, and
	/// SDK headers.
	public static func relevantBuildInputs(
		_ inputs: Set<URL>,
		packageRoots: Set<URL>,
		excludedRoots: Set<URL>
	) -> Set<URL> {
		let roots = Set(packageRoots.map(\.standardizedFileURL))
		let excluded = Set(excludedRoots.map(\.standardizedFileURL))
		return Set(
			inputs.map(\.standardizedFileURL).filter { input in
				guard !prunesTraversal(input, excludedRoots: excluded) else {
					return false
				}
				return roots.contains { input.isWithin($0) }
			})
	}

	/// Where a watcher has to look, and how far down.
	///
	/// Derived from the rules rather than from the package layout, so a narrow
	/// plan is a narrow watch. Everything a rule can match is reachable from one
	/// of these roots: the rules that widen by containment name a root to descend
	/// from, and the rules that match an exact path — a build input, a manifest —
	/// need only the directory holding it, since a file cannot change without its
	/// own directory being read.
	public var watchScope: WatchScope {
		let recursive = Self.outermost(
			sourceRoots.union(buildInputRoots).union(trackedRoots))
		// A directory already inside something watched recursively adds nothing.
		let shallow = Set(
			trackedFiles.union(manifestFiles).union(resolvedFiles)
				.map { $0.deletingLastPathComponent().standardizedFileURL }
		).filter { directory in
			!recursive.contains { directory.isWithin($0) }
		}
		return WatchScope(recursiveRoots: recursive, shallowRoots: shallow)
	}

	/// Drops any root that another root already contains.
	private static func outermost(_ roots: Set<URL>) -> Set<URL> {
		roots.filter { root in
			!roots.contains { $0 != root && root.isWithin($0) }
		}
	}

	/// Whether `candidate` is a directory no watcher should enter: SwiftPM
	/// scratch state, SCM metadata, or a caller-supplied excluded root.
	///
	/// Pruning these keeps recursive watchers from registering watches on,
	/// and the polling backend from rescanning, entire build trees.
	public func prunesTraversal(_ candidate: URL) -> Bool {
		Self.prunesTraversal(candidate, excludedRoots: excludedRoots)
	}

	/// The rule behind `prunesTraversal`, as a static so initialisation can
	/// apply it before the instance exists.
	private static func prunesTraversal(
		_ candidate: URL, excludedRoots: Set<URL>
	) -> Bool {
		let components = candidate.pathComponents
		if components.contains(".build") || components.contains(".git")
			|| components.contains(".swiftpm")
		{
			return true
		}
		let url = candidate.standardizedFileURL
		return excludedRoots.contains { url.isWithin($0) }
	}

	public func isRelevantChange(_ candidate: URL) -> Bool {
		matchedRule(for: candidate) != nil
	}

	/// Which rule makes `candidate` relevant, or `nil` if none does.
	///
	/// The order below is the design, not an implementation detail. A path the
	/// build reported reading outranks the pruning, so an explicitly declared
	/// input under a hidden directory still counts. The widening rules are
	/// checked ahead of the source-extension rule, because a directory of
	/// plugin inputs sits inside the target path that seeded the source roots,
	/// and the compiler's notion of a source file does not apply there.
	public func matchedRule(for candidate: URL) -> WatchRuleMatch? {
		let url = candidate.standardizedFileURL
		if trackedFiles.contains(url) || manifestFiles.contains(url)
			|| resolvedFiles.contains(url)
		{
			return .trackedPath
		}
		guard !prunesTraversal(url) else {
			return nil
		}
		// Anything inside a directory the build reads inputs from, whatever it
		// is named: a plugin that scans for its inputs will find it too.
		// Roots nest, so a root that rejects the path is not the last word: the
		// hidden-component test is relative to the root, and a path hidden below
		// one root can be plainly named below a deeper one. Each loop therefore
		// moves on to the next root rather than dismissing the change outright.
		for inputRoot in buildInputRoots
		where url.isWithin(inputRoot) && !hasHiddenComponent(url, below: inputRoot) {
			return .pluginInputDirectory(root: inputRoot.path)
		}
		// A file the build has never read, in a target root it reads that file
		// type from, is the shape of an input added since the last build.
		let directory = url.deletingLastPathComponent()
		if !url.lastPathComponent.hasPrefix("."),
			let extensions = buildInputExtensions[directory],
			extensions.contains(url.pathExtension.lowercased())
		{
			return .pluginInputExtension(root: directory.path)
		}
		for trackedRoot in trackedRoots
		where url.isWithin(trackedRoot) && !hasHiddenComponent(url, below: trackedRoot) {
			return .declaredResourceDirectory(root: trackedRoot.path)
		}
		guard sourceExtensions.contains(url.pathExtension.lowercased()) else {
			return nil
		}
		for sourceRoot in sourceRoots
		where url.isWithin(sourceRoot) && !hasHiddenComponent(url, below: sourceRoot) {
			return .sourceExtension(root: sourceRoot.path)
		}
		return nil
	}

	/// Whether any component of `url` below `root` is hidden.
	///
	/// SwiftPM's file enumeration skips hidden files and hidden directories, so
	/// a change under one can never affect the build, however source-like its
	/// name (emacs lock files such as `.#main.swift` carry a real source
	/// extension). Only components below the root are judged: the root itself
	/// is an exact planned path and may legitimately be hidden.
	private func hasHiddenComponent(_ url: URL, below root: URL) -> Bool {
		url.path.dropFirst(root.path.count).split(separator: "/").contains {
			$0.hasPrefix(".")
		}
	}
}
