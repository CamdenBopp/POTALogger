import SwiftUI

// MARK: - Spot List Style

enum SpotListStyle: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case compact = "OLED"
    case cards = "Cards"

    var id: String { rawValue }
    static let storageKey = "spotListStyle"
}

enum SpotIdentityDisplay: String, CaseIterable, Identifiable {
    case none = "None"
    case flags = "Flags"
    case profiles = "Profiles"
    case both = "Both"

    var id: String { rawValue }
    static let storageKey = "spotIdentityDisplay"

    var showsFlag: Bool {
        self == .flags || self == .both
    }

    var showsProfile: Bool {
        self == .profiles || self == .both
    }
}

// MARK: - Auto Refresh

enum SpotAutoRefreshInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    var id: Int { rawValue }
    static let storageKey = "spotAutoRefreshMinutes"
    static let `default`: SpotAutoRefreshInterval = .off

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .one: return "1 minute"
        default:   return "\(rawValue) minutes"
        }
    }

    /// Seconds between automatic refreshes, or `nil` when disabled.
    var seconds: TimeInterval? {
        rawValue == 0 ? nil : TimeInterval(rawValue * 60)
    }
}

// MARK: - Filter types

enum SpotBandFilter: String, CaseIterable, Identifiable, SpotFilterOption {
    case all = "All"
    case m160 = "160M"; case m80 = "80M"; case m60 = "60M"; case m40 = "40M"
    case m30 = "30M"; case m20 = "20M"; case m17 = "17M"; case m15 = "15M"
    case m12 = "12M"; case m10 = "10M"; case m6 = "6M"; case m2 = "2M"
    case cm70 = "70CM"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var accessibilityName: String {
        switch self {
        case .all: return "All bands"
        default: return rawValue.replacingOccurrences(of: "M", with: " meters")
                                .replacingOccurrences(of: "CM", with: " centimeters")
        }
    }
}

enum SpotModeFilter: String, CaseIterable, Identifiable, SpotFilterOption {
    case all = "All"
    case cw = "CW"; case ssb = "SSB"; case ft8 = "FT8"; case ft4 = "FT4"
    case data = "DATA"; case phone = "PHONE"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var accessibilityName: String {
        switch self {
        case .all: return "All modes"
        case .cw: return "Continuous wave"
        case .ssb: return "Single sideband"
        case .ft8: return "FT8"
        case .ft4: return "FT4"
        case .data: return "Data modes"
        case .phone: return "Phone modes"
        }
    }

    func matches(_ mode: String) -> Bool {
        switch self {
        case .all: return true
        case .data: return ["FT8", "FT4", "JS8", "RTTY", "PSK31", "WSPR", "JT65", "JT9", "DATA"].contains(mode.uppercased())
        case .phone: return ["SSB", "FM", "AM", "USB", "LSB", "PHONE"].contains(mode.uppercased())
        default: return mode.uppercased() == rawValue
        }
    }
}

enum SpotSortFilter: String, CaseIterable, Identifiable, SpotFilterOption {
    case time = "Time"
    case frequency = "Frequency"
    case callsign = "Callsign"

    var id: String { rawValue }
    var displayName: String { rawValue }
    var accessibilityName: String { rawValue }
}

enum SpotVisibilityFilter: String, CaseIterable, Identifiable {
    case show = "Show"
    case hide = "Hide"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

protocol SpotFilterOption: CaseIterable, Hashable, Identifiable {
    var displayName: String { get }
    var accessibilityName: String { get }
}

// MARK: - Main View

struct SpotsView: View {
    @StateObject private var viewModel = SpotsViewModel()
    @State private var showLogin = false
    @State private var showAwards = false
    @State private var showAddSpot = false
    @State private var isSigningIn = false
    @State private var activeDetail: SpotDetailDestination?

    @AppStorage(SpotListStyle.storageKey) private var spotListStyleRaw = SpotListStyle.default.rawValue
    private var spotListStyle: SpotListStyle { SpotListStyle(rawValue: spotListStyleRaw) ?? .default }

