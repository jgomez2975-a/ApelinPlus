import Foundation

// MARK: - Snapshot

/// What the row shows for one instance: an answer, or why there is none.
public struct BalanceSnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var reading: BalanceReading?
    public var failure: BalanceError?
    public var fetchedAt: Date

    public init(id: UUID, reading: BalanceReading? = nil, failure: BalanceError? = nil, fetchedAt: Date = Date()) {
        self.id = id
        self.reading = reading
        self.failure = failure
        self.fetchedAt = fetchedAt
    }

    public var isFailure: Bool { reading == nil }

    /// How the row should be tinted.
    public enum Tier: Sendable, Equatable {
        /// Money is there and above the warning line.
        case healthy
        /// Money is there but at or under the warning line.
        case low
        /// Nothing left, or the provider says the account cannot be used.
        case exhausted
        /// Asked, and the answer was a refusal or a transport error.
        case failed
        /// Never asked, or turned off.
        case unknown
    }

    public func tier(warningThreshold: Decimal?) -> Tier {
        if let failure {
            return failure == .notConfigured ? .unknown : .failed
        }
        guard let reading else { return .unknown }
        if reading.isAvailable == false { return .exhausted }
        guard let amount = reading.amount else {
            // A provider that reports only usage has no balance to warn on.
            return .healthy
        }
        if amount <= 0 { return .exhausted }
        if let threshold = warningThreshold, amount <= threshold { return .low }
        return .healthy
    }
}

// MARK: - Service

