//
//  POTALoggerApp.swift
//  POTALogger
//
//  Created by Camden Bopp on 4/6/25.
//

import SwiftUI
import AppIntents

@main
struct POTALoggerApp: App {
    let persistenceController = PersistenceController.shared
    @State private var locationManager = LocationManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        POTAShortcutsProvider.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(locationManager)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Release the 50k-record park index so the OS doesn't kill us while backgrounded
                ParkIndex.shared.releaseMemory()
            case .active:
                // Reload from Core Data on foreground (fast path, no network unless stale)
                ParkIndex.shared.load()
            default:
                break
            }
        }
        #if targetEnvironment(macCatalyst)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppRouter.shared.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        #endif
    }
}
