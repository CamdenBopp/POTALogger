//
//  ContentView.swift
//  POTALogger
//
//  Created by Camden Bopp on 4/6/25.
//

import SwiftUI
import CoreData
#if os(iOS)
import UIKit
#endif

struct ContentView: View {
    @State private var router = AppRouter.shared

    var body: some View {
        TabView(selection: Binding(
            get: { router.selectedTab.rawValue },
            set: { router.selectedTab = AppTab(rawValue: $0) ?? .spots }
        )) {
            SpotsView()
                .tabItem { Label("Spots", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppTab.spots.rawValue)

            MapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(AppTab.map.rawValue)

            MyLogsView()
                .tabItem { Label("My Logs", systemImage: "list.bullet.clipboard") }
                .tag(AppTab.logs.rawValue)

            #if !targetEnvironment(macCatalyst)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(AppTab.settings.rawValue)
            #endif
        }
        .onOpenURL { url in
            router.handle(url)
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .background(MapTabContextMenuInstaller())
        #endif
        #if targetEnvironment(macCatalyst)
        .sheet(isPresented: $router.showSettings) {
            SettingsView()
                .frame(minWidth: 400, minHeight: 300)
        }
        #endif
    }
}

struct MyLogsView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Item.timestamp, ascending: true)],
        animation: .default)
    private var items: FetchedResults<Item>

    var body: some View {
        NavigationView {
            List {
                ForEach(items) { item in
                    NavigationLink {
                        Text("Item at \(item.timestamp!, formatter: itemFormatter)")
                    } label: {
                        Text(item.timestamp!, formatter: itemFormatter)
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .navigationTitle("My Logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(context: viewContext)
            newItem.timestamp = Date()
            do {
                try viewContext.save()
            } catch {
                let nsError = error as NSError
                fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
            }
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            offsets.map { items[$0] }.forEach(viewContext.delete)
            do {
                try viewContext.save()
            } catch {
                let nsError = error as NSError
                fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
            }
        }
    }
}

private let itemFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()

#if os(iOS) && !targetEnvironment(macCatalyst)
private struct MapTabContextMenuInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InstallerViewController {
        InstallerViewController()
    }

    func updateUIViewController(_ uiViewController: InstallerViewController, context: Context) {}

    final class InstallerViewController: UIViewController, UIContextMenuInteractionDelegate {
        private weak var attachedTabBar: UITabBar?
        private lazy var interaction = UIContextMenuInteraction(delegate: self)
        private lazy var anchorView: UIView = {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            return view
        }()
        private var lastMenuLocation: CGPoint = .zero

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfNeeded()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installIfNeeded()
        }

        func installIfNeeded() {
            guard let tabBar = resolveTabBar(), tabBar !== attachedTabBar else { return }
            attachedTabBar?.removeInteraction(interaction)
            anchorView.removeFromSuperview()
            tabBar.addInteraction(interaction)
            tabBar.addSubview(anchorView)
            attachedTabBar = tabBar
        }

        private func resolveTabBar() -> UITabBar? {
            var vc: UIViewController? = self
            while let current = vc {
                if let tabBarController = current as? UITabBarController { return tabBarController.tabBar }
                vc = current.parent
            }

            guard let root = view.window?.rootViewController else { return nil }
            var queue: [UIViewController] = [root]
            while !queue.isEmpty {
                let current = queue.removeFirst()
                if let tabBarController = current as? UITabBarController { return tabBarController.tabBar }
                queue.append(contentsOf: current.children)
            }
            return nil
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let tabBar = attachedTabBar, isMapTabRegion(location, in: tabBar) else { return nil }
            lastMenuLocation = location

            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(title: "Map Filter", children: [
                    UIAction(
                        title: MapFilter.localParks.title,
                        image: UIImage(systemName: MapFilter.localParks.systemImage),
                        state: AppRouter.shared.mapFilter == .localParks ? .on : .off
                    ) { _ in
                        AppRouter.shared.mapFilter = .localParks
                        AppRouter.shared.selectedTab = .map
                    },
                    UIAction(
                        title: MapFilter.activatedParks.title,
                        image: UIImage(systemName: MapFilter.activatedParks.systemImage),
                        state: AppRouter.shared.mapFilter == .activatedParks ? .on : .off
                    ) { _ in
                        AppRouter.shared.mapFilter = .activatedParks
                        AppRouter.shared.selectedTab = .map
                    },
                    UIAction(
                        title: MapFilter.huntedParks.title,
                        image: UIImage(systemName: MapFilter.huntedParks.systemImage),
                        state: AppRouter.shared.mapFilter == .huntedParks ? .on : .off
                    ) { _ in
                        AppRouter.shared.mapFilter = .huntedParks
                        AppRouter.shared.selectedTab = .map
                    },
                ])
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            anchorPreview()
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            anchorPreview()
        }

        private func anchorPreview() -> UITargetedPreview? {
            guard let tabBar = attachedTabBar else { return nil }
            anchorView.frame = CGRect(origin: lastMenuLocation, size: CGSize(width: 1, height: 1))
            let params = UIPreviewParameters()
            params.backgroundColor = .clear
            params.shadowPath = UIBezierPath()
            return UITargetedPreview(
                view: anchorView,
                parameters: params,
                target: UIPreviewTarget(container: tabBar, center: lastMenuLocation)
            )
        }

        private func isMapTabRegion(_ location: CGPoint, in tabBar: UITabBar) -> Bool {
            #if targetEnvironment(macCatalyst)
            let tabCount: CGFloat = 3
            #else
            let tabCount: CGFloat = 4
            #endif
            let sliceWidth = tabBar.bounds.width / tabCount
            let minX = sliceWidth * CGFloat(AppTab.map.rawValue)
            return location.x >= minX && location.x < minX + sliceWidth
        }
    }
}
#endif

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(LocationManager())
}
