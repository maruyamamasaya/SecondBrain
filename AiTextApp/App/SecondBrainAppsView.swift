import SwiftUI

struct SecondBrainAppsView: View {
    @ObservedObject var store: ThoughtStore
    @Environment(\.openURL) private var openURL
    @State private var editorApp: SecondBrainApp?
    @State private var presentsNewApp = false
    @State private var deletionCandidate: SecondBrainApp?
    @State private var pendingExternalLaunch: PendingExternalLaunch?
    @State private var nativeFeature: SecondBrainNativeFeature?
    @State private var launchError: String?

    private var favorites: [SecondBrainApp] { store.secondBrainApps.filter(\.isFavorite) }
    private var others: [SecondBrainApp] { store.secondBrainApps.filter { !$0.isFavorite } }

    var body: some View {
        List {
            if store.secondBrainApps.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Appがありません").font(.headline)
                    Text("右上の追加ボタンからWeb Appや個人用Toolを登録できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                if !favorites.isEmpty { appSection("お気に入り", apps: favorites) }
                appSection(favorites.isEmpty ? "Apps / Tools" : "すべて", apps: others)
            }

            Section {
                Text("外部Appは起動前に接続先を表示します。Local WebのHTTPはlocalhost、.local、private／loopback／link-local addressだけを許可します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .themedScrollableBackground()
        .themedScreen(.expressive)
        .navigationTitle("Apps / Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { presentsNewApp = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Appを追加")
                    .accessibilityIdentifier("addSecondBrainAppButton")
            }
        }
        .sheet(isPresented: $presentsNewApp) {
            NavigationStack { SecondBrainAppEditorView(store: store) }
        }
        .sheet(item: $editorApp) { app in
            NavigationStack { SecondBrainAppEditorView(store: store, app: app) }
        }
        .navigationDestination(isPresented: Binding(
            get: { nativeFeature != nil },
            set: { if !$0 { nativeFeature = nil } }
        )) {
            if let nativeFeature { nativeDestination(nativeFeature) }
        }
        .confirmationDialog(
            "この接続先を開きますか？",
            isPresented: Binding(
                get: { pendingExternalLaunch != nil },
                set: { if !$0 { pendingExternalLaunch = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingExternalLaunch
        ) { pending in
            Button("開く") { open(pending) }
            Button("キャンセル", role: .cancel) {}
        } message: { pending in
            Text("\(pending.app.name)\n\(pending.confirmation)")
        }
        .confirmationDialog(
            "このAppを削除しますか？",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletionCandidate
        ) { app in
            Button("削除", role: .destructive) { _ = store.deleteSecondBrainApp(id: app.id) }
            Button("キャンセル", role: .cancel) {}
        } message: { app in
            Text(app.name)
        }
        .alert("Apps / Toolsを開けません", isPresented: Binding(
            get: { launchError != nil },
            set: { if !$0 { launchError = nil } }
        )) { Button("OK") {} } message: { Text(launchError ?? "") }
    }

    @ViewBuilder
    private func appSection(_ title: String, apps: [SecondBrainApp]) -> some View {
        if !apps.isEmpty {
            Section(title) {
                ForEach(apps) { app in
                    SecondBrainAppRow(
                        app: app,
                        onLaunch: { prepareLaunch(app) },
                        onEdit: { editorApp = app }
                    )
                    .swipeActions(edge: .trailing) {
                        Button("削除", role: .destructive) { deletionCandidate = app }
                        Button("編集") { editorApp = app }.tint(.blue)
                    }
                }
            }
        }
    }

    private func prepareLaunch(_ app: SecondBrainApp) {
        do {
            switch try SecondBrainAppLaunchPolicy.prepare(app) {
            case .native(let feature): nativeFeature = feature
            case .externalURL(let url, let confirmation):
                pendingExternalLaunch = PendingExternalLaunch(app: app, url: url, confirmation: confirmation)
            }
        } catch {
            launchError = error.localizedDescription
        }
    }

    private func open(_ pending: PendingExternalLaunch) {
        pendingExternalLaunch = nil
        openURL(pending.url) { accepted in
            if !accepted { launchError = "接続先を開けませんでした。\n\(pending.confirmation)" }
        }
    }

    @ViewBuilder
    private func nativeDestination(_ feature: SecondBrainNativeFeature) -> some View {
        switch feature {
        case .ai: AIPostRequestView(store: store)
        case .knowledge: KnowledgeManagementView(store: store)
        case .insights: ThoughtAnalyticsView(store: store)
        }
    }
}

private struct PendingExternalLaunch: Identifiable {
    let id = UUID()
    let app: SecondBrainApp
    let url: URL
    let confirmation: String
}

private struct SecondBrainAppRow: View {
    let app: SecondBrainApp
    let onLaunch: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: app.icon)
                .font(.title2)
                .frame(width: 34, height: 34)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.headline)
                if !app.description.isEmpty {
                    Text(app.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("\(app.category) · \(app.kind.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: onLaunch) { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(app.name)を開く")
                .accessibilityIdentifier("launchSecondBrainApp_\(app.id.uuidString)")
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(app.name)を編集")
                .accessibilityIdentifier("editSecondBrainApp_\(app.id.uuidString)")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SecondBrainAppEditorView: View {
    private enum ExternalTargetKind: String, CaseIterable, Identifiable {
        case web = "HTTPS"
        case deepLink = "Deep Link"
        var id: Self { self }
    }

    @ObservedObject var store: ThoughtStore
    @Environment(\.dismiss) private var dismiss
    private let existing: SecondBrainApp?
    @State private var name: String
    @State private var description: String
    @State private var icon: String
    @State private var kind: SecondBrainAppKind
    @State private var targetValue: String
    @State private var nativeFeature: SecondBrainNativeFeature
    @State private var externalTargetKind: ExternalTargetKind
    @State private var category: String
    @State private var isFavorite: Bool
    @State private var sortOrder: String
    @State private var validationError: String?

    init(store: ThoughtStore, app: SecondBrainApp? = nil) {
        self.store = store
        existing = app
        _name = State(initialValue: app?.name ?? "")
        _description = State(initialValue: app?.description ?? "")
        _icon = State(initialValue: app?.icon ?? "square.grid.2x2")
        _kind = State(initialValue: app?.kind ?? .web)
        _category = State(initialValue: app?.category ?? "その他")
        _isFavorite = State(initialValue: app?.isFavorite ?? false)
        _sortOrder = State(initialValue: String(app?.sortOrder ?? 0))
        switch app?.launchTarget {
        case .nativeFeature(let feature):
            _nativeFeature = State(initialValue: feature); _targetValue = State(initialValue: "")
            _externalTargetKind = State(initialValue: .web)
        case .webURL(let value):
            _nativeFeature = State(initialValue: .ai); _targetValue = State(initialValue: value)
            _externalTargetKind = State(initialValue: .web)
        case .localURL(let value):
            _nativeFeature = State(initialValue: .ai); _targetValue = State(initialValue: value)
            _externalTargetKind = State(initialValue: .web)
        case .deepLink(let value):
            _nativeFeature = State(initialValue: .ai); _targetValue = State(initialValue: value)
            _externalTargetKind = State(initialValue: .deepLink)
        case nil:
            _nativeFeature = State(initialValue: .ai); _targetValue = State(initialValue: "")
            _externalTargetKind = State(initialValue: .web)
        }
    }

    var body: some View {
        Form {
            Section("基本情報") {
                TextField("App名", text: $name).accessibilityIdentifier("secondBrainAppNameField")
                TextField("説明", text: $description, axis: .vertical)
                TextField("SF Symbol名", text: $icon).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("カテゴリ", text: $category)
                Toggle("お気に入り", isOn: $isFavorite)
                TextField("表示順", text: $sortOrder).keyboardType(.numberPad)
            }

            Section("起動先") {
                Picker("種別", selection: $kind) {
                    ForEach(SecondBrainAppKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: kind) { newKind in resetTarget(for: newKind) }

                if kind == .native {
                    Picker("機能", selection: $nativeFeature) {
                        ForEach(SecondBrainNativeFeature.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } else {
                    if kind == .external {
                        Picker("形式", selection: $externalTargetKind) {
                            ForEach(ExternalTargetKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    TextField(targetPlaceholder, text: $targetValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("secondBrainAppTargetField")
                    Text(targetHelp).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let message = validationError ?? store.secondBrainAppError {
                Section { Text(message).foregroundStyle(.red).font(.footnote) }
            }
        }
        .themedScrollableBackground()
        .themedScreen(.expressive)
        .navigationTitle(existing == nil ? "Appを追加" : "Appを編集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).accessibilityIdentifier("saveSecondBrainAppButton")
            }
        }
    }

    private var targetPlaceholder: String {
        switch kind {
        case .web: "https://example.com"
        case .localWeb: "http://192.168.1.10:8080"
        case .external: externalTargetKind == .web ? "https://example.com" : "example://path"
        case .native: ""
        }
    }

    private var targetHelp: String {
        switch kind {
        case .web: "HTTPSだけを許可します。"
        case .localWeb: "ローカルネットワークのHTTP／HTTPSだけを許可します。"
        case .external: "HTTPSまたは安全なDeep Linkを指定します。"
        case .native: "SecondBrain内の機能を開きます。"
        }
    }

    private func resetTarget(for kind: SecondBrainAppKind) {
        switch kind {
        case .native: targetValue = ""
        case .web: targetValue = ""
        case .localWeb: targetValue = "http://localhost:3000"
        case .external: targetValue = ""
        }
    }

    private func save() {
        guard let order = Int(sortOrder) else { validationError = "表示順は0以上の整数で入力してください。"; return }
        do {
            let launchTarget: SecondBrainAppLaunchTarget
            switch kind {
            case .native: launchTarget = .nativeFeature(nativeFeature)
            case .web: launchTarget = .webURL(targetValue)
            case .localWeb: launchTarget = .localURL(targetValue)
            case .external:
                launchTarget = externalTargetKind == .web ? .webURL(targetValue) : .deepLink(targetValue)
            }
            let app = try SecondBrainApp(
                id: existing?.id ?? UUID(),
                name: name,
                description: description,
                icon: icon,
                kind: kind,
                launchTarget: launchTarget,
                category: category,
                isFavorite: isFavorite,
                sortOrder: order,
                createdAt: existing?.createdAt ?? Date(),
                updatedAt: existing == nil ? nil : Date()
            )
            if store.saveSecondBrainApp(app, isNew: existing == nil) { dismiss() }
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private extension SecondBrainAppKind {
    var displayName: String {
        switch self {
        case .native: "Native"
        case .web: "Web"
        case .localWeb: "Local Web"
        case .external: "External"
        }
    }
}

private extension SecondBrainNativeFeature {
    var displayName: String {
        switch self {
        case .ai: "AI機能"
        case .knowledge: "Knowledge"
        case .insights: "振り返り"
        }
    }
}
