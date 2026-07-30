/// Selects the roots of the planned build that swift-watch invoked.
public struct WatchSelection: Sendable {
	public var action: Action
	public var names: [String]

	public init(action: Action = .build, names: [String] = []) {
		self.action = action
		self.names = names
	}

	public enum Action: Sendable {
		case build
		case test
		case run
	}
}
