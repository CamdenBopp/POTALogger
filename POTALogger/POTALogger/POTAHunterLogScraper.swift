import Foundation
import WebKit

// MARK: - Hunter Log Scraper

/// Fetches the signed-in user's hunter log and returns QSO counts per park reference.
/// Primary path: /user/logbook?hunterOnly=1 API (mirrors POTALinesMac).
/// Fallback: WKWebView scrape of pota.app.
@MainActor
final class POTAHunterLogScraper: NSObject, WKNavigationDelegate {
    static let shared = POTAHunterLogScraper()

    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Public API

    func fetchUniqueParkRefs(callsign: String) async -> Set<String> {
        Set(await fetchParkQSOCounts(callsign: callsign).keys)
    }

    /// Returns park reference → QSO count.
    /// Tries the /user/logbook JWT API first (same as POTALinesMac), falls back to web scraper.
    func fetchParkQSOCounts(callsign: String) async -> [String: Int] {
        let callsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !callsign.isEmpty else { return [:] }

        // 1. JWT-backed logbook API (primary — mirrors POTALinesMac.fetchEntriesViaAPI)
        if let counts = await fetchCountsViaLogbookAPI(), !counts.isEmpty {
            return counts
        }

        // 2. Web scraper fallback
        return await fetchCountsViaWebScraper(callsign: callsign)
    }

    // MARK: - /user/logbook API (primary path)

    private func fetchCountsViaLogbookAPI() async -> [String: Int]? {
        guard let token = AuthManager.shared.idToken ?? AuthManager.shared.accessToken else {
            print("[HunterLogScraper] No JWT available for logbook API")
            return nil
        }

        var allRefs: [String] = []

        for page in 1...50 {
            guard let url = URL(string: "https://api.pota.app/user/logbook?hunterOnly=1&page=\(page)&size=100") else { break }

            var request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse
            else {
                print("[HunterLogScraper] Logbook API network error on page \(page)")
                return nil
            }

            guard http.statusCode == 200 else {
                let preview = String((String(data: data, encoding: .utf8) ?? "").prefix(160))
                print("[HunterLogScraper] Logbook API HTTP \(http.statusCode) on page \(page): \(preview)")
                return nil
            }

            guard let pageRefs = Self.parseLogbookRefs(from: data) else {
                let preview = String((String(data: data, encoding: .utf8) ?? "").prefix(160))
                print("[HunterLogScraper] Logbook API decode failed on page \(page): \(preview)")
                return nil
            }

            print("[HunterLogScraper] Page \(page): \(pageRefs.count) row(s)")

            if pageRefs.isEmpty { break }
            allRefs.append(contentsOf: pageRefs)
            if pageRefs.count < 100 { break }
        }

        guard !allRefs.isEmpty else { return nil }

        print("[HunterLogScraper] Logbook API total: \(allRefs.count) QSOs")
        // Group by park ref to get counts — same as Mac's Dictionary(grouping:by:).mapValues(\.count)
        var counts: [String: Int] = [:]
        for ref in allRefs where !ref.isEmpty {
            counts[ref, default: 0] += 1
        }
        return counts
    }

    /// Parses the /user/logbook response and returns one park reference per QSO row.
    static func parseLogbookRefs(from data: Data) -> [String]? {
        // Try the typed response first (matches POTALinesMac LogbookAPIResponse)
        if let response = try? JSONDecoder().decode(LogbookAPIResponse.self, from: data) {
            return response.entries.compactMap { extractParkRef(from: $0.reference) }
        }
        // Fall back to raw JSON in case the shape differs
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let records: [[String: Any]]
        if let array = json as? [[String: Any]] {
            records = array
        } else if let dict = json as? [String: Any] {
            records = [dict["entries"], dict["items"], dict["results"], dict["data"]]
                .compactMap { $0 as? [[String: Any]] }.first ?? []
        } else {
            return nil
        }
        return records.compactMap { record in
            let raw = record["reference"] as? String
                   ?? record["parkRef"] as? String
                   ?? record["park"] as? String
            return extractParkRef(from: raw)
        }
    }

    static func extractParkRef(from value: String?) -> String? {
        guard let value else { return nil }
        let pattern = #"[A-Z]{1,4}(?:-[A-Z]{2})?-\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let resultRange = Range(match.range, in: value) else { return nil }
        return String(value[resultRange]).uppercased()
    }

    // MARK: - Web scraper fallback

    private func fetchCountsViaWebScraper(callsign: String) async -> [String: Int] {
        print("[HunterLogScraper] Falling back to web scraper for \(callsign)")
        for url in candidateURLs(for: callsign) {
            do {
                try await load(url: url)
                let counts = try await scrapeParkCounts(for: callsign)
                if !counts.isEmpty { return counts }
            } catch {
                continue
            }
        }
        return [:]
    }

