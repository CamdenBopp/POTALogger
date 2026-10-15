import SwiftUI
import WebKit
import CommonCrypto

// MARK: - Cognito Auth Constants

private enum CognitoAuth {
    static let baseURL     = "https://parksontheair.auth.us-east-2.amazoncognito.com"
    static let clientID    = "7hluqct0n2nckib7i7sd5753oa"
    static let redirectURI = "https://pota.app/"
    static let scope       = "aws.cognito.signin.user.admin email openid phone profile"
}

// MARK: - Auth request wrapper (Identifiable so .sheet(item:) works)

private struct AuthRequest: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Sign In Sheet

struct SignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authRequest: AuthRequest?
    @State private var isExchanging = false

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(.systemGray4))
                .frame(width: 40, height: 5)
                .padding(.top, 12)

            Image("POTALogo")
                .resizable()
                .scaledToFit()
                .frame(height: 60)
                .padding(.top, 8)

            Text("Sign in to POTA")
                .font(.title2)
                .fontWeight(.semibold)

            Divider().padding(.horizontal)

            if isExchanging {
                ProgressView("Signing in…")
                    .padding()
            } else {
                VStack(spacing: 12) {
                    CognitoSocialButton(provider: .amazon)  { startAuth(provider: "LoginWithAmazon") }
                    CognitoSocialButton(provider: .google)  { startAuth(provider: "Google") }
                    CognitoSocialButton(provider: .facebook){ startAuth(provider: "Facebook") }
                    CognitoSocialButton(provider: .email)   { startEmailAuth() }
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            Text("We won't post to any of your accounts without asking first")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .sheet(item: $authRequest) { request in
            CognitoWebView(url: request.url) { code in
                authRequest = nil          // dismiss the web view
                isExchanging = true
                Task {
                    await exchangeCodeForTokens(code: code)
                    await MainActor.run {
                        isExchanging = false
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - URL builders

    private func startAuth(provider: String) {
        authRequest = buildAuthURL(provider: provider).map { AuthRequest(url: $0) }
    }

    private func startEmailAuth() {
        authRequest = buildEmailAuthURL().map { AuthRequest(url: $0) }
    }

    private func buildAuthURL(provider: String) -> URL? {
        let (verifier, challenge) = PKCEHelper.generateChallenge()
        PKCEHelper.saveVerifier(verifier)

        var c = URLComponents(string: "\(CognitoAuth.baseURL)/oauth2/authorize")
        c?.queryItems = [
            URLQueryItem(name: "identity_provider",     value: provider),
            URLQueryItem(name: "redirect_uri",          value: CognitoAuth.redirectURI),
            URLQueryItem(name: "response_type",         value: "CODE"),
            URLQueryItem(name: "client_id",             value: CognitoAuth.clientID),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope",                 value: CognitoAuth.scope),
        ]
        return c?.url
    }

    private func buildEmailAuthURL() -> URL? {
        let (verifier, challenge) = PKCEHelper.generateChallenge()
        PKCEHelper.saveVerifier(verifier)

        var c = URLComponents(string: "\(CognitoAuth.baseURL)/login")
        c?.queryItems = [
            URLQueryItem(name: "redirect_uri",          value: CognitoAuth.redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "client_id",             value: CognitoAuth.clientID),
            URLQueryItem(name: "identity_provider",     value: "COGNITO"),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return c?.url
    }

    // MARK: - Token exchange

    private func exchangeCodeForTokens(code: String) async {
        guard
            let verifier = PKCEHelper.loadVerifier(),
            let tokenURL = URL(string: "\(CognitoAuth.baseURL)/oauth2/token")
        else { return }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "grant_type=authorization_code",
            "client_id=\(CognitoAuth.clientID)",
            "code=\(code)",
            "redirect_uri=\(CognitoAuth.redirectURI)",
            "code_verifier=\(verifier)",
        ].joined(separator: "&").data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            await AuthManager.shared.handleTokenResponse(data)
        } catch {
            print("Token exchange failed: \(error)")
        }
    }
}

// MARK: - WKWebView wrapper that intercepts the pota.app callback

struct CognitoWebView: UIViewControllerRepresentable {
    let url: URL
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> CognitoWebViewController {
        CognitoWebViewController(url: url, onCode: onCode)
    }

    func updateUIViewController(_ vc: CognitoWebViewController, context: Context) {}
}

final class CognitoWebViewController: UIViewController, WKNavigationDelegate {
    private let url: URL
    private let onCode: (String) -> Void
    private var webView: WKWebView!
    private var codeDelivered = false

    init(url: URL, onCode: @escaping (String) -> Void) {
        self.url    = url
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Use the default (shared) data store so cookies persist across sessions
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        webView.load(URLRequest(url: url))
    }

    // Intercept every navigation decision
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard !codeDelivered,
              let dest = action.request.url,
              dest.host == "pota.app",
              let components = URLComponents(url: dest, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            decisionHandler(.allow)
            return
        }

        // Got the code — cancel the navigation so the browser doesn't land on pota.app
        codeDelivered = true
        decisionHandler(.cancel)
        DispatchQueue.main.async { self.onCode(code) }
    }
}

// MARK: - Social button

enum SocialProvider {
    case amazon, google, facebook, email

    var label: String {
        switch self {
        case .amazon:   return "Continue with Login with Amazon"
        case .google:   return "Continue with Google"
        case .facebook: return "Continue with Facebook"
        case .email:    return "Sign in with Email"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .amazon:   return Color(red: 1.0, green: 0.757, blue: 0.027)
        case .google:   return .white
        case .facebook: return Color(red: 0.231, green: 0.349, blue: 0.596)
        case .email:    return Color(.systemGray5)
        }
    }

    var foregroundColor: Color {
        switch self {
        case .amazon, .google: return .black
        case .facebook:        return .white
        case .email:           return .primary
        }
    }

    var hasBorder: Bool { self == .google }
}

struct CognitoSocialButton: View {
    let provider: SocialProvider
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                providerIcon.frame(width: 24, height: 24)
                Text(provider.label)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(provider.backgroundColor)
            .foregroundColor(provider.foregroundColor)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.systemGray4), lineWidth: provider.hasBorder ? 1 : 0)
            )
        }
        .accessibilityLabel(provider.label)
    }

    @ViewBuilder
    private var providerIcon: some View {
        switch provider {
        case .amazon:
            Image(systemName: "cart.fill").foregroundColor(.black)
        case .google:
            Text("G")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Color(red: 0.259, green: 0.522, blue: 0.957))
        case .facebook:
            Image(systemName: "f.square.fill").foregroundColor(.white)
        case .email:
            Image(systemName: "envelope.fill").foregroundColor(.secondary)
        }
    }
}

// MARK: - PKCE helper

enum PKCEHelper {
    static func generateChallenge() -> (verifier: String, challenge: String) {
        let verifier  = generateVerifier()
        let challenge = generateChallenge(from: verifier)
        return (verifier, challenge)
    }

    private static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func generateChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return Data(hash).base64URLEncoded()
    }

    static func saveVerifier(_ verifier: String) {
        UserDefaults.standard.set(verifier, forKey: "pkce_verifier")
    }

    static func loadVerifier() -> String? {
        UserDefaults.standard.string(forKey: "pkce_verifier")
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
