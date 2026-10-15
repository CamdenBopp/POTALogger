import SwiftUI
import MapKit
import CoreLocation
#if os(iOS)
import UIKit
#endif

// MARK: - Location Manager

@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var userLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    func refreshLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else { return }
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Prefer the most accurate recent fix rather than blindly trusting the last callback.
        let recentLocations = locations.filter {
            $0.horizontalAccuracy >= 0 && $0.timestamp.timeIntervalSinceNow > -30
        }
        if let bestLocation = recentLocations.min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) {
            userLocation = bestLocation
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last known good fix if we have one; transient requestLocation failures are common.
        print("[MapView] location error: \(error.localizedDescription)")
    }
}

// MARK: - POTA Park Model

struct POTAPark: Decodable, Identifiable {
    let reference: String
    let name: String
    let latitude: Double
    let longitude: Double
    let locationDesc: String?
    let parktypeDesc: String?

    var id: String { reference }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Search Result

enum MapSearchResult: Identifiable {
    case park(POTAPark)
    case place(MKMapItem)

    var id: String {
        switch self {
        case .park(let p):  return "park-\(p.reference)"
        case .place(let m): return "place-\(m.name ?? UUID().uuidString)"
        }
    }

    var title: String {
        switch self {
        case .park(let p):  return "\(p.reference) — \(p.name)"
        case .place(let m): return m.name ?? "Unknown"
        }
    }

    var subtitle: String {
        switch self {
        case .park(let p):  return p.locationDesc ?? p.parktypeDesc ?? ""
        case .place(let m): return m.placemark.title ?? ""
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .park(let p):  return p.coordinate
        case .place(let m): return m.placemark.coordinate
        }
    }
}

// MARK: - Search View Model

@Observable
final class MapSearchViewModel {
    var query = ""
    var results: [MapSearchResult] = []
    var isSearching = false

    private var searchTask: Task<Void, Never>?

    // Detect POTA reference: one or more letter groups separated by hyphens, ending in digits
    // e.g. K-1234, VE-0042, US-NY-001
    private let parkRefPattern = /^[A-Za-z]{1,4}(-[A-Za-z]{2})?-\d+$/

    func search() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }

        results = []

        searchTask = Task {
            if !isParkRef(q) {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled else { return }

            isSearching = true
            defer { isSearching = false }

            if isParkRef(q) {
                await searchPark(q.uppercased())
            } else {
                await searchParksAndPlaces(q)
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        query = ""
        results = []
    }

    private func isParkRef(_ q: String) -> Bool {
        (try? parkRefPattern.wholeMatch(in: q)) != nil
    }

    private func searchPark(_ ref: String) async {
        guard let url = URL(string: "https://api.pota.app/park/\(ref)") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                results = []
                return
            }
            let park = try JSONDecoder().decode(POTAPark.self, from: data)
            results = [.park(park)]
        } catch {
            results = []
        }
    }

    // Runs POTA name search and MKLocalSearch in parallel; POTA parks shown first.
    private func searchParksAndPlaces(_ q: String) async {
        async let parkMatches = fetchParksByName(q)
        async let placeMatches = fetchPlaces(q)

        let parks = await parkMatches
        let places = await placeMatches

        // If POTA returned parks, show those first and skip address noise
        if !parks.isEmpty {
            results = parks
        } else {
            results = places
        }
    }

    private func fetchParksByName(_ q: String) async -> [MapSearchResult] {
        ParkIndex.shared.search(q).map { .park($0.toPOTAPark()) }
    }

    private func fetchPlaces(_ q: String) async -> [MapSearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.prefix(5).map { .place($0) }
        } catch {
            return []
        }
    }
}

// MARK: - Nearby Park (list view model)

private struct NearbyPark: Identifiable {
    let park: ParkRecord
    let distanceMi: Double
    let cardinal: String
    var id: String { park.reference }
}

private struct PersonalParkRefs {
    let refs: Set<String>
    let source: PersonalParkSource
}

private enum PersonalParkSource {
    case api
    case hunterLog
}

private final class RegionBox {
    var region: MKCoordinateRegion?
}

// MARK: - Map View

