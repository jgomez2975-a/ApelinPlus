import Foundation

// MARK: - Text

/// How a balance reads, kept free of UIKit so the same strings serve the
/// list row, the detail page and the accessibility label.
public enum BalanceText {
    /// Currency symbols the app draws itself, because `.currency(code:)`
    /// renders `CN¥` under an en_US locale and that is wider than the pill.
    private static let symbols: [String: String] = [
        "USD": "$", "CNY": "¥", "RMB": "¥", "EUR": "€", "GBP": "£", "JPY": "¥", "HKD": "HK$",
    ]

    /// `¥42.80`, `$3.12`, `€1,240`. Amounts of a thousand and up lose the
    /// decimals, which is what fits a 44-point row.
    public static func amount(_ value: Decimal, currency: String?) -> String {
        let code = (currency ?? "USD").uppercased()
        let symbol = symbols[code] ?? "\(code) "
        let magnitude = value.magnitude
        let body = magnitude >= 1000
            ? group(value, fractionDigits: 0)
            : group(value, fractionDigits: 2)
        return symbol + body
    }

    /// The pill on a provider row: the balance, or why there is none.
    public static func pill(_ snapshot: BalanceSnapshot, warningThreshold: Decimal?) -> String {
        if let failure = snapshot.failure {
            return failure == .notConfigured ? "—" : failure.shortDescription
        }
        guard let reading = snapshot.reading else { return "—" }
        switch snapshot.tier(warningThreshold: warningThreshold) {
        case .exhausted:
            // `Self.` is required: a local `amount` shadows the static
            // `amount(_:currency:)` and the call would resolve to the Decimal.
            if let amount = reading.amount, amount <= 0 {
                return Self.amount(amount, currency: reading.currency)
            }
            return "Unavailable"
        case .healthy, .low:
            if let amount = reading.amount {
                return Self.amount(amount, currency: reading.currency)
            }
            // A provider that reports usage and no balance: show the month.
            if let used = reading.usedThisMonth { return amount(used, currency: reading.currency) + " used" }
            return "—"
        case .failed, .unknown:
            return "—"
        }
    }

    /// The line under the provider's name: the endpoint host, then what the
    /// balance query added.
    public static func subtitle(
        host: String?,
        snapshot: BalanceSnapshot?,
        warningThreshold: Decimal?,
    ) -> String {
        var parts: [String] = []
        if let host, !host.isEmpty { parts.append(host) }
        guard let snapshot else { return parts.joined(separator: " · ") }
        if let reading = snapshot.reading {
            if let plan = reading.planName, !plan.isEmpty {
                parts.append(plan)
            }
            if let used = reading.usedToday, let currency = reading.currency {
                parts.append("today \(amount(used, currency: currency))")
            }
            if let available = reading.isAvailable, available == false {
                parts.append("unavailable")
            }
        } else if let failure = snapshot.failure, failure != .notConfigured {
            parts.append(failure.shortDescription.lowercased())
        }
        return parts.joined(separator: " · ")
    }

    /// How long ago the answer came back, in the words the detail page uses.
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) hr ago"
        default: return "\(Int(seconds / 86_400)) days ago"
        }
    }

    /// A row of the detail page: a name and its value.
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Everything the detail page lists, in the order it lists it. Empty
    /// when there is no reading to explain.
    public static func detailRows(_ snapshot: BalanceSnapshot, warningThreshold: Decimal?) -> [Row] {
        guard let reading = snapshot.reading else { return [] }
        var rows: [Row] = []
        if let amount = reading.amount, let currency = reading.currency {
            rows.append(Row("Balance", BalanceText.amount(amount, currency: currency)))
        }
        if let used = reading.usedToday, let currency = reading.currency {
            rows.append(Row("Today", BalanceText.amount(used, currency: currency)))
        }
        if let used = reading.usedThisMonth, let currency = reading.currency {
            rows.append(Row("This month", BalanceText.amount(used, currency: currency)))
        }
        if let granted = reading.granted, let currency = reading.currency {
            rows.append(Row("Granted", BalanceText.amount(granted, currency: currency)))
        }
        if let toppedUp = reading.toppedUp, let currency = reading.currency {
            rows.append(Row("Topped up", BalanceText.amount(toppedUp, currency: currency)))
        }
        if let plan = reading.planName, !plan.isEmpty {
            rows.append(Row("Plan", plan))
        }
        if let available = reading.isAvailable {
            rows.append(Row("Available", available ? "Yes" : "No"))
        }
        if let threshold = warningThreshold, let currency = reading.currency {
            rows.append(Row("Warning line", BalanceText.amount(threshold, currency: currency)))
        }
        rows.append(Row("Source", reading.source.title))
        if let note = reading.note, !note.isEmpty {
            rows.append(Row("Note", note))
        }
        rows.append(Row("Updated", age(snapshot.fetchedAt)))
        return rows
    }

    // MARK: Grouping

    private static func group(_ value: Decimal, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.usesGroupingSeparator = true
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
}
