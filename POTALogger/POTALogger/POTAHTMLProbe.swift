import Foundation

// MARK: - Models

enum POTAActivationState: Equatable, CustomStringConvertible {
    case active(ActivationRecord)
    case inactive(reason: String)
    case notFound
    case parseError(String)

    var description: String {
        switch self {
        case .active(let record):
            return """
            active
            callsign: \(record.callsign)
            park: \(record.park ?? "nil")
            frequency: \(record.frequency ?? "nil")
            lastHeard: \(record.lastHeard ?? "nil")
            comment: \(record.comment ?? "nil")
            """
        case .inactive(let reason):
            return "inactive: \(reason)"
        case .notFound:
            return "notFound"
        case .parseError(let message):
            return "parseError: \(message)"
        }
    }

    var isConfirmedActive: Bool {
        if case .active = self { return true }
        return false
    }

    /// Short human-readable summary suitable for UI display.
    var displayMessage: String {
        switch self {
        case .active(let record):
            var parts: [String] = ["Confirmed on pota.app"]
            if let park = record.park      { parts.append(park) }
            if let freq = record.frequency { parts.append(freq) }
            if let last = record.lastHeard { parts.append(last) }
            return parts.joined(separator: " · ")
        case .inactive(let reason):
            return "Spot posted — not yet active (\(reason))"
        case .notFound:
            return "Spot posted — may take a moment to appear on pota.app"
        case .parseError:
            return "Spot posted — couldn't verify on pota.app"
        }
    }
}

struct ActivationRecord: Equatable {
    let callsign: String
    let park: String?
    let frequency: String?
    let lastHeard: String?
    let comment: String?
}

// MARK: - HTML Probe

struct POTAHTMLProbe {

    // MARK: - Network fetch + probe

    /// Fetches the POTA activations page and checks whether `callsign` is listed as active.
    /// Retries once after a delay if the spot hasn't propagated yet.
    static func fetchAndCheck(
        callsign: String,
        initialDelay: Duration = .seconds(3),
        retryDelay: Duration = .seconds(5)
    ) async -> POTAActivationState {
        // Always bypass the URL cache — we need live content
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)

        guard let url = URL(string: "https://pota.app/") else {
            return .parseError("Invalid pota.app URL")
        }

        try? await Task.sleep(for: initialDelay)

        if let html = await fetch(url: url, session: session) {
            let state = checkActivation(in: html, callsign: callsign)
            if case .notFound = state {
                // Spot may not have propagated yet — try once more
                try? await Task.sleep(for: retryDelay)
                if let retryHTML = await fetch(url: url, session: session) {
                    return checkActivation(in: retryHTML, callsign: callsign)
                }
            }
            return state
        }

        return .parseError("Failed to load pota.app")
    }

    private static func fetch(url: URL, session: URLSession) async -> String? {
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - HTML parsing (provided logic, unchanged)

    static func checkActivation(in html: String, callsign: String) -> POTAActivationState {
        let normalizedCallsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard !normalizedCallsign.isEmpty else {
            return .parseError("Callsign was empty")
        }

        let cleaned = decodeHTML(html)
        let compact = collapseWhitespace(cleaned)

        guard compact.contains(normalizedCallsign) else {
            return .notFound
        }

        guard let block = extractRelevantBlock(from: cleaned, callsign: normalizedCallsign) else {
            return .inactive(reason: "Callsign found globally, but could not isolate its detail block")
        }

        let park = extractFirstMatch(in: block, pattern: #">([A-Z]-[A-Z0-9]+[^<]*)</a>"#)
            .map(cleanText)

        let frequency = extractFirstMatch(in: block, pattern: #">(\d+(?:\.\d+)?)\s*kHz</div>"#)
            .map { "\($0) kHz" }

        let lastHeard = extractFirstMatch(
            in: block,
            pattern: #">Last heard\s+([^<]+)</div>"#
        ).map { "Last heard " + cleanText($0) }

        let comment = extractFirstMatch(
            in: block,
            pattern: #">No spot information</div>"#
        ).map { _ in "No spot information" }

        if lastHeard != nil {
            let record = ActivationRecord(
                callsign: normalizedCallsign,
                park: park,
                frequency: frequency,
                lastHeard: lastHeard,
                comment: comment
            )
            return .active(record)
        }

        return .inactive(reason: "Matching callsign found, but no 'Last heard' line was present")
    }

    private static func extractRelevantBlock(from html: String, callsign: String) -> String? {
        guard let callRange = html.range(of: callsign, options: [.caseInsensitive]) else {
            return nil
        }

        let beforeCall = html[..<callRange.lowerBound]
        let afterCall  = html[callRange.upperBound...]

        let startMarker = #"<hr data-v-"#
        let endMarker   = #"<hr data-v-"#

        let startIndex = beforeCall.range(of: startMarker, options: [.backwards])?.lowerBound ?? html.startIndex
        let endIndex   = afterCall.range(of: endMarker)?.lowerBound ?? html.endIndex

        return String(html[startIndex..<endIndex])
    }

    private static func extractFirstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let capturedRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capturedRange])
    }

    private static func decodeHTML(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            ("&quot;", "\""), ("&amp;", "&"), ("&lt;", "<"),
            ("&gt;", ">"),    ("&#39;", "'"), ("&nbsp;", " "),
        ]
        for (entity, value) in replacements {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanText(_ text: String) -> String {
        collapseWhitespace(
            text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        )
    }
}
