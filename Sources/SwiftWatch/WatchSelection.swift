/// Selects which targets seed the watch closure.
public struct WatchSelection: Sendable {
	/// Names the user passed explicitly (`--target`, `--product`). When every
	/// name resolves to at least one local target, the closure is seeded from
	/// exactly these instead of from every root-package target, because
	/// swift-watch forwards the same selection to the underlying build.
	public var explicitNames: [String]

	/// Heuristic candidates, such as the executable argument of `swift run`.
	/// Resolved candidates broaden the default seeding but never narrow it,
	/// so a misidentified candidate resolves to nothing and changes nothing.
	public var candidateNames: [String]

	public init(explicitNames: [String] = [], candidateNames: [String] = []) {
		self.explicitNames = explicitNames
		self.candidateNames = candidateNames
	}
}