/// Asks one instance's provider what its account is worth, and remembers the
/// answer.
///
/// An actor, because the provider list rows, the balance detail page and the
/// background refresh all read the same cache and a half-updated entry would
/// show two different numbers on one screen.
public actor BalanceService {
    /// Everything that can answer, in the order `.automatic` tries them
    /// before host hints reorder it.
    public static let defaultAdapters: [any BalanceAdapter] = [
        OpenRouterAdapter(),
        DeepSeekAdapter(),
        NewAPIAdapter(),
        OneAPIAdapter(),
        OpenAIAdapter(),
    ]

    private let adapters: [any BalanceAdapter]
    private let credentials: BalanceCredentialStore
    private let session: URLSession
    private var cache: [UUID: BalanceSnapshot] = [:]
    /// One in-flight task per instance, so ten rows appearing at once do not
    /// send ten requests to the same relay.
    private var inFlight: [UUID: Task<BalanceSnapshot, Never>] = [:]
    /// Bumped by `forget`, so a request that finishes after its instance was
    /// removed cannot write the answer back into the cache.
    private var generation: [UUID: Int] = [:]

    public init(
        adapters: [any BalanceAdapter] = BalanceService.defaultAdapters,
        credentials: BalanceCredentialStore = BalanceCredentialStore(),
        session: URLSession = .shared,
    ) {
        self.adapters = adapters
        self.credentials = credentials
        self.session = session
    }

    // MARK: Cache

    public func cached(_ instanceID: UUID) -> BalanceSnapshot? {
        cache[instanceID]
    }

    public func allCached() -> [UUID: BalanceSnapshot] {
        cache
    }

    /// Whether a cached answer is old enough to be worth another request.
    public func needsRefresh(_ instance: ProviderInstance, now: Date = Date()) -> Bool {
        guard instance.balance.enabled, instance.balance.source != .none else { return false }
        guard let snapshot = cache[instance.id] else { return true }
        // A failure is retried on the next look rather than after the full
        // interval: the usual cause is being briefly offline.
        if snapshot.isFailure { return true }
        guard instance.balance.refreshInterval > 0 else { return false }
        return now.timeIntervalSince(snapshot.fetchedAt) >= instance.balance.refreshInterval
    }

    public func forget(_ instanceID: UUID) {
        cache[instanceID] = nil
        generation[instanceID] = (generation[instanceID] ?? 0) + 1
        inFlight[instanceID]?.cancel()
        inFlight[instanceID] = nil
    }

    // MARK: Querying

    /// Reads one instance's balance, joining a request already running.
    ///
    /// - Parameters:
    ///   - instance: whose balance.
    ///   - baseURL: the instance's Base URL as saved for its key. The balance
    ///     endpoint is derived from it.
    ///   - apiKey: the instance's model key. Used by DeepSeek, OpenRouter and
    ///     OpenAI; ignored by the relay adapters, which need a session token.
    @discardableResult
    public func refresh(
        instance: ProviderInstance,
        baseURL: String,
        apiKey: String,
    ) async -> BalanceSnapshot {
        if let running = inFlight[instance.id] {
            return await running.value
        }

        guard instance.balance.enabled, instance.balance.source != .none else {
            let snapshot = BalanceSnapshot(id: instance.id, failure: .notConfigured)
            cache[instance.id] = snapshot
            return snapshot
        }

        let token = generation[instance.id] ?? 0
        let task = Task.detached { [adapters, credentials, session] in
            let credential = try? credentials.credential(for: instance.id)
            var lastError: BalanceError = .notConfigured

            guard let endpoint = BalanceEndpoint(baseURL: baseURL) else {
                return BalanceSnapshot(id: instance.id, failure: .badEndpoint(baseURL))
            }

            let candidates = Self.ordered(
                adapters: adapters,
                settings: instance.balance.source,
                endpoint: endpoint,
                apiKey: apiKey,
            )

            for adapter in candidates {
                do {
                    let reading = try await adapter.read(
                        endpoint: endpoint,
                        apiKey: apiKey,
                        credential: credential,
                        settings: instance.balance,
                        session: session,
                    )
                    return BalanceSnapshot(id: instance.id, reading: reading)
                } catch let error as BalanceError {
                    // An adapter that could not be asked at all says nothing
                    // about the provider; keep looking.
                    if error == .notConfigured { continue }
                    lastError = error
                    // A pinned source has one chance; automatic keeps going
                    // past a refusal, because the refusal may belong to the
                    // wrong shape rather than to the credential.
                    if instance.balance.source != .automatic { break }
                } catch {
                    lastError = .network(error.localizedDescription)
                    if instance.balance.source != .automatic { break }
                }
            }
            return BalanceSnapshot(id: instance.id, failure: lastError)
        }
        inFlight[instance.id] = task

        let snapshot = await task.value
        inFlight[instance.id] = nil
        // Only the request that is still current may write the cache; a
        // `forget` during the await bumped the generation and owns nothing
        // any more.
        if (generation[instance.id] ?? 0) == token {
            cache[instance.id] = snapshot
        }
        return snapshot
    }

    /// Reads every instance whose settings ask for it, one at a time so a
    /// list of eight relays does not open eight sockets at once.
    ///
    /// - Parameter baseURL: instance id → its saved Base URL.
    /// - Parameter apiKey: instance id → its saved model key.
    ///
    /// Both lookups are `@Sendable`: they cross into the actor, and a
    /// closure that captured a view model would drag main-actor isolation
    /// along with it.
    @discardableResult
    public func refreshAll(
        instances: [ProviderInstance],
        baseURL: @Sendable (UUID) -> String?,
        apiKey: @Sendable (UUID) -> String?,
    ) async -> [UUID: BalanceSnapshot] {
        var results: [UUID: BalanceSnapshot] = [:]
        for instance in instances {
            guard instance.balance.enabled, instance.balance.source != .none else { continue }
            guard needsRefresh(instance) else {
                if let cached = cache[instance.id] { results[instance.id] = cached }
                continue
            }
            guard let url = baseURL(instance.id), !url.isEmpty else { continue }
            let snapshot = await refresh(
                instance: instance,
                baseURL: url,
                apiKey: apiKey(instance.id) ?? "",
            )
            results[instance.id] = snapshot
        }
        return results
    }

    // MARK: Ordering

    /// Which adapter to try first.
    ///
    /// A pinned source is the only candidate. `.automatic` is reordered by
    /// what the key and the host already say: an `sk-or-` key is
    /// OpenRouter's, `api.deepseek.com` is DeepSeek's, and a relay is
    /// neither, so the two New-API-family shapes go first for it.
    static func ordered(
        adapters: [any BalanceAdapter],
        settings: BalanceSettings.Source,
        endpoint: BalanceEndpoint,
        apiKey: String,
    ) -> [any BalanceAdapter] {
        if settings != .automatic {
            return adapters.filter { $0.source == settings }
        }
        let host = endpoint.host.lowercased()
        func score(_ adapter: any BalanceAdapter) -> Int {
            let hint: Int = switch adapter.source {
            case .openRouter:
                apiKey.hasPrefix("sk-or-") ? 100 : (host.contains("openrouter") ? 90 : 0)
            case .deepSeek:
                host.contains("deepseek") ? 100 : 30
            case .openAI:
                (host == "api.openai.com" || host.hasSuffix(".openai.com")) ? 100 : 0
            case .newAPI:
                20
            case .oneAPI:
                18
            case .automatic, .none:
                -1000
            }
            return hint * 1000 + adapter.probeOrder
        }
        return adapters.sorted { score($0) > score($1) }
    }
}
