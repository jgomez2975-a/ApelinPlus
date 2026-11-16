import Foundation

// MARK: - Tint

/// The colour plate an instance's mark sits on. A fixed palette, not a free
/// colour picker: sixteen shades in a settings list look like noise, five
/// can be told apart at a glance.
public enum ProviderTint: Int, Codable, Sendable, CaseIterable, Hashable {
    case blue = 0
    case orange = 1
    case green = 2
    case purple = 3
    case graphite = 4

    /// Two letters at most, drawn on the plate when the platform has no mark
    /// of its own. Taken from the label first, the platform name second.
    public var letter: String {
        switch self {
        case .blue: "B"
        case .orange: "O"
        case .green: "G"
        case .purple: "P"
        case .graphite: "X"
        }
    }
}

// MARK: - Balance settings

/// How, and whether, one instance's balance is asked for.
///
/// `source` is `.automatic` by default: `BalanceService` probes the four
/// known shapes in order and keeps the first that answers. A relay that
/// renames its endpoints, or sits behind a gateway that returns 200 for
/// everything, can be pinned to one shape instead.
public struct BalanceSettings: Codable, Sendable, Equatable, Hashable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// Probe every adapter, keep the first that answers.
        case automatic
        /// New-API and its forks (`/api/user/self`), quota in 1/500000 USD.
        case newAPI
        /// One-API and its forks (`/api/user/self`), quota in 1/500000 USD.
        case oneAPI
        /// OpenRouter (`/api/v1/credits`).
        case openRouter
        /// DeepSeek (`/user/balance`), reported in CNY.
        case deepSeek
        /// OpenAI's own billing endpoints. Most keys are refused these days;
        /// the failure is reported, not hidden.
        case openAI
        /// Not asked for. The row shows no balance at all.
        case none

        /// What the picker calls this shape.
        public var title: String {
            switch self {
            case .automatic: "Automatic"
            case .newAPI: "New-API"
            case .oneAPI: "One-API"
            case .openRouter: "OpenRouter"
            case .deepSeek: "DeepSeek"
            case .openAI: "OpenAI Billing"
            case .none: "Off"
            }
        }
    }

    public var enabled: Bool
    public var source: Source
    /// Seconds between refreshes. `0` refreshes only when the user asks.
    public var refreshInterval: TimeInterval
    /// The amount under which the row turns amber. `nil` never warns.
    public var warningThreshold: Decimal?
    /// New-API forks disagree about how many quota units make one dollar;
    /// 500000 is the upstream default. `nil` uses the adapter's default.
    public var quotaPerUnit: Decimal?
    /// Overrides the currency the adapter reports. `nil` trusts the adapter.
    public var currencyOverride: String?

    public init(
        enabled: Bool = true,
        source: Source = .automatic,
        refreshInterval: TimeInterval = 30 * 60,
        warningThreshold: Decimal? = nil,
        quotaPerUnit: Decimal? = nil,
        currencyOverride: String? = nil,
    ) {
        self.enabled = enabled
        self.source = source
        self.refreshInterval = refreshInterval
        self.warningThreshold = warningThreshold
        self.quotaPerUnit = quotaPerUnit
        self.currencyOverride = currencyOverride
    }

    /// What a fresh instance starts with: asked for, probed, every half hour.
    public static let `default` = BalanceSettings()

    /// Nothing is asked for, which is what a subscription account gets.
    public static let off = BalanceSettings(enabled: false, source: .none)
}

// MARK: - Instance

/// One way Apelin reaches a model provider — the unit the provider list
/// shows a row for.
///
/// Apelin keyed credentials by `AgentProvider`, so one platform had one
/// account. A user with three OpenAI-compatible relays therefore had three
/// accounts fighting over one row, and no way to tell them apart. An
/// instance is the identity that lets them coexist: it carries the user's
/// own label, its own plate colour and its own balance settings, and its
/// `id` is what the credential store appends to the provider's store id.
///
/// `providerID` is `AgentProvider.rawValue`, kept as a `String` so this type
/// — and everything built on it — has no dependency on `ApelinProtocol`.
public struct ProviderInstance: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    /// `AgentProvider.rawValue`, e.g. `openAICompatible`.
    public var providerID: String
    /// The user's own name for this instance. `nil` shows the platform name.
    public var label: String?
    /// Index into `ProviderTint.allCases`.
    public var tint: Int
    /// A free-form folder name. `nil` lists the instance on its own.
    public var group: String?
    /// Kept above the ungrouped rows.
    public var pinned: Bool
    public var createdAt: Date
    public var balance: BalanceSettings

    public init(
        id: UUID = UUID(),
        providerID: String,
        label: String? = nil,
        tint: Int = ProviderTint.blue.rawValue,
        group: String? = nil,
        pinned: Bool = false,
        createdAt: Date = Date(),
        balance: BalanceSettings = .default,
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.tint = tint
        self.group = group
        self.pinned = pinned
        self.createdAt = createdAt
        self.balance = balance
    }

    /// The name the row shows: the user's label, else the platform's name.
    /// `platformName` is passed in rather than looked up, so this type stays
    /// free of `AgentProvider`.
    public func displayName(platformName: String) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? platformName : trimmed
    }

    /// The first character of the label, for a plate with no mark.
    public func initial(platformName: String) -> String {
        let name = displayName(platformName: platformName)
        guard let first = name.first else { return "?" }
        return String(first).uppercased()
    }

    /// The keychain store id this instance's credentials live under.
    ///
    /// The first instance of a platform keeps the bare provider store id, so
    /// an account signed in before instances existed is found where it was
    /// left and needs no migration. Every later instance appends `@<uuid>`.
    public func storeID(providerStoreID: String, isFirstOfProvider: Bool) -> String {
        isFirstOfProvider ? providerStoreID : "\(providerStoreID)@\(id.uuidString)"
    }

    public var tintCase: ProviderTint {
        ProviderTint(rawValue: tint) ?? .blue
    }
}