struct MapView: View {
    @Environment(LocationManager.self) private var locationManager
    @State private var searchVM = MapSearchViewModel()
    @State private var cameraCommand: CameraCommand?
    @State private var pinnedPark: POTAPark?
    @State private var presentedPark: POTAPark?
    @State private var selectedParkReference: String?
    @State private var clusterParkListRequest: POTAClusterParkListRequest?
    /// Screen point (in the map container's space) the cluster popover points at.
    @State private var clusterAnchorPoint: CGPoint = .zero
    @State private var visibleParks: [ParkRecord] = []
    @State private var visibleParkQuery: VisibleParkQuery?
    @State private var regionBox = RegionBox()
    @State private var showList = false
    @State private var nearbyParks: [NearbyPark] = []
    /// Park references fetched for the current personal filter (activated / hunted).
    @State private var personalParkRefs: Set<String> = []
    @State private var isFetchingPersonalParks = false
    @State private var personalParkSource: PersonalParkSource = .api
    /// Hunted parks sorted by QSO count desc, capped at 200 for performance.
    @State private var huntedParkLines: [HuntedParkLine] = []
    /// QSO counts per park ref from the scraper; used to sort lines by activity.
    @State private var huntedParkQSOCounts: [String: Int] = [:]
    @FocusState private var searchFocused: Bool
    @AccessibilityFocusState private var listHeadingFocused: Bool
    @AppStorage("debugMode") private var debugMode = false
    @State private var debugBadgeHeight: CGFloat = 0
    /// Height of the top toolbar chrome (location / search / toggle) measured in
    /// the map's coordinate space. Pins whose marker falls within this band are
    /// occluded by the toolbar, so they're excluded from the accessibility tree.
    @State private var accessibilityTopInset: CGFloat = 0

    // MARK: - Hunted-parks line data

    private struct HuntedParkLine: Identifiable {
        let id: String           // park reference
        let coordinate: CLLocationCoordinate2D
        let qsoCount: Int
    }

    private struct VisibleParkQuery {
        let bounds: ParkCoordinateBounds
        let latitudeDelta: Double
        let longitudeDelta: Double

        func canReuse(for visibleBounds: ParkCoordinateBounds, region: MKCoordinateRegion) -> Bool {
            bounds.contains(latitude: visibleBounds.minLatitude, longitude: visibleBounds.minLongitude) &&
            bounds.contains(latitude: visibleBounds.minLatitude, longitude: visibleBounds.maxLongitude) &&
            bounds.contains(latitude: visibleBounds.maxLatitude, longitude: visibleBounds.minLongitude) &&
            bounds.contains(latitude: visibleBounds.maxLatitude, longitude: visibleBounds.maxLongitude) &&
            isSimilarZoom(to: region)
        }

        private func isSimilarZoom(to region: MKCoordinateRegion) -> Bool {
            let latitudeRatio = region.span.latitudeDelta / latitudeDelta
            let longitudeRatio = region.span.longitudeDelta / longitudeDelta
            return (0.5...2.0).contains(latitudeRatio) && (0.5...2.0).contains(longitudeRatio)
        }
    }

    // MARK: - Derived from filter

    /// Maximum personal parks to plot in full (independent of the viewport) before we
    /// fall back to viewport filtering. Activated sets are always well under this; only
    /// very large hunted logs hit the cap, where viewport gating keeps the map smooth.
    private static let personalParkPlotCap = 400

    /// Parks to plot for the active MapFilter.
    ///
    /// Local parks use the viewport-gated index (tens of thousands of parks worldwide).
    /// Personal filters (activated / hunted) plot the user's *entire* resolved park set
    /// regardless of the current viewport — otherwise a handful of scattered parks stay
    /// invisible until you happen to pan/zoom directly onto them. Large sets fall back to
    /// viewport filtering to stay performant.
    private var filteredVisibleParks: [ParkRecord] {
        let filter = AppRouter.shared.mapFilter
        guard filter != .localParks else { return visibleParks }
        guard !personalParkRefs.isEmpty else { return [] }
        let resolved = personalParkRefs.compactMap { ParkIndex.shared.park(reference: $0) }
        if resolved.count <= Self.personalParkPlotCap {
            return resolved
        }
        return visibleParks.filter { personalParkRefs.contains($0.reference) }
    }

