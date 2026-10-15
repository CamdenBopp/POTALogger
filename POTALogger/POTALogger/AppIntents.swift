import AppIntents
import Foundation

// MARK: - Shared fetch helper

private let base = "https://api.pota.app"

private func potaToken() -> String? {
    AuthManager.shared.idToken ?? AuthManager.shared.accessToken
}

private func fetch<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
    guard let token = potaToken() else {
        throw POTAIntentError.notSignedIn
    }
    guard let url = URL(string: "\(base)\(path)") else {
        throw POTAIntentError.badURL
    }
    var req = URLRequest(url: url)
    req.setValue(token, forHTTPHeaderField: "Authorization")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
        throw POTAIntentError.unauthorized
    }
    return try JSONDecoder().decode(T.self, from: data)
}

private enum POTAIntentError: Error, CustomStringConvertible {
    case notSignedIn
    case badURL
    case unauthorized
    case apiError(String)

    var description: String {
        switch self {
        case .notSignedIn:      return "You're not signed in to POTA Log."
        case .badURL:           return "Invalid endpoint URL."
        case .unauthorized:     return "POTA API rejected the request. Try signing out and back in."
        case .apiError(let m):  return "POTA API error: \(m)"
        }
    }
}

// MARK: - 1. Current QSO count

struct GetCurrentQSOsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get POTA QSO Count"
    static let description = IntentDescription("Returns your total hunter and activator QSO counts from POTA.")
    static let openAppWhenRun = false

    private struct UserStats: Decodable {
        struct HunterStats: Decodable { let qsos: Int }
        struct ActivatorStats: Decodable { let qsos: Int }
        let hunter: HunterStats
        let activator: ActivatorStats
        let callsign: String
    }

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        guard let callsign = AuthManager.shared.callsign
                          ?? AuthManager.shared.userInfo?.name else {
            throw POTAIntentError.notSignedIn
        }
        guard let url = URL(string: "\(base)/stats/user/\(callsign)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let stats = try? JSONDecoder().decode(UserStats.self, from: data)
        else {
            throw POTAIntentError.unauthorized
        }
        let result = "\(callsign): \(stats.hunter.qsos) hunter QSOs, \(stats.activator.qsos) activator QSOs"
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

// MARK: - 2. Percent until next award

struct GetNextAwardProgressIntent: AppIntent {
    static let title: LocalizedStringResource = "Get POTA Next Award Progress"
    static let description = IntentDescription("Returns how close you are to your next hunter parks award.")
    static let openAppWhenRun = false

    @Parameter(title: "Role", default: .hunter)
    var role: POTARole

    private struct ParksProgress: Decodable {
        let numParks: Int?
        let nextAwardLevel: Int?
        let completedPct: Double?
    }

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let path = "/user/award/progress/\(role.rawValue)/parks"
        let progress = try await fetch(ParksProgress.self, path: path)
        let pct   = progress.completedPct.map { Int($0.rounded()) } ?? 0
        let cur   = progress.numParks ?? 0
        let next  = progress.nextAwardLevel ?? 0
        let label = role == .hunter ? "Hunter" : "Activator"
        let result = "\(label): \(cur) of \(next) parks — \(pct)% to next award"
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

enum POTARole: String, AppEnum {
    case hunter    = "hunter"
    case activator = "activator"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "POTA Role"
    static let caseDisplayRepresentations: [POTARole: DisplayRepresentation] = [
        .hunter:    "Hunter",
        .activator: "Activator",
    ]
}

// MARK: - 3. Repeat offender park list

struct GetRepeatOffenderParksIntent: AppIntent {
    static let title: LocalizedStringResource = "Get POTA Repeat Offender Parks"
    static let description = IntentDescription("Lists the parks you've hunted the most times.")
    static let openAppWhenRun = false

    @Parameter(title: "Number of parks", default: 5)
    var count: Int

    private struct RepeatOffender: Decodable {
        let reference: String
        let name: String
        let contacts: Int
    }

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let parks = try await fetch([RepeatOffender].self,
                                    path: "/user/award/progress/hunter/repeatoffender")
        guard !parks.isEmpty else {
            let msg = "No repeat offender parks yet."
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
        let top = parks.prefix(max(1, min(count, 10)))
        let lines = top.enumerated().map { i, p in
            "\(i + 1). \(p.name) (\(p.reference)) — \(p.contacts) contacts"
        }
        let result = lines.joined(separator: "\n")
        let spoken = top.map { "\($0.name), \($0.contacts) contacts" }.joined(separator: "; ")
        return .result(value: result, dialog: IntentDialog(stringLiteral: spoken))
    }
}

// MARK: - Filter enums

enum POTABand: String, AppEnum, CaseIterable {
    case band160m = "160m"
    case band80m  = "80m"
    case band60m  = "60m"
    case band40m  = "40m"
    case band30m  = "30m"
    case band20m  = "20m"
    case band17m  = "17m"
    case band15m  = "15m"
    case band12m  = "12m"
    case band10m  = "10m"
    case band6m   = "6m"
    case band2m   = "2m"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Band"
    static let caseDisplayRepresentations: [POTABand: DisplayRepresentation] = [
        .band160m: "160m", .band80m: "80m",  .band60m: "60m",
        .band40m:  "40m",  .band30m: "30m",  .band20m: "20m",
        .band17m:  "17m",  .band15m: "15m",  .band12m: "12m",
        .band10m:  "10m",  .band6m:  "6m",   .band2m:  "2m",
    ]

    var freqRange: ClosedRange<Double> {
        switch self {
        case .band160m: return 1.8...2.0
        case .band80m:  return 3.5...4.0
        case .band60m:  return 5.3...5.4
        case .band40m:  return 7.0...7.3
        case .band30m:  return 10.1...10.15
        case .band20m:  return 14.0...14.35
        case .band17m:  return 18.068...18.168
        case .band15m:  return 21.0...21.45
        case .band12m:  return 24.89...24.99
        case .band10m:  return 28.0...29.7
        case .band6m:   return 50.0...54.0
        case .band2m:   return 144.0...148.0
        }
    }
}

enum POTASpotMode: String, AppEnum, CaseIterable {
    case ssb          = "SSB"
    case cw           = "CW"
    case ft8          = "FT8"
    case ft4          = "FT4"
    case fm           = "FM"
    case am           = "AM"
    case digitalVoice = "DIGITALVOICE"
    case rtty         = "RTTY"
    case js8          = "JS8"
    case data         = "DATA"
    case other        = "OTHER"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static let caseDisplayRepresentations: [POTASpotMode: DisplayRepresentation] = [
        .ssb:          "SSB",
        .cw:           "CW",
        .ft8:          "FT8",
        .ft4:          "FT4",
        .fm:           "FM",
        .am:           "AM",
        .digitalVoice: "Digital Voice",
        .rtty:         "RTTY",
        .js8:          "JS8",
        .data:         "Data / Digital",
        .other:        "Other",
    ]
}

enum POTAParkFilterType: String, AppEnum {
    case all       = "all"
    case activated = "activated"
    case hunted    = "hunted"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Park Filter"
    static let caseDisplayRepresentations: [POTAParkFilterType: DisplayRepresentation] = [
        .all:       "All / Local Parks",
        .activated: "My Activated Parks",
        .hunted:    "My Hunted Parks",
    ]
}

// MARK: - 4. Get live spots with limit

struct GetLiveSpotsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Live POTA Spots"
    static let description = IntentDescription("Returns current live POTA spots, up to the limit you set (max 100).")
    static let openAppWhenRun = false

    @Parameter(title: "Limit", description: "Maximum number of spots to return (1–100).", default: 20)
    var limit: Int

    private struct SpotResponse: Decodable {
        let activator: String
        let frequency: String
        let mode: String
        let reference: String
        let name: String?
        let comments: String?
    }

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let clamped = max(1, min(limit, 100))
        guard let url = URL(string: "\(base)/v1/spots") else { throw POTAIntentError.badURL }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw POTAIntentError.unauthorized }
        let spots = try JSONDecoder().decode([SpotResponse].self, from: data)
        let top = spots.prefix(clamped)
        guard !top.isEmpty else {
            let msg = "No live spots right now."
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
        let lines = top.map { "\($0.activator) @ \($0.frequency) \($0.mode) — \($0.reference)" }
        let result = lines.joined(separator: "\n")
        return .result(value: result, dialog: IntentDialog(stringLiteral: "\(top.count) spots found"))
    }
}

