import SwiftUI

private enum SpotPhase {
    case editing
    case verifying
    case verified(POTAActivationState)
    case smsSent
}

struct AddSpotView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var activator = ""
    @State private var spotter = ""
    @State private var reference = ""
    @State private var frequencyInput = ""
    @AppStorage(FrequencyFormatOptions.unitKey) private var freqUnit: FrequencyUnit = .kHz
    @State private var mode = "SSB"
    @State private var comment = ""
    @State private var selfSpot = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var phase: SpotPhase = .editing
    @State private var showOfflineAlert = false
    @State private var showMessageComposer = false

    var onSpotAdded: () async -> Void

    private let modes = ["SSB", "CW", "FT8", "FT4", "FM", "AM", "DIGITALVOICE", "RTTY", "JS8", "OTHER"]

    private var myCallsign: String? { AuthManager.shared.callsign }

    private var frequencyIsValid: Bool { Double(frequencyInput) != nil && !frequencyInput.isEmpty }

    /// Always returns a kHz integer string regardless of the selected input unit.
    private var resolvedFrequencyKHz: String {
        guard let val = Double(frequencyInput), val > 0 else { return frequencyInput }
        switch freqUnit {
        case .kHz: return frequencyInput
        case .MHz: return String(Int((val * 1_000).rounded()))
        }
    }

    private var canSubmit: Bool {
        let act = selfSpot ? (myCallsign ?? "") : activator
        return !act.trimmingCharacters(in: .whitespaces).isEmpty
            && !reference.trimmingCharacters(in: .whitespaces).isEmpty
            && frequencyIsValid
            && !isSubmitting
    }

    /// Activator callsign resolved consistently for both the API and SMS paths.
    private var resolvedActivator: String {
        ((selfSpot ? myCallsign : nil) ?? activator).uppercased()
    }

    var body: some View {
        NavigationView {
            Group {
                switch phase {
                case .editing:
                    spotForm
                case .verifying:
                    verifyingView
                case .verified(let state):
                    verifiedView(state)
                case .smsSent:
                    smsSentView
                }
            }
            .navigationTitle("Add Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if case .editing = phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await submitSpot() }
                        } label: {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("Spot")
                            }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        // Offline confirmation — shown when the user taps Spot without a connection.
        .confirmationDialog(
            "No Internet Connection",
            isPresented: $showOfflineAlert,
            titleVisibility: .visible
        ) {
            if APSpotSMS.canSend {
                Button("Send via SMS (APspot)") { showMessageComposer = true }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your spot can be relayed through the APspot SMS service instead.")
        }
        // SMS composer — pre-filled and ready to send.
        .sheet(isPresented: $showMessageComposer) {
            let sms = APSpotSMS(
                activator:    resolvedActivator,
                reference:    reference.uppercased(),
                frequencyKHz: resolvedFrequencyKHz,
                mode:         mode,
                comment:      comment
            )
            MessageComposeView(
                recipients: [APSpotSMS.phoneNumber],
                body: sms.body
            ) { result in
                showMessageComposer = false
                if result == .sent { phase = .smsSent }
            }
        }
    }

    // MARK: - Form

    private var spotForm: some View {
        Form {
            Section("Activator") {
                if let cs = myCallsign {
                    Toggle("Spot myself (\(cs))", isOn: $selfSpot)
                }
                if !selfSpot {
                    TextField("Callsign", text: $activator)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
            }

            if myCallsign == nil {
                Section("Spotter") {
                    TextField("Your callsign", text: $spotter)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
            }

            Section("Park") {
                TextField("Reference (e.g. K-0001)", text: $reference)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section("Signal") {
                HStack {
                    TextField(freqUnit == .kHz ? "e.g. 14074" : "e.g. 14.074", text: $frequencyInput)
                        .keyboardType(.decimalPad)
                    Picker("Unit", selection: $freqUnit) {
                        ForEach(FrequencyUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: freqUnit) { old, new in
                        guard let val = Double(frequencyInput), val > 0 else { return }
                        switch (old, new) {
                        case (.kHz, .MHz):
                            let hz = Int((val * 1_000).rounded())
                            let whole = hz / 1_000_000
                            let remainder = hz % 1_000_000
                            var frac = String(format: "%06d", remainder)
                            while frac.count > 1 && frac.hasSuffix("0") { frac.removeLast() }
                            frequencyInput = "\(whole).\(frac)"
                        case (.MHz, .kHz):
                            frequencyInput = String(Int((val * 1_000).rounded()))
                        default: break
                        }
                    }
                }
                Picker("Mode", selection: $mode) {
                    ForEach(modes, id: \.self) { Text($0) }
                }
            }

            Section("Comment") {
                TextField("Optional", text: $comment)
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Phase views

    private var verifyingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
            Text("Spot posted — verifying on pota.app…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private func verifiedView(_ state: POTAActivationState) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: state.isConfirmedActive ? "checkmark.circle.fill" : "clock.circle")
                .font(.system(size: 56))
                .foregroundStyle(state.isConfirmedActive ? .green : .secondary)
            Text(state.displayMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private var smsSentView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "message.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Spot sent via SMS")
                .font(.title3.weight(.semibold))
            Text("APspot will relay your spot to the POTA network. It should appear within a minute or two.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    // MARK: - Submission

    private func submitSpot() async {
        // ── Offline: hand off to APspot SMS relay ────────────────────
        guard ConnectivityMonitor.shared.isOnline else {
            showOfflineAlert = true
            return
        }

        // ── Online: normal API path ───────────────────────────────────
        guard let token = AuthManager.shared.idToken else {
            errorMessage = "Sign in to post spots."
            return
        }
        guard frequencyIsValid else {
            errorMessage = freqUnit == .kHz
                ? "Enter a valid frequency in kHz (e.g. 14074)."
                : "Enter a valid frequency in MHz (e.g. 14.074)."
            return
        }

        let resolvedSpotter = myCallsign ?? spotter.uppercased()

        guard !resolvedActivator.isEmpty, !resolvedSpotter.isEmpty,
              !reference.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Fill in all required fields."
            return
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        guard let url = URL(string: "https://api.pota.app/spot") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "Authorization")

        var body: [String: String] = [
            "activator":  resolvedActivator,
            "spotter":    resolvedSpotter,
            "reference":  reference.uppercased(),
            "frequency":  resolvedFrequencyKHz,
            "mode":       mode,
            "source":     "iOS",
        ]
        if !comment.isEmpty { body["comments"] = comment }

        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let apiMessage = (try? JSONDecoder().decode([String: String].self, from: data))?["message"]
                    ?? String(data: data, encoding: .utf8)
                errorMessage = apiMessage.map { "API error: \($0)" } ?? "Failed to post spot (no response body)."
                return
            }
            await onSpotAdded()
            phase = .verifying
            let state = await POTAHTMLProbe.fetchAndCheck(callsign: resolvedActivator)
            phase = .verified(state)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Previews

#Preview("Add Spot — editing") {
    AddSpotView { }
}

#Preview("Add Spot — SMS sent") {
    // Shows the smsSent confirmation screen in isolation.
    NavigationView {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "message.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Spot sent via SMS")
                .font(.title3.weight(.semibold))
            Text("APspot will relay your spot to the POTA network. It should appear within a minute or two.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .navigationTitle("Add Spot")
        .navigationBarTitleDisplayMode(.inline)
    }
}
