import Foundation

// MARK: - Store

/// Where `ProviderInstance`s live between launches: one JSON file, written
/// atomically, read once and cached.
///
/// A file rather than `UserDefaults`, because the list is a user document —
/// it survives a reinstall of the app bundle, it can be backed up and moved
/// between devices next to a project, and a corrupt one can be inspected
/// with `plutil` instead of being an opaque blob in a preferences domain.
///
/// An actor, because a settings screen, a chat composer and a background
/// balance refresh all reach it and none of them should see a half-written
/// file.
public actor ProviderInstanceStore {
    /// Where the file goes. Defaults to
    /// `Application Support/ApelinPlus/instances.json`.
    public struct Location: Sendable {
        public var directory: URL
        public var fileName: String

        public init(directory: URL, fileName: String = "instances.json") {
            self.directory = directory
            self.fileName = fileName
        }

        public static func standard() -> Location {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return Location(directory: base.appendingPathComponent("ApelinPlus", isDirectory: true))
        }

        public var fileURL: URL {
            directory.appendingPathComponent(fileName, isDirectory: false)
        }
    }

    private let location: Location
    private var cache: [ProviderInstance]?
    private var lastLoadError: String?

    public init(location: Location = .standard()) {
        self.location = location
    }

    /// Built per call rather than kept as a property: `JSONEncoder` is not
    /// `Sendable`, and holding one in an actor would make the type's
    /// isolation story murkier than the file I/O it wraps. The allocation is
    /// nothing next to a disk write.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Reading

    /// Every instance, in the order the list shows them: pinned first, then
    /// grouped, then ungrouped, each group by the user's label.
    ///
    /// - Parameter platformNames: `AgentProvider.rawValue` → its display
    ///   name. Used only to sort rows that have no label of their own, so
    ///   this type never needs `AgentProvider`.
    public func all(platformNames: [String: String] = [:]) -> [ProviderInstance] {
        (try? load()).map { sorted($0, platformNames: platformNames) } ?? []
    }

    /// One platform's instances, in display order. The first is the one that
    /// keeps the bare provider store id.
    public func instances(of providerID: String) -> [ProviderInstance] {
        (try? load())?
            .filter { $0.providerID == providerID }
            .sorted { $0.createdAt < $1.createdAt } ?? []
    }

    public func instance(id: UUID) -> ProviderInstance? {
        (try? load())?.first { $0.id == id }
    }

    /// The instance a platform's bare store id belongs to: its oldest one.
    public func primary(of providerID: String) -> ProviderInstance? {
        instances(of: providerID).first
    }

    /// Whether `instance` is the one holding the bare provider store id.
    public func isPrimary(_ instance: ProviderInstance) -> Bool {
        primary(of: instance.providerID)?.id == instance.id
    }

    /// The file could not be read or decoded last time. Shown in Settings
    /// rather than swallowed: a silently empty list looks like data loss.
    public func loadError() -> String? {
        _ = try? load()
        return lastLoadError
    }

    // MARK: - Writing

    /// Adds an instance, or replaces the one with the same id.
    public func upsert(_ instance: ProviderInstance) throws {
        var list = try load()
        if let index = list.firstIndex(where: { $0.id == instance.id }) {
            list[index] = instance
        } else {
            list.append(instance)
        }
        try save(list)
    }

    /// Removes one instance. Its credentials are the caller's to forget —
    /// this file knows nothing about the keychain.
    public func remove(id: UUID) throws {
        var list = try load()
        list.removeAll { $0.id == id }
        try save(list)
    }

    /// Applies an edit to one instance in place, leaving the rest untouched.
    /// Returns the edited instance, or `nil` when the id is not there.
    @discardableResult
    public func update(id: UUID, _ edit: (inout ProviderInstance) -> Void) throws -> ProviderInstance? {
        var list = try load()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        var instance = list[index]
        edit(&instance)
        instance.id = id
        list[index] = instance
        try save(list)
        return instance
    }

    /// Replaces the whole list. Used by the import and the migration below.
    public func replaceAll(_ instances: [ProviderInstance]) throws {
        try save(instances)
    }

    // MARK: - Migration

    /// Makes sure every platform that already has a signed-in account has an
    /// instance standing for it, so a build that predates instances opens
    /// with its accounts intact under their platform names.
    ///
    /// - Parameters:
    ///   - signedInProviderIDs: the `AgentProvider.rawValue` of every
    ///     platform `AgentAccountListResponse` reports as signed in.
    ///   - subscriptionProviderIDs: those whose account is a subscription
    ///     rather than a typed key. Their balance is not asked for, because
    ///     a subscription reports usage through the provider's own page and
    ///     not through a billing endpoint.
    /// - Returns: the instances it created. Empty when there was nothing to
    ///   do, which is the case on every launch after the first.
    @discardableResult
    public func migrate(
        signedInProviderIDs: [String],
        subscriptionProviderIDs: Set<String> = [],
    ) throws -> [ProviderInstance] {
        var list = try load()
        var created: [ProviderInstance] = []
        for providerID in signedInProviderIDs {
            guard !list.contains(where: { $0.providerID == providerID }) else { continue }
            let instance = ProviderInstance(
                providerID: providerID,
                balance: subscriptionProviderIDs.contains(providerID) ? .off : .default,
            )
            list.append(instance)
            created.append(instance)
        }
        if !created.isEmpty {
            try save(list)
        }
        return created
    }

    /// Drops instances whose platform no longer has a signed-in account and
    /// that the user never named. A named one is kept: the user wrote that
    /// label, and signing out to sign in again should not lose it.
    @discardableResult
    public func prune(
        signedInProviderIDs: Set<String>,
        keychainStoreIDs: Set<String>,
    ) throws -> [ProviderInstance] {
        var list = try load()
        let before = list.count
        list.removeAll { instance in
            guard !signedInProviderIDs.contains(instance.providerID) else { return false }
            guard (instance.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            // A later instance's credentials are still in the keychain when
            // only its account row went away; keep it so they are reachable.
            return !keychainStoreIDs.contains(instance.id.uuidString)
        }
        guard list.count != before else { return [] }
        try save(list)
        return list
    }

    // MARK: - File

    private func load() throws -> [ProviderInstance] {
        if let cache { return cache }
        let url = location.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            cache = []
            lastLoadError = nil
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let list = try Self.makeDecoder().decode([ProviderInstance].self, from: data)
            cache = list
            lastLoadError = nil
            return list
        } catch {
            // A file that will not decode is moved aside rather than
            // overwritten, so the labels the user typed can be recovered by
            // hand instead of vanishing on the next write.
            let aside = url.deletingPathExtension()
                .appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            cache = []
            lastLoadError = "Could not read the provider list. The file was kept as \(aside.lastPathComponent)."
            return []
        }
    }

    private func save(_ list: [ProviderInstance]) throws {
        let url = location.fileURL
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(list)
        // Atomic: a crash mid-write leaves the previous file, never half of
        // this one.
        try data.write(to: url, options: [.atomic])
        cache = list
    }

    // MARK: - Ordering

    private func sorted(_ list: [ProviderInstance], platformNames: [String: String]) -> [ProviderInstance] {
        list.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            let lhsGroup = (lhs.group ?? "").trimmingCharacters(in: .whitespaces)
            let rhsGroup = (rhs.group ?? "").trimmingCharacters(in: .whitespaces)
            if lhsGroup != rhsGroup {
                // Ungrouped rows sit above the groups.
                if lhsGroup.isEmpty { return true }
                if rhsGroup.isEmpty { return false }
                return lhsGroup.localizedStandardCompare(rhsGroup) == .orderedAscending
            }
            let lhsName = lhs.displayName(platformName: platformNames[lhs.providerID] ?? lhs.providerID)
            let rhsName = rhs.displayName(platformName: platformNames[rhs.providerID] ?? rhs.providerID)
            if lhsName != rhsName {
                return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
            }
            return lhs.createdAt < rhs.createdAt
        }
    }
}