    @AppStorage(SpotAutoRefreshInterval.storageKey) private var autoRefreshRaw = SpotAutoRefreshInterval.default.rawValue
    private var autoRefreshInterval: SpotAutoRefreshInterval { SpotAutoRefreshInterval(rawValue: autoRefreshRaw) ?? .default }

    // Filters
    @State private var selectedBand: SpotBandFilter = .all
    @State private var selectedMode: SpotModeFilter = .all
    @State private var selectedProgram: String = "All"
    @State private var selectedSort: SpotSortFilter = .time
    @State private var selectedQRT: SpotVisibilityFilter = .hide
    @State private var selectedHunted: SpotVisibilityFilter = .hide
    @State private var activeSheet: SpotFilterSheet?
    @State private var showFilters = false

    private var filteredSpots: [Spot] {
        var result = viewModel.spots

        // Band filter
        if selectedBand != .all {
            result = result.filter { $0.band == selectedBand.rawValue }
        }

        // Mode filter
        if selectedMode != .all {
            result = result.filter { selectedMode.matches($0.mode) }
        }

        // Program filter
        if selectedProgram != "All" {
            result = result.filter { $0.program == selectedProgram }
        }

        // QRT filter
        if selectedQRT == .hide {
            result = result.filter { !$0.isQRT }
        }

        // Sort
        switch selectedSort {
        case .time:
            result.sort { $0.ageInMinutes < $1.ageInMinutes }
        case .frequency:
            result.sort { (Double($0.frequency) ?? 0) < (Double($1.frequency) ?? 0) }
        case .callsign:
            result.sort { $0.activator.localizedCaseInsensitiveCompare($1.activator) == .orderedAscending }
        }

        return result
    }

    /// Available programs derived from current spots.
    private var availablePrograms: [String] {
        let programs = Set(viewModel.spots.map(\.program))
        return ["All"] + programs.sorted()
    }

    /// Counts per band for the badge.
    private var bandCounts: [SpotBandFilter: Int] {
        var counts: [SpotBandFilter: Int] = [.all: viewModel.spots.count]
        for spot in viewModel.spots {
            if let band = SpotBandFilter(rawValue: spot.band) {
                counts[band, default: 0] += 1
            }
        }
        return counts
    }

    /// Counts per mode for the badge.
    private var modeCounts: [SpotModeFilter: Int] {
        var counts: [SpotModeFilter: Int] = [.all: viewModel.spots.count]
        for filter in SpotModeFilter.allCases where filter != .all {
            counts[filter] = viewModel.spots.filter { filter.matches($0.mode) }.count
        }
        return counts
    }

    /// Counts per program.
    private var programCounts: [String: Int] {
        var counts: [String: Int] = ["All": viewModel.spots.count]
        for spot in viewModel.spots {
            counts[spot.program, default: 0] += 1
        }
        return counts
    }

