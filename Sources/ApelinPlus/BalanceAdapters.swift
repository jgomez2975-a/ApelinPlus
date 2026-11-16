import Foundation

// MARK: - Reading

/// What one provider said about one account's money.
///
/// Every field is optional because no two providers agree on what they
/// report: DeepSeek names a granted and a topped-up balance and no usage,
/// OpenRouter reports lifetime credits and lifetime usage and no balance,
/// OpenAI reports a limit and a month's cents. A field the provider did not
/// send stays `nil`, and the row shows only what is there rather than a
/// zero that would read as "you are out of money".
public struct BalanceReading: Sendable, Equatable {
    /// What is left, in `currency`.
    public var amount: Decimal?
    /// ISO 4217, uppercased. `nil` when the provider names no currency.
    public var currency: String?
    /// Spent today, when the provider separates it.
    public var usedToday: Decimal?
    /// Spent since the first of the month.
    public var usedThisMonth: Decimal?
    /// Granted credit, which does not count against the paid balance.
    public var granted: Decimal?
    /// Paid credit.
    public var toppedUp: Decimal?
    /// The plan or tier the provider names, if any.
    public var planName: String?
    /// Whether the provider says the account can still be used.
    public var isAvailable: Bool?
    /// The source that answered, which may differ from the one configured
    /// when the settings say `.automatic`.
    public var source: BalanceSettings.Source
    /// Anything worth showing that does not fit the fields above.
    public var note: String?

    public init(
        amount: Decimal? = nil,
        currency: String? = nil,
        usedToday: Decimal? = nil,
        usedThisMonth: Decimal? = nil,
        granted: Decimal? = nil,
        toppedUp: Decimal? = nil,
        planName: String? = nil,
        isAvailable: Bool? = nil,
        source: BalanceSettings.Source,
        note: String? = nil,
    ) {
        self.amount = amount
        self.currency = currency
        self.usedToday = usedToday
        self.usedThisMonth = usedThisMonth
        self.granted = granted
        self.toppedUp = toppedUp
        self.planName = planName
        self.isAvailable = isAvailable
        self.source = source
        self.note = note
    }
}

// MARK: - Errors

public enum BalanceError: Error, LocalizedError, Equatable {
    /// The instance has balance turned off, or no source could be tried.
    case notConfigured
    /// The endpoint is not a usable HTTP(S) origin.
    case badEndpoint(String)
    /// The provider does not accept the credential it was given.
    case unauthorized
    /// The endpoint answered, but not with a shape this adapter knows.
    case unrecognizedResponse(String)
    /// The provider has no such endpoint — usually the wrong source picked.
    case endpointMissing(String)
    /// The provider answered with an error of its own.
    case providerRefused(String)
    /// Transport.
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Balance is turned off for this provider."
        case let .badEndpoint(text): "The endpoint is not a valid address: \(text)"
        case .unauthorized: "The provider did not accept the credential."
        case let .unrecognizedResponse(text): "The provider answered in an unknown shape: \(text)"
        case let .endpointMissing(path): "This provider has no \(path) endpoint."
        case let .providerRefused(text): "The provider refused the query: \(text)"
        case let .network(text): "The request did not complete: \(text)"
        }
    }

    /// One line for the row, short enough for a 44-point cell.
    public var shortDescription: String {
        switch self {
        case .notConfigured: "Not queried"
        case .badEndpoint: "Bad address"
        case .unauthorized: "Key rejected"
        case .unrecognizedResponse: "Unknown reply"
        case .endpointMissing: "No endpoint"
        case .providerRefused: "Refused"
        case .network: "Offline"
        }
    }
}

// MARK: - Endpoint

/// Where a provider's API lives, derived from the base URL the user saved.
///
/// Users type `https://api.yunwu.ai/v1`, `https://api.yunwu.ai/v1/`, and
/// `https://api.yunwu.ai` for the same relay. Balance endpoints hang off the
/// **origin**, not off `/v1`, so the path a model request needs has to be
/// dropped first — and the drop has to survive a relay deployed under a
/// sub-path such as `https://gateway.example.com/yunwu/v1`.
public struct BalanceEndpoint: Sendable, Equatable {
    /// Scheme and host and port: what an absolute path is appended to.
    public var origin: URL
    /// Any path the relay sits under, with a leading slash and no trailing
    /// one. Empty when the API is at the root.
    public var basePath: String

