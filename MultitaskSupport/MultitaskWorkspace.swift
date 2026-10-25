import SwiftUI

@available(iOS 16.0, *)
@MainActor
final class MultitaskWorkspaceManager: ObservableObject {
    static let shared = MultitaskWorkspaceManager()
    private let defaults = LCUtils.appGroupUserDefault
    private var library: LCWorkspaceLibrary?
    private weak var libraryController: UIViewController?
    private var feedbackTask: Task<Void, Never>?
    @Published private(set) var isRestoring = false
    @Published private(set) var restoringIdentifier: String?
    @Published private(set) var workspaces: [LCNamedWorkspace] = []
    @Published private(set) var isStorageAvailable = false
    @Published private(set) var feedbackMessage: String?
    @Published private(set) var createdWorkspaceIdentifier: String?

    private init() {
        library = LCWorkspaceLibrary(defaults: LCUtils.appGroupUserDefault, legacyName: "lc.workspace.migratedName".loc)
        isStorageAvailable = library != nil
        workspaces = library?.workspaces ?? []
    }

    func refreshList() {
        if library == nil {
            library = LCWorkspaceLibrary(defaults: defaults, legacyName: "lc.workspace.migratedName".loc)
        }
        isStorageAvailable = library?.reload() == true
        workspaces = isStorageAvailable ? library?.workspaces ?? [] : []
    }

    func saveNew() {
        refreshList()
        guard !isRestoring, isStorageAvailable, let library else { return }
        guard let workspace = MultitaskDockManager.shared.windowHostingView.captureWorkspace() else {
            presentResult("lc.workspace.noWindows".loc)
            return
        }
        requestName(title: "lc.workspace.saveNew".loc, initialName: suggestedName()) { [weak self] name in
            guard let self else { return }
            guard let saved = library.save(workspace, name: name, replacing: nil) else {
                self.presentResult("lc.workspace.saveFailed".loc)
                return
            }
            self.refreshList()
            self.createdWorkspaceIdentifier = saved.identifier
            self.presentSuccess("lc.workspace.saved".localizeWithFormat(saved.name, workspace.windows.count))
        }
    }

    func duplicate(_ identifier: String) {
        guard !isRestoring, let entry = currentWorkspace(identifier), let library else { return }
        requestName(title: "lc.workspace.duplicate".loc, initialName: suggestedName(copying: entry.name)) { [weak self] name in
            guard let self else { return }
            guard let saved = library.save(entry.snapshot, name: name, replacing: nil) else {
                self.presentResult("lc.workspace.saveFailed".loc)
                return
            }
            self.refreshList()
            self.createdWorkspaceIdentifier = saved.identifier
            self.presentSuccess("lc.workspace.saved".localizeWithFormat(saved.name, saved.snapshot.windows.count))
        }
    }

    func setLayoutPreference(_ preference: LCWorkspaceLayoutPreference, enabled: Bool, for identifier: String) {
        guard !isRestoring, currentWorkspace(identifier) != nil, let library else { return }
        // Patch the latest saved record. Never recapture open windows or change live defaults here.
        guard library.setLayoutPreference(preference, enabled: enabled, for: identifier) else {
            refreshList()
            presentResult("lc.workspace.saveFailed".loc)
            return
        }
        refreshList()
        presentSuccess("lc.workspace.layoutSaved".loc)
    }

    @discardableResult
    func setTapSyncGroup(_ group: [String: Any], for identifier: String) -> Bool {
        guard !isRestoring, currentWorkspace(identifier) != nil, let library else { return false }
        guard library.setTapSyncGroup(group, for: identifier) else {
            refreshList()
            presentResult("lc.workspace.saveFailed".loc)
            return false
        }
        refreshList()
        presentSuccess("lc.tapSync.groupSaved".loc)
        return true
    }

