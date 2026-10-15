import SwiftUI

// MARK: - App Router
//
// Supported x-callback-url actions:
//   potalog://spots              → switch to Spots tab
//   potalog://map                → switch to Map tab (map view)
//   potalog://map?view=list      → switch to Map tab, open list view
//   potalog://map?view=map       → switch to Map tab, close list view
//   potalog://logs               → switch to My Logs tab
//   potalog://settings           → switch to Settings tab
//
//   potalog://map?type=local      → switch to Map tab, show Local Parks
//   potalog://map?type=activated  → switch to Map tab, show Activated Parks
//   potalog://map?type=hunted     → switch to Map tab, show Hunted Parks

enum AppTab: Int {
    case spots    = 0
    case map      = 1
    case logs     = 2
    case settings = 3
}

enum MapFilter {
    case localParks
    case activatedParks
    case huntedParks

    var title: String {
        switch self {
        case .localParks:     return "Local Parks"
        case .activatedParks: return "Activated Parks"
        case .huntedParks:    return "Hunted Parks"
        }
    }

    var systemImage: String {
        switch self {
        case .localParks:     return "map"
        case .activatedParks: return "checkmark.seal.fill"
        case .huntedParks:    return "binoculars.fill"
        }
    }
}

@Observable
final class AppRouter {
    static let shared = AppRouter()

    var selectedTab: AppTab = .spots
    /// Non-nil when a URL has requested a specific map view mode.
    /// MapView observes this and resets it to nil after applying.
    var requestedMapList: Bool? = nil
    /// Which set of parks to display on the Map tab.
    var mapFilter: MapFilter = .localParks
    /// Triggers the settings sheet on macOS (Cmd+,).
    var showSettings = false

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "potalog" else { return }
        let host = url.host?.lowercased() ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let viewParam = components?.queryItems?.first(where: { $0.name == "view" })?.value
        let typeParam = components?.queryItems?.first(where: { $0.name == "type" })?.value

        switch host {
        case "spots":
            selectedTab = .spots

        case "map":
            selectedTab = .map
            if let typeParam {
                switch typeParam {
                case "local":     mapFilter = .localParks
                case "activated": mapFilter = .activatedParks
                case "hunted":    mapFilter = .huntedParks
                default:          break
                }
            }
            if let viewParam {
                requestedMapList = (viewParam == "list")
            }

        case "logs":
            selectedTab = .logs

        case "settings":
            selectedTab = .settings

        default:
            break
        }
    }
}
