/// The optional rules by which a change counts as relevant.
///
/// Two rules are deliberately absent, because they are invariants rather than
/// policy: a path the build itself reported reading always counts, and build
/// output is never watched. Turning either off would produce a watcher that
/// misses what it exists to catch, or one that retriggers on its own builds.
///
/// What remains are the rules that widen past what a build has demonstrably
/// read. Each covers files no build has reported yet, so each trades a little
/// noise for catching work the next build will pick up.
public struct WatchRules: OptionSet, Sendable {
	public let rawValue: Int

	public init(rawValue: Int) {
		self.rawValue = rawValue
	}

	/// Watch, whole, the directories a build reads inputs from that hold
	/// something other than the target's own sources.
	///
	/// Covers new files, new file types, and new subdirectories under a
	/// directory a build tool plugin scans. Off, only inputs the build has
	/// already read count, and a newly added one waits for the next build from
	/// another cause.
	///
	/// A directory holding nothing but files the compiler consumes is the
	/// target's, not a plugin's, and falls to `pluginInputExtensions` instead.
	public static let pluginInputDirectories = WatchRules(rawValue: 1 << 0)

	/// Count files beside a target's sources whose extension the build already
	/// reads there.
	///
	/// The narrow form of the rule above, for plugin inputs that sit among a
	/// target's sources rather than in a directory of their own, where watching
	/// whole would swallow the module.
	public static let pluginInputExtensions = WatchRules(rawValue: 1 << 1)

	/// Watch, whole, the directories declared as target resources.
	///
	/// Off, only the resource files present when the package was described
	/// count.
	public static let declaredResourceDirectories = WatchRules(rawValue: 1 << 2)

	/// Count files under a target's sources that carry a source extension.
	///
	/// Off, only the sources `swift package describe` reported count, so a newly
	/// added `.swift` file waits for the manifest edit that would rediscover it.
	public static let sourceExtensions = WatchRules(rawValue: 1 << 3)

	public static let `default`: WatchRules = [
		.pluginInputDirectories, .pluginInputExtensions,
		.declaredResourceDirectories, .sourceExtensions,
	]

	/// The CLI spelling of each rule, in the order they are applied.
	public static let named: [(name: String, rule: WatchRules)] = [
		("plugin-input-directories", .pluginInputDirectories),
		("plugin-input-extensions", .pluginInputExtensions),
		("declared-resource-directories", .declaredResourceDirectories),
		("source-extensions", .sourceExtensions),
	]

	public static var allNames: [String] {
		named.map(\.name)
	}

	public init?(name: String) {
		guard let match = Self.named.first(where: { $0.name == name }) else {
			return nil
		}
		self = match.rule
	}
}

/// Why a change counted, named so the reason can be reported back.
public enum WatchRuleMatch: Equatable, Sendable {
	/// A path the build reported reading: a described source, a declared
	/// resource, a manifest input, or a package manifest.
	case trackedPath

	/// Inside `root`, a directory the build reads inputs from.
	case pluginInputDirectory(root: String)

	/// Beside a target's sources, carrying an extension the build reads there.
	case pluginInputExtension(root: String)

	/// Inside `root`, a directory declared as a target resource.
	case declaredResourceDirectory(root: String)

	/// Under a target's sources, carrying a source extension.
	case sourceExtension(root: String)

	public var ruleName: String {
		switch self {
		case .trackedPath: "tracked-path"
		case .pluginInputDirectory: "plugin-input-directories"
		case .pluginInputExtension: "plugin-input-extensions"
		case .declaredResourceDirectory: "declared-resource-directories"
		case .sourceExtension: "source-extensions"
		}
	}

	/// A one-line reason, for `--explain`.
	///
	/// Led by the rule name as `--disable-rule` spells it, so a rebuild nobody
	/// expected names the flag that would stop it.
	public var explanation: String {
		"\(ruleName) (\(detail))"
	}

	private var detail: String {
		switch self {
		case .trackedPath:
			"the build reported reading it"
		case .pluginInputDirectory(let root):
			"inside \(root), which the build reads inputs from"
		case .pluginInputExtension(let root):
			"the build reads this file type from \(root)"
		case .declaredResourceDirectory(let root):
			"inside \(root), declared as a resource"
		case .sourceExtension(let root):
			"a source file under \(root)"
		}
	}
}
