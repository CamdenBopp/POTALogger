import MessageUI
import SwiftUI

// MARK: - SMS spot model

/// Formats a POTA spot for submission via the APspot SMS relay service.
///
/// APspot format: `!<Callsign> POTA <Ref> <FreqMHz> <Mode> [<Comment up to 60 chars>]`
/// Example:       `!KF8CKX POTA K-1234 14.074 FT8 CQ from summit`
///
/// Reference: https://apspot.radio/getting-started/
struct APSpotSMS {
    static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    let activator: String
    let reference: String
    /// Frequency in kHz (as entered in the spot form — converted to MHz for SMS).
    let frequencyKHz: String
    let mode: String
    let comment: String

    var body: String {
        var parts: [String] = [
            "!\(activator.uppercased())",
            "POTA",
            reference.uppercased(),
            freqMHz,
            normalizedMode,
        ]
        let trimmed = comment.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            parts.append(String(trimmed.prefix(60)))
        }
        return parts.joined(separator: " ")
    }

    /// Destination number chosen by device region.
    /// Reference: https://apspot.radio/sms-numbers/
    static var phoneNumber: String {
        let region = Locale.current.region?.identifier ?? "US"
        switch region {
        case "CA": return "+18678772605"
        case "AU": return "+61489905884"
        default:   return "+18668705797"   // US — also the international default
        }
    }

    // MARK: Private helpers

    /// Converts kHz to MHz with trailing-zero stripping but at least one decimal place.
    /// 14074 → "14.074", 7000 → "7.0", 14200 → "14.2"
    private var freqMHz: String {
        guard let khz = Double(frequencyKHz), khz > 0 else { return frequencyKHz }
        let hz = Int((khz * 1_000).rounded())
        let whole = hz / 1_000_000
        let remainder = hz % 1_000_000
        var frac = String(format: "%06d", remainder)
        while frac.count > 1 && frac.hasSuffix("0") { frac.removeLast() }
        return "\(whole).\(frac)"
    }

    /// Maps app-internal mode strings to what APspot understands.
    private var normalizedMode: String {
        switch mode.uppercased() {
        case "DIGITALVOICE": return "FM"
        default:             return mode.uppercased()
        }
    }
}

// MARK: - SwiftUI wrapper for MFMessageComposeViewController

struct MessageComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    var onFinish: (MessageComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {

        let onFinish: (MessageComposeResult) -> Void
        init(onFinish: @escaping (MessageComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
            onFinish(result)
        }
    }
}

// MARK: - Previews

// MFMessageComposeViewController can't render in Simulator previews,
// so we preview the formatted SMS body text instead.

#Preview("SMS body — FT8 with comment") {
    let sms = APSpotSMS(
        activator:    "KF8CKX",
        reference:    "K-4566",
        frequencyKHz: "14074",
        mode:         "FT8",
        comment:      "CQ from the summit"
    )
    VStack(alignment: .leading, spacing: 12) {
        Text("To: \(APSpotSMS.phoneNumber)")
            .font(.caption).foregroundStyle(.secondary)
        Text(sms.body)
            .font(.body.monospaced())
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    .padding()
}

#Preview("SMS body — CW no comment") {
    let sms = APSpotSMS(
        activator:    "KF8CKX",
        reference:    "K-0001",
        frequencyKHz: "7032",
        mode:         "CW",
        comment:      ""
    )
    VStack(alignment: .leading, spacing: 12) {
        Text("To: \(APSpotSMS.phoneNumber)")
            .font(.caption).foregroundStyle(.secondary)
        Text(sms.body)
            .font(.body.monospaced())
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    .padding()
}
