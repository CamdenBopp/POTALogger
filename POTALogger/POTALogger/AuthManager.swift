import SwiftUI
import Security
import CryptoKit

// MARK: - Token Response

struct TokenResponse: Decodable {
    let accessToken: String
    let idToken: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case idToken      = "id_token"
        case refreshToken = "refresh_token"
    }
}

// MARK: - User Info

struct POTAUserInfo {
    let sub: String
    let name: String?
    let email: String?
    let pictureURL: URL?

    /// Up to two initials from the display name, falls back to "?"
    var initials: String {
        guard let name, !name.isEmpty else { return "?" }
        return name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0) }
            .joined()
            .uppercased()
    }
}

private struct UserInfoResponse: Decodable {
    let sub: String
    let name: String?
    let email: String?
    let picture: String?
}

// MARK: - POTA Stats

struct POTAStats: Decodable {
    let callsign: String
    let name: String
    let gravatar: String?

    struct ActivatorStats: Decodable {
        let activations: Int
        let parks: Int
        let qsos: Int
    }
    struct HunterStats: Decodable {
        let parks: Int
        let qsos: Int
    }

    let activator: ActivatorStats
    let hunter: HunterStats
    let awards: Int
    let endorsements: Int
}

// MARK: - Auth Manager

@Observable
final class AuthManager {
    static let shared = AuthManager()

    private(set) var isSignedIn = false
    private(set) var userInfo: POTAUserInfo?
    private(set) var stats: POTAStats?

    /// Gravatar URL built from the POTA stats hash, or from the signed-in email if the
    /// stats payload doesn't provide one. Matches the web behavior by requesting an identicon fallback.
    var gravatarURL: URL? {
        let hash =
            stats?.gravatar?.nonEmpty ??
            userInfo?.email.flatMap(Self.gravatarHash(for:))
        guard let hash else { return nil }
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=200&d=identicon")
    }

    private enum Key {
        static let access    = "pota.token.access"
        static let id        = "pota.token.id"
        static let refresh   = "pota.token.refresh"
        static let callsign  = "pota.callsign"
    }

    /// Tracks the async startup work so callers can await it before using the token.
    /// On every cold launch the refresh token (long-lived) is used to obtain a fresh
    /// hourly ID token; this task represents that work.  nil when no prior session exists.
    @ObservationIgnored private(set) var startupTask: Task<Void, Never>?

    private let userInfoURL = URL(string:
        "https://parksontheair.auth.us-east-2.amazoncognito.com/oauth2/userInfo")!
    private let tokenURL = URL(string:
        "https://parksontheair.auth.us-east-2.amazoncognito.com/oauth2/token")!
    private let cognitoClientID = "7hluqct0n2nckib7i7sd5753oa"

    init() {
        if loadToken(key: Key.access) != nil {
            isSignedIn = true
            // Stored so callers (e.g. AwardsViewModel) can await it before reading tokens,
            // preventing a race where an expired token yields silent 401s on first load.
            startupTask = Task {
                if loadToken(key: Key.refresh) != nil {
                    let ok = await refreshTokens()
                    if !ok {
                        // Refresh token itself has expired — clear the session rather than
                        // leaving the user stuck with stale data and no obvious error.
                        await MainActor.run { self.signOut() }
                        return
                    }
                }
                await refreshUserInfo()
                if callsign == nil {
                    await refreshCallsign()
                } else {
                    await refreshStats()
                }
            }
        }
    }

    /// Raw access token (OAuth scopes).
    var accessToken: String? { loadToken(key: Key.access) }

    /// ID token — this is what api.pota.app expects in the Authorization header (no Bearer prefix).
    var idToken: String? { loadToken(key: Key.id) }

    /// The verified POTA callsign (e.g. "KF8CKX"), persisted to UserDefaults after a successful
    /// awards fetch. This is the only reliable source — the Cognito username is the federated ID.
    var callsign: String? {
        get { UserDefaults.standard.string(forKey: Key.callsign) }
        set { UserDefaults.standard.set(newValue, forKey: Key.callsign) }
    }

    // MARK: - Token refresh

