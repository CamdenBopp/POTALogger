import SwiftUI
import Charts
import PDFKit

// MARK: - Band chart models

struct BandStat: Codable, Hashable {
    let band: String
    let mode: String
    let count: Int
}

// MARK: - Award models

struct ParksProgress: Codable {
    let numParks: Int?
    let nextAwardLevel: Int?
    let completedPct: Double?
}

struct ShiftProgress: Codable {
    let userId: Int?
    let contacts: Int?
    let nextAwardLevel: Int?
    let completedPct: Double?
}

struct DXEntityProgress: Codable {
    let numEntities: Int?
    let nextAwardLevel: Int?
    let completedPct: Double?
}

struct P2PProgress: Codable {
    let contacts: Int?
}

struct EarnedAward: Codable, Identifiable {
    let activeCallsign: String
    let dateGranted: String
    let awardName: String
    let awardDescription: String
    let endorsements: String?
    /// The badge level (e.g. 100 / 500 QSOs) — distinguishes certificate variants at the
    /// authenticated download endpoint. POTA sends this as a JSON number or string depending
    /// on the award, so it's decoded leniently and normalized to a string.
    let badgeNum: String?
    var id: String { "\(awardName)-\(dateGranted)" }

    enum CodingKeys: String, CodingKey {
        case activeCallsign, dateGranted, awardName, awardDescription, endorsements, badgeNum
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeCallsign   = try c.decode(String.self, forKey: .activeCallsign)
        dateGranted      = try c.decode(String.self, forKey: .dateGranted)
        awardName        = try c.decode(String.self, forKey: .awardName)
        awardDescription = try c.decode(String.self, forKey: .awardDescription)
        endorsements     = try c.decodeIfPresent(String.self, forKey: .endorsements)
        if let s = try? c.decode(String.self, forKey: .badgeNum) {
            badgeNum = s
        } else if let n = try? c.decode(Int.self, forKey: .badgeNum) {
            badgeNum = String(n)
        } else {
            badgeNum = nil
        }
    }
}

struct StateProgress: Codable, Identifiable {
    let locationId: Int
    let locationDesc: String
    let locationName: String
    var id: Int { locationId }
}

struct AllRefsProgress: Codable, Identifiable {
    let locationId: Int
    let locationName: String
    let locationDesc: String
    let numParksActivated: Int
    let numParksAvailable: Int
    let toGo: Int
    var id: Int { locationId }
}

struct RepeatOffender: Codable, Identifiable {
    let reference: String
    let name: String
    let parktypeDesc: String
    let contacts: Int
    var id: String { reference }
}

struct MultibandPark: Codable, Identifiable {
    let reference: String
    let name: String
    let bands: Int
    let bandlist: String
    var id: String { reference }
}

// MARK: - Cache

private struct CachedAwardsData: Codable {
    var callsign: String?
    var userId: Int?
    var hunterParks: ParksProgress?
    var activatorParks: ParksProgress?
    var hunterLateShift: ShiftProgress?
    var hunterEarlyShift: ShiftProgress?
    var activatorLateShift: ShiftProgress?
    var activatorEarlyShift: ShiftProgress?
    var hunterDXEntity: DXEntityProgress?
    var activatorP2P: P2PProgress?
    var earnedAwards: [EarnedAward]
    var hunterStates: [StateProgress]
    var activatorStates: [StateProgress]
    var hunterAllRefs: [AllRefsProgress]
    var activatorAllRefs: [AllRefsProgress]
    var hunterRepeatOffender: [RepeatOffender]
    var hunterMultiband: [MultibandPark]
    var activatorBandStats: [BandStat]?
    var hunterBandStats: [BandStat]?
}

// MARK: - Logbook band-stats decoder
//
// Primary:  GET /user/stats/activator/band  →  [{band, mode, count}]
//           GET /user/stats/hunter/band     →  [{band, mode, count}]
// Fallback: /user/logbook paginated, tallying band+mode per QSO entry.

private struct LogbookPageResponse: Decodable {
    let entries: [LogbookQSOEntry]

    private enum WrapperKey: String, CodingKey { case entries, items, results }

    init(from decoder: Decoder) throws {
        if let arr = try? decoder.singleValueContainer().decode([LogbookQSOEntry].self) {
            entries = arr; return
        }
        let c = try decoder.container(keyedBy: WrapperKey.self)
        entries = (try? c.decode([LogbookQSOEntry].self, forKey: .entries))
               ?? (try? c.decode([LogbookQSOEntry].self, forKey: .items))
               ?? (try? c.decode([LogbookQSOEntry].self, forKey: .results))
               ?? []
    }
}

private struct LogbookQSOEntry: Decodable {
    let band: String?
    let mode: String?
}

// MARK: - View Model

@Observable
final class AwardsViewModel {
    var callsign: String?
    /// POTA user id, recovered from the shift-progress responses. Required to build the
    /// authenticated high-resolution certificate download URL.
    var userId: Int?
    var hunterParks: ParksProgress?
    var activatorParks: ParksProgress?
    var hunterLateShift: ShiftProgress?
    var hunterEarlyShift: ShiftProgress?
    var activatorLateShift: ShiftProgress?
    var activatorEarlyShift: ShiftProgress?
    var hunterDXEntity: DXEntityProgress?
    var activatorP2P: P2PProgress?
    var earnedAwards: [EarnedAward] = []
    var hunterStates: [StateProgress] = []
    var activatorStates: [StateProgress] = []
    var hunterAllRefs: [AllRefsProgress] = []
    var activatorAllRefs: [AllRefsProgress] = []
    var hunterRepeatOffender: [RepeatOffender] = []
    var hunterMultiband: [MultibandPark] = []
    var activatorBandStats: [BandStat] = []
    var hunterBandStats: [BandStat] = []
    var isLoading = false
    var isRefreshing = false

