import Foundation
import CoreData
import CoreLocation

// MARK: - Park Record

struct ParkRecord {
    let reference: String
    let name: String
    let active: Bool
    let locationDesc: String
    let latitude: Double
    let longitude: Double
    let grid: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var hasValidCoordinate: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    func toPOTAPark() -> POTAPark {
        POTAPark(
            reference: reference,
            name: name,
            latitude: latitude,
            longitude: longitude,
            locationDesc: locationDesc.isEmpty ? nil : locationDesc,
            parktypeDesc: nil
        )
    }
}

// MARK: - Park Spatial Index

struct ParkCoordinateBounds {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    var midLatitude: Double { (minLatitude + maxLatitude) / 2 }
    var midLongitude: Double { (minLongitude + maxLongitude) / 2 }

    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= minLatitude &&
        latitude <= maxLatitude &&
        longitude >= minLongitude &&
        longitude <= maxLongitude
    }

    func intersects(_ other: ParkCoordinateBounds) -> Bool {
        !(other.minLatitude > maxLatitude ||
          other.maxLatitude < minLatitude ||
          other.minLongitude > maxLongitude ||
          other.maxLongitude < minLongitude)
    }
}

private final class ParkQuadTree {
    private final class Node {
        private static let capacity = 16
        private static let maxDepth = 18

        let bounds: ParkCoordinateBounds
        private var parks: [ParkRecord] = []
        private var children: [Node] = []
        private let depth: Int

        init(bounds: ParkCoordinateBounds, depth: Int = 0) {
            self.bounds = bounds
            self.depth = depth
        }

        func insert(_ park: ParkRecord) {
            guard bounds.contains(latitude: park.latitude, longitude: park.longitude) else { return }

            if !children.isEmpty {
                child(containing: park)?.insert(park)
                return
            }

            parks.append(park)
            if parks.count > Self.capacity && depth < Self.maxDepth {
                subdivide()
            }
        }

        func query(in queryBounds: ParkCoordinateBounds, into results: inout [ParkRecord]) {
            guard bounds.intersects(queryBounds) else { return }

            for park in parks where queryBounds.contains(latitude: park.latitude, longitude: park.longitude) {
                results.append(park)
            }

            for child in children {
                child.query(in: queryBounds, into: &results)
            }
        }

        private func child(containing park: ParkRecord) -> Node? {
            children.first { $0.bounds.contains(latitude: park.latitude, longitude: park.longitude) }
        }

        private func subdivide() {
            let midLat = bounds.midLatitude
            let midLon = bounds.midLongitude
            children = [
                Node(bounds: ParkCoordinateBounds(
                    minLatitude: bounds.minLatitude,
                    maxLatitude: midLat,
                    minLongitude: bounds.minLongitude,
                    maxLongitude: midLon
                ), depth: depth + 1),
                Node(bounds: ParkCoordinateBounds(
                    minLatitude: bounds.minLatitude,
                    maxLatitude: midLat,
                    minLongitude: midLon,
                    maxLongitude: bounds.maxLongitude
                ), depth: depth + 1),
                Node(bounds: ParkCoordinateBounds(
                    minLatitude: midLat,
                    maxLatitude: bounds.maxLatitude,
                    minLongitude: bounds.minLongitude,
                    maxLongitude: midLon
                ), depth: depth + 1),
                Node(bounds: ParkCoordinateBounds(
                    minLatitude: midLat,
                    maxLatitude: bounds.maxLatitude,
                    minLongitude: midLon,
                    maxLongitude: bounds.maxLongitude
                ), depth: depth + 1)
            ]

            let existing = parks
            parks.removeAll(keepingCapacity: false)
            for park in existing {
                child(containing: park)?.insert(park)
            }
        }
    }

    private let root = Node(bounds: ParkCoordinateBounds(
        minLatitude: -90,
        maxLatitude: 90,
        minLongitude: -180,
        maxLongitude: 180
    ))

    init(parks: [ParkRecord]) {
        for park in parks {
            root.insert(park)
        }
    }

    func query(in bounds: ParkCoordinateBounds) -> [ParkRecord] {
        var results: [ParkRecord] = []
        root.query(in: bounds, into: &results)
        return results
    }
}

// MARK: - Park Index

/// Persists all_parks_ext.csv to Core Data and provides fast local name/reference search.
/// On first launch, downloads the CSV and populates the store. On subsequent launches,
/// loads from Core Data immediately and re-downloads only when the data is older than 7 days.
@Observable
final class ParkIndex {
    static let shared = ParkIndex()

