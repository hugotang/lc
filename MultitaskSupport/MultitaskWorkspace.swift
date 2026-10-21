import SwiftUI

@available(iOS 16.0, *)
@MainActor
final class MultitaskWorkspaceManager: ObservableObject {
    static let shared = MultitaskWorkspaceManager()
    private let defaults = LCUtils.appGroupUserDefault
    private let storageKey = "LCWindowWorkspace"
    @Published private(set) var isRestoring = false
    @Published private(set) var savedWindowCount = 0

    private init() {
        savedWindowCount = savedWorkspace?.windows.count ?? 0
    }

    private var savedWorkspace: LCWindowWorkspace? {
        LCWindowWorkspace(propertyList: defaults.object(forKey: storageKey))
    }

    func save() {
        guard !isRestoring else { return }
        guard let workspace = MultitaskDockManager.shared.windowHostingView.captureWorkspace() else {
            presentResult("lc.workspace.noWindows".loc)
            return
        }
        defaults.set(workspace.propertyList, forKey: storageKey)
        savedWindowCount = workspace.windows.count
        presentResult("lc.workspace.saved".localizeWithFormat(savedWindowCount))
    }

    func copyRestoreLink() {
        guard savedWorkspace != nil,
              let url = LCWorkspaceRestoreURL(UserDefaults.lcAppUrlScheme()) else {
            presentResult("lc.workspace.unavailable".loc)
            return
        }
        UIPasteboard.general.string = url.absoluteString
        presentResult("lc.workspace.restoreLinkCopied".loc)
    }

    func restore(showSuccess: Bool = true) async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        guard await waitForHostWindow() else {
            if !Task.isCancelled { presentResult("lc.workspace.notReady".loc) }
            return
        }
        guard (MultitaskMode(rawValue: defaults.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow) == .virtualWindow,
              let workspace = savedWorkspace else {
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

    private func presentResult(_ message: String) {
        // Present from the main window so feedback also survives a dismissed Dock menu.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }?.windows.first { $0.isKeyWindow }
            guard var presenter = window?.rootViewController else { return }
            while let next = presenter.presentedViewController { presenter = next }
            let alert = UIAlertController(title: "lc.workspace.title".loc, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default))
            presenter.present(alert, animated: true)
        }
    }
}

@available(iOS 16.0, *)
struct MultitaskWorkspaceActions: View {
    @ObservedObject private var manager = MultitaskWorkspaceManager.shared

    var body: some View {
        Button { manager.save() } label: {
            Label("lc.workspace.save".loc, systemImage: "square.and.arrow.down")
        }
        .disabled(manager.isRestoring)
        Button { Task { await manager.restore() } } label: {
            Label((manager.isRestoring ? "lc.workspace.restoring" : "lc.workspace.restore").loc, systemImage: "rectangle.3.group")
        }
        .disabled(manager.isRestoring || manager.savedWindowCount == 0)
        Button { manager.copyRestoreLink() } label: {
            Label("lc.workspace.copyRestoreLink".loc, systemImage: "link")
        }
        .disabled(manager.isRestoring || manager.savedWindowCount == 0)
    }
}
