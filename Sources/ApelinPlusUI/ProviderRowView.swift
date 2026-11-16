import ApelinPlus
import SwiftUI

/// One row of the provider list: a plate, the user's label, and what the
/// account is worth.
///
/// The title is the label, not the platform. That is the whole point of
/// instances: three rows that all say "OpenAI Compatible" tell a user with
/// three relays nothing, while "Yunwu", "Laozhang" and "Self-hosted" do.
/// The platform name moves to the subtitle, and only when the label is not
/// already the platform's own name.
public struct ProviderRowView: View {
    private let instance: ProviderInstance
    private let platformName: String
    private let host: String?
    private let snapshot: BalanceSnapshot?
    private let warningThreshold: Decimal?

    public init(
        instance: ProviderInstance,
        platformName: String,
        host: String?,
        snapshot: BalanceSnapshot?,
        warningThreshold: Decimal?,
    ) {
        self.instance = instance
        self.platformName = platformName
        self.host = host
        self.snapshot = snapshot
        self.warningThreshold = warningThreshold
    }

    public var body: some View {
        HStack(spacing: ProviderMetrics.rowSpacing) {
            ProviderPlate(
                letter: instance.initial(platformName: platformName),
                tint: instance.tintCase,
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if instance.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            BalancePill(snapshot: snapshot, warningThreshold: warningThreshold)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(combinedLabel)
    }

    // MARK: Text

    private var title: String {
        instance.displayName(platformName: platformName)
    }

    /// A label the user typed replaces the platform in the title, so the
    /// platform has to move down or it disappears from the screen.
    private var showsPlatformInSubtitle: Bool {
        let label = (instance.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty && label.caseInsensitiveCompare(platformName) != .orderedSame
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsPlatformInSubtitle {
            parts.append(platformName)
        }
        let fromBalance = BalanceText.subtitle(
            host: host,
            snapshot: snapshot,
            warningThreshold: warningThreshold,
        )
        if !fromBalance.isEmpty {
            parts.append(fromBalance)
        }
        return parts.joined(separator: " · ")
    }

    private var combinedLabel: String {
        var parts = [title]
        if !subtitle.isEmpty { parts.append(subtitle) }
        if let snapshot, let reading = snapshot.reading, let amount = reading.amount {
            parts.append("balance " + BalanceText.amount(amount, currency: reading.currency))
        } else if let failure = snapshot?.failure, failure != .notConfigured {
            parts.append(failure.errorDescription ?? failure.shortDescription)
        }
        return parts.joined(separator: ", ")
    }
}