    /// QRT counts.
    private var qrtShowCount: Int { viewModel.spots.count }
    private var qrtHideCount: Int { viewModel.spots.filter { !$0.isQRT }.count }

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading && viewModel.spots.isEmpty {
                    ProgressView("Loading spots...")
                } else if let error = viewModel.errorMessage, viewModel.spots.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await viewModel.fetchSpots() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    spotList
                    .refreshable {
                        await viewModel.fetchSpots()
                    }
                }
            }
            .navigationTitle("Spots")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if viewModel.isLoading {
                        ProgressView()
                            .accessibilityLabel("Refreshing spots")
                    } else {
                        Button {
                            Task { await viewModel.fetchSpots() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh spots")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showFilters.toggle()
                        }
                    } label: {
                        Image(systemName: showFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(showFilters ? "Hide filters" : "Show filters")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if AuthManager.shared.isSignedIn {
                            showAddSpot = true
                        } else {
                            showLogin = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if AuthManager.shared.isSignedIn {
                        Button { showAwards = true } label: {
                            ProfileAvatar(
                                userInfo:    AuthManager.shared.userInfo,
                                overrideURL: AuthManager.shared.gravatarURL
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            guard !isSigningIn else { return }
                            isSigningIn = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                showLogin = true
                                isSigningIn = false
                            }
                        } label: {
                            ZStack {
                                Text("Sign In")
                                    .opacity(isSigningIn ? 0 : 1)
                                ProgressView()
                                    .tint(.white)
                                    .opacity(isSigningIn ? 1 : 0)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(.blue, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showFilters)
        .task {
            ParkIndex.shared.load()
            await viewModel.fetchSpots()
        }
        .task(id: autoRefreshRaw) {
            await runAutoRefresh()
        }
        .sheet(isPresented: $showLogin) {
            SignInSheet()
#if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
#endif
        }
        .sheet(isPresented: $showAwards) {
            AwardsView()
        }
        .sheet(isPresented: $showAddSpot) {
            AddSpotView {
                await viewModel.fetchSpots()
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .band:
                SpotFilterSelectionSheet(
                    title: "Band",
                    options: SpotBandFilter.allCases.filter { bandCounts[$0] != nil || $0 == .all },
                    selected: selectedBand,
                    countProvider: { bandCounts[$0] ?? 0 },
                    onSelect: { selectedBand = $0 }
                )
            case .mode:
                SpotFilterSelectionSheet(
                    title: "Mode",
                    options: Array(SpotModeFilter.allCases),
                    selected: selectedMode,
                    countProvider: { modeCounts[$0] ?? 0 },
                    onSelect: { selectedMode = $0 }
                )
            case .sort:
                SpotFilterSelectionSheet(
                    title: "Sort",
                    options: Array(SpotSortFilter.allCases),
                    selected: selectedSort,
                    countProvider: { _ in nil },
                    onSelect: { selectedSort = $0 }
                )
            case .program:
                programSheet
            }
        }
        .sheet(item: $activeDetail) { detail in
            switch detail {
            case .activator(let callsign):
                SpotActivatorStatsView(callsign: callsign)
            case .park(let park):
                ParkDetailView(park: park)
                    .presentationDetents([.fraction(0.28), .medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var spotList: some View {
        switch spotListStyle {
        case .default:
            List {
                if showFilters {
                    filterGrid
                        .padding(.vertical, 8)
                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 14))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                ForEach(filteredSpots) { spot in
                    SpotRowDefault(
                        spot: spot,
                        onActivatorTap: { presentStats(for: spot.activator) },
                        onReferenceTap: { presentPark(for: spot.reference) }
                    )
                }
            }
        case .compact, .cards:
            ScrollView {
                LazyVStack(spacing: 0) {
                    headerSection
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    if showFilters {
                        filterGrid
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    HStack {
                        Text("\(filteredSpots.count) spots")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)

                    ForEach(filteredSpots) { spot in
                        switch spotListStyle {
                        case .default:
                            EmptyView()
                        case .compact:
                            VStack(spacing: 0) {
                                SpotRowCompact(
                                    spot: spot,
                                    onActivatorTap: { presentStats(for: spot.activator) },
                                    onReferenceTap: { presentPark(for: spot.reference) }
                                )
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                Divider()
                                    .padding(.leading, 16)
                            }
                        case .cards:
                            SpotRow(
                                spot: spot,
                                onActivatorTap: { presentStats(for: spot.activator) },
                                onReferenceTap: { presentPark(for: spot.reference) }
                            )
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if viewModel.isLoading {
                Text("Refreshing...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var filterGrid: some View {
        Group {
            if #available(iOS 26, macOS 26, *) {
                GlassEffectContainer(spacing: 18) {
                    filterGridContent
                }
            } else {
                filterGridContent
            }
        }
        .padding(14)
        .spotFilterPanelBackground()
    }

    private var filterGridContent: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                SpotFilterSummaryButton(
                    title: "Band",
                    value: selectedBand.displayName,
                    count: bandCounts[selectedBand],
                    systemImage: "dot.radiowaves.left.and.right",
                    accessibilityHint: "Opens band filter options",
                    action: { activeSheet = .band }
                )

                SpotFilterSummaryButton(
                    title: "Mode",
                    value: selectedMode.displayName,
                    count: modeCounts[selectedMode],
                    systemImage: "waveform",
                    accessibilityHint: "Opens mode filter options",
                    action: { activeSheet = .mode }
                )
            }

            GridRow {
                SpotFilterSummaryButton(
                    title: "Program",
                    value: selectedProgram,
                    count: programCounts[selectedProgram],
                    systemImage: "globe",
                    accessibilityHint: "Opens program filter options",
                    action: { activeSheet = .program }
                )

                SpotFilterSummaryButton(
                    title: "Sort",
                    value: selectedSort.displayName,
                    count: nil,
                    systemImage: "arrow.up.arrow.down",
                    accessibilityHint: "Opens sort options",
                    action: { activeSheet = .sort }
                )
            }

            GridRow {
                HStack {
                    SpotBinaryFilterCard(
                        title: "QRT",
                        selection: $selectedQRT,
                        showCount: qrtShowCount,
                        hideCount: qrtHideCount
                    )
                    Spacer(minLength: 0)
                }
                .gridCellColumns(2)
            }
        }
    }

    private var programSheet: some View {
        NavigationStack {
            List(availablePrograms, id: \.self) { program in
                Button {
                    selectedProgram = program
                    activeSheet = nil
                } label: {
                    HStack(spacing: 12) {
                        Text(program)
                            .foregroundStyle(.primary)

                        Spacer()

                        if let count = programCounts[program] {
                            SpotCountBadge(count: count)
                        }

                        if program == selectedProgram {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Program")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func presentStats(for callsign: String) {
        let normalized = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return }
        activeDetail = .activator(normalized)
    }

    private func presentPark(for reference: String) {
        let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return }

        Task {
            guard let park = await resolvePark(reference: normalized) else { return }
            await MainActor.run {
                activeDetail = .park(park)
            }
        }
    }

    private func resolvePark(reference: String) async -> POTAPark? {
        if let cached = ParkIndex.shared.park(reference: reference) {
            return cached.toPOTAPark()
        }

        guard let url = URL(string: "https://api.pota.app/park/\(reference)") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return nil
        }

        return try? JSONDecoder().decode(POTAPark.self, from: data)
    }

    /// Periodically reloads spots while the view is visible, honoring the
    /// user's auto-refresh interval. The enclosing `.task(id:)` cancels and
    /// restarts this loop whenever the interval changes (including to Off).
    private func runAutoRefresh() async {
        guard let seconds = autoRefreshInterval.seconds else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { break }
            if !viewModel.isLoading {
                await viewModel.fetchSpots()
            }
        }
    }
}

// MARK: - Filter Sheet Enum

private enum SpotFilterSheet: String, Identifiable {
    case band, mode, program, sort
    var id: String { rawValue }
}

private enum SpotDetailDestination: Identifiable {
    case activator(String)
    case park(POTAPark)

    var id: String {
        switch self {
        case .activator(let callsign):
            return "activator-\(callsign)"
        case .park(let park):
            return "park-\(park.reference)"
        }
    }
}

// MARK: - Spot Identity

private struct SpotProfileResponse: Decodable {
    let gravatar: String?
}

private actor SpotProfileImageCache {
    static let shared = SpotProfileImageCache()

    private var urlsByCallsign: [String: URL] = [:]
    private var missingCallsigns: Set<String> = []

    func url(for callsign: String) async -> URL? {
        let key = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return nil }

        if let cached = urlsByCallsign[key] { return cached }
        if missingCallsigns.contains(key) { return nil }

        guard let url = URL(string: "https://api.pota.app/stats/user/\(key)") else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                missingCallsigns.insert(key)
                return nil
            }

            let profile = try JSONDecoder().decode(SpotProfileResponse.self, from: data)
            let hash = profile.gravatar?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let hash, !hash.isEmpty,
                  let avatarURL = URL(string: "https://www.gravatar.com/avatar/\(hash)?s=96&d=identicon") else {
                missingCallsigns.insert(key)
                return nil
            }

            urlsByCallsign[key] = avatarURL
            return avatarURL
        } catch {
            missingCallsigns.insert(key)
            return nil
        }
    }
}

private struct SpotIdentityView: View {
    let spot: Spot
    var profileSize: CGFloat = 24

    @AppStorage(SpotIdentityDisplay.storageKey) private var displayRaw = SpotIdentityDisplay.none.rawValue
    @State private var profileURL: URL?

    private var display: SpotIdentityDisplay {
        SpotIdentityDisplay(rawValue: displayRaw) ?? .none
    }

    var body: some View {
        if display != .none {
            HStack(spacing: 5) {
                if display.showsFlag, let flag = spot.countryFlag {
                    Text(flag)
                        .font(.system(size: profileSize * 0.78))
                        .accessibilityLabel(spot.countryCode ?? "Country")
                }

                if display.showsProfile {
                    SpotActivatorAvatar(
                        callsign: spot.activator,
                        imageURL: profileURL,
                        size: profileSize
                    )
                }
            }
            .task(id: "\(displayRaw)-\(spot.activator)") {
                guard display.showsProfile else {
                    profileURL = nil
                    return
                }
                profileURL = await SpotProfileImageCache.shared.url(for: spot.activator)
            }
        }
    }
}

private struct SpotActivatorAvatar: View {
    let callsign: String
    let imageURL: URL?
    let size: CGFloat

    private var initials: String {
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(2)).uppercased()
    }

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        initialsCircle
                    }
                }
            } else {
                initialsCircle
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("\(callsign) profile")
    }

    private var initialsCircle: some View {
        Circle()
            .fill(.blue.gradient)
            .overlay(
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Spot Row (Cards)

struct SpotRow: View {
    let spot: Spot
    let onActivatorTap: (() -> Void)?
    let onReferenceTap: (() -> Void)?

    @AppStorage(FrequencyFormatOptions.unitKey)  private var freqUnit  = FrequencyUnit.MHz.rawValue
    @AppStorage(FrequencyFormatOptions.zerosKey) private var freqZeros = FrequencyZeros.trimmed.rawValue

    private var frequencyText: String {
        formatFrequency(
            spot.frequency,
            unit:          FrequencyUnit(rawValue: freqUnit)   ?? .MHz,
            trailingZeros: FrequencyZeros(rawValue: freqZeros) ?? .trimmed
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        SpotIdentityView(spot: spot, profileSize: 24)
                        SpotActionLabel(
                            text: spot.activator,
                            font: .headline,
                            color: .primary,
                            action: onActivatorTap
                        )
                        Spacer()
                        Text(frequencyText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(spot.mode)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15))
                            .foregroundStyle(.tint)
                            .clipShape(Capsule())
                    }
                    HStack {
                        SpotActionLabel(
                            text: spot.reference,
                            font: .caption,
                            color: .accentColor,
                            action: onReferenceTap
                        )
                        if let name = spot.name {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if spot.isQRT {
                            Text("QRT")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.red)
                        }
                        Text("\(spot.ageInMinutes)m ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let comments = spot.comments, !comments.isEmpty {
                Text(comments)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

// MARK: - Spot Row (Default)

struct SpotRowDefault: View {
    let spot: Spot
    let onActivatorTap: (() -> Void)?
    let onReferenceTap: (() -> Void)?

    @AppStorage(FrequencyFormatOptions.unitKey)  private var freqUnit  = FrequencyUnit.MHz.rawValue
    @AppStorage(FrequencyFormatOptions.zerosKey) private var freqZeros = FrequencyZeros.trimmed.rawValue

    private var frequencyText: String {
        formatFrequency(
            spot.frequency,
            unit:          FrequencyUnit(rawValue: freqUnit)   ?? .MHz,
            trailingZeros: FrequencyZeros(rawValue: freqZeros) ?? .trimmed
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SpotIdentityView(spot: spot, profileSize: 24)
                SpotActionLabel(
                    text: spot.activator,
                    font: .headline,
                    color: .primary,
                    action: onActivatorTap
                )
                Spacer()
                Text(frequencyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(spot.mode)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15))
                    .foregroundStyle(.tint)
                    .clipShape(Capsule())
            }
            HStack {
                SpotActionLabel(
                    text: spot.reference,
                    font: .caption,
                    color: .accentColor,
                    action: onReferenceTap
                )
                if let name = spot.name {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(spot.ageInMinutes)m ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let comments = spot.comments, !comments.isEmpty {
                Text(comments)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Spot Row (Compact)

struct SpotRowCompact: View {
    let spot: Spot
    let onActivatorTap: (() -> Void)?
    let onReferenceTap: (() -> Void)?

    @AppStorage(FrequencyFormatOptions.unitKey)  private var freqUnit  = FrequencyUnit.MHz.rawValue
    @AppStorage(FrequencyFormatOptions.zerosKey) private var freqZeros = FrequencyZeros.trimmed.rawValue

    private var frequencyText: String {
        formatFrequency(
            spot.frequency,
            unit:          FrequencyUnit(rawValue: freqUnit)   ?? .MHz,
            trailingZeros: FrequencyZeros(rawValue: freqZeros) ?? .trimmed
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SpotIdentityView(spot: spot, profileSize: 22)
                SpotActionLabel(
                    text: spot.activator,
                    font: .headline,
                    color: .primary,
                    action: onActivatorTap
                )
                Spacer()
                Text(frequencyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(spot.mode)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            HStack {
                SpotActionLabel(
                    text: spot.reference,
                    font: .caption,
                    color: .accentColor,
                    action: onReferenceTap
                )
                if let name = spot.name {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if spot.isQRT {
                    Text("QRT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                }
                Text("\(spot.ageInMinutes)m ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let comments = spot.comments, !comments.isEmpty {
                Text(comments)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct SpotActionLabel: View {
    let text: String
    let font: Font
    let color: Color
    let action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                }
                .buttonStyle(.plain)
            } else {
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
            }
        }
    }
}

private struct SpotActivatorStatsView: View {
    let callsign: String

    @State private var stats: POTAStats?
    @State private var isLoading = false
    @State private var loadFailed = false

    private var avatarURL: URL? {
        guard let hash = stats?.gravatar?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hash.isEmpty else {
            return nil
        }
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=200&d=identicon")
    }

    var body: some View {
        ScrollView {
            Group {
                if #available(iOS 26, macOS 26, *) {
                    GlassEffectContainer(spacing: 22) {
                        statsContent
                    }
                } else {
                    statsContent
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .task(id: callsign) {
            await loadStats()
        }
    }

    private var statsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerCard

            if isLoading {
                ProgressView("Loading stats…")
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if loadFailed {
                Text("Unable to load activator stats right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .spotStatsCardBackground()
            } else if let stats {
                SpotStatsSectionCard(
                    title: "Hunted",
                    subtitle: "Hunter activity",
                    systemImage: "dot.scope",
                    accent: .blue,
                    columns: 2,
                    items: [
                        .init(title: "QSOs", value: "\(stats.hunter.qsos)"),
                        .init(title: "Parks", value: "\(stats.hunter.parks)")
                    ]
                )

                SpotStatsSectionCard(
                    title: "Activated",
                    subtitle: "Activator activity",
                    systemImage: "antenna.radiowaves.left.and.right",
                    accent: .green,
                    columns: 3,
                    items: [
                        .init(title: "QSOs", value: "\(stats.activator.qsos)"),
                        .init(title: "Activations", value: "\(stats.activator.activations)"),
                        .init(title: "Parks", value: "\(stats.activator.parks)")
                    ]
                )

                SpotStatsSectionCard(
                    title: "Recognition",
                    subtitle: "Program milestones",
                    systemImage: "rosette",
                    accent: .recognitionGold,
                    columns: 2,
                    items: [
                        .init(title: "Awards", value: "\(stats.awards)"),
                        .init(title: "Endorsements", value: "\(stats.endorsements)")
                    ]
                )
            }
        }
    }

    private var headerCard: some View {
        HStack(spacing: 16) {
            SpotActivatorAvatar(
                callsign: stats?.callsign ?? callsign,
                imageURL: avatarURL,
                size: 68
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(stats?.callsign ?? callsign)
                    .font(.title2.weight(.bold))
                if let name = stats?.name, !name.isEmpty {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Parks on the Air Stats")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(18)
        .spotStatsCardBackground()
    }

    private func loadStats() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        guard let url = URL(string: "https://api.pota.app/stats/user/\(callsign)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(POTAStats.self, from: data) else {
            loadFailed = true
            return
        }

        stats = decoded
    }
}

private struct SpotStatsItem: Identifiable {
    let title: String
    let value: String

    var id: String { title }
}

private struct SpotStatsSectionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let columns: Int
    let items: [SpotStatsItem]

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline.weight(.semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(accent)
                        .frame(width: 36, height: 36)
                        .background(accent.opacity(0.18), in: Circle())
                        .accessibilityHidden(true)
                }

                Spacer()
            }
            .accessibilityElement(children: .combine)

            statsGrid
        }
        .padding(18)
        .spotStatsCardBackground(tint: accent.opacity(0.14))
    }

    private var statsGrid: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                SpotStatsPill(title: item.title, value: item.value, accent: accent)
            }
        }
    }
}

private struct SpotStatsPill: View {
    let title: String
    let value: String
    var accent: Color = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spotStatsPillBackground(accent: accent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
}

private extension Color {
    /// Warm gold accent for the Recognition stats section. Plain `.orange` muddies
    /// into brown at low opacity over dark backgrounds; this stays clean.
    static let recognitionGold = Color(red: 0.96, green: 0.70, blue: 0.22)
}

private extension View {
    @ViewBuilder
    func spotStatsCardBackground(tint: Color = .white.opacity(0.10)) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
                .background(Color.white.opacity(0.001))
                .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: 24))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.45), .white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
                .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
        } else {
            self
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.regularMaterial)
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(tint)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.30), .white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.20), radius: 16, x: 0, y: 10)
                .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        }
    }

    func spotStatsPillBackground(accent: Color) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.30), accent.opacity(0.20)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.14), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(accent.opacity(0.22), lineWidth: 1)
            }
    }

    @ViewBuilder
    func spotFilterPanelBackground() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.black.opacity(0.12))
                        .blur(radius: 24)
                        .offset(y: 16)
                }
                .background(Color.white.opacity(0.001))
                .glassEffect(.clear.tint(.white.opacity(0.05)), in: .rect(cornerRadius: 22))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.34), .white.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 2)
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.22), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.12), radius: 20, x: 0, y: 10)
        }
    }

    @ViewBuilder
    func spotFilterTileBackground(interactive: Bool = false) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
                .background(Color.white.opacity(0.001))
                .glassEffect(
                    interactive
                    ? .regular.tint(.white.opacity(0.14)).interactive()
                    : .regular.tint(.white.opacity(0.14)),
                    in: .rect(cornerRadius: 16)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.42), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
                .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .blendMode(.plusLighter)
                        }
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.30), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 6)
                .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        }
    }
}

