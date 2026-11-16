import ApelinPlus
import Foundation
import SwiftUI

/// The state behind one balance page.
///
/// A model rather than `@State` in the view for a concurrency reason, not
/// a style one: `.task` and `.refreshable` take `@Sendable` closures, and a
/// closure that touched the view's own storage would be capturing a
/// non-Sendable `View`. Handing both to an `@MainActor` object keeps the
/// crossing legal and the fetch in one place.
@MainActor
public final class BalanceDetailModel: ObservableObject {
    /// Reads the balance again. Supplied by the caller because only the app
    /// knows where the key for this instance lives.
    public typealias Refresh = @Sendable () async -> BalanceSnapshot?

    @Published public private(set) var snapshot: BalanceSnapshot?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var hasLoaded = false

    private let refresh: Refresh

    public init(snapshot: BalanceSnapshot?, refresh: @escaping Refresh) {
        self.snapshot = snapshot
        self.refresh = refresh
    }

    /// Fetches once per appearance. Returning to the page does not send a
    /// second request; the toolbar button is how a user asks again.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard snapshot == nil else { return }
        await reload()
    }

    public func reload() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if let fresh = await refresh() {
            snapshot = fresh
        }
        hasLoaded = true
    }
}

/// One provider's money, explained.
///
/// The number is at the top because that is the question; everything under
/// it exists to let the user decide whether to trust the number — which
/// endpoint answered, when, and what the provider actually said.
public struct BalanceDetailScreen: View {
    @ObservedObject private var model: BalanceDetailModel

    private let instance: ProviderInstance
    private let platformName: String
    private let host: String?

    public init(
        instance: ProviderInstance,
        platformName: String,
        host: String?,
        model: BalanceDetailModel,
    ) {
        self.instance = instance
        self.platformName = platformName
        self.host = host
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        List {
            summarySection
            breakdownSection
            sourceSection
        }
        .groupedListStyle()
        .navigationTitle(instance.displayName(platformName: platformName))
        .refreshable { await model.reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.reload() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
            }
        }
        .task { await model.loadIfNeeded() }
    }

    // MARK: Sections

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    BalanceDot(tier: tier)
                    Text(statusLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(headline)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tier == .failed || tier == .unknown ? Color.primary : tier.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var breakdownSection: some View {
        let rows = detailRows
        if !rows.isEmpty {
            Section("Breakdown") {
                ForEach(rows) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Text(row.value)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var sourceSection: some View {
        Section {
            if let host, !host.isEmpty {
                HStack {
                    Text("Host")
                    Spacer()
                    Text(host)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
            }
            HStack {
                Text("Endpoint")
                Spacer()
                Text(endpointPath)
                    .foregroundStyle(.secondary)
                    .font(.callout.monospaced())
            }
            if needsRelayToken {
                Text("This relay answers only with the site's own session token and user id. Set them in the provider's editor — the model key will always come back rejected here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Where this came from")
        }
    }

    // MARK: Derived

    private var tier: BalanceSnapshot.Tier {
        model.snapshot?.tier(warningThreshold: instance.balance.warningThreshold) ?? .unknown
    }

    private var headline: String {
        guard let snapshot = model.snapshot else { return "—" }
        if let reading = snapshot.reading, let amount = reading.amount {
            return BalanceText.amount(amount, currency: reading.currency)
        }
        if let reading = snapshot.reading, let used = reading.usedThisMonth {
            return BalanceText.amount(used, currency: reading.currency)
        }
        if let failure = snapshot.failure {
            return failure == .notConfigured ? "—" : failure.shortDescription
        }
        return "—"
    }

    private var statusLine: String {
        guard let snapshot = model.snapshot else { return "No reading yet" }
        if let failure = snapshot.failure {
            return failure == .notConfigured
                ? "Balance is not queried for this provider"
                : (failure.errorDescription ?? failure.shortDescription)
        }
        switch tier {
        case .healthy: return "Enough credit"
        case .low: return "Below the warning line"
        case .exhausted: return "No credit left"
        case .failed: return "The provider refused the query"
        case .unknown: return "No reading yet"
        }
    }

    /// A second line only when there is something the headline does not
    /// already say.
    private var caption: String? {
        guard let snapshot = model.snapshot, let reading = snapshot.reading else { return nil }
        var parts: [String] = []
        if let plan = reading.planName, !plan.isEmpty { parts.append(plan) }
        if reading.amount == nil, let used = reading.usedThisMonth, let currency = reading.currency {
            parts.append("used " + BalanceText.amount(used, currency: currency))
        }
        if let available = reading.isAvailable, available == false {
            parts.append("the provider says this account is unavailable")
        }
        parts.append(BalanceText.age(snapshot.fetchedAt))
        return parts.joined(separator: " · ")
    }

    private var detailRows: [BalanceText.Row] {
        guard let snapshot = model.snapshot else { return [] }
        return BalanceText.detailRows(snapshot, warningThreshold: instance.balance.warningThreshold)
    }

    private var endpointPath: String {
        switch model.snapshot?.reading?.source ?? instance.balance.source {
        case .newAPI, .oneAPI: "/api/user/self"
        case .openRouter: "/api/v1/credits"
        case .deepSeek: "/user/balance"
        case .openAI: "/v1/dashboard/billing/*"
        case .automatic: "probed"
        case .none: "not queried"
        }
    }

    private var needsRelayToken: Bool {
        let source = model.snapshot?.reading?.source ?? instance.balance.source
        return source == .newAPI || source == .oneAPI || source == .automatic
    }
}