    private let base = "https://api.pota.app"
    private static var cacheURL: URL {
        URL.cachesDirectory.appending(path: "awards_cache_v2.json")
    }

    // MARK: Cache

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func loadCache() -> CachedAwardsData? {
        guard let data = try? Data(contentsOf: Self.cacheURL) else { return nil }
        return try? JSONDecoder().decode(CachedAwardsData.self, from: data)
    }

    private func applyCache(_ c: CachedAwardsData) {
        callsign             = c.callsign
        userId               = c.userId
        hunterParks          = c.hunterParks
        activatorParks       = c.activatorParks
        hunterLateShift      = c.hunterLateShift
        hunterEarlyShift     = c.hunterEarlyShift
        activatorLateShift   = c.activatorLateShift
        activatorEarlyShift  = c.activatorEarlyShift
        hunterDXEntity       = c.hunterDXEntity
        activatorP2P         = c.activatorP2P
        earnedAwards         = c.earnedAwards
        hunterStates         = c.hunterStates
        activatorStates      = c.activatorStates
        hunterAllRefs        = c.hunterAllRefs
        activatorAllRefs     = c.activatorAllRefs
        hunterRepeatOffender = c.hunterRepeatOffender
        hunterMultiband      = c.hunterMultiband
        activatorBandStats   = c.activatorBandStats ?? []
        hunterBandStats      = c.hunterBandStats    ?? []
    }