// MARK: - Filter UI Components

private struct SpotFilterSummaryButton: View {
    let title: String
    let value: String
    let count: Int?
    let systemImage: String
    let accessibilityHint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }

                HStack(spacing: 8) {
                    Text(value)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let count {
                        SpotCountBadge(count: count)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .spotFilterTileBackground(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count != nil ? "\(title), \(value), \(count!) results" : "\(title), \(value)")
        .accessibilityHint(accessibilityHint)
    }
}

private struct SpotBinaryFilterCard: View {
    let title: String
    @Binding var selection: SpotVisibilityFilter
    let showCount: Int
    let hideCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker(title, selection: $selection) {
                Text("Show (\(showCount))").tag(SpotVisibilityFilter.show)
                Text("Hide (\(hideCount))").tag(SpotVisibilityFilter.hide)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel("\(title) filter")
        }
        .padding(14)
        .frame(minHeight: 88, alignment: .topLeading)
        .spotFilterTileBackground()
    }
}

private struct SpotCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.blue))
            .accessibilityHidden(true)
    }
}

private struct SpotFilterSelectionSheet<Option: SpotFilterOption>: View {
    let title: String
    let options: [Option]
    let selected: Option
    let countProvider: (Option) -> Int?
    let onSelect: (Option) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(options) { option in
                Button {
                    onSelect(option)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.displayName)
                                .foregroundStyle(.primary)
                            if option.accessibilityName != option.displayName {
                                Text(option.accessibilityName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if let count = countProvider(option) {
                            SpotCountBadge(count: count)
                        }

                        if option == selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