// MARK: - 5. Filter spots by park type, state, band, mode, age, RST

struct FilterSpotsIntent: AppIntent {
    static let title: LocalizedStringResource = "Filter POTA Spots"
    static let description = IntentDescription(
        "Fetch live spots filtered by park type, state, band, mode, age, or RST. All filters are optional.")
    static let openAppWhenRun = false

    @Parameter(title: "Park Filter", default: .all)
    var parkFilter: POTAParkFilterType

    @Parameter(title: "State", description: "Two-letter US state code, e.g. OH.")
    var state: String?

    @Parameter(title: "Band")
    var band: POTABand?

    @Parameter(title: "Mode")
    var mode: POTASpotMode?

    @Parameter(title: "Max Age (minutes)", description: "Only include spots newer than this many minutes.")
    var maxAgeMinutes: Int?

    @Parameter(title: "RST", description: "Only include spots whose comments contain this RST value, e.g. 59.")
    var rst: String?

    @Parameter(title: "Limit", description: "Maximum results to return (1–100).", default: 20)
    var limit: Int

    private struct SpotResponse: Decodable {
        let activator: String
        let frequency: String
        let mode: String
        let reference: String
        let name: String?
        let spotTime: String
        let comments: String?

        var ageInMinutes: Int {
            guard let d = parseSpotTime(spotTime) else { return 0 }
            return max(0, Int(Date().timeIntervalSince(d) / 60))
        }
    }

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let clamped = max(1, min(limit, 100))

