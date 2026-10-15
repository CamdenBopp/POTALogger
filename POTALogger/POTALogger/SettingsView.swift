import SwiftUI
import UserNotifications

struct SettingsView: View {
    private var displayIcon: String {
        #if targetEnvironment(macCatalyst)
        "macbook"
        #else
        "iphone.gen3"
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        MyProfileSettingsView()
                    } label: {
                        Label {
                            Text("My Profile")
                        } icon: {
                            SettingsIcon(systemImage: "person.fill", color: .indigo)
                        }
                    }

                }

                Section {
                    NavigationLink {
                        DisplayAppearanceView()
                    } label: {
                        Label {
                            Text("Display & Appearance")
                        } icon: {
                            SettingsIcon(systemImage: displayIcon, color: .blue)
                        }
                    }

                    NavigationLink {
                        SpotsSettingsView()
                    } label: {
                        Label {
                            Text("Spots")
                        } icon: {
                            SettingsIcon(systemImage: "dot.radiowaves.left.and.right", color: .green)
                        }
                    }

                    NavigationLink {
                        NotificationsSettingsView()
                    } label: {
                        Label {
                            Text("Notifications")
                        } icon: {
                            SettingsIcon(systemImage: "bell.badge.fill", color: .red)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Label {
                            Text("Advanced")
                        } icon: {
                            SettingsIcon(systemImage: "gearshape.2.fill", color: .gray)
                        }
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct SettingsIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(.white)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Destination views

struct DisplayAppearanceView: View {
    @AppStorage(FrequencyFormatOptions.unitKey)  private var freqUnit  = FrequencyUnit.MHz.rawValue
    @AppStorage(FrequencyFormatOptions.zerosKey) private var freqZeros = FrequencyZeros.trimmed.rawValue
    @AppStorage(SpotListStyle.storageKey) private var spotListStyleRaw = SpotListStyle.default.rawValue
    @AppStorage(SpotIdentityDisplay.storageKey) private var spotIdentityDisplayRaw = SpotIdentityDisplay.none.rawValue
    @AppStorage("awards.showPreview") private var showAwardsPreview = true

    private var selectedUnit: FrequencyUnit { FrequencyUnit(rawValue: freqUnit) ?? .MHz }
    private var selectedZeros: FrequencyZeros { FrequencyZeros(rawValue: freqZeros) ?? .trimmed }
    private var preview: String { formatFrequency("7036", unit: selectedUnit, trailingZeros: selectedZeros) }

    var body: some View {
        Form {
            Section("Frequency Display") {
                Picker("Unit", selection: $freqUnit) {
                    ForEach(FrequencyUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Trailing zeros", isOn: Binding(
                    get: { selectedZeros == .shown },
                    set: { freqZeros = ($0 ? FrequencyZeros.shown : .trimmed).rawValue }
                ))

                LabeledContent("Preview") {
                    Text(preview)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Section {
                Picker("Spot List Style", selection: $spotListStyleRaw) {
                    ForEach(SpotListStyle.allCases) { style in
                        Text(style.rawValue).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Spot Identity", selection: $spotIdentityDisplayRaw) {
                    ForEach(SpotIdentityDisplay.allCases) { display in
                        Text(display.rawValue).tag(display.rawValue)
                    }
                }
            } header: {
                Text("Spots")
            } footer: {
                Text("Default uses the original plain list row. Spot Identity can show country flags, activator profiles, or both.")
            }

            Section {
                Toggle("Show Awards Preview", isOn: $showAwardsPreview)
            } header: {
                Text("Awards")
            } footer: {
                Text("When enabled, earned awards show certificate preview cards. Turn it off to use the simpler rosette style.")
            }

        }
        .navigationTitle("Display & Appearance")
    }
}

struct SpotsSettingsView: View {
    @AppStorage(SpotAutoRefreshInterval.storageKey) private var autoRefreshRaw = SpotAutoRefreshInterval.default.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Auto Refresh", selection: $autoRefreshRaw) {
                    ForEach(SpotAutoRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval.rawValue)
                    }
                }
            } footer: {
                Text("Automatically reload the spots list at the selected interval. You can always pull to refresh.")
            }
        }
        .navigationTitle("Spots")
    }
}

struct NotificationsSettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @State private var showDeniedAlert = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Notifications", isOn: Binding(
                    get: { notificationsEnabled },
                    set: { newValue in
                        if newValue {
                            requestNotificationPermission()
                        } else {
                            notificationsEnabled = false
                        }
                    }
                ))
            } footer: {
                Text("Notifications are off by default. Enabling requires permission from your device.")
            }
        }
        .navigationTitle("Notifications")
        .alert("Notifications Denied", isPresented: $showDeniedAlert) {
            Button("Open Settings") {
                #if targetEnvironment(macCatalyst)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    UIApplication.shared.open(url)
                }
                #else
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #endif
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notifications have been denied. Please enable them in System Settings.")
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    notificationsEnabled = true
                } else {
                    notificationsEnabled = false
                    UNUserNotificationCenter.current().getNotificationSettings { settings in
                        DispatchQueue.main.async {
                            if settings.authorizationStatus == .denied {
                                showDeniedAlert = true
                            }
                        }
                    }
                }
            }
        }
    }
}

struct MyProfileSettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("Profile settings coming soon.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("My Profile")
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("debugMode") private var debugMode = false

    private var monitor: NetworkMonitor { NetworkMonitor.shared }

    var body: some View {
        Form {
            Section {
                Toggle("Debug Mode", isOn: $debugMode)
                    .onChange(of: debugMode) { _, enabled in
                        if enabled {
                            monitor.enable()
                        } else {
                            monitor.disable()
                            monitor.clear()
                        }
                    }
            } footer: {
                Text("Logs all network requests made by the app in real time.")
            }

            if debugMode {
                Section {
                    LabeledContent("Total Requests") {
                        Text("\(monitor.entries.count)")
                            .monospacedDigit()
                    }
                    Button("Clear Log", role: .destructive) {
                        monitor.clear()
                    }
                }

                Section("Request Log") {
                    if monitor.entries.isEmpty {
                        Text("No requests yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(monitor.entries.indices.reversed(), id: \.self) { i in
                            let entry = monitor.entries[i]
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.url)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                    .lineLimit(4)
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Advanced")
        .onAppear {
            if debugMode { monitor.enable() }
        }
    }
}