    public init(origin: URL, basePath: String = "") {
        self.origin = origin
        self.basePath = basePath
    }

    /// Reads a saved base URL. Returns `nil` when it is not HTTP(S) with a
    /// host, which is the same rule `AccountDesk.validated` applies to a
    /// key's Base URL field.
    public init?(baseURL: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { return nil }

        var originText = "\(scheme)://\(host)"
        if let port = components.port {
            originText += ":\(port)"
        }
        guard let origin = URL(string: originText) else { return nil }
        self.origin = origin

        // The path a balance endpoint keeps: everything except a trailing
        // version prefix, which belongs to the model API rather than to the
        // deployment. Longest first, because `/api/v1` ends with `/v1` and
        // stripping the short one would leave a stray `/api`.
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let versionPrefixes = ["/compatible-mode/v1", "/api/v1", "/v1beta", "/openai", "/v1"]
        if let prefix = versionPrefixes.first(where: { path.hasSuffix($0) }) {
            path.removeLast(prefix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        self.basePath = path
    }

    /// The origin, the deployment's path, then `path`.
    public func url(_ path: String) -> URL? {
        let joined = basePath + (path.hasPrefix("/") ? path : "/" + path)
        return URL(string: joined, relativeTo: origin)?.absoluteURL
    }

    /// `api.yunwu.ai`, for the row's subtitle.
    public var host: String {
        origin.host ?? origin.absoluteString
    }
}

// MARK: - Adapter

/// One provider's balance API.
public protocol BalanceAdapter: Sendable {
    var source: BalanceSettings.Source { get }
    /// Tried in this order when the settings say `.automatic`. A provider
    /// that is only ever reached by one relay family should be early.
    var probeOrder: Int { get }

    func read(
        endpoint: BalanceEndpoint,
        apiKey: String,
        credential: BalanceCredential?,
        settings: BalanceSettings,
        session: URLSession,
    ) async throws -> BalanceReading
}

// MARK: - Shared plumbing

/// The bits every adapter repeats: build a GET, send it, turn a status into
/// `BalanceError`, decode.
enum BalanceHTTP {
    static func get(
        _ url: URL,
        headers: [String: String],
        session: URLSession,
        timeout: TimeInterval = 15,
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BalanceError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BalanceError.unrecognizedResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200 ... 299:
            return data
        case 401, 403:
            throw BalanceError.unauthorized
        case 404:
            throw BalanceError.endpointMissing(url.path)
        default:
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw BalanceError.providerRefused("HTTP \(http.statusCode) \(body)")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw BalanceError.unrecognizedResponse(body)
        }
    }
}

/// A number a provider sends as either `12.5` or `"12.50"`.
///
/// The two are not academic: DeepSeek sends `"total_balance":"110.00"` as a
/// string, OpenAI sends `"total_usage":1234` as a number, and relays differ
/// between firmware versions of the same product.
struct FlexibleDecimal: Decodable, Sendable, Equatable {
    var value: Decimal?

    init(_ value: Decimal?) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
            return
        }
        if let number = try? container.decode(Decimal.self) {
            value = number
            return
        }
        if let text = try? container.decode(String.self) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
            return
        }
        // A nested amount, as some relays send: {"amount": 1.5}
        if let object = try? container.decode([String: FlexibleDecimal].self) {
            value = object["amount"]?.value ?? object["value"]?.value
            return
        }
        value = nil
    }
}

// MARK: - New-API

/// New-API and its forks. `GET /api/user/self` with the site's own session
/// token, not the model key — which is why `BalanceCredential` exists.
///
/// `quota` counts in units of `quotaPerUnit` per US dollar, 500000 by
/// default; a fork that changed the unit is why the setting is exposed.
public struct NewAPIAdapter: BalanceAdapter {
    public let source: BalanceSettings.Source = .newAPI
    public let probeOrder: Int = 10