    /// Uses the stored refresh token to get a new access + ID token pair.
    /// Returns true on success, false if the refresh token is missing or expired.
    @discardableResult
    func refreshTokens() async -> Bool {
        guard let refreshToken = loadToken(key: Key.refresh) else { return false }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "grant_type=refresh_token",
            "client_id=\(cognitoClientID)",
            "refresh_token=\(refreshToken)",
        ].joined(separator: "&").data(using: .utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else { return false }

        // Cognito refresh responses contain new access + ID tokens but not a new refresh token
        saveToken(tokens.accessToken, key: Key.access)
        saveToken(tokens.idToken,     key: Key.id)
        return true
    }

    // MARK: - Called after successful token exchange

    func handleTokenResponse(_ data: Data) async {
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            print("AuthManager: failed to decode token response")
            return
        }
        saveToken(response.accessToken, key: Key.access)
        saveToken(response.idToken,     key: Key.id)
        if let refresh = response.refreshToken {
            saveToken(refresh, key: Key.refresh)
        }
        await refreshUserInfo()
        await refreshCallsign()
        await MainActor.run { isSignedIn = true }
    }

    // MARK: - Sign out

    func signOut() {
        [Key.access, Key.id, Key.refresh].forEach(deleteToken)
        UserDefaults.standard.removeObject(forKey: Key.callsign)
        isSignedIn = false
        userInfo = nil
        stats = nil
    }

    // MARK: - Callsign fetch

    private func refreshCallsign() async {
        guard let token = loadToken(key: Key.id) ?? loadToken(key: Key.access),
              let url = URL(string: "https://api.pota.app/user/award/earned") else { return }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let awards = try? JSONDecoder().decode([EarnedAwardCallsign].self, from: data),
              let cs = awards.first?.activeCallsign else { return }
        callsign = cs
        await refreshStats(callsign: cs)
    }

    // MARK: - POTA stats fetch

    func refreshStats(callsign cs: String? = nil) async {
        let cs = cs ?? callsign
        guard let cs,
              let url = URL(string: "https://api.pota.app/stats/user/\(cs)") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let fetched = try? JSONDecoder().decode(POTAStats.self, from: data) else { return }
        await MainActor.run { stats = fetched }
    }

    private struct EarnedAwardCallsign: Decodable {
        let activeCallsign: String
    }

    // MARK: - User info fetch

    private func refreshUserInfo() async {
        guard let token = loadToken(key: Key.access) else { return }

        var request = URLRequest(url: userInfoURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let response  = try? JSONDecoder().decode(UserInfoResponse.self, from: data)
        else { return }

        let info = POTAUserInfo(
            sub:        response.sub,
            name:       response.name,
            email:      response.email,
            pictureURL: response.picture.flatMap { URL(string: $0) }
        )
        await MainActor.run { userInfo = info }
    }

    // MARK: - Keychain helpers

    private func saveToken(_ token: String, key: String) {
        let data = Data(token.utf8)
        let query: [CFString: Any] = [
            kSecClass:                     kSecClassGenericPassword,
            kSecAttrAccount:               key,
            kSecAttrAccessible:            kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData:                 data,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadToken(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:                   kSecClassGenericPassword,
            kSecAttrAccount:             key,
            kSecReturnData:              true,
            kSecMatchLimit:              kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteToken(key: String) {
        let query: [CFString: Any] = [
            kSecClass:                   kSecClassGenericPassword,
            kSecAttrAccount:             key,
            kSecUseDataProtectionKeychain: true,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension AuthManager {
    static func gravatarHash(for email: String) -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = Insecure.MD5.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Profile avatar view

struct ProfileAvatar: View {
    let userInfo: POTAUserInfo?
    var size: CGFloat = 28
    /// Preferred image URL (e.g. Gravatar). Falls back to userInfo.pictureURL, then initials.
    var overrideURL: URL? = nil

    private var imageURL: URL? { overrideURL ?? userInfo?.pictureURL }

    var body: some View {
        if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    initialsCircle
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            initialsCircle
        }
    }

    private var initialsCircle: some View {
        Circle()
            .fill(.blue.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(userInfo?.initials ?? "?")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}
