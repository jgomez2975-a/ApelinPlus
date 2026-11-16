import ApelinPlus
import Foundation
import SwiftUI

/// What the provider list shows, and the calls it makes to get there.
///
/// A model rather than bindings scattered through the view: the list needs
/// the instance file, the balance cache and the keychain at the same time,
/// and three independent `@State` copies of that would disagree with each
/// other after the first refresh.
@MainActor
public final class ProviderListModel: ObservableObject {
    /// `UUID` → the value stored under that instance's key. Passed in
    /// rather than read here, because the keychain lives in the app's
    /// process and this type is meant to stay testable without one.
    public typealias StringLookup = @Sendable (UUID) -> String?

    /// A display name for a platform id. `AgentProvider` is the app's, so
    /// the caller maps it; the fallback is the raw id.
    public typealias PlatformNamer = @Sendable (String) -> String

    @Published public private(set) var instances: [ProviderInstance] = []
    @Published public private(set) var balances: [UUID: BalanceSnapshot] = [:]
    @Published public private(set) var loadError: String?
    @Published public private(set) var isRefreshing = false
    @Published public var searchText = ""

    private let store: ProviderInstanceStore
    private let service: BalanceService
    private let credentials: BalanceCredentialStore
    private let baseURL: StringLookup
    private let apiKey: StringLookup
    private let nameForPlatform: PlatformNamer

    public init(
        store: ProviderInstanceStore,
        service: BalanceService,
        credentials: BalanceCredentialStore = BalanceCredentialStore(),
        baseURL: @escaping StringLookup,
        apiKey: @escaping StringLookup,
        nameForPlatform: @escaping PlatformNamer = { $0 },
    ) {
        self.store = store
        self.service = service
        self.credentials = credentials
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.nameForPlatform = nameForPlatform
    }

    // MARK: - Loading

    public func load() async {
        instances = await store.all()
        loadError = await store.loadError()
        balances = await service.allCached()
        // The cache is only half of it: rows whose instance asked for a
        // balance and has no cached answer yet still need one request.
        await refreshStaleBalances()
    }

    /// Fetches only the instances whose balance is enabled, turned on and
    /// older than its refresh interval. Called from `load` so opening the
    /// list does not depend on the user pulling to refresh.
    public func refreshStaleBalances() async {
        guard !isRefreshing else { return }
        let targets = instances.filter { instance in
            instance.balance.enabled && instance.balance.source != .none
        }
        guard !targets.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let urls = urlsByInstance(targets)
        let keys = keysByInstance(targets)
        let results = await service.refreshAll(
            instances: targets,
            baseURL: { urls[$0] },
            apiKey: { keys[$0] ?? "" },
        )
        balances.merge(results) { _, new in new }
    }

    /// Refreshes everything, ignoring the interval. This is what a pull to
    /// refresh does, and what the detail page's button does.
    public func refreshAllBalances() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let targets = instances.filter { $0.balance.enabled && $0.balance.source != .none }
        guard !targets.isEmpty else { return }