    func update(_ identifier: String) {
        guard !isRestoring, let entry = currentWorkspace(identifier), let library else { return }
        guard let snapshot = MultitaskDockManager.shared.windowHostingView.captureWorkspace() else {
            presentResult("lc.workspace.noWindows".loc)
            return
        }
        let alert = UIAlertController(title: "lc.workspace.update".loc,
            message: "lc.workspace.updateConfirmation".localizeWithFormat(entry.name, snapshot.windows.count), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel))
        alert.addAction(UIAlertAction(title: "lc.workspace.update".loc, style: .default) { [weak self] _ in
            guard let self, !self.isRestoring else { return }
            guard library.reload(), let current = library.workspace(identifier: identifier),
                  let saved = library.save(snapshot, name: current.name, replacing: identifier) else {
                self.presentResult("lc.workspace.saveFailed".loc)
                return
            }
            self.refreshList()
            self.presentSuccess("lc.workspace.saved".localizeWithFormat(saved.name, snapshot.windows.count))
        })
        present(alert)
    }

    func rename(_ identifier: String) {
        guard !isRestoring, let entry = currentWorkspace(identifier), let library else { return }
        requestName(title: "lc.common.rename".loc, initialName: entry.name, identifier: identifier) { [weak self] name in
            guard library.rename(identifier, name: name) else {
                self?.presentResult("lc.workspace.saveFailed".loc)
                return
            }
            self?.refreshList()
            self?.presentSuccess("lc.workspace.renamed".localizeWithFormat(name.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    func delete(_ identifier: String, completion: @escaping () -> Void = {}) {
        guard !isRestoring, let entry = currentWorkspace(identifier), let library else { return }
        let alert = UIAlertController(title: "lc.workspace.deleteTitle".loc,
            message: "lc.workspace.deleteConfirmation".localizeWithFormat(entry.name), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel))
        alert.addAction(UIAlertAction(title: "lc.common.delete".loc, style: .destructive) { [weak self] _ in
            guard let self, !self.isRestoring else { return }
            guard library.remove(identifier) else {
                self.refreshList()
                self.presentResult("lc.workspace.deleteFailed".loc)
                return
            }
            self.refreshList()
            completion()
            self.presentSuccess("lc.workspace.deleted".localizeWithFormat(entry.name))
        })
        present(alert)
    }

    func copyRestoreLink(identifier: String) {
        refreshList()
        guard isStorageAvailable, let entry = library?.workspace(identifier: identifier),
              let url = LCWorkspaceRestoreURLForIdentifier(UserDefaults.lcAppUrlScheme(), entry.identifier) else {
            presentResult("lc.workspace.notFound".loc)
            return
        }
        UIPasteboard.general.string = url.absoluteString
        presentSuccess("lc.workspace.linkCopied".loc, detailedMessage: "lc.workspace.restoreLinkCopied".loc)
    }

    func restore(identifier: String? = nil, showSuccess: Bool = false) async {
        guard !isRestoring else { return }
        refreshList()
        guard isStorageAvailable, let library else {
            presentResult("lc.workspace.storageUnavailable".loc)
            return
        }
        guard let entry = library.workspace(identifier: identifier) else {
            presentResult((identifier == nil ? "lc.workspace.unavailable" : "lc.workspace.notFound").loc)
            return
        }
        // Bind the request before suspending. A named link must never fall back to another save.
        let workspace = entry.snapshot
        feedbackTask?.cancel()
        feedbackMessage = nil
        isRestoring = true
        restoringIdentifier = entry.identifier
        LCTapSyncCoordinator.shared.pause()
        defer {
            isRestoring = false
            restoringIdentifier = nil
        }
        guard await waitForHostWindow() else {
            if !Task.isCancelled { presentResult("lc.workspace.notReady".loc) }
            return
        }
        guard (MultitaskMode(rawValue: defaults.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow) == .virtualWindow else {
            presentResult("lc.workspace.unavailable".loc)
            return
        }
        let models = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        let selected = workspace.windows.compactMap { entry in models.first { $0.appInfo.relativeBundlePath == entry.bundleName } }
        do {
            if selected.contains(where: { $0.appInfo.isLocked || $0.appInfo.isHidden }) {
                guard try await LCUtils.authenticateUser() else { return }
            }
        } catch {
            presentResult(error.localizedDescription)
            return
        }

        if let controller = libraryController, controller.presentingViewController != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controller.dismiss(animated: true) { continuation.resume() }
            }
        }
        let host = MultitaskDockManager.shared.windowHostingView
        host.finishGridEditing()
        // Exclude entries that cannot launch, and reserve the remaining saved
        // slots before any game reads its startup screen dimensions.
        let launchEntries = workspace.windows.filter { entry in
            guard let model = models.first(where: { $0.appInfo.relativeBundlePath == entry.bundleName }) else { return false }
            return model.appInfo.defaultClassicMode == 0 && model.uiContainers.contains { $0.folderName == entry.dataUUID }
        }
        if !launchEntries.isEmpty,
           let launchWorkspace = LCWindowWorkspace(windows: launchEntries, proportions: workspace.proportions,
                singleRowInLandscape: workspace.singleRowInLandscape, reservePortraitTop: workspace.reservePortraitTop,
                reservePortraitBottom: workspace.reservePortraitBottom) {
            host.prepareWorkspaceForLaunch(launchWorkspace)
        }
        defer { host.finishWorkspaceLaunch() }
        var restored = 0
        var failures: [String] = []
        for entry in workspace.windows {
            if Task.isCancelled { return }
            guard let model = models.first(where: { $0.appInfo.relativeBundlePath == entry.bundleName }) else {
                failures.append("lc.workspace.missingApp".localizeWithFormat(entry.bundleName))
                continue
            }
            let name = model.appInfo.displayName() ?? entry.bundleName
            guard model.uiContainers.contains(where: { $0.folderName == entry.dataUUID }) else {
                failures.append("lc.workspace.missingContainer".localizeWithFormat(name))
                continue
            }
            guard model.appInfo.defaultClassicMode == 0 else {
                failures.append("lc.workspace.unsupportedApp".localizeWithFormat(name))
                continue
            }
            do {
                // A retained termination screen must be removed before runApp checks existing windows.
                if let old = host.window(forContainer: entry.dataUUID), old.isAppTerminated {
                    old.closeWindow()
                    for _ in 0..<30 {
                        if host.window(forContainer: entry.dataUUID) !== old { break }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if host.window(forContainer: entry.dataUUID) === old {
                        throw "lc.workspace.windowUnavailable".loc
                    }
                }
                try await model.runApp(multitask: true, containerFolderName: entry.dataUUID)
                guard let vc = host.window(forContainer: entry.dataUUID), !vc.isAppTerminated, vc.appSceneVC.isAppRunning else {
                    throw "lc.workspace.windowUnavailable".loc
                }
                if vc.appSceneVC.shouldIgnoreSceneUpdates {
                    PiPManager.shared?.stopPiP()
                    for _ in 0..<60 {
                        if !vc.appSceneVC.shouldIgnoreSceneUpdates { break }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    guard !vc.appSceneVC.shouldIgnoreSceneUpdates else { throw "lc.workspace.windowUnavailable".loc }
                }
                restored += 1
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        if restored > 0 {
            defaults.set(true, forKey: "LCAutoTileMultitaskWindows")
            host.applyWorkspace(workspace)
        }
        if showSuccess || !failures.isEmpty {
            let result = "lc.workspace.restored".localizeWithFormat(restored, workspace.windows.count)
            presentResult(([result] + failures).joined(separator: "\n"))
        }
    }

    private func waitForHostWindow() async -> Bool {
        // Match the Dock's host selection. Its initializer needs a mounted root view;
        // a cold-start URL can arrive before SwiftUI has installed that view.
        for _ in 0..<100 {
            if Task.isCancelled { return false }
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               scene.activationState == .foregroundActive,
               let window = scene.windows.first,
               window.rootViewController?.viewIfLoaded?.subviews.first != nil {
                return true
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    func presentLibrary() {
        guard libraryController == nil else { return }
        refreshList()
        feedbackTask?.cancel()
        feedbackMessage = nil
        let controller = UIHostingController(rootView: MultitaskWorkspaceLibraryView())
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.prefersGrabberVisible = true
        libraryController = controller
        present(controller)
    }

    private func currentWorkspace(_ identifier: String) -> LCNamedWorkspace? {
        refreshList()
        guard isStorageAvailable else {
            presentResult("lc.workspace.storageUnavailable".loc)
            return nil
        }
        guard let entry = library?.workspace(identifier: identifier) else {
            presentResult("lc.workspace.notFound".loc)
            return nil
        }
        return entry
    }

    private func suggestedName(copying original: String? = nil) -> String {
        var number = 1
        while true {
            var name: String
            if var base = original {
                name = "lc.workspace.duplicateName".localizeWithFormat(base, number)
                while name.utf16.count > 80 && !base.isEmpty {
                    base.removeLast()
                    name = "lc.workspace.duplicateName".localizeWithFormat(base, number)
                }
            } else {
                name = "lc.workspace.defaultName".localizeWithFormat(number)
            }
            if library?.canUseName(name, excluding: nil) == true { return name }
            number += 1
        }
    }

    private func requestName(title: String, initialName: String, identifier: String? = nil, commit: @escaping (String) -> Void) {
        guard let library else { return }
        let alert = UIAlertController(title: title, message: "lc.workspace.nameRules".loc, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initialName
            field.placeholder = "lc.workspace.name".loc
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
        }
        let save = UIAlertAction(title: (identifier == nil ? "lc.workspace.save" : "lc.common.rename").loc, style: .default) { [weak self, weak alert] _ in
            guard let self, !self.isRestoring, let name = alert?.textFields?.first?.text,
                  library.canUseName(name, excluding: identifier) else { return }
            commit(name)
        }
        save.isEnabled = library.canUseName(initialName, excluding: identifier)
        if let field = alert.textFields?.first {
            field.addAction(UIAction { [weak field, weak save] _ in
                save?.isEnabled = library.canUseName(field?.text ?? "", excluding: identifier)
            }, for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel))
        alert.addAction(save)
        present(alert)
    }

    private func present(_ controller: UIViewController) {
        // Present from the main window after the Dock's context menu closes.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }?.windows.first { $0.isKeyWindow }
            guard var presenter = window?.rootViewController else { return }
            while let next = presenter.presentedViewController { presenter = next }
            presenter.present(controller, animated: true)
        }
    }

    private func presentResult(_ message: String) {
        let alert = UIAlertController(title: "lc.workspace.title".loc, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default))
        present(alert)
    }

    private func presentSuccess(_ message: String, detailedMessage: String? = nil) {
        guard libraryController?.presentingViewController != nil else {
            presentResult(detailedMessage ?? message)
            return
        }
        feedbackTask?.cancel()
        feedbackMessage = message
        UIAccessibility.post(notification: .announcement, argument: message)
        feedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            self?.feedbackMessage = nil
        }
    }
}

@available(iOS 16.0, *)
struct MultitaskWorkspaceActions: View {
    @ObservedObject private var manager = MultitaskWorkspaceManager.shared

    var body: some View {
        Button { manager.presentLibrary() } label: {
            Label("lc.workspace.manage".loc, systemImage: "folder")
        }
        .disabled(manager.isRestoring)
        .onAppear { manager.refreshList() }
        Button { manager.saveNew() } label: {
            Label("lc.workspace.saveNew".loc, systemImage: "plus.rectangle.on.rectangle")
        }
        .disabled(manager.isRestoring || !manager.isStorageAvailable)
        Menu {
            ForEach(manager.workspaces, id: \.identifier) { entry in
                Button(entry.name) { Task { await manager.restore(identifier: entry.identifier) } }
            }
        } label: {
            Label((manager.isRestoring ? "lc.workspace.restoring" : "lc.workspace.restore").loc, systemImage: "rectangle.3.group")
        }
        .disabled(manager.isRestoring || manager.workspaces.isEmpty)
        Menu {
            ForEach(manager.workspaces, id: \.identifier) { entry in
                Button(entry.name) { manager.copyRestoreLink(identifier: entry.identifier) }
            }
        } label: {
            Label("lc.workspace.copyRestoreLink".loc, systemImage: "link")
        }
        .disabled(manager.isRestoring || manager.workspaces.isEmpty)
    }
}

@available(iOS 16.0, *)
private struct MultitaskWorkspaceLibraryView: View {
    @ObservedObject private var manager = MultitaskWorkspaceManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var path: [String] = []

    private var matchingWorkspaces: [LCNamedWorkspace] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? manager.workspaces : manager.workspaces.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !manager.isStorageAvailable {
                    Section {
                        Label("lc.workspace.storageUnavailable".loc, systemImage: "exclamationmark.triangle")
                        Button("lc.workspace.retry".loc) { manager.refreshList() }
                    }
                } else if manager.workspaces.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.3.group").font(.largeTitle).foregroundStyle(.secondary)
                        Text("lc.workspace.empty".loc).foregroundStyle(.secondary)
                        Button { manager.saveNew() } label: {
                            Label("lc.workspace.saveNew".loc, systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                } else if matchingWorkspaces.isEmpty {
                    Section {
                        Label("lc.workspace.noSearchResults".loc, systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        Button("lc.workspace.clearSearch".loc) { searchText = "" }
                    }
                } else {
                    Section {
                        ForEach(matchingWorkspaces, id: \.identifier) { entry in
                            NavigationLink(value: entry.identifier) {
                                HStack(spacing: 12) {
                                    Group {
                                        if manager.restoringIdentifier == entry.identifier {
                                            ProgressView()
                                        } else {
                                            Image(systemName: entry.snapshot.singleRowInLandscape ? "rectangle.split.3x1" : "square.grid.2x2")
                                                .font(.title3).foregroundStyle(.tint)
                                        }
                                    }
                                    .frame(width: 30).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.name).font(.headline).lineLimit(2)
                                        Text("lc.workspace.windowCount".localizeWithFormat(entry.snapshot.windows.count) + " · " +
                                             (entry.snapshot.singleRowInLandscape ? "lc.multitask.landscapeLayout.singleRow" : "lc.multitask.landscapeLayout.automatic").loc)
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // A destructive role removes the row before our confirmation is answered.
                                Button { manager.delete(entry.identifier) } label: {
                                    Label("lc.common.delete".loc, systemImage: "trash")
                                }
                                .tint(.red)
                                Button { manager.rename(entry.identifier) } label: {
                                    Label("lc.common.rename".loc, systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button { Task { await manager.restore(identifier: entry.identifier) } } label: {
                                    Label("lc.workspace.restore".loc, systemImage: "play.fill")
                                }
                                .tint(.blue)
                            }
                            .contextMenu { MultitaskWorkspaceContextActions(identifier: entry.identifier) }
                        }
                    } footer: {
                        Text("lc.workspace.listHint".loc)
                    }
                }
            }
            .disabled(manager.isRestoring)
            .navigationTitle("lc.workspace.title".loc)
            .searchable(text: $searchText, prompt: "lc.workspace.search".loc)
            .navigationDestination(for: String.self) { identifier in
                MultitaskWorkspaceDetailView(identifier: identifier)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("lc.common.done".loc) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { manager.saveNew() } label: {
                        Label("lc.workspace.saveNew".loc, systemImage: "plus")
                    }
                    .disabled(manager.isRestoring || !manager.isStorageAvailable)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if manager.isRestoring {
                HStack {
                    ProgressView()
                    Text("lc.workspace.restoring".loc)
                }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding().allowsHitTesting(false)
            } else if let message = manager.feedbackMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding().allowsHitTesting(false)
            }
        }
        .onAppear { manager.refreshList() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { manager.refreshList() }
        }
        .onChange(of: manager.createdWorkspaceIdentifier) { identifier in
            guard let identifier else { return }
            searchText = ""
            path = [identifier]
        }
        .onChange(of: manager.workspaces.map(\.identifier)) { identifiers in
            path.removeAll { !identifiers.contains($0) }
        }
    }
}

@available(iOS 16.0, *)
private struct MultitaskWorkspaceContextActions: View {
    let identifier: String
    var includesRestoreActions = true
    @ObservedObject private var manager = MultitaskWorkspaceManager.shared

    var body: some View {
        Group {
            if includesRestoreActions {
                Button { Task { await manager.restore(identifier: identifier) } } label: {
                    Label("lc.workspace.restore".loc, systemImage: "play.fill")
                }
                Button { manager.copyRestoreLink(identifier: identifier) } label: {
                    Label("lc.workspace.copyRestoreLink".loc, systemImage: "link")
                }
                Divider()
            }
            Button { manager.rename(identifier) } label: {
                Label("lc.common.rename".loc, systemImage: "pencil")
            }
            Button { manager.duplicate(identifier) } label: {
                Label("lc.workspace.duplicate".loc, systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) { manager.delete(identifier) } label: {
                Label("lc.common.delete".loc, systemImage: "trash")
            }
        }
        .disabled(manager.isRestoring || !manager.isStorageAvailable)
    }
}

@available(iOS 16.0, *)
private struct MultitaskWorkspaceDetailView: View {
    let identifier: String
    @ObservedObject private var manager = MultitaskWorkspaceManager.shared

    private var workspace: LCNamedWorkspace? { manager.workspaces.first { $0.identifier == identifier } }

    private func tapSyncRole(_ window: LCWorkspaceWindow, snapshot: LCWindowWorkspace) -> String? {
        if snapshot.tapSyncGroup["source"] as? String == window.dataUUID { return "lc.tapSync.source".loc }
        if (snapshot.tapSyncGroup["targets"] as? [String])?.contains(window.dataUUID) == true { return "lc.tapSync.follower".loc }
        return nil
    }

    private func preference(_ preference: LCWorkspaceLayoutPreference, _ keyPath: KeyPath<LCWindowWorkspace, Bool>) -> Binding<Bool> {
        Binding {
            workspace?.snapshot[keyPath: keyPath] ?? false
        } set: { value in
            manager.setLayoutPreference(preference, enabled: value, for: identifier)
        }
    }

    var body: some View {
        Group {
            if let workspace {
                Form {
                    Section {
                        Button { Task { await manager.restore(identifier: identifier) } } label: {
                            Label("lc.workspace.restore".loc, systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    Section {
                        Picker("lc.multitask.landscapeLayout".loc, selection: preference(.singleRowInLandscape, \.singleRowInLandscape)) {
                            Text("lc.multitask.landscapeLayout.automatic".loc).tag(false)
                            Text("lc.multitask.landscapeLayout.singleRow".loc).tag(true)
                        }
                    } header: {
                        Text("lc.workspace.savedLayout".loc)
                    }
                    Section {
                        Toggle("lc.multitask.reservePortraitTop".loc, isOn: preference(.reservePortraitTop, \.reservePortraitTop))
                        Toggle("lc.multitask.reservePortraitBottom".loc, isOn: preference(.reservePortraitBottom, \.reservePortraitBottom))
                    } header: {
                        Text("lc.multitask.portraitReservedAreas".loc)
                    } footer: {
                        Text("lc.workspace.layoutAutosave".loc)
                    }
                    Section {
                        NavigationLink {
                            MultitaskSavedTapSyncEditor(identifier: identifier)
                        } label: {
                            HStack {
                                Label("lc.tapSync.savedGroup".loc, systemImage: "hand.draw")
                                Spacer()
                                Text(workspace.snapshot.tapSyncGroup.isEmpty ? "lc.common.none".loc :
                                    (workspace.snapshot.tapSyncGroup["mode"] as? String == "twoFingers" ? "lc.tapSync.mode.twoFingers".loc :
                                     workspace.snapshot.tapSyncGroup["mode"] as? String == "singleFinger" ?
                                        "lc.tapSync.mode.singleFinger".loc : "lc.tapSync.mode.tapsOnly".loc))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("lc.tapSync.workspaceHelp".loc)
                    }
                    Section {
                        ForEach(Array(workspace.snapshot.windows.enumerated()), id: \.element.dataUUID) { index, window in
                            MultitaskWorkspaceWindowRow(window: window, position: index + 1,
                                annotation: tapSyncRole(window, snapshot: workspace.snapshot))
                        }
                    } header: {
                        Text("lc.workspace.windowCount".localizeWithFormat(workspace.snapshot.windows.count))
                    } footer: {
                        if !workspace.snapshot.tapSyncGroup.isEmpty {
                            Text("lc.tapSync.workspaceHelp".loc)
                        }
                    }
                    Section {
                        Button { manager.copyRestoreLink(identifier: identifier) } label: {
                            Label("lc.workspace.copyRestoreLink".loc, systemImage: "link")
                        }
                        DisclosureGroup("lc.workspace.shortcutHelp".loc) {
                            Text("lc.workspace.shortcutInstructions".loc).font(.footnote)
                        }
                    } header: {
                        Text("lc.workspace.homeScreenShortcut".loc)
                    }
                    Section {
                        Button { manager.update(identifier) } label: {
                            Label("lc.workspace.update".loc, systemImage: "arrow.triangle.2.circlepath")
                        }
                    } footer: {
                        Text("lc.workspace.replaceDescription".loc)
                    }
                }
                .disabled(manager.isRestoring)
            } else {
                Text("lc.workspace.notFound".loc)
            }
        }
        .navigationTitle(workspace?.name ?? "lc.workspace.title".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    MultitaskWorkspaceContextActions(identifier: identifier, includesRestoreActions: false)
                } label: {
                    Label("lc.workspace.actions".loc, systemImage: "ellipsis.circle")
                }
                .disabled(manager.isRestoring || workspace == nil)
            }
        }
    }
}

@available(iOS 16.0, *)
struct MultitaskWorkspaceWindowRow: View {
    let window: LCWorkspaceWindow
    let position: Int
    var annotation: String? = nil
    @ObservedObject private var sharedModel = DataManager.shared.model
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    private var app: LCAppModel? {
        (sharedModel.apps + sharedModel.hiddenApps).first { $0.appInfo.relativeBundlePath == window.bundleName }
    }
    private var isHidden: Bool { app?.appInfo.isHidden == true && !sharedModel.isHiddenAppUnlocked }
    private var title: String {
        if isHidden { return "lc.workspace.hiddenApp".loc }
        // Hidden app models may not have loaded yet. Never expose a saved bundle path as a fallback name.
        return app?.appInfo.displayName() ?? "lc.workspace.appUnavailable".loc
    }
    private var details: String {
        if isHidden { return "lc.workspace.hiddenAppDetails".loc }
        guard let app else { return "lc.workspace.windowScale".localizeWithFormat(Int((window.scale * 100).rounded())) }
        guard let container = app.uiContainers.first(where: { $0.folderName == window.dataUUID }) else {
            return "lc.workspace.containerUnavailable".loc
        }
        return "lc.workspace.windowDetails".localizeWithFormat(container.name, Int((window.scale * 100).rounded()))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(position).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if !isHidden, let icon = app?.appInfo.iconIsDarkIcon(darkModeIcon) {
                Image(uiImage: icon).resizable().scaledToFit()
                    .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: isHidden ? "lock.fill" : "questionmark.app")
                    .frame(width: 36, height: 36).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(details).font(.caption).foregroundStyle(.secondary)
                if let annotation { Text(annotation).font(.caption).foregroundStyle(Color.accentColor) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
