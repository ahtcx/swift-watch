#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

public enum DependencyLocation: Equatable, Sendable {
	case fileSystem(path: String)
	case localSourceControl(path: String)
	case unsupported
}

public struct DescribedPackage: Decodable, Sendable {
	public let path: String
	public let dependencies: [Dependency]
	public let products: [Product]
	public let targets: [Target]

	public init(
		path: String,
		dependencies: [Dependency],
		products: [Product] = [],
		targets: [Target]
	) {
		self.path = path
		self.dependencies = dependencies
		self.products = products
		self.targets = targets
	}

	enum CodingKeys: String, CodingKey {
		case path
		case dependencies
		case products
		case targets
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.path = try container.decode(String.self, forKey: .path)
		self.dependencies = try container.decode([Dependency].self, forKey: .dependencies)
		self.products =
			try container.decodeIfPresent([Product].self, forKey: .products) ?? []
		self.targets = try container.decode([Target].self, forKey: .targets)
	}

	public struct Product: Decodable, Sendable {
		public let name: String
		public let targets: [String]

		public init(name: String, targets: [String]) {
			self.name = name
			self.targets = targets
		}
	}

	public struct Target: Decodable, Sendable {
		public let name: String
		public let path: String
		public let sources: [String]
		public let targetDependencies: [String]
		public let productDependencies: [String]

		public init(
			name: String,
			path: String,
			sources: [String],
			targetDependencies: [String] = [],
			productDependencies: [String] = []
		) {
			self.name = name
			self.path = path
			self.sources = sources
			self.targetDependencies = targetDependencies
			self.productDependencies = productDependencies
		}

		enum CodingKeys: String, CodingKey {
			case name
			case path
			case sources
			case targetDependencies = "target_dependencies"
			case productDependencies = "product_dependencies"
		}

		public init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			self.name = try container.decode(String.self, forKey: .name)
			self.path = try container.decode(String.self, forKey: .path)
			self.sources = try container.decode([String].self, forKey: .sources)
			self.targetDependencies =
				try container.decodeIfPresent(
					[String].self, forKey: .targetDependencies) ?? []
			self.productDependencies =
				try container.decodeIfPresent(
					[String].self, forKey: .productDependencies) ?? []
		}
	}

	public struct Dependency: Decodable, Sendable {
		public let location: DependencyLocation
		public let identity: String

		public init(identity: String, location: DependencyLocation) {
			self.location = location
			self.identity = identity
		}

		enum CodingKeys: String, CodingKey {
			case type
			case path
			case url
			case identity
		}

		enum Kind: String, Decodable {
			case fileSystem
			case sourceControl
			case registry
		}

		public init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			self.identity = try container.decode(String.self, forKey: .identity)
			switch try container.decode(Kind.self, forKey: .type) {
			case .fileSystem:
				self.location = .fileSystem(
					path: try container.decode(String.self, forKey: .path))
			case .sourceControl:
				let raw = try container.decode(String.self, forKey: .url)
				if raw.hasPrefix("/") || raw.hasPrefix(".") {
					self.location = .localSourceControl(path: raw)
				} else {
					self.location = .unsupported
				}
			case .registry:
				self.location = .unsupported
			}
		}
	}
}