    public init() {}

    public func read(
        endpoint: BalanceEndpoint,
        apiKey: String,
        credential: BalanceCredential?,
        settings: BalanceSettings,
        session: URLSession,
    ) async throws -> BalanceReading {
        // New-API will not read balance from an `sk-` key. Without a session
        // token there is nothing to ask with, and pretending otherwise would
        // report "key rejected" for a provider that was never asked properly.
        guard let token = credential?.accessToken, !token.isEmpty else {
            throw BalanceError.notConfigured
        }
        guard let url = endpoint.url("/api/user/self") else {
            throw BalanceError.badEndpoint(endpoint.origin.absoluteString)
        }
        var headers = ["Authorization": "Bearer \(token)"]
        if let userID = credential?.userID, !userID.isEmpty {
            headers["New-Api-User"] = userID
        }

        let data = try await BalanceHTTP.get(url, headers: headers, session: session)
        let payload = try BalanceHTTP.decode(Self.Response.self, from: data)
        guard payload.success != false else {
            throw BalanceError.providerRefused(payload.message ?? "success: false")
        }
        guard let body = payload.data else {
            throw BalanceError.unrecognizedResponse("no data")
        }

        let perUnit = settings.quotaPerUnit ?? 500_000
        let remaining = body.quota?.value.map { $0 / perUnit }
        let used = body.usedQuota?.value.map { $0 / perUnit }
        return BalanceReading(
            amount: remaining,
            currency: settings.currencyOverride ?? "USD",
            usedThisMonth: used,
            planName: body.group,
            source: source,
        )
    }

    struct Response: Decodable, Sendable {
        var success: Bool?
        var message: String?
        var data: Body?

        struct Body: Decodable, Sendable {
            var quota: FlexibleDecimal?
            var usedQuota: FlexibleDecimal?
            var group: String?

            enum CodingKeys: String, CodingKey {
                case quota
                case usedQuota = "used_quota"
                case group
            }
        }
    }
}

// MARK: - One-API

/// One-API and its forks. Same endpoint and same quota unit as New-API; the
/// difference that matters is that some One-API builds answer a bare object
/// without the `success` wrapper, which the decoder here tolerates.
public struct OneAPIAdapter: BalanceAdapter {
    public let source: BalanceSettings.Source = .oneAPI
    public let probeOrder: Int = 20

    public init() {}

    public func read(
        endpoint: BalanceEndpoint,
        apiKey: String,
        credential: BalanceCredential?,
        settings: BalanceSettings,
        session: URLSession,
    ) async throws -> BalanceReading {
        guard let token = credential?.accessToken, !token.isEmpty else {
            throw BalanceError.notConfigured
        }
        guard let url = endpoint.url("/api/user/self") else {
            throw BalanceError.badEndpoint(endpoint.origin.absoluteString)
        }
        var headers = ["Authorization": "Bearer \(token)"]
        if let userID = credential?.userID, !userID.isEmpty {
            headers["New-Api-User"] = userID
        }

        let data = try await BalanceHTTP.get(url, headers: headers, session: session)
        let payload = try BalanceHTTP.decode(Self.Response.self, from: data)
        guard payload.success != false else {
            throw BalanceError.providerRefused(payload.message ?? "success: false")
        }
        // Either the wrapped body or the object itself.
        let body = payload.data ?? payload.asBody
        guard let body else {
            throw BalanceError.unrecognizedResponse("no data")
        }

        let perUnit = settings.quotaPerUnit ?? 500_000
        return BalanceReading(
            amount: body.quota?.value.map { $0 / perUnit },
            currency: settings.currencyOverride ?? "USD",
            usedThisMonth: body.usedQuota?.value.map { $0 / perUnit },
            planName: body.group,
            source: source,
        )
    }

