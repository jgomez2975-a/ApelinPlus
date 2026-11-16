import ApelinPlus
import SwiftUI

/// The small capsule on a provider row: what the account is worth, or why
/// there is no number.
///
/// Nothing at all is drawn when the balance was never asked for. A dash
/// would say "asked and got nothing", which is a different and more
/// alarming fact than "this provider does not report balance".
public struct BalancePill: View {
    private let snapshot: BalanceSnapshot?
    private let warningThreshold: Decimal?

    public init(snapshot: BalanceSnapshot?, warningThreshold: Decimal?) {
        self.snapshot = snapshot
        self.warningThreshold = warningThreshold
    }

    public var body: some View {
        if let text = pillText {
            let tier = snapshot?.tier(warningThreshold: warningThreshold) ?? .unknown
            Text(text)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(tier.color)
                .lineLimit(1)
                .padding(.horizontal, ProviderMetrics.pillHorizontalPadding)
                .padding(.vertical, ProviderMetrics.pillVerticalPadding)
                .background(tier.color.opacity(0.12), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(tier.color.opacity(0.18), lineWidth: 0.5)
                }
                .accessibilityLabel(accessibilityText(tier: tier))
        }
    }

    /// `nil` means draw nothing, which is the case for a provider that has
    /// balance turned off and for one that has not been asked yet.
    private var pillText: String? {
        guard let snapshot else { return nil }
        if snapshot.reading == nil, snapshot.failure == nil || snapshot.failure == .notConfigured {
            return nil
        }
        return BalanceText.pill(snapshot, warningThreshold: warningThreshold)
    }

    private func accessibilityText(tier: BalanceSnapshot.Tier) -> String {
        guard let snapshot else { return "" }
        if let failure = snapshot.failure {
            return "Balance unavailable. \(failure.errorDescription ?? failure.shortDescription)"
        }
        guard let reading = snapshot.reading else { return "Balance unknown" }
        let amount = reading.amount.map { BalanceText.amount($0, currency: reading.currency) } ?? "no amount"
        return switch tier {
        case .exhausted: "Balance \(amount). Out of credit."
        case .low: "Balance \(amount). Below the warning line."
        default: "Balance \(amount)."
        }
    }
}
