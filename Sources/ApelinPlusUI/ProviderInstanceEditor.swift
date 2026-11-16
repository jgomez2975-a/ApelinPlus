import ApelinPlus
import SwiftUI

/// Rename, recolour, regroup, and decide whether this instance's balance is
/// asked for.
///
/// The balance credential is a separate field on purpose. A New-API relay
/// will not answer `/api/user/self` with the `sk-` model key, so the token
/// a user copies from the site's console is a second secret, and it is
/// stored in the keychain rather than in the instance file. The editor says
/// so out loud instead of letting a 401 look like a bug.
public struct ProviderInstanceEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProviderInstance
    @State private var credential: BalanceCredential
    @State private var thresholdText: String
    @State private var quotaText: String

    private let platformName: String
    private let isNew: Bool
    private let knownGroups: [String]
    private let onSave: (ProviderInstance, BalanceCredential) -> Void

    public init(
        instance: ProviderInstance,
        platformName: String,
        isNew: Bool = false,
        credential: BalanceCredential = BalanceCredential(),
        knownGroups: [String] = [],
        onSave: @escaping (ProviderInstance, BalanceCredential) -> Void,
    ) {
        _draft = State(initialValue: instance)
        _credential = State(initialValue: credential)
        _thresholdText = State(initialValue: instance.balance.warningThreshold.map(Self.format) ?? "")
        _quotaText = State(initialValue: instance.balance.quotaPerUnit.map(Self.format) ?? "")
        self.platformName = platformName
        self.isNew = isNew
        self.knownGroups = knownGroups
        self.onSave = onSave
    }

    public var body: some View {
        Form {
            nameSection
            appearanceSection
            balanceSection
            credentialSection
            advancedSection
        }
        .navigationTitle(isNew ? "New provider" : "Edit provider")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    commit()
                }
                .disabled(!isValid)
            }
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        Section {
            TextField(platformName, text: labelBinding)
                .nameTextEntry()
            HStack(spacing: ProviderMetrics.rowSpacing) {
                ProviderPlate(
                    letter: draft.initial(platformName: platformName),
                    tint: draft.tintCase,
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.displayName(platformName: platformName))
                        .font(.body.weight(.medium))
                    Text(platformName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Name")
        } footer: {
            Text("Two relays of the same kind can coexist once they have different names. Leaving this empty shows “\(platformName)”.")
        }
    }

    private var appearanceSection: some View {
        Section {
            HStack(spacing: 14) {
                ForEach(ProviderTint.allCases, id: \.self) { tint in
                    Button {
                        draft.tint = tint.rawValue
                    } label: {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 30, height: 30)
                            .overlay {
                                if draft.tint == tint.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tint.localizedName)
                    .accessibilityAddTraits(draft.tint == tint.rawValue ? [.isSelected] : [])
                }
                Spacer()
            }
            .padding(.vertical, 2)

            TextField("Group", text: groupBinding)
            if !knownGroups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(knownGroups, id: \.self) { group in
                            Button {
                                draft.group = group
                            } label: {
                                Text(group)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Toggle("Pin to top", isOn: $draft.pinned)
        } header: {
            Text("Appearance")
        } footer: {
            Text("The colour is what tells three relays apart at a glance in the list.")
        }
    }

    private var balanceSection: some View {
        Section {
            Toggle("Query balance", isOn: $draft.balance.enabled)

            if draft.balance.enabled {
                Picker("Source", selection: $draft.balance.source) {
                    ForEach(BalanceSettings.Source.allCases, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }

                Picker("Refresh", selection: intervalBinding) {
                    Text("Only when I ask").tag(TimeInterval(0))
                    Text("Every 5 minutes").tag(TimeInterval(300))
                    Text("Every 15 minutes").tag(TimeInterval(900))
                    Text("Every 30 minutes").tag(TimeInterval(1800))
                    Text("Every hour").tag(TimeInterval(3600))
                }

                HStack {
                    Text("Warn under")
                    Spacer()
                    TextField("Off", text: $thresholdText)
                        .multilineTextAlignment(.trailing)
                        .numberTextEntry()
                        .frame(maxWidth: 100)
                }
            }
        } header: {
            Text("Balance")
        } footer: {
            Text(balanceFooter)
        }
    }

    private var credentialSection: some View {
        Group {
            if showsCredentialFields {
                Section {
                    SecureField("Access token", text: accessTokenBinding)
                        .plainTextEntry()
                    TextField("User id", text: userIDBinding)
                        .plainTextEntry()
                } header: {
                    Text("Balance credential")
                } footer: {
                    Text("A New-API or One-API relay will not read balance with the `sk-` model key. Open the site in a browser, sign in, copy the access token from local storage and the numeric user id from the console. Both stay in the keychain.")
                }
            }
        }
    }

    private var advancedSection: some View {
        Section {
            HStack {
                Text("Quota per unit")
                Spacer()
                TextField("500000", text: $quotaText)
                    .multilineTextAlignment(.trailing)
                    .numberTextEntry()
                    .frame(maxWidth: 120)
            }
            HStack {
                Text("Currency")
                Spacer()
                TextField("Automatic", text: currencyBinding)
                    .multilineTextAlignment(.trailing)
                    .plainTextEntry()
                    .frame(maxWidth: 100)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Only touch these when a relay reports an obviously wrong number: a fork that changed how many quota units make one dollar will show `¥0.00` until this matches.")
        }
    }

    // MARK: Bindings

    private var labelBinding: Binding<String> {
        Binding(
            get: { draft.label ?? "" },
            set: { draft.label = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
        )
    }

    private var groupBinding: Binding<String> {
        Binding(
            get: { draft.group ?? "" },
            set: { draft.group = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
        )
    }

    private var currencyBinding: Binding<String> {
        Binding(
            get: { draft.balance.currencyOverride ?? "" },
            set: { draft.balance.currencyOverride = $0.isEmpty ? nil : $0.uppercased() },
        )
    }

    private var intervalBinding: Binding<TimeInterval> {
        Binding(
            get: { draft.balance.refreshInterval },
            set: { draft.balance.refreshInterval = $0 },
        )
    }

    private var accessTokenBinding: Binding<String> {
        Binding(
            get: { credential.accessToken ?? "" },
            set: { credential.accessToken = $0.isEmpty ? nil : $0 },
        )
    }

    private var userIDBinding: Binding<String> {
        Binding(
            get: { credential.userID ?? "" },
            set: { credential.userID = $0.isEmpty ? nil : $0 },
        )
    }

    // MARK: Rules

    private var showsCredentialFields: Bool {
        draft.balance.enabled
            && (draft.balance.source == .automatic || draft.balance.source == .newAPI || draft.balance.source == .oneAPI)
    }

    private var isValid: Bool {
        thresholdText.isEmpty || Decimal(string: thresholdText) != nil
    }

    private var balanceFooter: String {
        switch draft.balance.source {
        case .none:
            "No request is sent for this provider."
        case .automatic, .newAPI, .oneAPI:
            "Probed against every known shape. New-API and One-API need the credential below; without it they are skipped rather than reported as rejected."
        case .openRouter:
            "Reads lifetime credits and usage from `/api/v1/credits`, using the model key."
        case .deepSeek:
            "Reads `/user/balance`, using the model key. Reported in CNY unless a currency is set below."
        case .openAI:
            "Reads the billing endpoints. Most keys are refused by OpenAI these days; the refusal is shown as “Key rejected”, not as a balance of zero."
        }
    }

    // MARK: Commit

    private func commit() {
        draft.balance.warningThreshold = thresholdText.isEmpty
            ? nil
            : Decimal(string: thresholdText)
        draft.balance.quotaPerUnit = quotaText.isEmpty
            ? nil
            : Decimal(string: quotaText)
        if !showsCredentialFields {
            credential = BalanceCredential()
        }
        onSave(draft, credential)
        if isNew { dismiss() }
    }

    private static func format(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.usesGroupingSeparator = false
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }
}