        let urls = urlsByInstance(targets)
        let keys = keysByInstance(targets)
        for instance in targets {
            guard let url = urls[instance.id] else { continue }
            let snapshot = await service.refresh(
                instance: instance,
                baseURL: url,
                apiKey: keys[instance.id] ?? "",
            )
            balances[instance.id] = snapshot
        }
    }

    public func refreshBalance(of instance: ProviderInstance) async -> BalanceSnapshot? {
        guard let url = baseURL(instance.id), !url.isEmpty else { return nil }
        let snapshot = await service.refresh(
            instance: instance,
            baseURL: url,
            apiKey: apiKey(instance.id) ?? "",
        )
        balances[instance.id] = snapshot
        return snapshot
    }

    // MARK: - Editing

    public func save(_ instance: ProviderInstance) async {
        do {
            try await store.upsert(instance)
        } catch {
            loadError = error.localizedDescription
            return
        }
        await load()
    }

    public func delete(_ instance: ProviderInstance) async {
        try? await store.remove(id: instance.id)
        // Order matters: bumping the balance service first stops a request
        // that is already in flight from writing the answer back.
        await service.forget(instance.id)
        try? credentials.remove(instance.id)
        balances[instance.id] = nil
        await load()
    }

    public func duplicate(_ instance: ProviderInstance) async {
        var copy = instance
        copy.id = UUID()
        copy.createdAt = Date()
        copy.label = Self.copyName(of: instance, platformName: nameForPlatform(instance.providerID))
        copy.pinned = false
        try? await store.upsert(copy)
        await load()
    }

    // MARK: - Reading

    public func platformName(_ instance: ProviderInstance) -> String {
        nameForPlatform(instance.providerID)
    }

    public func host(_ instance: ProviderInstance) -> String? {
        guard let raw = baseURL(instance.id), !raw.isEmpty else { return nil }
        return BalanceEndpoint(baseURL: raw)?.host
    }

    public func balance(_ instance: ProviderInstance) -> BalanceSnapshot? {
        balances[instance.id]
    }

    /// Clears the banner the alert shows after the user has read it.
    public func dismissLoadError() {
        loadError = nil
    }

    // MARK: - Sections

    public struct Section: Identifiable, Sendable {
        public var id: String
        /// `nil` draws no header, which is what the pinned block and the
        /// ungrouped rows get.
        public var title: String?
        public var instances: [ProviderInstance]
    }

    /// Pinned first, then ungrouped, then each named group in order. The
    /// store already sorts that way; this only cuts it into sections so
    /// the list can draw separators with names on them.
    public var sections: [Section] {
        let visible = filtered
        var pinned: [ProviderInstance] = []
        var ungrouped: [ProviderInstance] = []
        var groups: [(name: String, items: [ProviderInstance])] = []

        for instance in visible {
            if instance.pinned {
                pinned.append(instance)
                continue
            }
            let name = (instance.group ?? "").trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                ungrouped.append(instance)
            } else if let index = groups.firstIndex(where: { $0.name == name }) {
                groups[index].items.append(instance)
            } else {
                groups.append((name, [instance]))
            }
        }

        var result: [Section] = []
        if !pinned.isEmpty {
            result.append(Section(id: "pinned", title: "Pinned", instances: pinned))
        }
        if !ungrouped.isEmpty {
            result.append(Section(id: "ungrouped", title: groups.isEmpty ? nil : "Others", instances: ungrouped))
        }
        for group in groups {
            result.append(Section(id: "group-\(group.name)", title: group.name, instances: group.items))
        }
        return result
    }

    public var filtered: [ProviderInstance] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return instances }
        return instances.filter { instance in
            let label = instance.label ?? ""
            let platform = platformName(instance)
            let group = instance.group ?? ""
            let host = host(instance) ?? ""
            return [label, platform, group, host].contains { field in
                field.localizedCaseInsensitiveContains(needle)
            }
        }
    }

    public var isEmpty: Bool {
        instances.isEmpty
    }

    // MARK: - Helpers

    /// Snapshot the lookups into plain dictionaries before handing them to
    /// the balance service. A closure that captured `self` would be
    /// main-actor isolated and could not cross into the actor.
    private func urlsByInstance(_ list: [ProviderInstance]) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for instance in list {
            if let url = baseURL(instance.id), !url.isEmpty {
                map[instance.id] = url
            }
        }
        return map
    }

    private func keysByInstance(_ list: [ProviderInstance]) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for instance in list {
            if let key = apiKey(instance.id), !key.isEmpty {
                map[instance.id] = key
            }
        }
        return map
    }

    private static func copyName(of instance: ProviderInstance, platformName: String) -> String {
        let base = instance.displayName(platformName: platformName)
        return "\(base) copy"
    }
}
