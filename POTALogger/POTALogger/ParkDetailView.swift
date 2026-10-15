import SwiftUI

private struct ParkActivationRecord: Decodable, Identifiable {
    let activeCallsign: String
    let qsoDate: String
    let totalQSOs: Int
    let qsosCW: Int
    let qsosDATA: Int
    let qsosPHONE: Int

    var id: String { "\(activeCallsign)-\(qsoDate)-\(totalQSOs)" }

    private enum CodingKeys: String, CodingKey {
        case activeCallsign
        case qsoDate = "qso_date"
        case totalQSOs
        case qsosCW
        case qsosDATA
        case qsosPHONE
    }
}

struct ParkDetailView: View {
    let park: POTAPark
    @Environment(\.dismiss) private var dismiss
    @State private var activations: [ParkActivationRecord] = []
    @State private var isLoadingActivations = false
    @State private var activationLoadFailed = false

    private var cachedRecord: ParkRecord? {
        ParkIndex.shared.park(reference: park.reference)
    }

    private var countryCode: String {
        let raw = (park.locationDesc ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "?" }
        if let dash = raw.firstIndex(of: "-") {
            return String(raw[..<dash])
        }
        return raw
    }

    private var countryName: String {
        Locale.current.localizedString(forRegionCode: countryCode.uppercased()) ?? countryCode
    }

    private var locator: String? {
        let grid = cachedRecord?.grid.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return grid.isEmpty ? nil : grid
    }

    private var coordinateText: String {
        let lat = String(format: "%.4f", park.latitude)
        let lon = String(format: "%.4f", park.longitude)
        if let locator {
            return "\(lat), \(lon)  \(locator)"
        }
        return "\(lat), \(lon)"
    }

    private var locationChips: [String] {
        let desc = (park.locationDesc ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return desc.isEmpty ? [countryCode] : desc
    }

    private var totalActivationQSOs: Int {
        activations.reduce(0) { $0 + $1.totalQSOs }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                factsCard
                locationCard
                activationsCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .overlay(alignment: .topTrailing) {
            closeButton
        }
        .task(id: park.reference) {
            await loadActivations()
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(.secondaryLabel))
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill), in: Circle())
                .overlay {
                    Circle().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
        .padding(.top, 20)
        .accessibilityLabel("Close")
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(park.reference)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(park.name)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // Leave room for the floating close button in the top-trailing corner.
                Color.clear.frame(width: 40, height: 40)
            }

            Divider()

            HStack(spacing: 10) {
                infoPill(title: "Country", value: countryName)
                infoPill(title: "Type", value: park.parktypeDesc ?? "POTA Park")
                infoPill(title: "Activations", value: "\(activations.count)")
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var factsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Park Facts")
            factRow("Reference", park.reference)
            factDivider
            factRow("Country", countryName)
            factDivider
            factRow("Coordinates", coordinateText)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var locationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Location")
            ParkDetailChipFlow(spacing: 8) {
                ForEach(locationChips, id: \.self) { chip in
                    Text(chip)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var activationsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Recent Activations")

            if isLoadingActivations {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else if activationLoadFailed {
                Text("Unable to load activation history right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else if activations.isEmpty {
                Text("No activation history found for this park.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                HStack(spacing: 10) {
                    infoPill(title: "Events", value: "\(activations.count)")
                    infoPill(title: "QSOs", value: "\(totalActivationQSOs)")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

                ForEach(activations.prefix(12)) { activation in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activation.activeCallsign)
                                    .font(.subheadline.weight(.medium))
                                Text(formattedDate(activation.qsoDate))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(activation.totalQSOs) QSOs")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            statChip(label: "CW", value: activation.qsosCW)
                            statChip(label: "DATA", value: activation.qsosDATA)
                            statChip(label: "PHONE", value: activation.qsosPHONE)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if activation.id != activations.prefix(12).last?.id {
                        factDivider
                    }
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var factDivider: some View {
        Divider().padding(.leading, 16)
    }

    private func infoPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statChip(label: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    private func formattedDate(_ raw: String) -> String {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyyMMdd"
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.dateStyle = .medium
        return input.date(from: raw).map(output.string(from:)) ?? raw
    }

    @MainActor
    private func loadActivations() async {
        guard let encodedRef = park.reference.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.pota.app/park/activations/\(encodedRef)?count=all")
        else { return }

        isLoadingActivations = true
        activationLoadFailed = false
        defer { isLoadingActivations = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                activationLoadFailed = true
                activations = []
                return
            }
            activations = try JSONDecoder().decode([ParkActivationRecord].self, from: data)
        } catch {
            activationLoadFailed = true
            activations = []
        }
    }
}

#Preview {
    ParkDetailView(
        park: POTAPark(
            reference: "US-8105",
            name: "West Blue Rock State Forest",
            latitude: 39.8546,
            longitude: -82.0066,
            locationDesc: "US-OH",
            parktypeDesc: "State Forest"
        )
    )
}

private struct ParkDetailChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