    /// Nearby parks list, filtered by the active MapFilter.
    private var filteredNearbyParks: [NearbyPark] {
        let filter = AppRouter.shared.mapFilter
        guard filter != .localParks else { return nearbyParks }
        guard !personalParkRefs.isEmpty else { return [] }
        return nearbyParks.filter { personalParkRefs.contains($0.park.reference) }
    }

    private var markerTint: Color {
        switch AppRouter.shared.mapFilter {
        case .localParks:     return .green
        case .activatedParks: return .orange
        case .huntedParks:    return .blue
        }
    }

    private var listTitle: String {
        switch AppRouter.shared.mapFilter {
        case .localParks:     return "Nearby Parks"
        case .activatedParks: return "Your Activations"
        case .huntedParks:    return "Your Hunted Parks"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            POTAMKMapView(
                parks: filteredVisibleParks,
                geodesicOrigin: AppRouter.shared.mapFilter == .huntedParks
                    ? locationManager.userLocation?.coordinate : nil,
                geodesicEndpoints: huntedParkLines.map(\.coordinate),
                pinnedPark: pinnedPark,
                markerTint: UIColor(markerTint),
                selectedParkReference: $selectedParkReference,
                cameraCommand: cameraCommand,
                onClusterListRequested: { request in
                    if request.parks.isEmpty {
                        clusterParkListRequest = nil
                    } else {
                        searchVM.results = []
                        searchFocused = false
                        clusterAnchorPoint = request.anchor
                        clusterParkListRequest = request
                    }
                },
                onRegionChanged: { region in
                    regionBox.region = region
                    updateVisibleParks(in: region)
                },
                onTapped: {
                    searchVM.results = []
                    searchFocused = false
                    clusterParkListRequest = nil
                },
                accessibilityTopInset: accessibilityTopInset,
                legalBottomInset: debugMode ? debugBadgeHeight + 12 : 0
            )
            // Pins are hidden from VoiceOver whenever an overlay covers the map: the
            // list or the search-results dropdown. (The cluster popover is a real system
            // popover, which makes the background inert for VoiceOver on its own.)
            .accessibilityHidden(showList || !searchVM.results.isEmpty)

            // List view overlay — sits between the map and the search toolbar
            if showList {
                parkListOverlay
            }

            searchOverlay

            // The park list presents as a real system popover — that's what makes
            // VoiceOver play the modal "popover" chime (UIPopoverPresentationController
            // modalizes; nothing hand-rolled reproduces it). We present it through UIKit
            // so we can strip the popover's arrow + platter border and show only the
            // floating chips, while keeping the presentation (and its earcon) intact.
            if !showList {
                #if os(iOS) && !targetEnvironment(macCatalyst)
                BorderlessClusterPopover(item: $clusterParkListRequest, anchorPoint: clusterAnchorPoint) { request in
                    clusterParkListPopover(request)
                }
                .allowsHitTesting(false)
                #else
                Color.clear
                    .frame(width: 1, height: 1)
                    .popover(item: $clusterParkListRequest) { request in
                        clusterParkListPopover(request)
                    }
                    .position(clusterAnchorPoint)
                    .allowsHitTesting(false)
                #endif
            }

            // Debug badge — park index load status
            if debugMode {
                VStack {
                    Spacer()
                    HStack {
                        parkIndexBadge
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { debugBadgeHeight = $0 }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .coordinateSpace(name: "mapContainer")
        .onAppear {
            ParkIndex.shared.load()
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUse()
            } else {
                locationManager.refreshLocation()
            }
            if locationManager.authorizationStatus == .authorizedWhenInUse ||
               locationManager.authorizationStatus == .authorizedAlways {
                cameraCommand = CameraCommand(region: nil, animated: false)
            }
            let filter = AppRouter.shared.mapFilter
            if filter != .localParks {
                Task { await fetchPersonalParks(for: filter) }
            }
        }
        .onChange(of: locationManager.authorizationStatus) { _, status in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                locationManager.refreshLocation()
                cameraCommand = CameraCommand(region: nil, animated: true)
            }
        }
        .onChange(of: ParkIndex.shared.isLoaded) { _, loaded in
            guard loaded else { return }
            if let region = regionBox.region {
                updateVisibleParks(in: region)
            }
            if AppRouter.shared.mapFilter == .huntedParks && !personalParkRefs.isEmpty {
                resolveHuntedParkLines()
            }
        }
        .onChange(of: AppRouter.shared.requestedMapList) { _, requested in
            guard let requested else { return }
            showList = requested
            AppRouter.shared.requestedMapList = nil
        }
        .onChange(of: AppRouter.shared.mapFilter) { _, filter in
            personalParkRefs = []
            personalParkSource = .api
            huntedParkLines = []
            huntedParkQSOCounts = [:]
            selectedParkReference = nil
            clusterParkListRequest = nil
            visibleParkQuery = nil
            guard filter != .localParks else { return }
            Task { await fetchPersonalParks(for: filter) }
        }
        .onChange(of: selectedParkReference) { _, reference in
            guard let reference,
                  let park = ParkIndex.shared.park(reference: reference) else { return }
            pinnedPark = park.toPOTAPark()
            presentedPark = park.toPOTAPark()
        }
        .onChange(of: locationManager.userLocation) { _, _ in
            if showList { computeNearbyParks() }
        }
        .onChange(of: showList) { _, showing in
            if showing {
                clusterParkListRequest = nil
                locationManager.refreshLocation()
                computeNearbyParks()
                // Delay one runloop so the list is in the hierarchy before focus moves
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    listHeadingFocused = true
                }
            }
        }
        .sheet(item: $presentedPark, onDismiss: {
            pinnedPark = nil
            selectedParkReference = nil
        }) { park in
            ParkDetailView(park: park)
                .presentationDetents([.fraction(0.28), .medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    // MARK: Park index debug badge

    /// Content of the cluster park-list system popover: our original chip-styled park
    /// cards. The popover chrome (arrow, dimming, VoiceOver modality + earcons, and
    /// dismissal) is provided by `.popover`, so this only renders the cards.
    private func clusterParkListPopover(_ request: POTAClusterParkListRequest) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(request.parks, id: \.reference) { park in
                    Button {
                        clusterParkListRequest = nil
                        select(.park(park.toPOTAPark()))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "tree.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(clusterParkTitle(for: park))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Text(clusterParkSubtitle(for: park))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 6)

                            Text(park.reference)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        // Plain material capsule per chip — NOT .glass. Liquid Glass
                        // samples whatever shows through the clear popover background
                        // (the live Metal map), which contends with MapKit for the
                        // drawable and can trigger the "failed to acquire drawable"
                        // hang. Plain material composites cheaply and keeps the
                        // free-floating-capsule look with no surrounding platter.
                        .background(.regularMaterial, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(clusterParkTitle(for: park)), \(clusterParkSubtitle(for: park)), \(park.reference)")
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .frame(width: 300, height: min(CGFloat(request.parks.count) * 60 + 24, 360))
        // Force a true popover (arrow + modality + earcon) on iPhone instead of letting
        // it adapt into a sheet at compact width.
        .presentationCompactAdaptation(.popover)
        // Drop the popover's container background so only the floating capsule chips
        // show — each chip carries its own material, so no surrounding rectangle.
        .presentationBackground(.clear)
    }

    private func clusterParkTitle(for park: ParkRecord) -> String {
        if !park.locationDesc.isEmpty {
            return park.locationDesc
        }
        return park.name
    }

    private func clusterParkSubtitle(for park: ParkRecord) -> String {
        let parts = park.reference.split(separator: "-")
        if parts.count >= 2 {
            return parts.prefix(2).joined(separator: "-")
        }
        return park.reference
    }

    private var parkIndexBadge: some View {
        HStack(spacing: 5) {
            let filter = AppRouter.shared.mapFilter
            if filter != .localParks {
                Image(systemName: filter.systemImage)
                    .foregroundStyle(markerTint)
                if isFetchingPersonalParks {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading \(filter.title.lowercased())…")
                } else {
                    Text("\(personalParkRefs.count.formatted()) \(filter.title.lowercased())")
                    if filter == .huntedParks && personalParkSource == .hunterLog {
                        Text("from log")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if ParkIndex.shared.isLoaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(ParkIndex.shared.parks.count.formatted()) parks indexed")
            } else {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading park index…")
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Search overlay

    private var searchOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Compact toolbar: location | search field | map/list toggle
            HStack(spacing: 8) {
                // Current location button
                Button {
                    locationManager.refreshLocation()
                    cameraCommand = CameraCommand(region: nil, animated: true)
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 38, height: 38)
                        .background(.regularMaterial, in: Circle())
                }

                // Search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)

                    TextField("Park ref or name…", text: $searchVM.query)
                        .focused($searchFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .submitLabel(.search)
                        .onSubmit { searchVM.search() }
                        .onChange(of: searchVM.query) { _, _ in searchVM.search() }

                    if !searchVM.query.isEmpty {
                        Button {
                            searchVM.clear()
                            pinnedPark = nil
                            searchFocused = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

                // Map / list toggle
                Button {
                    showList.toggle()
                } label: {
                    Image(systemName: showList ? "map" : "list.bullet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 38)
                        .background(.regularMaterial, in: Circle())
                }
            }
            // Report the toolbar's bottom edge (in the map's coordinate space) so
            // the map can exclude pins occluded by this chrome from VoiceOver.
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named("mapContainer")).maxY
            } action: { accessibilityTopInset = max(0, $0) }

            // Search results dropdown (map mode only)
            if !searchVM.results.isEmpty && !showList {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(searchVM.results) { result in
                            Button { select(result) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: result.icon)
                                        .foregroundStyle(.tint)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        if !result.subtitle.isEmpty {
                                            Text(result.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                            }
                            if result.id != searchVM.results.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: Park list overlay

    private var parkListOverlay: some View {
        VStack(spacing: 0) {
            // Spacer matching the toolbar height so the list starts below it
            Color.clear.frame(height: 70)

            // Heading row — changes with the active filter
            HStack {
                Text(listTitle)
                    .font(.headline)
                if isFetchingPersonalParks {
                    ProgressView().scaleEffect(0.7)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 12)
            .background(.regularMaterial)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($listHeadingFocused)

            if filteredNearbyParks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    if isFetchingPersonalParks {
                        ProgressView()
                        Text("Loading your parks…")
                            .foregroundStyle(.secondary)
                    } else if !ParkIndex.shared.isLoaded {
                        ProgressView()
                        Text("Loading park index…")
                            .foregroundStyle(.secondary)
                    } else if AppRouter.shared.mapFilter != .localParks && personalParkRefs.isEmpty {
                        Image(systemName: "person.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(AuthManager.shared.isSignedIn
                             ? "No parks found for this filter"
                             : "Sign in to see your parks")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "location.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(locationManager.authorizationStatus == .authorizedWhenInUse ||
                             locationManager.authorizationStatus == .authorizedAlways
                             ? "Waiting for a live GPS fix"
                             : "Enable location to see nearby parks")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            } else {
                List(filteredNearbyParks) { item in
                    Button {
                        showList = false
                        select(.park(item.park.toPOTAPark()))
                    } label: {
                        HStack(spacing: 12) {
                            // Cardinal + distance column
                            VStack(spacing: 2) {
                                Text(item.cardinal)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tint)
                                Text(item.distanceMi < 10
                                     ? String(format: "%.1f mi", item.distanceMi)
                                     : "\(Int(item.distanceMi)) mi")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .frame(width: 46)

                            // Reference + name
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.park.reference)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                                Text(item.park.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func computeNearbyParks() {
        guard let userLoc = locationManager.userLocation else {
            nearbyParks = []
            return
        }
        nearbyParks = ParkIndex.shared.nearestParks(to: userLoc.coordinate, limit: 200).map { park in
            let loc = CLLocation(latitude: park.latitude, longitude: park.longitude)
            let dist = userLoc.distance(from: loc) * 0.000621371
            let b = parkBearing(from: userLoc.coordinate, to: park.coordinate)
            return NearbyPark(park: park, distanceMi: dist, cardinal: parkCardinal(b))
        }
    }

    /// Filters the park index to parks inside (or near) the visible region.
    /// Only activates when zoomed in enough to avoid plotting tens of thousands of pins.
    private func updateVisibleParks(in region: MKCoordinateRegion) {
        guard ParkIndex.shared.isLoaded, region.span.latitudeDelta < 4.0 else {
            if visibleParkQuery != nil {
                visibleParkQuery = nil
                updateVisibleParksIfChanged([])
            }
            return
        }
        let latHalf = region.span.latitudeDelta / 2
        let lonHalf = region.span.longitudeDelta / 2
        let visibleBounds = ParkCoordinateBounds(
            minLatitude: region.center.latitude - latHalf,
            maxLatitude: region.center.latitude + latHalf,
            minLongitude: region.center.longitude - lonHalf,
            maxLongitude: region.center.longitude + lonHalf
        )

        if let visibleParkQuery, visibleParkQuery.canReuse(for: visibleBounds, region: region) {
            return
        }

        let paddingScale = prefetchScale(for: region)
        let queryBounds = paddedBounds(around: visibleBounds, latitudePadding: latHalf * paddingScale, longitudePadding: lonHalf * paddingScale)
        let results = ParkIndex.shared.parks(in: queryBounds)
        visibleParkQuery = VisibleParkQuery(
            bounds: queryBounds,
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
        updateVisibleParksIfChanged(results.count <= 2000 ? results : Array(results.prefix(2000)))
    }

    private func paddedBounds(
        around bounds: ParkCoordinateBounds,
        latitudePadding: Double,
        longitudePadding: Double
    ) -> ParkCoordinateBounds {
        ParkCoordinateBounds(
            minLatitude: max(-90, bounds.minLatitude - latitudePadding),
            maxLatitude: min(90, bounds.maxLatitude + latitudePadding),
            minLongitude: max(-180, bounds.minLongitude - longitudePadding),
            maxLongitude: min(180, bounds.maxLongitude + longitudePadding)
        )
    }

    private func prefetchScale(for region: MKCoordinateRegion) -> Double {
        switch region.span.latitudeDelta {
        case ..<0.5: return 4.0
        case ..<1.5: return 2.5
        default: return 1.5
        }
    }

    /// Frames the map around the user's activated parks. A single park gets a city-level
    /// zoom; multiple parks get a padded bounding box. No-op until ParkIndex has resolved
    /// the coordinates, or if the filter changed out from under the async fetch.
    private func fitCameraToActivatedParks() {
        guard AppRouter.shared.mapFilter == .activatedParks else { return }
        let coords = personalParkRefs.compactMap { ParkIndex.shared.park(reference: $0)?.coordinate }
        guard !coords.isEmpty else { return }

        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.15),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.15)
        )
        cameraCommand = CameraCommand(
            region: MKCoordinateRegion(center: center, span: span),
            animated: true
        )
    }

    private func updateVisibleParksIfChanged(_ parks: [ParkRecord]) {
        guard parks.count != visibleParks.count ||
              !parks.elementsEqual(visibleParks, by: { $0.reference == $1.reference }) else { return }
        visibleParks = parks
    }

    private func select(_ result: MapSearchResult) {
        cameraCommand = CameraCommand(
            region: MKCoordinateRegion(
                center: result.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
            ),
            animated: true
        )
        if case .park(let park) = result {
            pinnedPark = park
            presentedPark = park
        }
        searchVM.results = []
        searchFocused = false
    }

    // MARK: - Personal park fetch

    /// Fetches the list of park references for the signed-in user's activations or hunts
    /// and stores them in `personalParkRefs` for viewport filtering.
    private func fetchPersonalParks(for filter: MapFilter) async {
        // Wait for startup token refresh so callsign is populated before we read it.
        await AuthManager.shared.startupTask?.value
        guard let callsign = AuthManager.shared.callsign else {
            print("[MapView] fetchPersonalParks: no callsign, aborting")
            return
        }

        await MainActor.run { isFetchingPersonalParks = true }
        defer { Task { await MainActor.run { isFetchingPersonalParks = false } } }

        switch filter {
        case .localParks:     return
        case .activatedParks:
            // /user/activations?all=1 is the authoritative list pota.app itself uses for
            // "My Activations" — one request, distinct parks. (The old
            // /activator/<call>/activations endpoint returned nothing.)
            if let fetched = await fetchPersonalParkRefsFromAPI(path: "/user/activations?all=1") {
                await MainActor.run {
                    // Guard against a slower fetch from a previous filter landing after the
                    // user has already switched away — otherwise it overwrites this set.
                    guard AppRouter.shared.mapFilter == filter else { return }
                    personalParkRefs = fetched.refs
                    personalParkSource = fetched.source
                    // Activated parks have no location-radiating lines like hunted parks,
                    // so frame the user's activations directly — otherwise a few scattered
                    // pins are easy to miss wherever the camera happens to be.
                    fitCameraToActivatedParks()
                }
            }
        case .huntedParks:
            if let fetched = await fetchHuntedParkData(callsign: callsign) {
                await MainActor.run {
                    guard AppRouter.shared.mapFilter == filter else { return }
                    personalParkRefs = fetched.refs
                    personalParkSource = fetched.source
                    resolveHuntedParkLines()
                }
            }
        }
    }

    private func fetchHuntedParkData(callsign: String) async -> PersonalParkRefs? {
        print("[MapView] fetchHuntedParkData: scraping hunter log for \(callsign)")
        let counts = await POTAHunterLogScraper.shared.fetchParkQSOCounts(callsign: callsign)
        print("[MapView] fetchHuntedParkData: scraper returned \(counts.count) parks")
        if !counts.isEmpty {
            await MainActor.run { huntedParkQSOCounts = counts }
            return PersonalParkRefs(refs: Set(counts.keys), source: .hunterLog)
        }

        // Fallback: POTA API (no QSO counts available)
        print("[MapView] fetchHuntedParkData: scraper empty, trying API fallback")
        await MainActor.run { huntedParkQSOCounts = [:] }
        let result = await fetchPersonalParkRefsFromAPI(path: "/hunter/\(callsign)/activations")
        print("[MapView] fetchHuntedParkData: API returned \(result?.refs.count ?? -1) parks (nil=failed)")
        return result
    }

    /// Resolves personalParkRefs against ParkIndex, sorts by QSO count desc, caps at 200.
    private func resolveHuntedParkLines() {
        guard AppRouter.shared.mapFilter == .huntedParks else { return }
        let counts = huntedParkQSOCounts
        huntedParkLines = personalParkRefs
            .compactMap { ParkIndex.shared.park(reference: $0) }
            .map { HuntedParkLine(id: $0.reference, coordinate: $0.coordinate, qsoCount: counts[$0.reference] ?? 0) }
            .sorted { $0.qsoCount > $1.qsoCount }
            .prefix(200)
            .map { $0 }
    }

    private func fetchPersonalParkRefsFromAPI(path: String) async -> PersonalParkRefs? {
        guard let token = AuthManager.shared.idToken ?? AuthManager.shared.accessToken,
              let url = URL(string: "https://api.pota.app\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        // Primary: an array of objects carrying a "reference" key.
        struct ParkRef: Decodable { let reference: String }
        if let records = try? JSONDecoder().decode([ParkRef].self, from: data) {
            return PersonalParkRefs(refs: Set(records.map(\.reference)), source: .api)
        }

        // Fallback: tolerate wrapped or differently-named shapes by pulling any
        // park-reference-looking strings out of the raw JSON.
        let refs = Self.parkRefs(fromLooseJSON: data)
        return refs.isEmpty ? nil : PersonalParkRefs(refs: refs, source: .api)
    }

    /// Extracts park references from an arbitrary JSON payload by walking it and matching
    /// "reference"/"parkRef"/"park" string values against the POTA reference pattern.
    private static func parkRefs(fromLooseJSON data: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var refs = Set<String>()

        func walk(_ node: Any) {
            switch node {
            case let array as [Any]:
                array.forEach(walk)
            case let dict as [String: Any]:
                for key in ["reference", "parkRef", "park"] {
                    if let value = dict[key] as? String,
                       let ref = POTAHunterLogScraper.extractParkRef(from: value) {
                        refs.insert(ref)
                    }
                }
                dict.values.forEach(walk)
            default:
                break
            }
        }

        walk(root)
        return refs
    }

}

// MARK: - Bearing / cardinal helpers

private func parkBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
    let lat1 = from.latitude  * .pi / 180
    let lat2 = to.latitude    * .pi / 180
    let dLon = (to.longitude - from.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
}

private func parkCardinal(_ degrees: Double) -> String {
    ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((degrees + 22.5) / 45) % 8]
}

// MARK: - Helpers

private extension View {
    @ViewBuilder
    func mapFilterChipStyle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            self
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}

private extension MapSearchResult {
    var icon: String {
        switch self {
        case .park:  return "tree.fill"
        case .place: return "mappin"
        }
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)

/// Presents SwiftUI content as a **borderless, arrow-less** UIKit popover.
///
/// We must present through `UIPopoverPresentationController` because that is what
/// makes VoiceOver play the modal "popover" chime — decompiling UIKit's a11y bundle
/// showed the chime comes from the presentation controller modalizing its transition
/// view, not from any notification, and a SwiftUI overlay never triggers it. But the
/// system popover also draws an arrow + rounded platter we don't want. This presenter
/// keeps the presentation (and its earcon) while removing the arrow (`permittedArrowDirections
/// = []`) and the platter (`.clear` background + a no-draw `UIPopoverBackgroundView`),
/// leaving only the floating capsule chips.
struct BorderlessClusterPopover<Item: Identifiable, Content: View>: UIViewControllerRepresentable {
    @Binding var item: Item?
    /// Anchor in this view's coordinate space (the map container) the popover points at.
    var anchorPoint: CGPoint
    @ViewBuilder var content: (Item) -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false   // anchor only — never blocks the map
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(anchorHost: vc)
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var parent: BorderlessClusterPopover
        private weak var presented: UIViewController?
        private var presentedID: Item.ID?

        init(_ parent: BorderlessClusterPopover) { self.parent = parent }

        func sync(anchorHost: UIViewController) {
            // Dismiss when the item cleared or changed identity.
            if let presented, presentedID != parent.item?.id {
                presented.dismiss(animated: true)
                self.presented = nil
                presentedID = nil
            }

            guard let item = parent.item, presented == nil else { return }
            guard anchorHost.viewIfLoaded?.window != nil else {
                // Not in a window yet — retry on the next runloop tick.
                DispatchQueue.main.async { [weak self, weak anchorHost] in
                    guard let self, let anchorHost else { return }
                    self.sync(anchorHost: anchorHost)
                }
                return
            }

            let host = UIHostingController(rootView: parent.content(item))
            host.view.backgroundColor = .clear
            host.sizingOptions = [.preferredContentSize]  // size the popover to the chips
            host.modalPresentationStyle = .popover

            guard let pop = host.popoverPresentationController else { return }
            pop.delegate = self
            pop.permittedArrowDirections = []            // no arrow
            pop.backgroundColor = .clear                 // no platter tint
            pop.popoverBackgroundViewClass = NoChromePopoverBackground.self  // no border/shadow
            pop.sourceView = anchorHost.view
            pop.sourceRect = CGRect(x: parent.anchorPoint.x, y: parent.anchorPoint.y, width: 1, height: 1)

            anchorHost.present(host, animated: true)
            presented = host
            presentedID = item.id
        }

        // Stay a popover on iPhone instead of adapting to a full-screen sheet.
        func adaptivePresentationStyle(for controller: UIPresentationController,
                                       traitCollection: UITraitCollection) -> UIModalPresentationStyle {
            .none
        }

        // Outside-tap / swipe dismiss → clear the SwiftUI binding.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            presented = nil
            presentedID = nil
            if parent.item != nil { parent.item = nil }
        }
    }
}

/// A `UIPopoverBackgroundView` that draws nothing: no arrow, no border, no shadow,
/// zero content insets. Turns the system popover into a transparent container so only
/// the presented content (the floating chips) is visible.
final class NoChromePopoverBackground: UIPopoverBackgroundView {
    private var _arrowOffset: CGFloat = 0
    private var _arrowDirection: UIPopoverArrowDirection = .up

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowColor = UIColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var arrowOffset: CGFloat {
        get { _arrowOffset } set { _arrowOffset = newValue }
    }
    override var arrowDirection: UIPopoverArrowDirection {
        get { _arrowDirection } set { _arrowDirection = newValue }
    }

    override class func arrowBase() -> CGFloat { 0 }
    override class func arrowHeight() -> CGFloat { 0 }
    override class func contentViewInsets() -> UIEdgeInsets { .zero }
}

#endif