        // Fetch all live spots
        guard let url = URL(string: "\(base)/v1/spots") else { throw POTAIntentError.badURL }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw POTAIntentError.unauthorized }
        var spots = try JSONDecoder().decode([SpotResponse].self, from: data)

        // Park type filter — activated/hunted require sign-in
        if parkFilter != .all {
            guard let token = potaToken(),
                  let callsign = AuthManager.shared.callsign else { throw POTAIntentError.notSignedIn }
            let path = parkFilter == .activated
                ? "/activator/\(callsign)/activations"
                : "/hunter/\(callsign)/activations"
            guard let refURL = URL(string: "\(base)\(path)") else { throw POTAIntentError.badURL }
            var req = URLRequest(url: refURL)
            req.setValue(token, forHTTPHeaderField: "Authorization")
            if let (refData, _) = try? await URLSession.shared.data(for: req) {
                struct ParkRef: Decodable { let reference: String }
                if let refs = try? JSONDecoder().decode([ParkRef].self, from: refData) {
                    let refSet = Set(refs.map(\.reference))
                    spots = spots.filter { refSet.contains($0.reference) }
                }
            }
        }

        // State filter — look up locationDesc in the local park index
        if let stateInput = state?.uppercased().trimmingCharacters(in: .whitespaces), !stateInput.isEmpty {
            if !ParkIndex.shared.isLoaded {
                ParkIndex.shared.load()
                var waited = 0
                while !ParkIndex.shared.isLoaded, waited < 50 {
                    try await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
            }
            if ParkIndex.shared.isLoaded {
                // Match "OH" → "US-OH", or a longer string as a direct contains check
                let stateRefs: Set<String>
                if stateInput.count == 2 {
                    stateRefs = Set(ParkIndex.shared.parks
                        .filter { $0.locationDesc.uppercased().hasSuffix("-\(stateInput)") }
                        .map(\.reference))
                } else {
                    stateRefs = Set(ParkIndex.shared.parks
                        .filter { $0.locationDesc.uppercased().contains(stateInput) }
                        .map(\.reference))
                }
                spots = spots.filter { stateRefs.contains($0.reference) }
            }
        }

        // Band filter
        if let band {
            spots = spots.filter {
                guard let freq = Double($0.frequency) else { return false }
                return band.freqRange.contains(freq)
            }
        }

        // Mode filter
        if let mode {
            spots = spots.filter { $0.mode.uppercased() == mode.rawValue }
        }

        // Age filter
        if let maxAge = maxAgeMinutes {
            spots = spots.filter { $0.ageInMinutes <= maxAge }
        }

        // RST filter — search comments
        if let rst, !rst.isEmpty {
            spots = spots.filter { ($0.comments ?? "").contains(rst) }
        }

        let top = spots.prefix(clamped)
        guard !top.isEmpty else {
            let msg = "No spots matched your filters."
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }
        let lines = top.map { "\($0.activator) @ \($0.frequency) \($0.mode) — \($0.reference)" }
        let result = lines.joined(separator: "\n")
        let spoken = "\(top.count) spot\(top.count == 1 ? "" : "s") matched"
        return .result(value: result, dialog: IntentDialog(stringLiteral: spoken))
    }
}

// MARK: - 6. Post a spot

