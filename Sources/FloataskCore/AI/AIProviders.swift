import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AIAvailability: Equatable {
    case available
    case unavailable(String)   // user-facing reason
}

/// A text-in / text-out model. The planner owns prompting and validation, so providers stay tiny
/// and interchangeable (on-device Apple model today, Claude via API key later, others possible).
public protocol AIProvider {
    var displayName: String { get }
    /// True when requests never leave this Mac.
    var isLocal: Bool { get }
    func availability() -> AIAvailability
    func complete(system: String, prompt: String) async throws -> String
}

public enum AIError: LocalizedError {
    case unavailable(String)
    case badResponse(String)
    case network(String)
    case refused

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        case .badResponse: return "The assistant's answer couldn't be understood. Try rephrasing."
        case .network(let why): return why
        case .refused: return "The assistant declined this request."
        }
    }
}

// MARK: - Apple on-device model (Apple Intelligence, ~3B, no download)

public final class AppleIntelligenceProvider: AIProvider {
    public init() {}
    public var displayName: String { "Apple on-device model" }
    public var isLocal: Bool { true }

    public func availability() -> AIAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .unavailable("Turn on Apple Intelligence in System Settings to use the on-device assistant.")
            case .deviceNotEligible:
                return .unavailable("This Mac doesn't support Apple Intelligence. Add a Claude API key in Settings instead.")
            case .modelNotReady:
                return .unavailable("The on-device model is still downloading. Try again in a few minutes.")
            @unknown default:
                return .unavailable("The on-device model is unavailable right now.")
            }
        }
        #else
        return .unavailable("The on-device model requires macOS 26.")
        #endif
    }

    public func complete(system: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if case .unavailable(let why) = availability() { throw AIError.unavailable(why) }
        let session = LanguageModelSession(instructions: system)
        let options = GenerationOptions(temperature: 0.2)
        do {
            return try await session.respond(to: prompt, options: options).content
        } catch {
            Log.write("apple model error: \(error)")
            throw AIError.badResponse("\(error)")
        }
        #else
        throw AIError.unavailable("The on-device model requires macOS 26.")
        #endif
    }
}

// MARK: - Claude (Anthropic Messages API, raw HTTP — there is no official Swift SDK)

public final class AnthropicProvider: AIProvider {
    public static let defaultModel = "claude-opus-5-5"
    let model: String
    let apiKey: () -> String?

    public init(model: String, apiKey: @escaping () -> String? = { Keychain.read(Keychain.anthropicAccount) }) {
        self.model = model.isEmpty ? AnthropicProvider.defaultModel : model
        self.apiKey = apiKey
    }

    public var displayName: String { "Claude (\(model))" }
    public var isLocal: Bool { false }

    public func availability() -> AIAvailability {
        (apiKey()?.isEmpty ?? true) ? .unavailable("Add your Claude API key in Settings to use Claude.") : .available
    }

    public func complete(system: String, prompt: String) async throws -> String {
        guard let key = apiKey(), !key.isEmpty else { throw AIError.unavailable("Add your Claude API key in Settings.") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Server-side fallback: if a classifier declines, the API retries on a suitable model itself.
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AIError.network("Couldn't reach the Claude API. Check your internet connection.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            Log.write("anthropic error \(status): \(message)")
            switch status {
            case 401, 403: throw AIError.network("Your Claude API key was rejected. Check it in Settings.")
            case 429: throw AIError.network("Claude is rate-limiting requests. Try again shortly.")
            default: throw AIError.network("The Claude API returned an error (\(status)).")
            }
        }
        if (json["stop_reason"] as? String) == "refusal" { throw AIError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.badResponse("empty") }
        return text
    }
}

// MARK: - Keychain (API keys never go in the vault)

public enum Keychain {
    public static let service = AppIdentity.bundleId
    public static let anthropicAccount = "anthropic-api-key"

    public static func save(_ value: String, account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Keys saved while the app was called Taskflow (before 0.2.0) are moved over on first read.
    static let legacyService = "io.github.shihab-abir.taskflow"

    public static func read(_ account: String) -> String? {
        if let value = read(account, service: service) { return value }
        guard let old = read(account, service: legacyService) else { return nil }
        if save(old, account: account) { delete(account, service: legacyService) }
        return old
    }

    static func read(_ account: String, service: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(_ account: String, service: String = service) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }
}