    private func saveCache() {
        let c = CachedAwardsData(
            callsign:            callsign,
            userId:              userId,
            hunterParks:         hunterParks,
            activatorParks:      activatorParks,
            hunterLateShift:     hunterLateShift,
            hunterEarlyShift:    hunterEarlyShift,
            activatorLateShift:  activatorLateShift,
            activatorEarlyShift: activatorEarlyShift,
            hunterDXEntity:      hunterDXEntity,
            activatorP2P:        activatorP2P,
            earnedAwards:        earnedAwards,
            hunterStates:        hunterStates,
            activatorStates:     activatorStates,
            hunterAllRefs:       hunterAllRefs,
            activatorAllRefs:    activatorAllRefs,
            hunterRepeatOffender: hunterRepeatOffender,
            hunterMultiband:     hunterMultiband,
            activatorBandStats:  activatorBandStats,
            hunterBandStats:     hunterBandStats
        )
        if let data = try? JSONEncoder().encode(c) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    func load() async {
        // Wait for the startup refresh-token exchange to finish so we always hold a fresh
        // token. Without this, cold-launch API calls race against the token refresh and
        // silently receive 401s, producing empty parks/states lists.
        await AuthManager.shared.startupTask?.value
        guard let token = AuthManager.shared.idToken ?? AuthManager.shared.accessToken else { return }

        if let cached = loadCache() {
            applyCache(cached)
            isRefreshing = true
        } else {
            isLoading = true
        }
        defer {
            isLoading = false
            isRefreshing = false
        }

        async let hp   = get(ParksProgress.self,     "/user/award/progress/hunter/parks",              token)
        async let ap   = get(ParksProgress.self,     "/user/award/progress/activator/parks",           token)
        async let hls  = get(ShiftProgress.self,     "/user/award/progress/hunter/lateshift",          token)
        async let hes  = get(ShiftProgress.self,     "/user/award/progress/hunter/earlyshift",         token)
        async let als  = get(ShiftProgress.self,     "/user/award/progress/activator/lateshift",       token)
        async let aes  = get(ShiftProgress.self,     "/user/award/progress/activator/earlyshift",      token)
        async let hd   = get(DXEntityProgress.self,  "/user/award/progress/hunter/dxentity",           token)
        async let p2p  = get(P2PProgress.self,       "/user/award/progress/activator/p2p",             token)
        async let ea   = getArray(EarnedAward.self,      "/user/award/earned",                         token)
        async let hs   = getArray(StateProgress.self,    "/user/award/progress/hunter/usstates",       token)
        async let as_  = getArray(StateProgress.self,    "/user/award/progress/activator/usstates",    token)
        async let har  = getArray(AllRefsProgress.self,  "/user/award/progress/hunter/allrefs",        token)
        async let aar  = getArray(AllRefsProgress.self,  "/user/award/progress/activator/allrefs",     token)
        async let hro  = getArray(RepeatOffender.self,   "/user/award/progress/hunter/repeatoffender", token)
        async let hmb  = getArray(MultibandPark.self,    "/user/award/progress/hunter/n1ccmultiband",  token)

        hunterParks          = await hp
        activatorParks       = await ap
        hunterLateShift      = await hls
        hunterEarlyShift     = await hes
        activatorLateShift   = await als
        activatorEarlyShift  = await aes
        userId = hunterLateShift?.userId ?? hunterEarlyShift?.userId
              ?? activatorLateShift?.userId ?? activatorEarlyShift?.userId ?? userId
        hunterDXEntity       = await hd
        activatorP2P         = await p2p
        earnedAwards         = await ea
        let resolvedCallsign = earnedAwards.first?.activeCallsign
        callsign             = resolvedCallsign ?? AuthManager.shared.callsign
        if let resolvedCallsign { AuthManager.shared.callsign = resolvedCallsign }
        hunterStates         = await hs
        activatorStates      = await as_
        hunterAllRefs        = await har
        activatorAllRefs     = await aar
        hunterRepeatOffender = await hro
        hunterMultiband      = await hmb

        // Band stats: primary endpoints, logbook fallback.
        async let activatorBands = getArray(BandStat.self, "/user/stats/activator/band", token)
        async let hunterBands    = getArray(BandStat.self, "/user/stats/hunter/band",    token)
        let ab = await activatorBands
        let hb = await hunterBands
        activatorBandStats = ab.isEmpty ? await fetchLogbookBandStats(token: token, queryParam: "activatorOnly=1") : ab
        hunterBandStats    = hb.isEmpty ? await fetchLogbookBandStats(token: token, queryParam: "hunterOnly=1")    : hb

        saveCache()
    }

    /// Fallback: paginates /user/logbook, tallying band+mode per QSO entry.
    private func fetchLogbookBandStats(token: String, queryParam: String) async -> [BandStat] {
        var tally: [String: Int] = [:]
        for pageNum in 1...200 {
            guard let url = URL(string: "\(base)/user/logbook?\(queryParam)&page=\(pageNum)&size=100") else { break }
            var req = URLRequest(url: url)
            req.setValue(token, forHTTPHeaderField: "Authorization")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let page = try? JSONDecoder().decode(LogbookPageResponse.self, from: data)
            else { break }
            for entry in page.entries {
                guard let band = entry.band, let mode = entry.mode,
                      !band.isEmpty, !mode.isEmpty else { continue }
                tally["\(band.uppercased())|\(mode.uppercased())", default: 0] += 1
            }
            if page.entries.count < 100 { break }
        }
        return tally.compactMap { key, count -> BandStat? in
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return BandStat(band: String(parts[0]), mode: String(parts[1]), count: count)
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ token: String) async -> T? {
        guard let url = URL(string: "\(base)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func getArray<T: Decodable>(_ type: T.Type, _ path: String, _ token: String) async -> [T] {
        guard let url = URL(string: "\(base)\(path)") else { return [] }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
}

// MARK: - Tab

private enum AwardsTab: String, CaseIterable, Identifiable {
    case stats  = "My Stats"
    case awards = "My Awards"
    var id: String { rawValue }
}

// MARK: - Awards View

struct AwardsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm = AwardsViewModel()
    @State private var selectedTab: AwardsTab = .stats
    @State private var galleryRequest: AwardGalleryRequest?
    @AppStorage("awards.showPreview") private var showAwardsPreview = true

    var body: some View {
        VStack(spacing: 0) {
            // Custom header — avoids NavigationStack inside sheet causing duplicate toolbar
            HStack {
                Text(vm.callsign ?? "Awards")
                    .font(.headline)
                if vm.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.75)
                        .transition(.opacity)
                }
                Spacer()
                Button("Sign Out", role: .destructive) {
                    AwardsViewModel.clearCache()
                    AuthManager.shared.signOut()
                    dismiss()
                }
                .font(.subheadline)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)

            Picker("Section", selection: $selectedTab) {
                ForEach(AwardsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if vm.isLoading {
                Spacer()
                ProgressView("Loading awards…")
                Spacer()
            } else {
                switch selectedTab {
                case .stats:  statsTabBody
                case .awards: awardsTabBody
                }
            }
        }
        .task { await vm.load() }
        .fullScreenCover(item: $galleryRequest) { request in
            AwardCertificateGallery(awards: vm.earnedAwards, startIndex: request.index, userId: vm.userId) {
                galleryRequest = nil
            }
        }
    }

    // MARK: Tab bodies

    private var awardsTabBody: some View {
        ScrollView {
            VStack(spacing: 16) {
                profileHeader
                if !vm.earnedAwards.isEmpty { earnedSection }
                hunterSection
                activatorSection
            }
            .padding()
        }
    }

    @ViewBuilder
    private var statsTabBody: some View {
        ScrollView {
            VStack(spacing: 16) {
                profileHeader
                if vm.activatorBandStats.isEmpty && vm.hunterBandStats.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No band stats yet")
                            .font(.headline)
                        Text("Once POTA reports per-band QSOs for your callsign, your activator and hunter breakdowns will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    BandsChartsSection(
                        activatorStats: vm.activatorBandStats,
                        hunterStats: vm.hunterBandStats
                    )
                }
            }
            .padding()
        }
    }

    // MARK: Profile header

    private var profileHeader: some View {
        HStack(spacing: 16) {
            ProfileAvatar(
                userInfo: AuthManager.shared.userInfo,
                size: 56,
                overrideURL: AuthManager.shared.gravatarURL
            )
            VStack(alignment: .leading, spacing: 3) {
                if let cs = vm.callsign {
                    Text(cs).font(.title2.weight(.bold))
                }
                if let name = AuthManager.shared.userInfo?.name {
                    Text(name).font(.subheadline).foregroundStyle(.secondary)
                }
                if let email = AuthManager.shared.userInfo?.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Earned awards

    private var earnedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Earned Awards").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(vm.earnedAwards.enumerated()), id: \.element.id) { index, award in
                        if showAwardsPreview {
                            AwardPreviewChip(award: award, userId: vm.userId) {
                                galleryRequest = AwardGalleryRequest(index: index)
                            }
                        } else {
                            AwardRosetteChip(award: award, userId: vm.userId) {
                                galleryRequest = AwardGalleryRequest(index: index)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: Hunter section

    private var hunterSection: some View {
        CardSection(title: "Hunter", icon: "binoculars.fill") {
            if let p = vm.hunterParks {
                ProgressCard(title: "Parks", value: p.numParks,
                             next: p.nextAwardLevel, pct: p.completedPct)
            }
            if let d = vm.hunterDXEntity {
                ProgressCard(title: "DX Entities", value: d.numEntities,
                             next: d.nextAwardLevel, pct: d.completedPct)
            }
            if let s = vm.hunterEarlyShift {
                ProgressCard(title: "Early Shift", value: s.contacts,
                             next: s.nextAwardLevel, pct: s.completedPct, unit: "QSOs")
            }
            if let s = vm.hunterLateShift {
                ProgressCard(title: "Late Shift", value: s.contacts,
                             next: s.nextAwardLevel, pct: s.completedPct, unit: "QSOs")
            }
            StateGrid(title: "US States Hunted", earnedStates: vm.hunterStates)
            if !vm.hunterRepeatOffender.isEmpty {
                RepeatOffenderList(parks: vm.hunterRepeatOffender)
            }
            if !vm.hunterMultiband.isEmpty {
                MultibandList(parks: vm.hunterMultiband)
            }
            if !vm.hunterAllRefs.isEmpty {
                RegionProgressList(title: "Progress by Region", refs: vm.hunterAllRefs)
            }
        }
    }

    // MARK: Activator section

    private var activatorSection: some View {
        CardSection(title: "Activator", icon: "antenna.radiowaves.left.and.right") {
            if let p = vm.activatorParks {
                ProgressCard(title: "Parks", value: p.numParks,
                             next: p.nextAwardLevel, pct: p.completedPct)
            }
            if let p = vm.activatorP2P, let c = p.contacts, c > 0 {
                LabeledValue(label: "Park-to-Park", value: "\(c) QSOs")
            }
            if let s = vm.activatorEarlyShift, (s.contacts ?? 0) > 0 || (s.nextAwardLevel ?? 0) > 0 {
                ProgressCard(title: "Early Shift", value: s.contacts,
                             next: s.nextAwardLevel, pct: s.completedPct, unit: "QSOs")
            }
            if let s = vm.activatorLateShift, (s.contacts ?? 0) > 0 || (s.nextAwardLevel ?? 0) > 0 {
                ProgressCard(title: "Late Shift", value: s.contacts,
                             next: s.nextAwardLevel, pct: s.completedPct, unit: "QSOs")
            }
            StateGrid(title: "US States Activated", earnedStates: vm.activatorStates)
            if !vm.activatorAllRefs.isEmpty {
                RegionProgressList(title: "Progress by Region", refs: vm.activatorAllRefs)
            }
        }
    }
}

// MARK: - Bands chart section

private let hfBandOrder:  [String] = ["160M","80M","60M","40M","30M","20M","17M","15M","12M","10M"]
private let vhfBandOrder: [String] = ["6M","4M","2M","1.25M","70CM"]

private enum ChartRole: String, CaseIterable, Identifiable {
    case activator = "Activator"
    case hunter    = "Hunter"
    var id: String { rawValue }
}

private enum BandMode: String, CaseIterable {
    case cw    = "CW"
    case data  = "DATA"
    case phone = "PHONE"

    var color: Color {
        switch self {
        case .cw:    return Color(hue: 0.60, saturation: 0.75, brightness: 0.90)
        case .data:  return Color(hue: 0.37, saturation: 0.72, brightness: 0.78)
        case .phone: return Color(hue: 0.08, saturation: 0.85, brightness: 0.95)
        }
    }
}

private struct BandChartPoint: Identifiable {
    let id = UUID()
    let band: String
    let mode: String
    let count: Int
}

struct BandsChartsSection: View {
    let activatorStats: [BandStat]
    let hunterStats: [BandStat]

    @State private var role: ChartRole = .hunter

    private var stats: [BandStat] { role == .activator ? activatorStats : hunterStats }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Role", selection: $role) {
                ForEach(ChartRole.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.segmented)

            BandsChartCard(title: "HF Bands",        stats: stats, bandOrder: hfBandOrder)
            BandsChartCard(title: "VHF / UHF Bands", stats: stats, bandOrder: vhfBandOrder)

            BandsModeLegend()
        }
    }
}

private struct BandsChartCard: View {
    let title: String
    let stats: [BandStat]
    let bandOrder: [String]

    private static let slotWidth: CGFloat = 56
    private static let barWidth:  CGFloat = 9

    private var activeBands: [String] {
        let withData = Set(stats.compactMap { s -> String? in
            let b = normalizeBand(s.band)
            guard bandOrder.contains(b), s.count > 0 else { return nil }
            return b
        })
        return bandOrder.filter { withData.contains($0) }
    }

    private var chartData: [BandChartPoint] {
        var lookup: [String: Int] = [:]
        for s in stats {
            lookup["\(normalizeBand(s.band))|\(normalizeMode(s.mode))", default: 0] += s.count
        }
        return activeBands.flatMap { bandKey in
            BandMode.allCases.compactMap { mode -> BandChartPoint? in
                let count = lookup["\(bandKey)|\(mode.rawValue)"] ?? 0
                guard count > 0 else { return nil }
                return BandChartPoint(band: displayLabel(bandKey),
                                      mode: mode.rawValue, count: count)
            }
        }
    }

    private var yMax: Int {
        max(niceUpperBound(chartData.map(\.count).max() ?? 0), 10)
    }

    private var chartWidth: CGFloat {
        CGFloat(max(activeBands.count, 1)) * Self.slotWidth + 24
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)

            if activeBands.isEmpty {
                Text("No contacts on these bands yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Chart(chartData) { point in
                        BarMark(
                            x: .value("Band", point.band),
                            y: .value("QSOs", point.count),
                            width: .fixed(Self.barWidth)
                        )
                        .position(by: .value("Mode", point.mode))
                        .foregroundStyle(color(for: point.mode))
                        .accessibilityLabel("\(point.band) \(point.mode)")
                        .accessibilityValue("\(point.count) QSOs")
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisValueLabel(centered: true) {
                                if let label = value.as(String.self) {
                                    Text(label)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading,
                                  values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.4, dash: [4, 3]))
                            AxisValueLabel {
                                if let n = value.as(Int.self), n > 0 {
                                    Text("\(n)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .chartYScale(domain: 0...yMax)
                    .chartLegend(.hidden)
                    .frame(width: chartWidth, height: 220)
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func normalizeBand(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        switch s {
        case "70CM", "70 CM": return "70CM"
        case "1.25M", "1.25 M", "125CM": return "1.25M"
        default: return s
        }
    }

    private func normalizeMode(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
        case "SSB","USB","LSB","AM","FM","PHONE": return "PHONE"
        case "FT8","FT4","RTTY","PSK","PSK31","JT65","JT9","DIGITAL","DIGI": return "DATA"
        case "CW": return "CW"
        default: return "DATA"
        }
    }

    private func color(for mode: String) -> Color {
        switch mode {
        case BandMode.cw.rawValue:    return BandMode.cw.color
        case BandMode.phone.rawValue: return BandMode.phone.color
        default:                      return BandMode.data.color
        }
    }

    private func displayLabel(_ bandKey: String) -> String {
        switch bandKey {
        case "70CM":  return "70cm"
        case "1.25M": return "1.25m"
        default:      return bandKey.replacingOccurrences(of: "M", with: "m")
        }
    }

    private func niceUpperBound(_ value: Int) -> Int {
        guard value > 0 else { return 10 }
        let exp = floor(log10(Double(value)))
        let mag = pow(10.0, exp)
        let norm = Double(value) / mag
        let rounded: Double = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 5 ? 5 : 10
        return Int(rounded * mag)
    }
}

private struct BandsModeLegend: View {
    var body: some View {
        HStack(spacing: 18) {
            ForEach(BandMode.allCases, id: \.self) { mode in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(mode.color)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    Text(mode.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Supporting award views

private struct CardSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ProgressCard: View {
    let title: String
    let value: Int?
    let next: Int?
    let pct: Double?
    var unit = "parks"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                if let v = value, let n = next {
                    Text("\(v) / \(n) \(unit)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if let v = value {
                    Text("\(v) \(unit)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let pct {
                ProgressView(value: min(pct / 100.0, 1.0))
                    .tint(pct >= 100 ? .green : .blue)
            }
        }
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.subheadline.weight(.medium))
            Spacer()
            Text(value).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

private struct AwardPreviewChip: View {
    let award: EarnedAward
    let userId: Int?
    /// Opens the shared swipeable certificate gallery at this award's position.
    let onOpen: () -> Void
    @State private var shareURL: URL?

    /// Thumbnail shown inside the chip.
    private var thumbnailURL: URL? { AwardCertificate.thumbnailURL(for: award) }

    var body: some View {
        Button {
            onOpen()
        } label: {
            VStack(spacing: 4) {
                AsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Image(systemName: "rosette")
                            .font(.title2)
                            .foregroundStyle(.yellow)
                    }
                }
                .frame(width: 88, height: 64)

                Text(award.awardName)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 88)
                if let e = award.endorsements, !e.isEmpty {
                    Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 88)
                }
                Text(String(award.dateGranted.prefix(10)))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        // VoiceOver rotor: Activate (default) opens QuickLook; Share opens the system share sheet.
        .accessibilityAction(named: "Share") {
            Task { await openShareSheet() }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL {
                ActivityView(url: url)
            }
        }
    }

    private func openShareSheet() async {
        if let pdf = await AwardCertificate.ensurePDF(for: award, userId: userId) { shareURL = pdf }
    }
}

private struct AwardRosetteChip: View {
    let award: EarnedAward
    let userId: Int?
    /// Opens the shared swipeable certificate gallery at this award's position.
    let onOpen: () -> Void
    @State private var shareURL: URL?

    var body: some View {
        Button {
            onOpen()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "rosette")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                    .frame(width: 88, height: 28)
                Text(award.awardName)
                    .font(.caption2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 88)
                if let e = award.endorsements, !e.isEmpty {
                    Text(e)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 88)
                }
                Text(String(award.dateGranted.prefix(10)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAction(named: "Share") {
            Task { await openShareSheet() }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL {
                ActivityView(url: url)
            }
        }
    }

    private func openShareSheet() async {
        if let pdf = await AwardCertificate.ensurePDF(for: award, userId: userId) { shareURL = pdf }
    }
}

// MARK: - Certificate PDF pipeline

/// Shared certificate download + PDF rendering, used by the award chips (for sharing)
/// and the swipeable QuickLook gallery. Certificates are cached on disk keyed by award
/// name so repeated opens skip the network round-trip.
enum AwardCertificate {
    static func thumbnailURL(for award: EarnedAward) -> URL? {
        let encoded = award.awardName
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? award.awardName
        return URL(string: "https://static.pota.app/v0/certificate/thumbnails/\(encoded).png")
    }

    /// Full-size certificate — one directory level up from thumbnails.
    static func fullSizeURL(for award: EarnedAward) -> URL? {
        let encoded = award.awardName
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? award.awardName
        return URL(string: "https://static.pota.app/v0/certificate/\(encoded).png")
    }

    /// Stable cache path keyed to the award name so repeated taps skip the download.
    /// `hiRes` selects a separate file so the real (authenticated) certificate never
    /// collides with the low-resolution thumbnail-wrapped fallback.
    static func cachedPDFURL(for award: EarnedAward, hiRes: Bool = false) -> URL? {
        let safe = award.awardName
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "cert"
        let prefix = hiRes ? "pota_hires_" : "pota_cert_"
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("\(prefix)\(safe).pdf")
    }

    /// The authenticated advanced-certificate endpoint the POTA site itself uses. It returns
    /// JSON `{ "url": … }` pointing at the real, full-resolution certificate (a 960×720 PDF).
    /// Mirrors the site's parameter order: userId / awardName (spaces→`+`) / badge / endorsement /
    /// extra, defaulting the optional slots to `0`.
    static func advancedCertificateURL(userId: Int, award: EarnedAward) -> URL? {
        let name = award.awardName
            .replacingOccurrences(of: " ", with: "+")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? award.awardName
        let badge = (award.badgeNum.map { !$0.isEmpty } ?? false) ? award.badgeNum! : "0"
        let endorsement: String = {
            guard let e = award.endorsements, !e.isEmpty else { return "0" }
            return e.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "0"
        }()
        return URL(string: "https://api.pota.app/award/advancedcertificate/\(userId)/\(name)/\(badge)/\(endorsement)/0")
    }

    private struct CertificateLink: Decodable { let url: String }

    /// Downloads and caches the real, full-resolution certificate via the authenticated
    /// endpoint. Returns the local PDF URL, or `nil` if the user id / token is missing or the
    /// endpoint fails — callers fall back to ``ensurePDF(for:userId:)``'s low-resolution wrap so
    /// the viewer always shows *something*.
    static func ensureHiResPDF(for award: EarnedAward, userId: Int?) async -> URL? {
        guard let userId else { return nil }
        if let cached = cachedPDFURL(for: award, hiRes: true),
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let token = AuthManager.shared.idToken ?? AuthManager.shared.accessToken,
              let endpoint = advancedCertificateURL(userId: userId, award: award) else { return nil }

        var req = URLRequest(url: endpoint)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let link = try? JSONDecoder().decode(CertificateLink.self, from: data),
              let fileURL = URL(string: link.url) else { return nil }

        guard let (fileData, fileResp) = try? await URLSession.shared.data(from: fileURL),
              let fileHTTP = fileResp as? HTTPURLResponse, fileHTTP.statusCode == 200,
              !fileData.isEmpty else { return nil }

        // The endpoint serves a PDF; if it ever serves a raster instead, wrap it so the
        // caller always receives a PDF.
        let pdfData: Data
        if fileData.starts(with: [0x25, 0x50, 0x44, 0x46]) {          // "%PDF"
            pdfData = fileData
        } else if let image = UIImage(data: fileData), let wrapped = pdfWrapping(image) {
            pdfData = wrapped
        } else {
            return nil
        }

        guard let dest = cachedPDFURL(for: award, hiRes: true) else { return nil }
        try? pdfData.write(to: dest, options: .atomic)
        return dest
    }

    /// Returns a certificate PDF for the award: the real full-resolution one when it can be
    /// fetched, otherwise a low-resolution PDF wrapping the thumbnail. Cached either way.
    static func ensurePDF(for award: EarnedAward, userId: Int?) async -> URL? {
        if let hiRes = await ensureHiResPDF(for: award, userId: userId) { return hiRes }
        if let cached = cachedPDFURL(for: award), FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let candidates = [fullSizeURL(for: award), thumbnailURL(for: award)].compactMap { $0 }
        for remote in candidates {
            if let pdf = await fetchAsPDF(remote, award: award) { return pdf }
        }
        return nil
    }

    /// Downloads `remote`, wraps it in a single-page US Letter landscape PDF, caches it, and
    /// returns the local URL. Used only as the low-resolution fallback.
    private static func fetchAsPDF(_ remote: URL, award: EarnedAward) async -> URL? {
        guard let (data, response) = try? await URLSession.shared.data(from: remote),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty,
              let image = UIImage(data: data),
              let pdfData = pdfWrapping(image),
              let dest = cachedPDFURL(for: award)
        else { return nil }
        try? pdfData.write(to: dest, options: .atomic)
        return dest
    }

    /// Renders `image` into a single-page US Letter landscape PDF (792 × 612 pt — the geometry
    /// POTA uses for its real certificates), returning the PDF data.
    static func pdfWrapping(_ image: UIImage) -> Data? {
        let pageRect = CGRect(origin: .zero, size: CGSize(width: 792, height: 612))
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            let s = image.size
            let scale = min(pageRect.width / s.width, pageRect.height / s.height)
            let drawSize = CGSize(width: s.width * scale, height: s.height * scale)
            let drawRect = CGRect(
                x: (pageRect.width  - drawSize.width)  / 2,
                y: (pageRect.height - drawSize.height) / 2,
                width:  drawSize.width,
                height: drawSize.height
            )
            image.draw(in: drawRect)
        }
    }
}

// MARK: - Swipeable certificate gallery

/// Identifies which award the gallery should open on. The index is into the ordered
/// `earnedAwards` array, so the gallery's left/right swipe walks the same list.
struct AwardGalleryRequest: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Full-screen, swipeable certificate viewer — the Photos / Books / iMessage style of
/// paging file-to-file. Built with a paged `TabView` so it carries none of
/// QuickLook's chrome (notably its transient "x of N" page indicator); the only controls
/// are a Done button and a per-certificate Share button.
struct AwardCertificateGallery: View {
    let awards: [EarnedAward]
    let userId: Int?
    let onDone: () -> Void
    private let startIndex: Int

    /// The merged, multi-page PDF (one page per award) once every certificate has been fetched.
    @State private var document: PDFDocument?
    @State private var loadFailed = false
    /// The page currently on screen; kept in sync by the pager so the title / Share act on it.
    @State private var currentIndex: Int
    @State private var shareURL: URL?

    init(awards: [EarnedAward], startIndex: Int, userId: Int?, onDone: @escaping () -> Void) {
        self.awards = awards
        self.userId = userId
        self.onDone = onDone
        self.startIndex = startIndex
        _currentIndex = State(initialValue: startIndex)
    }

    private var currentAward: EarnedAward? {
        awards.indices.contains(currentIndex) ? awards[currentIndex] : nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let document {
                    CertificatePagerView(document: document,
                                         startIndex: startIndex,
                                         currentIndex: $currentIndex)
                        .ignoresSafeArea(edges: .bottom)
                } else if loadFailed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text("Couldn't load certificate").font(.subheadline)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(currentAward?.awardName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { onDone() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if let award = currentAward,
                               let pdf = await AwardCertificate.ensurePDF(for: award, userId: userId) {
                                shareURL = pdf
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                    .disabled(currentAward == nil)
                }
            }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
                if let url = shareURL {
                    ActivityView(url: url)
                }
            }
        }
        .task { await buildDocument() }
    }

    /// Fetches every award's certificate PDF concurrently (real full-resolution where possible,
    /// low-resolution thumbnail wrap otherwise) and merges them into one document, exactly one
    /// page per award so the page index stays aligned with `awards`.
    private func buildDocument() async {
        guard document == nil else { return }
        let awardsLocal = awards
        let uid = userId

        let urls: [URL?] = await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, award) in awardsLocal.enumerated() {
                group.addTask { (index, await AwardCertificate.ensurePDF(for: award, userId: uid)) }
            }
            var out = [URL?](repeating: nil, count: awardsLocal.count)
            for await (index, url) in group { out[index] = url }
            return out
        }

        let merged = PDFDocument()
        for (index, award) in awardsLocal.enumerated() {
            let page: PDFPage? = {
                if let url = urls[index], let doc = PDFDocument(url: url),
                   let first = doc.page(at: 0)?.copy() as? PDFPage {
                    return first
                }
                return Self.placeholderPage(for: award)
            }()
            if let page { merged.insert(page, at: merged.pageCount) }
        }

        if merged.pageCount > 0 {
            document = merged
        } else {
            loadFailed = true
        }
    }

    /// A dark single-page PDF standing in for a certificate that failed to download, so the
    /// pager keeps one page per award and the titles line up.
    private static func placeholderPage(for award: EarnedAward) -> PDFPage? {
        let rect = CGRect(x: 0, y: 0, width: 792, height: 612)
        let data = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            ctx.beginPage()
            UIColor.black.setFill()
            ctx.cgContext.fill(rect)
            let text = "Certificate unavailable\n\(award.awardName)" as NSString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white.withAlphaComponent(0.7),
                .font: UIFont.systemFont(ofSize: 30),
                .paragraphStyle: style,
            ]
            let bounds = text.boundingRect(
                with: CGSize(width: rect.width - 80, height: rect.height),
                options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
            text.draw(in: CGRect(x: 40, y: (rect.height - bounds.height) / 2,
                                 width: rect.width - 80, height: bounds.height),
                      withAttributes: attrs)
        }
        return PDFDocument(data: data)?.page(at: 0)
    }
}

/// A `PDFView` configured like Books / Photos: one certificate per screen, horizontal paging,
/// and per-page pinch / double-tap zoom. Because PDFKit owns the paging *and* the zoom, a swipe
/// while zoomed pans the certificate and only turns the page at the edge — the behaviour the old
/// SwiftUI `TabView` couldn't provide.
private struct CertificatePagerView: UIViewRepresentable {
    let document: PDFDocument
    let startIndex: Int
    @Binding var currentIndex: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true, withViewOptions:
            [UIPageViewController.OptionsKey.interPageSpacing: 20])
        view.autoScales = true
        view.maxScaleFactor = 6
        view.backgroundColor = .black
        view.document = document
        if let page = document.page(at: startIndex) {
            view.go(to: page)
        }
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(currentIndex: $currentIndex, document: document) }

    final class Coordinator {
        @Binding var currentIndex: Int
        let document: PDFDocument

        init(currentIndex: Binding<Int>, document: PDFDocument) {
            _currentIndex = currentIndex
            self.document = document
        }

        func attach(to view: PDFView) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged, object: view)
        }

        // PDFKit posts this on the main thread as the user pages, so the binding can be
        // updated directly.
        @objc private func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            currentIndex = index
        }
    }
}

/// Thin `UIViewControllerRepresentable` wrapper around `UIActivityViewController`.
private struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private struct StateGrid: View {
    let title: String
    let earnedStates: [StateProgress]

    private static let allStates = [
        "AK","AL","AR","AZ","CA","CO","CT","DC","DE","FL",
        "GA","HI","IA","ID","IL","IN","KS","KY","LA","MA",
        "MD","ME","MI","MN","MO","MS","MT","NC","ND","NE",
        "NH","NJ","NM","NV","NY","OH","OK","OR","PA","RI",
        "SC","SD","TN","TX","UT","VA","VT","WA","WI","WV","WY"
    ]

    private func isEarned(_ abbr: String) -> Bool {
        earnedStates.contains { $0.locationDesc.hasSuffix("-\(abbr)") }
    }

    private let columns = [GridItem(.adaptive(minimum: 42, maximum: 52), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(earnedStates.count) / \(Self.allStates.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Self.allStates, id: \.self) { abbr in
                    let earned = isEarned(abbr)
                    Text(abbr)
                        .font(.caption2.monospaced().weight(.semibold))
                        .frame(minWidth: 36)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(earned ? Color.green.opacity(0.16) : Color.red.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(earned ? Color.green : Color.red)
                        .accessibilityLabel("\(abbr), \(earned ? "earned" : "not earned")")
                }
            }
        }
    }
}

private struct RepeatOffenderList: View {
    let parks: [RepeatOffender]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Repeat Offender").font(.subheadline.weight(.medium))
            ForEach(parks.prefix(5)) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.caption).lineLimit(1)
                        Text(p.reference).font(.caption2).foregroundStyle(.tint)
                    }
                    Spacer()
                    Text("\(p.contacts)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if parks.count > 5 {
                Text("+ \(parks.count - 5) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MultibandList: View {
    let parks: [MultibandPark]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("N1CC Multiband").font(.subheadline.weight(.medium))
            ForEach(parks) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.caption).lineLimit(1)
                        Text(p.reference).font(.caption2).foregroundStyle(.tint)
                    }
                    Spacer()
                    Text(p.bandlist).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RegionProgressList: View {
    let title: String
    let refs: [AllRefsProgress]
    @State private var expanded = false

    private struct RegionCountryGroup: Identifiable {
        let countryCode: String
        let countryName: String
        let refs: [AllRefsProgress]
        var id: String { countryCode }
    }

    private var sortedRefs: [AllRefsProgress] {
        refs.sorted {
            let countryCompare = $0.countrySortKey.localizedCaseInsensitiveCompare($1.countrySortKey)
            if countryCompare != .orderedSame { return countryCompare == .orderedAscending }

            let nameCompare = $0.locationName.localizedCaseInsensitiveCompare($1.locationName)
            if nameCompare != .orderedSame { return nameCompare == .orderedAscending }

            return $0.locationDesc.localizedCaseInsensitiveCompare($1.locationDesc) == .orderedAscending
        }
    }

    private var displayedRefs: [AllRefsProgress] {
        expanded ? sortedRefs : Array(sortedRefs.prefix(5))
    }

    private var groupedRefs: [RegionCountryGroup] {
        var groups: [RegionCountryGroup] = []
        for ref in displayedRefs {
            if let lastIndex = groups.indices.last, groups[lastIndex].countryCode == ref.countryCode {
                groups[lastIndex] = RegionCountryGroup(
                    countryCode: groups[lastIndex].countryCode,
                    countryName: groups[lastIndex].countryName,
                    refs: groups[lastIndex].refs + [ref]
                )
            } else {
                groups.append(
                    RegionCountryGroup(
                        countryCode: ref.countryCode,
                        countryName: ref.countryDisplayName,
                        refs: [ref]
                    )
                )
            }
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            ForEach(groupedRefs) { group in
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.countryName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Rectangle()
                            .fill(.tertiary)
                            .frame(height: 1)
                    }
                    .padding(.top, 8)

                    ForEach(group.refs) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(r.locationName).font(.caption)
                                Spacer()
                                Text("\(r.numParksActivated)/\(r.numParksAvailable)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(r.numParksActivated),
                                         total: Double(r.numParksAvailable))
                                .tint(.blue)
                        }
                    }
                }
            }
            if sortedRefs.count > 5 {
                Button(expanded ? "Show less" : "Show all \(sortedRefs.count) regions") {
                    expanded.toggle()
                }
                .font(.caption)
            }
        }
    }
}

