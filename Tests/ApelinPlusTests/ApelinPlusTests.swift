import Foundation
import XCTest
@testable import ApelinPlus

// MARK: - Stub transport

/// Answers requests from a table keyed by URL path, so an adapter can be
/// tested without a network.
final class StubURLProtocol: URLProtocol {
    struct Stub: Sendable {
        var status: Int
        var body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: Stub] = [:]
    /// Every path asked for, in order, so a test can prove the adapter
    /// picked the endpoint it claims to.
    nonisolated(unsafe) private static var requested: [String] = []

    static func reset() {
        lock.lock()
        table = [:]
        requested = []
        lock.unlock()
    }

    static func set(status: Int = 200, body: String, for path: String) {
        lock.lock()
        table[path] = Stub(status: status, body: body)
        lock.unlock()
    }

    static func record(_ path: String) {
        lock.lock()
        requested.append(path)
        lock.unlock()
    }

    static var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    private static func stub(_ path: String) -> Stub? {
        lock.lock()
        defer { lock.unlock() }
        return table[path]
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.record(path)
        guard let stub = Self.stub(path) else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Endpoint

final class BalanceEndpointTests: XCTestCase {
    func testDropsModelVersionPrefix() throws {
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://api.yunwu.ai/v1"))
        XCTAssertEqual(endpoint.origin.absoluteString, "https://api.yunwu.ai")
        XCTAssertEqual(endpoint.basePath, "")
        XCTAssertEqual(endpoint.url("/api/user/self")?.absoluteString, "https://api.yunwu.ai/api/user/self")
    }

    func testKeepsDeploymentSubpath() throws {
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://gateway.example.com/yunwu/v1"))
        XCTAssertEqual(endpoint.basePath, "/yunwu")
        XCTAssertEqual(
            endpoint.url("/api/user/self")?.absoluteString,
            "https://gateway.example.com/yunwu/api/user/self",
        )
    }

    func testKeepsExplicitPort() throws {
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "http://192.168.1.9:3000/v1/"))
        XCTAssertEqual(endpoint.host, "192.168.1.9")
        XCTAssertEqual(endpoint.origin.absoluteString, "http://192.168.1.9:3000")
    }

    func testRejectsNonHTTP() {
        XCTAssertNil(BalanceEndpoint(baseURL: "ftp://example.com/v1"))
        XCTAssertNil(BalanceEndpoint(baseURL: "not a url"))
        XCTAssertNil(BalanceEndpoint(baseURL: ""))
    }
}

// MARK: - Decoding

final class FlexibleDecimalTests: XCTestCase {
    func testReadsNumberStringAndNestedAmount() throws {
        struct Box: Decodable {
            var number: FlexibleDecimal?
            var text: FlexibleDecimal?
            var nested: FlexibleDecimal?
        }
        let json = #"{"number":12.5,"text":"110.00","nested":{"amount":3.25}}"#
        let box = try JSONDecoder().decode(Box.self, from: Data(json.utf8))
        XCTAssertEqual(box.number?.value, Decimal(string: "12.5"))
        XCTAssertEqual(box.text?.value, Decimal(string: "110.00"))
        XCTAssertEqual(box.nested?.value, Decimal(string: "3.25"))
    }
}

// MARK: - Adapters

final class BalanceAdapterTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        session = StubURLProtocol.session()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    func testNewAPIReadsQuotaInDollars() async throws {
        StubURLProtocol.set(body: #"{"success":true,"data":{"quota":21400000,"used_quota":500000,"group":"default"}}"#, for: "/api/user/self")
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://relay.example.com/v1"))
        let reading = try await NewAPIAdapter().read(
            endpoint: endpoint,
            apiKey: "sk-model-key",
            credential: BalanceCredential(accessToken: "session-token", userID: "7"),
            settings: BalanceSettings(),
            session: session,
        )
        XCTAssertEqual(reading.amount, Decimal(string: "42.8"))
        XCTAssertEqual(reading.usedThisMonth, 1)
        XCTAssertEqual(reading.currency, "USD")
        XCTAssertEqual(reading.source, .newAPI)
    }

    func testNewAPIWithoutSessionTokenIsNotConfigured() async throws {
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://relay.example.com/v1"))
        do {
            _ = try await NewAPIAdapter().read(
                endpoint: endpoint,
                apiKey: "sk-model-key",
                credential: nil,
                settings: BalanceSettings(),
                session: session,
            )
            XCTFail("A relay without a session token has nothing to ask with")
        } catch let error as BalanceError {
            XCTAssertEqual(error, .notConfigured)
        }
    }