    struct Response: Decodable, Sendable {
        var success: Bool?
        var message: String?
        var data: Body?
        // A build that answers `{"quota":…,"used_quota":…}` at the top level.
        var quota: FlexibleDecimal?
        var usedQuota: FlexibleDecimal?
        var group: String?

        enum CodingKeys: String, CodingKey {
            case success, message, data, quota, group
            case usedQuota = "used_quota"
        }

        var asBody: Body? {
            guard quota != nil || usedQuota != nil else { return nil }
            return Body(quota: quota, usedQuota: usedQuota, group: group)
        }

        struct Body: Decodable, Sendable {
            var quota: FlexibleDecimal?
            var usedQuota: FlexibleDecimal?
            var group: String?

            enum CodingKeys: String, CodingKey {
                case quota
                case usedQuota = "used_quota"
                case group
            }
        }
    }
}

// MARK: - OpenRouter

/// OpenRouter's credits endpoint. Takes the model key itself, so no
/// `BalanceCredential` is needed. Reports lifetime credits and lifetime
/// usage rather than a balance, so the remaining amount is the difference.
public struct OpenRouterAdapter: BalanceAdapter {
    public let source: BalanceSettings.Source = .openRouter
    public let probeOrder: Int = 30

    public init() {}

    public func read(
        endpoint: BalanceEndpoint,
        apiKey: String,
        credential: BalanceCredential?,
        settings: BalanceSettings,
        session: URLSession,
    ) async throws -> BalanceReading {
        guard !apiKey.isEmpty else { throw BalanceError.unauthorized }
        guard let url = endpoint.url("/api/v1/credits") else {
            throw BalanceError.badEndpoint(endpoint.origin.absoluteString)
        }
        let data = try await BalanceHTTP.get(
            url,
            headers: ["Authorization": "Bearer \(apiKey)"],
            session: session,
        )
        let payload = try BalanceHTTP.decode(Response.self, from: data)
        guard let body = payload.data else {
            throw BalanceError.unrecognizedResponse("no data")
        }
        let total = body.totalCredits?.value
        let used = body.totalUsage?.value
        let remaining: Decimal? = if let total, let used { total - used } else { nil }
        return BalanceReading(
            amount: remaining,
            currency: settings.currencyOverride ?? "USD",
            usedThisMonth: used,
            source: source,
        )
    }

    struct Response: Decodable, Sendable {
        var data: Body?

        struct Body: Decodable, Sendable {
            var totalCredits: FlexibleDecimal?
            var totalUsage: FlexibleDecimal?

            enum CodingKeys: String, CodingKey {
                case totalCredits = "total_credits"
                case totalUsage = "total_usage"
            }
        }
    }
}

// MARK: - DeepSeek

/// DeepSeek's own balance endpoint. Reports a granted and a topped-up
/// balance separately; the reserved amount, when present, is already taken
/// out of the total, so `total_balance` is what is spendable.
public struct DeepSeekAdapter: BalanceAdapter {
    public let source: BalanceSettings.Source = .deepSeek
    public let probeOrder: Int = 40

    public init() {}

    public func read(
        endpoint: BalanceEndpoint,
        apiKey: String,
        credential: BalanceCredential?,
        settings: BalanceSettings,
        session: URLSession,
    ) async throws -> BalanceReading {
        guard !apiKey.isEmpty else { throw BalanceError.unauthorized }
        guard let url = endpoint.url("/user/balance") else {
            throw BalanceError.badEndpoint(endpoint.origin.absoluteString)
        }
        let data = try await BalanceHTTP.get(
            url,
            headers: ["Authorization": "Bearer \(apiKey)"],
            session: session,
        )
        let payload = try BalanceHTTP.decode(Response.self, from: data)
        guard let infos = payload.balanceInfos, !infos.isEmpty else {
            throw BalanceError.unrecognizedResponse("no balance_infos")
        }
        // A multi-currency account lists one entry per currency. The user's
        // override wins; otherwise CNY, because that is what a Chinese
        // account is topped up in and what the app's other prices show.
        let wanted = settings.currencyOverride?.uppercased()
        let info = infos.first { $0.currency?.uppercased() == wanted }
            ?? infos.first { $0.currency?.uppercased() == "CNY" }
            ?? infos[0]

        return BalanceReading(
            amount: info.totalBalance?.value,
            currency: wanted ?? info.currency?.uppercased() ?? "CNY",
            granted: info.grantedBalance?.value,
            toppedUp: info.toppedUpBalance?.value,
            isAvailable: payload.isAvailable,
            source: source,
        )
    }