private extension AllRefsProgress {
    var countryCode: String {
        let trimmed = locationDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Other" }
        if let dash = trimmed.firstIndex(of: "-") {
            return String(trimmed[..<dash])
        }
        return trimmed
    }

    var countryDisplayName: String {
        Locale.current.localizedString(forRegionCode: countryCode.uppercased()) ?? countryCode
    }

    var countrySortKey: String {
        countryCode
    }
}

// MARK: - Flow layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Previews

#Preview("Awards") {
    AwardsView()
}

#Preview("Bands — hunter rich dataset") {
    ScrollView {
        BandsChartsSection(
            activatorStats: [
                BandStat(band: "40M", mode: "CW",    count: 52),
                BandStat(band: "30M", mode: "DATA",  count: 11),
                BandStat(band: "20M", mode: "CW",    count: 28),
                BandStat(band: "20M", mode: "PHONE", count: 14),
                BandStat(band: "2M",  mode: "PHONE", count: 3),
            ],
            hunterStats: [
                BandStat(band: "10M", mode: "CW",    count: 6),
                BandStat(band: "10M", mode: "PHONE", count: 22),
                BandStat(band: "15M", mode: "CW",    count: 41),
                BandStat(band: "15M", mode: "PHONE", count: 8),
                BandStat(band: "17M", mode: "CW",    count: 12),
                BandStat(band: "17M", mode: "PHONE", count: 6),
                BandStat(band: "20M", mode: "CW",    count: 195),
                BandStat(band: "20M", mode: "PHONE", count: 148),
                BandStat(band: "30M", mode: "CW",    count: 34),
                BandStat(band: "40M", mode: "CW",    count: 235),
                BandStat(band: "40M", mode: "PHONE", count: 134),
                BandStat(band: "60M", mode: "PHONE", count: 1),
                BandStat(band: "70CM",mode: "PHONE", count: 8),
            ]
        )
        .padding()
    }
}

#Preview("Bands — sparse activator only") {
    ScrollView {
        BandsChartsSection(
            activatorStats: [
                BandStat(band: "40M", mode: "CW", count: 8),
                BandStat(band: "30M", mode: "CW", count: 2),
            ],
            hunterStats: []
        )
        .padding()
    }
}
