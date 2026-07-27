/// The build system a `swift build` invocation will use.
///
/// swift-watch forwards `--build-system` rather than acting on it, so this
/// exists only to pick the reader that understands what that build will leave
/// behind. A value it does not recognise is carried by name rather than
/// rejected: an unknown build system is one whose plugin inputs cannot be
/// resolved, which is a warning and a narrower watch, not an error.
public enum BuildSystem: Equatable, Sendable {
	/// SwiftPM's own build system, which plans through an llbuild manifest.
	case native

	/// Swift Build, which plans through a PIF and an `XCBuildData` tree.
	case swiftBuild

	/// Anything else `--build-system` may name, now or in a later toolchain.
	case unrecognised(name: String)

	/// The spelling `swift build --build-system` takes.
	public var name: String {
		switch self {
		case .native: Self.nativeName
		case .swiftBuild: Self.swiftBuildName
		case .unrecognised(let name): name
		}
	}

	public init(name: String) {
		switch name {
		case Self.nativeName: self = .native
		case Self.swiftBuildName: self = .swiftBuild
		default: self = .unrecognised(name: name)
		}
	}

	/// The reader for this build system, or `nil` when nothing it writes can be
	/// read for plugin inputs.
	public var reader: (any BuildManifestReading)? {
		switch self {
		case .native: NativeBuildManifest()
		case .swiftBuild: SwiftBuildManifest()
		case .unrecognised: nil
		}
	}

	/// What `swift build` uses when nobody says otherwise.
	///
	/// Tracking SwiftPM's default rather than assuming it holds forever: if a
	/// toolchain changes it, the reader picked here is the wrong one and the
	/// manifest simply never appears, which surfaces as the same warning an
	/// unrecognised build system gets.
	public static let `default` = BuildSystem.native

	private static let nativeName = "native"
	private static let swiftBuildName = "swiftbuild"
}
