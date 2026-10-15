import Foundation

// MARK: - Spot date parsing
//
// The POTA API returns spotTime as "2026-04-07T03:04:29" — no timezone designator.
// ISO8601DateFormatter with .withInternetDateTime requires one and will always fail.
// We treat bare date-time strings as UTC.

private let _spotTimeISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let _spotTimeUTC: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f
}()

func parseSpotTime(_ raw: String) -> Date? {
    // Try with timezone designator (future-proofs in case the API ever adds one)
    if let d = _spotTimeISO.date(from: raw) { return d }
    // Primary case: bare UTC string with no designator
    return _spotTimeUTC.date(from: raw)
}

struct Spot: Identifiable, Decodable {
    let spotId: Int
    let activator: String
    let frequency: String
    let mode: String
    let reference: String
    let name: String?
    let spotTime: String
    let comments: String?
    let spotter: String?
    let source: String?
    let locationDesc: String?
    let grid4: String?
    let grid6: String?
    let latitude: Double?
    let longitude: Double?
    let count: Int?
    let expire: Int?

    var id: Int { spotId }

    var ageInMinutes: Int {
        guard let date = parseSpotTime(spotTime) else { return 0 }
        return max(0, Int(Date().timeIntervalSince(date) / 60))
    }

    /// Whether the spot is expired (QRT). expire <= 0 or missing means QRT.
    var isQRT: Bool {
        guard let expire else { return true }
        return expire <= 0
    }

    /// Program prefix derived from the park reference (e.g. "JP" from "JP-1918", "US" from "US-1234").
    var program: String {
        let parts = reference.split(separator: "-")
        guard let first = parts.first else { return "?" }
        return String(first)
    }

    var countryCode: String? {
        let candidates = [
            locationDesc?.split(separator: "-").first.map(String.init),
            reference.split(separator: "-").first.map(String.init)
        ]

        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .first { Locale.Region.isoRegions.contains(Locale.Region($0)) }
    }

    var countryFlag: String? {
        guard let countryCode else { return nil }
        let scalars = countryCode.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            let ascii = scalar.value
            guard ascii >= 65, ascii <= 90 else { return nil }
            return UnicodeScalar(127397 + Int(ascii))
        }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Band name derived from frequency in kHz.
    var band: String {
        guard let freq = Double(frequency) else { return "?" }
        switch freq {
        case 1800...2000:    return "160M"
        case 3500...4000:    return "80M"
        case 5330...5410:    return "60M"
        case 7000...7300:    return "40M"
        case 10100...10150:  return "30M"
        case 14000...14350:  return "20M"
        case 18068...18168:  return "17M"
        case 21000...21450:  return "15M"
        case 24890...24990:  return "12M"
        case 28000...29700:  return "10M"
        case 50000...54000:  return "6M"
        case 144000...148000: return "2M"
        case 420000...450000: return "70CM"
        default:             return "?"
        }
    }
}

@MainActor
class SpotsViewModel: ObservableObject {
    @Published var spots: [Spot] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func fetchSpots() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let url = URL(string: "https://api.pota.app/v1/spots") else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "Failed to fetch spots"
                return
            }
            spots = try JSONDecoder().decode([Spot].self, from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