struct PostSpotIntent: AppIntent {
    static let title: LocalizedStringResource = "Post a POTA Spot"
    static let description = IntentDescription(
        "Post a spot to the POTA network without opening the app. Leave Activator blank to self-spot.")
    static let openAppWhenRun = false

    @Parameter(title: "Activator Callsign",
               description: "The callsign being activated. Leave blank to use your own callsign for a self-spot.")
    var activator: String?

    @Parameter(title: "Park Reference",
               description: "POTA park reference, e.g. K-0001 or K-TEST.")
    var reference: String

    @Parameter(title: "Frequency (kHz)",
               description: "Frequency in kHz — e.g. 14074 for 14.074 MHz, 1999 for 1.999 MHz.")
    var frequencyKHz: Int

    @Parameter(title: "Mode", default: .ssb)
    var mode: POTASpotMode

    @Parameter(title: "Comment")
    var comment: String?

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        // Proactively refresh — Cognito access tokens expire after 1 hour
        _ = await AuthManager.shared.refreshTokens()

        guard let token = AuthManager.shared.idToken ?? AuthManager.shared.accessToken else {
            throw POTAIntentError.notSignedIn
        }

        let trimmed = activator?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        let resolvedActivator = trimmed.isEmpty ? AuthManager.shared.callsign : trimmed
        guard let resolvedActivator, !resolvedActivator.isEmpty else {
            throw POTAIntentError.notSignedIn
        }
        let resolvedSpotter = AuthManager.shared.callsign ?? resolvedActivator
        let resolvedRef     = reference.trimmingCharacters(in: .whitespaces).uppercased()

        guard let url = URL(string: "https://api.pota.app/spot") else {
            throw POTAIntentError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "Authorization")

        var body: [String: String] = [
            "activator": resolvedActivator,
            "spotter":   resolvedSpotter,
            "reference": resolvedRef,
            "frequency": String(frequencyKHz),
            "mode":      mode.rawValue,
            "source":    "iOS",
        ]
        if let comment, !comment.isEmpty { body["comments"] = comment }

        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["message"]
                      ?? "Failed to post spot"
            throw POTAIntentError.apiError(msg)
        }

        // Verify the spot appears on pota.app — retries once after a delay
        let htmlState = await POTAHTMLProbe.fetchAndCheck(callsign: resolvedActivator)
        let result = "Spotted \(resolvedActivator) at \(resolvedRef) on \(frequencyKHz) kHz \(mode.rawValue). \(htmlState.displayMessage)"
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

// MARK: - Shortcuts provider

struct POTAShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetCurrentQSOsIntent(),
            phrases: [
                "How many Q.S.O.s do I have in \(.applicationName)",
                "Get my P.O.T.A. Q.S.O. count in \(.applicationName)",
                "Check my \(.applicationName) contacts",
            ],
            shortTitle: "P.O.T.A. Q.S.O. Count",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: GetNextAwardProgressIntent(),
            phrases: [
                "How close am I to my next P.O.T.A. award in \(.applicationName)",
                "Check my \(.applicationName) award progress",
                "What's my next \(.applicationName) award",
            ],
            shortTitle: "Next Award Progress",
            systemImageName: "rosette"
        )
        AppShortcut(
            intent: GetRepeatOffenderParksIntent(),
            phrases: [
                "Show my repeat offender parks in \(.applicationName)",
                "Which parks have I visited most in \(.applicationName)",
                "List my top \(.applicationName) parks",
            ],
            shortTitle: "Repeat Offender Parks",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: GetLiveSpotsIntent(),
            phrases: [
                "Show live P.O.T.A. spots in \(.applicationName)",
                "Get current spots in \(.applicationName)",
                "What's active on P.O.T.A. in \(.applicationName)",
            ],
            shortTitle: "Live POTA Spots",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: FilterSpotsIntent(),
            phrases: [
                "Filter P.O.T.A. spots in \(.applicationName)",
                "Search spots by band in \(.applicationName)",
                "Find P.O.T.A. spots in \(.applicationName)",
            ],
            shortTitle: "Filter POTA Spots",
            systemImageName: "line.3.horizontal.decrease"
        )
        AppShortcut(
            intent: PostSpotIntent(),
            phrases: [
                "Self spot in \(.applicationName)",
                "Post a P.O.T.A. spot in \(.applicationName)",
                "Spot an activator in \(.applicationName)",
            ],
            shortTitle: "Post a POTA Spot",
            systemImageName: "dot.radiowaves.left.and.right.circle"
        )
    }
}