    func testNewAPIHonoursQuotaPerUnit() async throws {
        StubURLProtocol.set(body: #"{"success":true,"data":{"quota":1000000,"used_quota":0}}"#, for: "/api/user/self")
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://relay.example.com"))
        let reading = try await NewAPIAdapter().read(
            endpoint: endpoint,
            apiKey: "",
            credential: BalanceCredential(accessToken: "t", userID: "1"),
            settings: BalanceSettings(quotaPerUnit: 100_000),
            session: session,
        )
        XCTAssertEqual(reading.amount, 10)
    }

    func testDeepSeekPrefersCNY() async throws {
        StubURLProtocol.set(
            body: #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"1.00"},{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#,
            for: "/user/balance",
        )
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://api.deepseek.com"))
        let reading = try await DeepSeekAdapter().read(
            endpoint: endpoint,
            apiKey: "sk-deepseek",
            credential: nil,
            settings: BalanceSettings(),
            session: session,
        )
        XCTAssertEqual(reading.amount, 110)
        XCTAssertEqual(reading.currency, "CNY")
        XCTAssertEqual(reading.granted, 10)
        XCTAssertEqual(reading.toppedUp, 100)
        XCTAssertEqual(reading.isAvailable, true)
    }

    func testOpenRouterSubtractsUsageFromCredits() async throws {
        StubURLProtocol.set(body: #"{"data":{"total_credits":100.0,"total_usage":25.5}}"#, for: "/api/v1/credits")
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://openrouter.ai/api/v1"))
        let reading = try await OpenRouterAdapter().read(
            endpoint: endpoint,
            apiKey: "sk-or-v1-abc",
            credential: nil,
            settings: BalanceSettings(),
            session: session,
        )
        XCTAssertEqual(reading.amount, Decimal(string: "74.5"))
        XCTAssertEqual(reading.usedThisMonth, Decimal(string: "25.5"))
    }

    func testOpenAITakesLimitMinusMonthInCents() async throws {
        StubURLProtocol.set(body: #"{"hard_limit_usd":120.0,"plan":{"title":"Pay as you go"}}"#, for: "/v1/dashboard/billing/subscription")
        StubURLProtocol.set(body: #"{"total_usage":1234}"#, for: "/v1/dashboard/billing/usage")
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://api.openai.com/v1"))
        let reading = try await OpenAIAdapter().read(
            endpoint: endpoint,
            apiKey: "sk-openai",
            credential: nil,
            settings: BalanceSettings(),
            session: session,
        )
        XCTAssertEqual(reading.amount, Decimal(string: "107.66"))
        XCTAssertEqual(reading.usedThisMonth, Decimal(string: "12.34"))
        XCTAssertEqual(reading.planName, "Pay as you go")
    }

    func test401BecomesKeyRejected() async throws {
        StubURLProtocol.set(status: 401, body: #"{"error":"bad key"}"#, for: "/user/balance")
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://api.deepseek.com"))
        do {
            _ = try await DeepSeekAdapter().read(
                endpoint: endpoint,
                apiKey: "sk-wrong",
                credential: nil,
                settings: BalanceSettings(),
                session: session,
            )
            XCTFail("A 401 is a refusal")
        } catch let error as BalanceError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertEqual(error.shortDescription, "Key rejected")
        }
    }

    func testAutomaticPrefersOpenRouterForItsOwnKey() throws {
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://some-relay.example.com/v1"))
        let ordered = BalanceService.ordered(
            adapters: BalanceService.defaultAdapters,
            settings: .automatic,
            endpoint: endpoint,
            apiKey: "sk-or-v1-abc",
        )
        XCTAssertEqual(ordered.first?.source, .openRouter)
    }

    func testAutomaticPrefersDeepSeekByHost() throws {
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://api.deepseek.com"))
        let ordered = BalanceService.ordered(
            adapters: BalanceService.defaultAdapters,
            settings: .automatic,
            endpoint: endpoint,
            apiKey: "sk-anything",
        )
        XCTAssertEqual(ordered.first?.source, .deepSeek)
    }

    func testPinnedSourceHasOneCandidate() throws {
        let endpoint = try XCTUnwrap(BalanceEndpoint(baseURL: "https://relay.example.com"))
        let ordered = BalanceService.ordered(
            adapters: BalanceService.defaultAdapters,
            settings: .oneAPI,
            endpoint: endpoint,
            apiKey: "",
        )
        XCTAssertEqual(ordered.map(\.source), [.oneAPI])
    }
}

// MARK: - Tiers and text

final class BalancePresentationTests: XCTestCase {
    private func snapshot(_ amount: Decimal?, threshold: Decimal? = nil) -> BalanceSnapshot {
        BalanceSnapshot(id: UUID(), reading: BalanceReading(amount: amount, currency: "CNY", source: .newAPI))
    }

    func testTierBoundaries() {
        XCTAssertEqual(snapshot(0).tier(warningThreshold: 5), .exhausted)
        XCTAssertEqual(snapshot(5).tier(warningThreshold: 5), .low)
        XCTAssertEqual(snapshot(4.99).tier(warningThreshold: 5), .low)
        XCTAssertEqual(snapshot(5.01).tier(warningThreshold: 5), .healthy)
        XCTAssertEqual(snapshot(5.01, threshold: nil).tier(warningThreshold: nil), .healthy)
    }

    func testFailureTierIsUnknownWhenNotConfigured() {
        let off = BalanceSnapshot(id: UUID(), failure: .notConfigured)
        XCTAssertEqual(off.tier(warningThreshold: nil), .unknown)
        let refused = BalanceSnapshot(id: UUID(), failure: .unauthorized)
        XCTAssertEqual(refused.tier(warningThreshold: nil), .failed)
    }

    func testPillReadsTheBalance() {
        XCTAssertEqual(BalanceText.pill(snapshot(Decimal(string: "42.8")), warningThreshold: nil), "¥42.80")
        XCTAssertEqual(BalanceText.pill(snapshot(1240), warningThreshold: nil), "¥1,240")
        XCTAssertEqual(BalanceText.pill(BalanceSnapshot(id: UUID(), failure: .unauthorized), warningThreshold: nil), "Key rejected")
    }

    func testSubtitleJoinsHostAndPlan() {
        let reading = BalanceReading(amount: 42.8, currency: "USD", planName: "default", source: .newAPI)
        let text = BalanceText.subtitle(
            host: "api.yunwu.ai",
            snapshot: BalanceSnapshot(id: UUID(), reading: reading),
            warningThreshold: nil,
        )
        XCTAssertEqual(text, "api.yunwu.ai · default")
    }
}

// MARK: - Instances

final class ProviderInstanceStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ApelinPlusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> ProviderInstanceStore {
        ProviderInstanceStore(location: .init(directory: directory))
    }

    func testMigrationCreatesOneInstancePerSignedInProvider() async throws {
        let store = store()
        let created = try await store.migrate(
            signedInProviderIDs: ["openAICompatible", "deepSeek"],
            subscriptionProviderIDs: ["anthropicOAuth"],
        )
        XCTAssertEqual(created.count, 2)
        let all = await store.all()
        XCTAssertEqual(all.count, 2)
        // Subscriptions are not asked for balance.
        XCTAssertEqual(all.first { $0.providerID == "anthropicOAuth" }, nil)
    }

    func testMigrationIsIdempotent() async throws {
        let store = store()
        try await store.migrate(signedInProviderIDs: ["openAICompatible"])
        let second = try await store.migrate(signedInProviderIDs: ["openAICompatible"])
        XCTAssertTrue(second.isEmpty)
        let all = await store.all()
        XCTAssertEqual(all.count, 1)
    }

    func testSecondInstanceGetsItsOwnStoreID() async throws {
        let store = store()
        let first = ProviderInstance(providerID: "openAICompatible", label: "Yunwu")
        let second = ProviderInstance(providerID: "openAICompatible", label: "Laozhang")
        try await store.upsert(first)
        try await store.upsert(second)

        let firstIsPrimary = await store.isPrimary(first)
        let secondIsPrimary = await store.isPrimary(second)
        XCTAssertTrue(firstIsPrimary)
        XCTAssertFalse(secondIsPrimary)
        XCTAssertEqual(first.storeID(providerStoreID: "openai-compatible", isFirstOfProvider: true), "openai-compatible")
        XCTAssertEqual(
            second.storeID(providerStoreID: "openai-compatible", isFirstOfProvider: false),
            "openai-compatible@\(second.id.uuidString)",
        )
    }

    func testOrderingPutsPinnedFirstThenGroups() async throws {
        let store = store()
        let alpha = ProviderInstance(providerID: "openAICompatible", label: "Alpha", group: "Relay")
        let beta = ProviderInstance(providerID: "deepSeek", label: "Beta", group: "Relay")
        let pinned = ProviderInstance(providerID: "openAI", label: "Zeta", pinned: true)
        let loose = ProviderInstance(providerID: "openRouter", label: "Loose")
        try await store.upsert(alpha)
        try await store.upsert(beta)
        try await store.upsert(pinned)
        try await store.upsert(loose)

        let ordered = await store.all()
        XCTAssertEqual(ordered.map(\.label), ["Zeta", "Loose", "Alpha", "Beta"])
    }

    func testUpdateKeepsTheID() async throws {
        let store = store()
        let instance = ProviderInstance(providerID: "openAICompatible")
        try await store.upsert(instance)
        let updated = try await store.update(id: instance.id) { $0.label = "Renamed" }
        XCTAssertEqual(updated?.id, instance.id)
        XCTAssertEqual(updated?.label, "Renamed")
    }

    func testBrokenFileIsMovedAsideRatherThanOverwritten() async throws {
        let url = directory.appendingPathComponent("instances.json")
        try Data("{ not json".utf8).write(to: url)

        let store = store()
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
        let error = await store.loadError()
        XCTAssertNotNil(error)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("instances.broken-") })
    }
}
