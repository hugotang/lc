import SwiftUI

@available(iOS 16.0, *)
@MainActor
final class MultitaskWorkspaceManager: ObservableObject {
    static let shared = MultitaskWorkspaceManager()
    private let defaults = LCUtils.appGroupUserDefault
    private let library: LCWorkspaceLibrary?
    private weak var libraryController: UIViewController?
    @Published private(set) var isRestoring = false
    @Published private(set) var workspaces: [LCNamedWorkspace] = []
    @Published private(set) var isStorageAvailable = false

    private init() {
        library = LCWorkspaceLibrary(defaults: LCUtils.appGroupUserDefault, legacyName: "lc.workspace.migratedName".loc)
        isStorageAvailable = library != nil
        workspaces = library?.workspaces ?? []
    }

    func refreshList() {
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
        var number = 1
        var name = "lc.workspace.defaultName".localizeWithFormat(number)
        while !library.canUseName(name, excluding: nil) {
            number += 1
            name = "lc.workspace.defaultName".localizeWithFormat(number)
        }
        requestName(title: "lc.workspace.saveNew".loc, initialName: name) { [weak self] name in
            guard let self else { return }
            guard let saved = library.save(workspace, name: name, replacing: nil) else {
                self.presentResult("lc.workspace.saveFailed".loc)
                return
            }
            self.refreshList()
            self.presentResult("lc.workspace.saved".localizeWithFormat(saved.name, workspace.windows.count))
        }
    }

    func update(_ identifier: String) {
        refreshList()
        guard !isRestoring, isStorageAvailable, let library, let entry = library.workspace(identifier: identifier) else { return }
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
            self.presentResult("lc.workspace.saved".localizeWithFormat(saved.name, snapshot.windows.count))
        })
        present(alert)
    }

    func rename(_ identifier: String) {
        refreshList()
        guard !isRestoring, isStorageAvailable, let library, let entry = library.workspace(identifier: identifier) else { return }
        requestName(title: "lc.common.rename".loc, initialName: entry.name, identifier: identifier) { [weak self] name in
            guard library.rename(identifier, name: name) else {
                self?.presentResult("lc.workspace.saveFailed".loc)
                return
            }
            self?.refreshList()
        }
    }

    func delete(_ identifier: String, completion: @escaping () -> Void) {
        refreshList()
        guard !isRestoring, isStorageAvailable, let library, let entry = library.workspace(identifier: identifier) else { return }
        let alert = UIAlertController(title: "lc.workspace.deleteTitle".loc,
            message: "lc.workspace.deleteConfirmation".localizeWithFormat(entry.name), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel))
        alert.addAction(UIAlertAction(title: "lc.common.delete".loc, style: .destructive) { [weak self] _ in
            guard let self, !self.isRestoring, library.remove(identifier) else { return }
            self.refreshList()
            completion()
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
        presentResult("lc.workspace.restoreLinkCopied".loc)
    }

    func restore(identifier: String? = nil, showSuccess: Bool = true) async {
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
        isRestoring = true
        defer { isRestoring = false }
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
        var restored = 0
        var failures: [String] = []
        for entry in workspace.windows {
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
        let controller = UIHostingController(rootView: MultitaskWorkspaceLibraryView())
        controller.modalPresentationStyle = .pageSheet
        libraryController = controller
        present(controller)
    }

    private func requestName(title: String, initialName: String, identifier: String? = nil, commit: @escaping (String) -> Void) {
        guard let library else { return }
        let alert = UIAlertController(title: title, message: "lc.workspace.nameRules".loc, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initialName
            field.placeholder = "lc.workspace.name".loc
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
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
}

@available(iOS 16.0, *)
struct MultitaskWorkspaceActions: View {
    @ObservedObject private var manager = MultitaskWorkspaceManager.shared

    var body: some View {
        Button { manager.saveNew() } label: {
            Label("lc.workspace.saveNew".loc, systemImage: "plus.rectangle.on.rectangle")
        }
        .disabled(manager.isRestoring || !manager.isStorageAvailable)
        .onAppear { manager.refreshList() }
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
        Button { manager.presentLibrary() } label: {
            Label("lc.workspace.manage".loc, systemImage: "folder")
        }
        .disabled(manager.isRestoring)
    }
}

@available(iOS 16.0, *)
private struct MultitaskWorkspaceLibraryView: View {
    @ObservedObject private var manager = MultitaskWorkspaceManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !manager.isStorageAvailable {
                    Text("lc.workspace.storageUnavailable".loc)
                } else {
                    Button { manager.saveNew() } label: {
                        Label("lc.workspace.saveNew".loc, systemImage: "plus.rectangle.on.rectangle")
                    }
                    if manager.workspaces.isEmpty {
                        Text("lc.workspace.empty".loc).foregroundStyle(.secondary)
                    }
                    ForEach(manager.workspaces, id: \.identifier) { entry in
                        NavigationLink {
                            MultitaskWorkspaceDetailView(identifier: entry.identifier)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name)
                                Text("lc.workspace.windowCount".localizeWithFormat(entry.snapshot.windows.count))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .disabled(manager.isRestoring)
            .navigationTitle("lc.workspace.title".loc)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
    }
}

@available(iOS 16.0, *)
private struct MultitaskWorkspaceDetailView: View {
    let identifier: String
    @ObservedObject private var manager = MultitaskWorkspaceManager.shared
    @Environment(\.dismiss) private var dismiss

    private var workspace: LCNamedWorkspace? { manager.workspaces.first { $0.identifier == identifier } }

    var body: some View {
        Group {
            if let workspace {
                Form {
                    Section {
                        Text("lc.workspace.windowCount".localizeWithFormat(workspace.snapshot.windows.count))
                        LabeledContent("lc.multitask.landscapeLayout".loc,
                            value: (workspace.snapshot.singleRowInLandscape ? "lc.multitask.landscapeLayout.singleRow" : "lc.multitask.landscapeLayout.automatic").loc)
                    }
                    Section {
                        LabeledContent("lc.multitask.reservePortraitTop".loc,
                            value: (workspace.snapshot.reservePortraitTop ? "lc.multitask.reservedArea.reserved" : "lc.multitask.reservedArea.extended").loc)
                        LabeledContent("lc.multitask.reservePortraitBottom".loc,
                            value: (workspace.snapshot.reservePortraitBottom ? "lc.multitask.reservedArea.reserved" : "lc.multitask.reservedArea.extended").loc)
                    } header: {
                        Text("lc.multitask.portraitReservedAreas".loc)
                    }
                    Section {
                        Button { Task { await manager.restore(identifier: identifier) } } label: {
                            Label("lc.workspace.restore".loc, systemImage: "rectangle.3.group")
                        }
                        Button { manager.copyRestoreLink(identifier: identifier) } label: {
                            Label("lc.workspace.copyRestoreLink".loc, systemImage: "link")
                        }
                    }
                    Section {
                        Button("lc.workspace.update".loc) { manager.update(identifier) }
                        Button("lc.common.rename".loc) { manager.rename(identifier) }
                        Button("lc.common.delete".loc, role: .destructive) {
                            manager.delete(identifier) { dismiss() }
                        }
                    }
                }
                .disabled(manager.isRestoring)
            } else {
                Text("lc.workspace.notFound".loc)
            }
        }
        .navigationTitle(workspace?.name ?? "lc.workspace.title".loc)
        .navigationBarTitleDisplayMode(.inline)
    }
}