    private(set) var parks: [ParkRecord] = []
    private(set) var parksByReference: [String: ParkRecord] = [:]
    private(set) var isLoaded = false
    @ObservationIgnored private var spatialIndex: ParkQuadTree?
    private var loadTask: Task<Void, Never>?

    private static let lastFetchedKey = "parkIndexLastFetched"
    private static let refreshInterval: TimeInterval = 7 * 24 * 3600

    /// Drops the in-memory park array. Call when entering the background so the OS
    /// doesn't kill the process for holding 50k+ records nobody can see.
    @MainActor
    func releaseMemory() {
        parks = []
        parksByReference = [:]
        spatialIndex = nil
        isLoaded = false
        loadTask?.cancel()
        loadTask = nil
    }

    func load() {
        guard loadTask == nil else { return }
        loadTask = Task.detached(priority: .userInitiated) {
            // 1. Fast path: serve from Core Data if available
            let cached = Self.loadFromStore()
            if !cached.isEmpty {
                let index = Self.makeReferenceIndex(cached)
                let spatialIndex = ParkQuadTree(parks: cached)
                await MainActor.run {
                    ParkIndex.shared.replaceInMemoryParks(
                        cached,
                        parksByReference: index,
                        spatialIndex: spatialIndex
                    )
                }
            }

            // 2. Refresh if empty or stale (> 7 days)
            let lastFetch = UserDefaults.standard.double(forKey: Self.lastFetchedKey)
            let age = Date().timeIntervalSince1970 - lastFetch
            if cached.isEmpty || age > Self.refreshInterval {
                await Self.downloadAndStore()
            }
        }
    }

    /// Case-insensitive substring match on name and reference; prefix matches ranked first.
    func search(_ query: String) -> [ParkRecord] {
        guard isLoaded else { return [] }
        return ParkIndex.search(parks, query: query)
    }

    func park(reference: String) -> ParkRecord? {
        parksByReference[reference]
    }

    func parks(in bounds: ParkCoordinateBounds) -> [ParkRecord] {
        guard isLoaded else { return [] }
        guard let spatialIndex else {
            return parks.filter { bounds.contains(latitude: $0.latitude, longitude: $0.longitude) }
        }
        return spatialIndex.query(in: bounds)
    }

