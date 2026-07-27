// swift-tools-version: 6.3

import PackageDescription

let package = Package(
	name: "swift-watch",
	platforms: [.macOS(.v13)],
	products: [
		.executable(name: "swift-watch", targets: ["swift-watch"])
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
		.package(
			url: "https://github.com/swiftlang/swift-subprocess.git",
			exact: "1.0.0-beta.1", traits: []),
	],
	targets: [
		.target(
			name: "SwiftWatch",
			dependencies: [
				.product(name: "Subprocess", package: "swift-subprocess")
			]
		),
		.target(
			name: "SwiftWatchPolling",
			dependencies: ["SwiftWatch"]
		),
		.target(
			name: "SwiftWatchFSEvents",
			dependencies: ["SwiftWatch"]
		),
		.target(
			name: "SwiftWatchInotify",
			dependencies: ["SwiftWatch"]
		),
		.target(
			name: "SwiftWatchRuntime",
			dependencies: ["SwiftWatch"]
		),
		.executableTarget(
			name: "swift-watch",
			dependencies: [
				"SwiftWatch",
				"SwiftWatchPolling",
				"SwiftWatchRuntime",
				.target(
					name: "SwiftWatchFSEvents",
					condition: .when(platforms: [.macOS])),
				.target(
					name: "SwiftWatchInotify",
					condition: .when(platforms: [.linux])),
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
			]
		),
		.testTarget(
			name: "SwiftWatchTests",
			dependencies: ["SwiftWatch", "swift-watch"]
		),
		.testTarget(
			name: "SwiftWatchRuntimeTests",
			dependencies: ["SwiftWatch", "SwiftWatchRuntime"]
		),
		.testTarget(
			name: "SwiftWatchPollingTests",
			dependencies: ["SwiftWatch", "SwiftWatchPolling"]
		),
		.testTarget(
			name: "SwiftWatchFSEventsTests",
			dependencies: ["SwiftWatch", "SwiftWatchFSEvents"]
		),
		.testTarget(
			name: "SwiftWatchInotifyTests",
			dependencies: ["SwiftWatch", "SwiftWatchInotify"]
		),
	],
	swiftLanguageModes: [.v6]
)