    struct Response: Decodable, Sendable {
        var isAvailable: Bool?
        var balanceInfos: [Info]?

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }

        struct Info: Decodable, Sendable {
            var currency: String?
            var totalBalance: FlexibleDecimal?
            var grantedBalance: FlexibleDecimal?
            var toppedUpBalance: FlexibleDecimal?

            enum CodingKeys: String, CodingKey {
                case currency
                case totalBalance = "total_balance"
                case grantedBalance = "granted_balance"
                case toppedUpBalance = "topped_up_balance"
            }
        }
    }
}

// MARK: - OpenAI

/// OpenAI's own billing endpoints. Two requests: the subscription's hard
/// limit, then this month's usage in cents.
///
/// Most org keys are refused these days — the endpoints answer 401 for a
/// key that works for completions. That refusal is reported as
/// `.unauthorized` rather than as a balance of zero, because a wrong number
/// is worse than a missing one.
public struct OpenAIAdapter: BalanceAdapter {
    public let source: BalanceSettings.Source = .openAI
    public let probeOrder: Int = 50

    public init() {}

    public func read(
        endpoint: BalanceEndpoint,
        apiKey: String,
        credential: BalanceCredential?,
        settings: BalanceSettings,
        session: URLSession,
    ) async throws -> BalanceReading {
        guard !apiKey.isEmpty else { throw BalanceError.unauthorized }
        guard let subscriptionURL = endpoint.url("/v1/dashboard/billing/subscription"),
              var usageComponents = URLComponents(url: endpoint.origin, resolvingAgainstBaseURL: false)
        else { throw BalanceError.badEndpoint(endpoint.origin.absoluteString) }

        let headers = ["Authorization": "Bearer \(apiKey)"]
        let subscriptionData = try await BalanceHTTP.get(subscriptionURL, headers: headers, session: session)
        let subscription = try BalanceHTTP.decode(Subscription.self, from: subscriptionData)

        // OpenAI counts usage from the first of the month, in cents, over a
        // range that includes today.
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let end = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"

        usageComponents.path = (endpoint.url("/v1/dashboard/billing/usage")?.path ?? "/v1/dashboard/billing/usage")
        usageComponents.queryItems = [
            URLQueryItem(name: "start_date", value: formatter.string(from: start)),
            URLQueryItem(name: "end_date", value: formatter.string(from: end)),
        ]
        guard let usageURL = usageComponents.url else {
            throw BalanceError.badEndpoint(endpoint.origin.absoluteString)
        }
        let usageData = try await BalanceHTTP.get(usageURL, headers: headers, session: session)
        let usage = try BalanceHTTP.decode(Usage.self, from: usageData)

        let limit = subscription.hardLimitUSD?.value
        let spent = usage.totalUsage?.value.map { $0 / 100 }
        let remaining: Decimal? = if let limit, let spent { limit - spent } else { nil }
        return BalanceReading(
            amount: remaining,
            currency: settings.currencyOverride ?? "USD",
            usedThisMonth: spent,
            planName: subscription.plan?.title,
            source: source,
            note: limit.map { "Limit \($0)" },
        )
    }

    struct Subscription: Decodable, Sendable {
        var hardLimitUSD: FlexibleDecimal?
        var plan: Plan?

        enum CodingKeys: String, CodingKey {
            case hardLimitUSD = "hard_limit_usd"
            case plan
        }

        struct Plan: Decodable, Sendable {
            var title: String?
        }
    }

    struct Usage: Decodable, Sendable {
        var totalUsage: FlexibleDecimal?

        enum CodingKeys: String, CodingKey {
            case totalUsage = "total_usage"
        }
    }
}