    private func candidateURLs(for callsign: String) -> [URL] {
        ["https://pota.app/#/user/logbook",
         "https://pota.app/#/hunter/\(callsign)",
         "https://pota.app/"]
            .compactMap(URL.init(string:))
    }

    private func load(url: URL) async throws {
        let webView = configuredWebView()
        navigationContinuation?.resume(throwing: CancellationError())
        navigationContinuation = nil

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            webView.load(request)
        }
    }

    private func configuredWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isHidden = true
        self.webView = webView
        return webView
    }

    private func scrapeParkCounts(for callsign: String) async throws -> [String: Int] {
        guard let webView else { return [:] }

        let script = """
        (async () => {
          const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
          const textOf = el => (el?.innerText || el?.textContent || "").trim();
          const buttons = () => Array.from(document.querySelectorAll("button, a, [role='button'], .v-btn"));

          const waitFor = async (predicate, timeout = 12000, interval = 250) => {
            const end = Date.now() + timeout;
            while (Date.now() < end) {
              const value = predicate();
              if (value) return value;
              await delay(interval);
            }
            return null;
          };

          const setRowsPerPage = async () => {
            const selection = Array.from(document.querySelectorAll(".v-select__selection"))
              .find(el => ["10", "25", "50"].includes(textOf(el)));
            if (!selection) return;
            selection.click();
            await delay(250);
            const option = Array.from(document.querySelectorAll('[role="option"]'))
              .find(el => textOf(el) === "100");
            if (!option) return;
            option.click();
            await delay(600);
          };

          const findNextButton = () => {
            let nextBtn = Array.from(document.querySelectorAll("button"))
              .find(b => textOf(b).toLowerCase().includes("next") && !b.disabled);
            if (!nextBtn) {
              nextBtn = Array.from(document.querySelectorAll("button"))
                .find(b => !b.disabled && (
                  b.innerHTML.includes("chevron_right") ||
                  b.innerHTML.includes("arrow_forward")
                ));
            }
            if (!nextBtn) {
              const paginationBtns = Array.from(document.querySelectorAll("button"))
                .filter(b => /^\\d+$/.test(textOf(b)) && !b.disabled);
              const currentPageBtn = paginationBtns.find(b =>
                b.classList.contains("v-btn--active") || b.getAttribute("aria-current") === "page");
              if (currentPageBtn) {
                const cur = parseInt(textOf(currentPageBtn), 10);
                nextBtn = paginationBtns.find(b => parseInt(textOf(b), 10) === cur + 1);
              }
            }
            return nextBtn || null;
          };

          const extractRef = raw => {
            const match = (raw || "").match(/[A-Z]{1,4}(?:-[A-Z]{2})?-\\d+/i);
            return match ? match[0].toUpperCase() : "";
          };

          const scrapeRows = () => Array.from(document.querySelectorAll("main table tbody tr"))
            .map(row => {
              const cells = row.querySelectorAll("td");
              if (cells.length < 9) return null;
              return extractRef(textOf(cells[8]));
            })
            .filter(Boolean);

          const rowsReady = await waitFor(() => document.querySelectorAll("main table tbody tr").length > 0);
          if (!rowsReady) return JSON.stringify({ counts: {} });

          await setRowsPerPage();
          await delay(1500);

          const allRefs = [];
          let page = 1;
          while (page <= 50) {
            const rows = await waitFor(() => {
              const cur = scrapeRows();
              return cur.length ? cur : null;
            }, 10000);
            if (!rows || !rows.length) break;
            allRefs.push(...rows);
            if (rows.length < 100) break;
            const next = findNextButton();
            if (!next) break;
            const before = JSON.stringify(scrapeRows());
            next.click();
            await delay(2000);
            await waitFor(() => JSON.stringify(scrapeRows()) !== before, 10000);
            page += 1;
          }

          const counts = {};
          for (const ref of allRefs) { counts[ref] = (counts[ref] || 0) + 1; }
          return JSON.stringify({ counts });
        })();
        """

        let raw = try await webView.evaluateJavaScript(script)
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ScrapePayload.self, from: data)
        else { return [:] }

        return payload.counts
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume(returning: ())
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }
}

// MARK: - Decodable types (mirror POTALinesMac)

private struct LogbookAPIResponse: Decodable {
    let count: Int?
    let entries: [LogbookAPIEntry]
}

private struct LogbookAPIEntry: Decodable {
    let reference: String?

    enum CodingKeys: String, CodingKey {
        case reference
    }
}

private struct ScrapePayload: Decodable {
    let counts: [String: Int]
}

private func jsonStringLiteral(_ value: String) -> String {
    let data = try? JSONEncoder().encode(value)
    return String(data: data ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
}
