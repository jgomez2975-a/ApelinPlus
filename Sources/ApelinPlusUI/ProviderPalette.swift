import ApelinPlus
import SwiftUI

// MARK: - Tints

/// The five plate colours, as actual colours.
///
/// Fixed values rather than semantic ones: `ProviderTint` exists so a user
/// can tell three OpenAI-compatible relays apart at a glance, and a
/// semantic colour would make all five go grey together under a contrast
/// setting — which is exactly the case where the distinction matters.
/// Each is dark enough for white text on it and dark enough for itself as
/// text on a light background.
public extension ProviderTint {
    var color: Color {
        switch self {
        case .blue: Color(red: 0.11, green: 0.42, blue: 0.91)
        case .orange: Color(red: 0.92, green: 0.47, blue: 0.11)
        case .green: Color(red: 0.11, green: 0.62, blue: 0.38)
        case .purple: Color(red: 0.53, green: 0.34, blue: 0.85)
        case .graphite: Color(red: 0.35, green: 0.38, blue: 0.44)
        }
    }

    /// The plate a row's mark sits on. Slightly lighter than `color` so a
    /// row of five does not read as five buttons.
    var plateColor: Color {
        color.opacity(0.14)
    }

    /// What the colour picker calls this. `letter` is for drawing on the
    /// plate, which is a different job.
    var localizedName: String {
        switch self {
        case .blue: "Blue"
        case .orange: "Orange"
        case .green: "Green"
        case .purple: "Purple"
        case .graphite: "Graphite"
        }
    }
}

// MARK: - Tiers

public extension BalanceSnapshot.Tier {
    /// What the pill and the dot are drawn in.
    ///
    /// Green means there is money, amber means it is under the warning
    /// line, red means it is gone or the account cannot be used. A refusal
    /// is grey, not red: the provider said nothing about the balance, and
    /// red would claim it did.
    var color: Color {
        switch self {
        case .healthy: Color(red: 0.11, green: 0.62, blue: 0.38)
        case .low: Color(red: 0.92, green: 0.47, blue: 0.11)
        case .exhausted: Color(red: 0.86, green: 0.21, blue: 0.20)
        case .failed: Color.secondary
        case .unknown: Color.secondary
        }
    }
}

// MARK: - Metrics

/// Sizes shared by the list, the editor and the detail page.
///
/// Named rather than inlined because the plate, the pill and the row's
/// height have to agree: a pill two points taller than its plate makes a
/// list of ten rows look drunk.
public enum ProviderMetrics {
    public static let plateSize: CGFloat = 38
    public static let plateCorner: CGFloat = 10
    public static let rowSpacing: CGFloat = 12
    public static let sectionSpacing: CGFloat = 24
    public static let pillHorizontalPadding: CGFloat = 8
    public static let pillVerticalPadding: CGFloat = 3
}

// MARK: - Plate

/// The coloured square with an initial on it, drawn when a provider has no
/// symbol of its own.
public struct ProviderPlate: View {
    private let letter: String
    private let tint: ProviderTint

    public init(letter: String, tint: ProviderTint) {
        self.letter = letter
        self.tint = tint
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: ProviderMetrics.plateCorner, style: .continuous)
            .fill(tint.plateColor)
            .frame(width: ProviderMetrics.plateSize, height: ProviderMetrics.plateSize)
            .overlay {
                Text(letter)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint.color)
            }
            .accessibilityHidden(true)
    }
}

/// The small filled circle a balance row leads with, for the detail page
/// where there is no plate.
public struct BalanceDot: View {
    private let tier: BalanceSnapshot.Tier

    public init(tier: BalanceSnapshot.Tier) {
        self.tier = tier
    }

    public var body: some View {
        Circle()
            .fill(tier.color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}
