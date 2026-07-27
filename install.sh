#!/bin/sh
# Installs the latest swift-watch release. No root required.
#
#   curl -fsSL https://raw.githubusercontent.com/ahtcx/swift-watch/main/install.sh | sh
#
# Re-run to update; an existing install is replaced. To uninstall, delete the
# binary: rm ~/.local/bin/swift-watch
#
# Override the install location with SWIFT_WATCH_BIN_DIR, or pin a release
# with SWIFT_WATCH_VERSION.

set -eu

REPO="ahtcx/swift-watch"

main() {
	command -v curl >/dev/null 2>&1 || fail "curl is required but was not found."

	bin_dir="${SWIFT_WATCH_BIN_DIR:-$HOME/.local/bin}"

	case "$(uname -s)" in
		Darwin) os="macos" ;;
		Linux) os="linux" ;;
		*) unsupported "operating system: $(uname -s)" ;;
	esac

	case "$(uname -m)" in
		arm64 | aarch64) arch="arm64" ;;
		x86_64 | amd64) arch="x64" ;;
		*) unsupported "architecture: $(uname -m)" ;;
	esac

	version="${SWIFT_WATCH_VERSION:-$(latest_version)}"
	[ -n "$version" ] || fail "could not determine the latest version"

	mkdir -p "$bin_dir"
	tmp="$bin_dir/.swift-watch.$$"
	trap 'rm -f "$tmp"' EXIT

	curl -fsSL -o "$tmp" \
		"https://github.com/$REPO/releases/download/$version/swift-watch-$version-$os-$arch"
	chmod 755 "$tmp"
	mv -f "$tmp" "$bin_dir/swift-watch"

	echo "Installed swift-watch $version to $bin_dir/swift-watch"
	case ":$PATH:" in
		*":$bin_dir:"*) ;;
		*) echo "Add it to your PATH: export PATH=\"$bin_dir:\$PATH\"" ;;
	esac
	echo "To uninstall: rm $bin_dir/swift-watch"

	# Linux binaries need the Swift runtime and look for it at the conventional
	# path. A toolchain installed elsewhere has to be pointed to.
	if ! "$bin_dir/swift-watch" --help >/dev/null 2>&1; then
		echo "Warning: swift-watch did not start; it needs a Swift toolchain." >&2
		echo "If yours is not at /usr/lib/swift/linux, add its lib/swift/linux to LD_LIBRARY_PATH." >&2
	fi
}

# No prebuilt binary matches this machine. Building from source still works
# anywhere Swift does, since the polling watcher is the portable fallback.
unsupported() {
	fail "No prebuilt swift-watch for $1.
Build it from source with 'swift build -c release', or open an issue:
https://github.com/$REPO/issues"
}

# Resolved from the release redirect rather than the API, which is rate
# limited for unauthenticated callers.
latest_version() {
	curl -fsSLI -o /dev/null -w '%{url_effective}' \
		"https://github.com/$REPO/releases/latest" | sed -n 's|.*/tag/||p'
}

fail() {
	echo "$@" >&2
	exit 1
}

main "$@"
