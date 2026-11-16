import ApelinPlus
import SwiftUI

/// The provider list, rebuilt around instances.
///
/// What changed from the old screen, and why:
///
/// - A row is keyed by instance id, not by provider, so three
///   OpenAI-compatible relays are three rows instead of one fight.
/// - The title is the user's label. The platform moves to the subtitle,
///   and only when the label is not the platform's own name.
/// - Every row carries its balance, so a dead relay is visible without
///   opening it.
public struct ProviderListScreen: View {
    @ObservedObject private var model: ProviderListModel

    private let onSelect: (ProviderInstance) -> Void
    private let onAdd: () -> Void
    private let onEdit: (ProviderInstance) -> Void

    @State private var pendingDelete: ProviderInstance?

    public init(
        model: ProviderListModel,
        onSelect: @escaping (ProviderInstance) -> Void,
        onAdd: @escaping () -> Void,
        onEdit: @escaping (ProviderInstance) -> Void,
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.onSelect = onSelect
        self.onAdd = onAdd
        self.onEdit = onEdit
    }

    public var body: some View {
        list
            .searchable(text: $model.searchText, prompt: Text("Name, platform or host"))
            .refreshable { await model.refreshAllBalances() }
            .overlay { emptyState }
            .toolbar { toolbarContent }
            .task { await model.load() }
            .confirmationDialog(
                "Delete this provider?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } },
                ),
                presenting: pendingDelete,
            ) { instance in
                Button("Delete \(instance.displayName(platformName: model.platformName(instance)))", role: .destructive) {
                    Task { await model.delete(instance) }
                    pendingDelete = nil
                }
                Button("Keep", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("Its key and its balance token are removed from the keychain too.")
            }
            .alert(
                "The provider list could not be read",
                isPresented: Binding(
                    get: { model.loadError != nil },
                    set: { if !$0 { model.dismissLoadError() } },
                ),
            ) {
                Button("OK", role: .cancel) { model.dismissLoadError() }
            } message: {
                Text(model.loadError ?? "")
            }
    }

    // MARK: List

    private var list: some View {
        List {
            ForEach(model.sections) { section in
                SwiftUI.Section {
                    ForEach(section.instances) { instance in
                        row(instance)
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                    }
                }
            }
        }
        .groupedListStyle()
    }

    private func row(_ instance: ProviderInstance) -> some View {
        Button {
            onSelect(instance)
        } label: {
            ProviderRowView(
                instance: instance,
                platformName: model.platformName(instance),
                host: model.host(instance),
                snapshot: model.balance(instance),
                warningThreshold: instance.balance.warningThreshold,
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = instance
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                onEdit(instance)
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await model.duplicate(instance) }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .tint(.indigo)
        }
        .contextMenu {
            Button {
                onEdit(instance)
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
            }
            Button {
                Task { await model.duplicate(instance) }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            if instance.balance.enabled, instance.balance.source != .none {
                Button {
                    Task { _ = await model.refreshBalance(of: instance) }
                } label: {
                    Label("Refresh balance", systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) {
                pendingDelete = instance
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: Chrome

    private var emptyState: some View {
        Group {
            if model.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No providers yet")
                        .font(.headline)
                    Text("Add one and give it a name. Two relays of the same kind can now sit side by side.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Button("Add a provider", action: onAdd)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
                .padding(32)
            } else if model.filtered.isEmpty, !model.searchText.isEmpty {
                ContentUnavailableFallback(
                    title: "Nothing matches",
                    message: "No provider's name, platform or host contains “\(model.searchText)”.",
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: onAdd) {
                Label("Add provider", systemImage: "plus")
            }
        }
        // `.topBarLeading` is iOS 17 and this package starts at 16;
        // `.automatic` puts a spinner wherever the platform wants it.
        ToolbarItem(placement: .automatic) {
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// `ContentUnavailableView` is iOS 17; the package supports 16.
struct ContentUnavailableFallback: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(24)
    }
}
