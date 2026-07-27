#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

extension URL {
	/// Whether this path is `directory` or lies inside it.
	///
	/// Compared as paths rather than by walking components, so callers must
	/// standardize first. The trailing separator is what keeps `Sources/AppKit`
	/// from reading as a path inside `Sources/App`, and is not appended twice
	/// for the filesystem root, which already ends in one.
	func isWithin(_ directory: URL) -> Bool {
		if self == directory {
			return true
		}
		let base = directory.path
		return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
	}
}

/// Whether `rawPath` has to be resolved against a base directory to name a
/// file.
///
/// Absolute is recognised in both spellings: a leading separator, or a drive
/// letter. Reading a Windows path as relative would silently append it to the
/// base and name a file that does not exist.
func isRelativePath(_ rawPath: String) -> Bool {
	if rawPath.hasPrefix("/") || rawPath.hasPrefix(#"\"#) {
		return false
	}
	var characters = Substring(rawPath)
	guard let drive = characters.popFirst(), drive.isLetter else {
		return true
	}
	return !characters.hasPrefix(":/") && !characters.hasPrefix(#":\"#)
}
