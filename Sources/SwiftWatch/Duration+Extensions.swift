#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif

extension Duration {
	var timeInterval: TimeInterval {
		Double(components.seconds)
			+ (Double(components.attoseconds) / 1_000_000_000_000_000_000)
	}

	var nanoseconds: Int64 {
		let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
		guard !seconds.overflow else {
			return .max
		}
		let fraction = components.attoseconds / 1_000_000_000
		let total = seconds.partialValue.addingReportingOverflow(fraction)
		return total.overflow ? .max : total.partialValue
	}
}
