import Foundation

enum FrequencyUnit: String, CaseIterable, Identifiable {
    case MHz
    case kHz

    var id: String { rawValue }
}

enum FrequencyZeros: String, CaseIterable, Identifiable {
    case trimmed = "trimmed"
    case shown   = "shown"

    var id: String { rawValue }
}

struct FrequencyFormatOptions {
    static let unitKey  = "freqUnit"
    static let zerosKey = "freqTrailingZeros"
}

/// Formats a frequency string from the POTA API.
/// The API returns frequency in kHz (e.g. "7041" = 7.041 MHz, "14074" = 14.074 MHz).
func formatFrequency(_ raw: String, unit: FrequencyUnit, trailingZeros: FrequencyZeros) -> String {
    guard let khz = Double(raw) else { return "\(raw) \(unit.rawValue)" }

    // Work in integer Hz to eliminate floating-point drift (7041 * 1000 → 7041000)
    let hz = Int((khz * 1_000).rounded())

    switch unit {
    case .MHz:
        if trailingZeros == .shown {
            // Always 3 decimal places (kHz resolution): 144.200
            return String(format: "%.3f MHz", Double(hz) / 1_000_000)
        } else {
            // Strip trailing zeros: 144.2, 14.074
            return "\(trimHz(hz, divisor: 1_000_000, minDecimals: 0)) MHz"
        }

    case .kHz:
        if trailingZeros == .shown {
            // 3 decimal places (Hz resolution): 14074.000
            return String(format: "%.3f kHz", Double(hz) / 1_000)
        } else {
            // Always at least 1 decimal place: 14074.0, 14074.1
            return "\(trimHz(hz, divisor: 1_000, minDecimals: 1)) kHz"
        }
    }
}

/// Divides integer Hz by divisor, formats as a decimal string, trims trailing zeros
/// but keeps at least `minDecimals` decimal places.
private func trimHz(_ hz: Int, divisor: Int, minDecimals: Int) -> String {
    let whole = hz / divisor
    let remainder = hz % divisor
    let places = Int(log10(Double(divisor)))  // 6 for MHz, 3 for kHz

    // Full fractional string, zero-padded (e.g. "074000" for 14.074 MHz)
    var fracDigits = String(format: "%0*d", places, remainder)

    // Trim trailing zeros down to minDecimals
    while fracDigits.count > minDecimals && fracDigits.hasSuffix("0") {
        fracDigits.removeLast()
    }

    if fracDigits.isEmpty {
        return "\(whole)"
    }
    return "\(whole).\(fracDigits)"
}