    func nearestParks(to coordinate: CLLocationCoordinate2D, limit: Int) -> [ParkRecord] {
        guard isLoaded else { return [] }

        let candidates: [ParkRecord]
        if let spatialIndex {
            candidates = Self.nearestCandidates(from: spatialIndex, around: coordinate, limit: limit)
        } else {
            candidates = parks
        }

        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return candidates
            .sorted {
                let lhs = CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                let rhs = CLLocation(latitude: $1.latitude, longitude: $1.longitude)
                return origin.distance(from: lhs) < origin.distance(from: rhs)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Pure search over an arbitrary park list. Extracted for testability.
    static func search(_ parks: [ParkRecord], query: String) -> [ParkRecord] {
        let q = query.lowercased()
        var matches = parks.filter {
            $0.name.lowercased().contains(q) ||
            $0.reference.lowercased().contains(q)
        }
        matches.sort {
            let aPrefix = $0.name.lowercased().hasPrefix(q)
            let bPrefix = $1.name.lowercased().hasPrefix(q)
            if aPrefix != bPrefix { return aPrefix }
            return $0.name < $1.name
        }
        return Array(matches.prefix(8))
    }

    private static func makeReferenceIndex(_ parks: [ParkRecord]) -> [String: ParkRecord] {
        parks.reduce(into: [:]) { index, park in
            index[park.reference] = park
        }
    }

    @MainActor
    private func replaceInMemoryParks(
        _ parks: [ParkRecord],
        parksByReference: [String: ParkRecord],
        spatialIndex: ParkQuadTree
    ) {
        self.parks = parks
        self.parksByReference = parksByReference
        self.spatialIndex = spatialIndex
        self.isLoaded = true
    }

    private static func nearestCandidates(
        from spatialIndex: ParkQuadTree,
        around coordinate: CLLocationCoordinate2D,
        limit: Int
    ) -> [ParkRecord] {
        let expansions = [0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 180]
        var candidates: [ParkRecord] = []
        for degrees in expansions {
            let bounds = ParkCoordinateBounds(
                minLatitude: max(-90, coordinate.latitude - degrees),
                maxLatitude: min(90, coordinate.latitude + degrees),
                minLongitude: max(-180, coordinate.longitude - degrees),
                maxLongitude: min(180, coordinate.longitude + degrees)
            )
            candidates = spatialIndex.query(in: bounds)
            if candidates.count >= limit || degrees == expansions.last {
                break
            }
        }
        return candidates
    }

    // MARK: - Core Data

    private static func loadFromStore() -> [ParkRecord] {
        let ctx = PersistenceController.shared.container.newBackgroundContext()
        var records: [ParkRecord] = []
        ctx.performAndWait {
            let req = NSFetchRequest<NSDictionary>(entityName: "CachedPark")
            req.resultType = .dictionaryResultType
            guard let dicts = try? ctx.fetch(req) else { return }
            records = dicts.compactMap { d in
                guard let ref  = d["reference"] as? String,
                      let name = d["name"] as? String,
                      let lat  = d["latitude"]  as? Double,
                      let lon  = d["longitude"] as? Double else { return nil }
                let record = ParkRecord(
                    reference:   ref,
                    name:        name,
                    active:      d["active"]      as? Bool   ?? true,
                    locationDesc: d["locationDesc"] as? String ?? "",
                    latitude:    lat,
                    longitude:   lon,
                    grid:        d["grid"]        as? String ?? ""
                )
                return record.hasValidCoordinate ? record : nil
            }
        }
        return records
    }

    private static func downloadAndStore() async {
        guard let url = URL(string: "https://pota.app/all_parks_ext.csv") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let records = parseCSV(data)
            guard !records.isEmpty else { return }

            let ctx = PersistenceController.shared.container.newBackgroundContext()

            // Replace all existing parks then batch-insert fresh data
            try await ctx.perform {
                let deleteReq: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "CachedPark")
                try ctx.execute(NSBatchDeleteRequest(fetchRequest: deleteReq))

                var i = 0
                let insertReq = NSBatchInsertRequest(entityName: "CachedPark") { (dict: NSMutableDictionary) -> Bool in
                    guard i < records.count else { return true }
                    let r = records[i]
                    dict["reference"]    = r.reference
                    dict["name"]         = r.name
                    dict["active"]       = r.active
                    dict["locationDesc"] = r.locationDesc.isEmpty ? nil : r.locationDesc
                    dict["latitude"]     = r.latitude
                    dict["longitude"]    = r.longitude
                    dict["grid"]         = r.grid.isEmpty ? nil : r.grid
                    i += 1
                    return false
                }
                try ctx.execute(insertReq)
            }

            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastFetchedKey)

            // Reuse the already-parsed records — avoids a full duplicate allocation from Core Data
            let index = Self.makeReferenceIndex(records)
            let spatialIndex = ParkQuadTree(parks: records)
            await MainActor.run {
                ParkIndex.shared.replaceInMemoryParks(
                    records,
                    parksByReference: index,
                    spatialIndex: spatialIndex
                )
            }
        } catch {
            // Silent failure — existing cached data (or empty) remains in use
        }
    }

    // MARK: - CSV Parsing

    // CSV columns: reference,name,active,parkTypeId,locationDesc,latitude,longitude,grid
    static func parseCSV(_ data: Data) -> [ParkRecord] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var records = [ParkRecord]()
        records.reserveCapacity(60_000)
        var isFirstLine = true
        // enumerateLines processes one line at a time without allocating a [String] for all lines
        text.enumerateLines { line, _ in
            if isFirstLine { isFirstLine = false; return } // skip header
            guard !line.isEmpty else { return }
            let f = parseRow(line)
            guard f.count >= 8,
                  let lat = Double(f[5]),
                  let lon = Double(f[6]) else { return }
            let record = ParkRecord(
                reference:    f[0],
                name:         f[1],
                active:       f[2] == "1",
                locationDesc: f[4],
                latitude:     lat,
                longitude:    lon,
                grid:         f[7]
            )
            guard record.hasValidCoordinate else { return }
            records.append(record)
        }
        return records
    }

    /// RFC 4180 CSV row parser — handles quoted fields containing commas.
    static func parseRow(_ line: String) -> [String] {
        var fields = [String]()
        var current = ""
        var inQuotes = false
        var idx = line.startIndex

        while idx < line.endIndex {
            let c = line[idx]
            switch c {
            case "\"":
                let next = line.index(after: idx)
                if inQuotes && next < line.endIndex && line[next] == "\"" {
                    current.append("\"")
                    idx = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            default:
                current.append(c)
            }
            idx = line.index(after: idx)
        }
        fields.append(current)
        return fields
    }
}
