import SwiftUI
import Combine

@available(iOS 16.0, *)
@MainActor
@objc final class MultitaskTapSyncManager: NSObject, ObservableObject {
    @objc static let shared = MultitaskTapSyncManager()
    let coordinator = LCTapSyncCoordinator.shared
    @Published private(set) var revision = 0
    private var subscription: AnyCancellable?
    private weak var panelController: UIViewController?

    private override init() {
        super.init()
        subscription = NotificationCenter.default.publisher(for: .LCTapSyncDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    var windows: [LCWorkspaceWindow] { coordinator.availableWindows }
    var source: String? { coordinator.sourceContainer }
    var targets: [String] { coordinator.targetContainers }
    var sourceWindow: LCWorkspaceWindow? { windows.first { $0.dataUUID == source } }
    var candidates: [LCWorkspaceWindow] {
        guard let sourceWindow else { return [] }
        return windows.filter { $0.bundleName == sourceWindow.bundleName && $0.dataUUID != sourceWindow.dataUUID }
    }
    var missingTargets: [String] {
        let visible = Set(candidates.map(\.dataUUID))
        return targets.filter { !visible.contains($0) }
    }

    func position(of window: LCWorkspaceWindow) -> Int {
        (windows.firstIndex { $0.dataUUID == window.dataUUID } ?? 0) + 1
    }

    func refresh() { revision &+= 1 }

    func selectSource(_ window: LCWorkspaceWindow) {
        coordinator.useAsSource(window.dataUUID)
    }

    @objc(windowMenuForContainer:) func windowMenu(forContainer container: String) -> UIMenu {
        let useSource = UIAction(title: "lc.tapSync.useAsSource".loc, image: UIImage(systemName: "hand.point.up.left")) { [weak self] _ in
            self?.coordinator.useAsSource(container)
        }
        useSource.state = source == container ? .on : .off
        if source == container || !windows.contains(where: { $0.dataUUID == container }) || !coordinator.isReady(forContainer: container) {
            useSource.attributes = .disabled
        }
        var actions: [UIMenuElement] = [useSource]
        if targets.contains(container) {
            actions.append(UIAction(title: "lc.tapSync.removeFollower".loc, image: UIImage(systemName: "minus.circle")) { [weak self] _ in
                self?.coordinator.removeTarget(container)
            })
        }
        actions.append(UIAction(title: "lc.tapSync.configure".loc, image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.presentPanel()
        })
        return UIMenu(title: "lc.tapSync.title".loc, options: .displayInline, children: actions)
    }

    func toggleTarget(_ window: LCWorkspaceWindow) {
        var updated = targets
        if let index = updated.firstIndex(of: window.dataUUID) { updated.remove(at: index) }
        else { updated.append(window.dataUUID) }
        coordinator.selectSource(source, targets: updated)
    }

    func selectAllTargets() {
        coordinator.selectSource(source, targets: candidates.filter { coordinator.canReplay(forContainer: $0.dataUUID) }.map(\.dataUUID))
    }

    @objc func presentPanel() {
        guard panelController == nil else { return }
        let host = MultitaskDockManager.shared.windowHostingView
        coordinator.host = host
        if coordinator.isActive || coordinator.isStarting || coordinator.isRecovering { coordinator.pause() }
        guard let window = host.window ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first,
              var presenter = window.rootViewController else { return }
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let controller = UIHostingController(rootView: MultitaskTapSyncPanel())
        controller.modalPresentationStyle = .pageSheet
        controller.sheetPresentationController?.prefersGrabberVisible = true
        panelController = controller
        presenter.present(controller, animated: true)
    }

    func startFromPanel() {
        guard coordinator.canStart else { return }
        guard let controller = panelController else { coordinator.start(); return }
        // Input must start after the sheet has stopped covering the guest windows.
        controller.dismiss(animated: true) { [weak self] in self?.coordinator.start() }
    }

    func dismissForMeasurement() -> Bool {
        guard let presenter = panelController?.presentingViewController else { return false }
        presenter.dismiss(animated: true)
        return true
    }
}

@available(iOS 16.0, *)
struct MultitaskTapSyncActions: View {
    @ObservedObject private var manager = MultitaskTapSyncManager.shared

    var body: some View {
        Button { manager.presentPanel() } label: {
            Label("lc.tapSync.title".loc, systemImage: "hand.tap")
        }
        if manager.coordinator.isActive || manager.coordinator.isStarting || manager.coordinator.isRecovering {
            Button { manager.coordinator.pause() } label: {
                Label("lc.tapSync.pause".loc, systemImage: "pause.circle")
            }
        } else if manager.source != nil && !manager.targets.isEmpty {
            Button { manager.coordinator.start() } label: {
                Label("lc.tapSync.start".loc, systemImage: "play.circle")
            }
            .disabled(!manager.coordinator.canStart)
        }
    }
}

@available(iOS 16.0, *)
struct MultitaskTapSyncWindowActions: View {
    let container: String
    @ObservedObject private var manager = MultitaskTapSyncManager.shared

    var body: some View {
        Button { manager.coordinator.useAsSource(container) } label: {
            Label("lc.tapSync.useAsSource".loc, systemImage: "hand.point.up.left")
        }
        .disabled(manager.source == container || !manager.windows.contains(where: { $0.dataUUID == container }) ||
                  !manager.coordinator.isReady(forContainer: container))
        if manager.targets.contains(container) {
            Button { manager.coordinator.removeTarget(container) } label: {
                Label("lc.tapSync.removeFollower".loc, systemImage: "minus.circle")
            }
        }
    }
}

@available(iOS 16.0, *)
private struct MultitaskTapSyncPanel: View {
    @ObservedObject private var manager = MultitaskTapSyncManager.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("LCTapSyncCompactControls", store: LCUtils.appGroupUserDefault) private var compactControls = UIDevice.current.userInterfaceIdiom == .phone
    @AppStorage("LCTapSyncShowWindowRoles", store: LCUtils.appGroupUserDefault) private var showWindowRoles = true
    @State private var copyingDiagnostics = false
    @State private var diagnosticsCopied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(manager.coordinator.statusKey.loc, systemImage: manager.coordinator.hasInterruption ? "exclamationmark.triangle" :
                          manager.coordinator.mode == .tapsOnly ? "hand.tap" : "hand.draw")
                    ForEach(manager.coordinator.interruptedContainers, id: \.self) { container in
                        VStack(alignment: .leading, spacing: 8) {
                            if let window = manager.windows.first(where: { $0.dataUUID == container }) {
                                MultitaskWorkspaceWindowRow(window: window, position: manager.position(of: window))
                            } else {
                                Label("lc.tapSync.affectedMissingWindow".localizeWithFormat(manager.coordinator.windowNumber(forContainer: container)),
                                      systemImage: "exclamationmark.circle")
                            }
                            Text(manager.coordinator.statusKey(forContainer: container).loc)
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if manager.targets.contains(container) {
                                Button("lc.tapSync.removeFollower".loc) { manager.coordinator.removeTarget(container) }
                            } else if manager.source == container {
                                Text("lc.tapSync.sourceNeedsAttention".loc).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if manager.coordinator.forwardedTapCount > 0 {
                        Text("lc.tapSync.sentCount".localizeWithFormat(manager.coordinator.forwardedTapCount))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button { manager.startFromPanel() } label: {
                        Label("lc.tapSync.start".loc, systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!manager.coordinator.canStart)
                } footer: {
                    Text(manager.source != nil && !manager.targets.isEmpty && !manager.coordinator.canStart
                         ? "lc.tapSync.alignWindows".loc : "lc.tapSync.description".loc)
                }
                MultitaskTapSyncModeSection(mode: Binding(get: { manager.coordinator.mode }, set: { manager.coordinator.mode = $0 }))
                Section {
                    Toggle("lc.tapSync.resumeOnSource".loc, isOn: Binding(
                        get: { manager.coordinator.resumeOnSource }, set: { manager.coordinator.resumeOnSource = $0 }))
                    Toggle("lc.tapSync.syncReturnGesture".loc, isOn: Binding(
                        get: { manager.coordinator.syncReturnGesture }, set: { manager.coordinator.syncReturnGesture = $0 }))
                        .disabled(!manager.coordinator.resumeOnSource)
                    Toggle("lc.tapSync.autoResumeAfterRotation".loc, isOn: Binding(
                        get: { manager.coordinator.autoResumeAfterRotation }, set: { manager.coordinator.autoResumeAfterRotation = $0 }))
                } header: {
                    Text("lc.tapSync.automaticResume".loc)
                } footer: {
                    Text("lc.tapSync.automaticResumeHelp".loc)
                }
                Section {
                    if manager.windows.isEmpty {
                        Text("lc.tapSync.noWindows".loc).foregroundStyle(.secondary)
                    }
                    if manager.source != nil && manager.sourceWindow == nil {
                        Text("lc.tapSync.sourceMissing".loc).foregroundStyle(.secondary)
                    }
                    ForEach(Array(manager.windows.enumerated()), id: \.element.dataUUID) { index, window in
                        Button { manager.selectSource(window) } label: {
                            selectionRow(window, position: index + 1, selected: manager.source == window.dataUUID)
                        }
                        .buttonStyle(.plain)
                        .disabled(!manager.coordinator.isReady(forContainer: window.dataUUID))
                        .accessibilityAddTraits(manager.source == window.dataUUID ? .isSelected : [])
                    }
                } header: {
                    Text("lc.tapSync.source".loc)
                } footer: {
                    Text("lc.tapSync.sourceHelp".loc)
                }
                if manager.sourceWindow != nil {
                    Section {
                        if manager.candidates.isEmpty {
                            Text("lc.tapSync.noTargets".loc).foregroundStyle(.secondary)
                        } else {
                            Button("lc.tapSync.selectAll".loc) { manager.selectAllTargets() }
                        }
                        ForEach(manager.candidates, id: \.dataUUID) { window in
                            let selected = manager.targets.contains(window.dataUUID)
                            Button { manager.toggleTarget(window) } label: {
                                selectionRow(window, position: manager.position(of: window), selected: selected, needsReplay: true)
                            }
                            .buttonStyle(.plain)
                            .disabled(!selected && !manager.coordinator.canReplay(forContainer: window.dataUUID))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                        if !manager.missingTargets.isEmpty {
                            Button("lc.tapSync.removeMissingTargets".localizeWithFormat(manager.missingTargets.count)) {
                                let missing = Set(manager.missingTargets)
                                manager.coordinator.selectSource(manager.source, targets: manager.targets.filter { !missing.contains($0) })
                            }
                        }
                    } header: {
                        Text("lc.tapSync.targets".localizeWithFormat(manager.targets.count))
                    } footer: {
                        Text("lc.tapSync.targetsHelp".loc)
                    }
                }
                Section {
                    Toggle("lc.tapSync.compactControls".loc, isOn: $compactControls)
                    Toggle("lc.tapSync.showWindowRoles".loc, isOn: $showWindowRoles)
                    Button("lc.tapSync.resetControls".loc) {
                        LCUtils.appGroupUserDefault.removeObject(forKey: "LCTapSyncControlsPortraitPosition")
                        LCUtils.appGroupUserDefault.removeObject(forKey: "LCTapSyncControlsLandscapePosition")
                    }
                } header: {
                    Text("lc.tapSync.floatingControls".loc)
                } footer: {
                    Text("lc.tapSync.controlsHelp".loc)
                }
                Section {
                    MultitaskPerformanceActions()
                }
                Section {
                    Button {
                        copyingDiagnostics = true
                        diagnosticsCopied = false
                        manager.coordinator.readInputDiagnostics { report in
                            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                               let text = String(data: data, encoding: .utf8) {
                                UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true])
                                diagnosticsCopied = true
                            }
                            copyingDiagnostics = false
                        }
                    } label: {
                        Label((diagnosticsCopied ? "lc.tapSync.diagnosticsCopied" : "lc.tapSync.copyDiagnostics").loc,
                              systemImage: diagnosticsCopied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(copyingDiagnostics)
                } footer: {
                    Text("lc.tapSync.diagnosticsHelp".loc)
                }
                Section {
                    DisclosureGroup("lc.tapSync.help".loc) {
                        Text("lc.tapSync.limitations".loc).font(.footnote)
                        Text("lc.tapSync.workspaceHelp".loc).font(.footnote)
                    }
                    if manager.source != nil {
                        Button("lc.tapSync.clearGroup".loc) { manager.coordinator.selectSource(nil, targets: []) }
                    }
                }
            }
            .navigationTitle("lc.tapSync.title".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.common.done".loc) { dismiss() }
                }
            }
        }
        .onAppear { manager.refresh() }
    }

    private func selectionRow(_ window: LCWorkspaceWindow, position: Int, selected: Bool, needsReplay: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                MultitaskWorkspaceWindowRow(window: window, position: position)
                if !manager.coordinator.isReady(forContainer: window.dataUUID) {
                    Text("lc.tapSync.notConnected".loc).font(.caption).foregroundStyle(.secondary)
                } else if needsReplay && !manager.coordinator.canReplay(forContainer: window.dataUUID) {
                    Text("lc.tapSync.unsupported".loc).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

@available(iOS 16.0, *)
private struct MultitaskTapSyncModeSection: View {
    @Binding var mode: LCTapSyncMode

    var body: some View {
        Section {
            Picker("lc.tapSync.mode".loc, selection: $mode) {
                Text("lc.tapSync.mode.tapsOnly".loc).tag(LCTapSyncMode.tapsOnly)
                Text("lc.tapSync.mode.singleFinger".loc).tag(LCTapSyncMode.singleFinger)
                Text("lc.tapSync.mode.twoFingers".loc).tag(LCTapSyncMode.twoFingers)
            }
            .pickerStyle(.menu)
        } header: {
            Text("lc.tapSync.mode".loc)
        } footer: {
            Text((mode == .twoFingers ? "lc.tapSync.twoFingersHelp" : mode == .singleFinger ? "lc.tapSync.singleFingerHelp" : "lc.tapSync.tapsOnlyHelp").loc)
        }
    }
}

@available(iOS 16.0, *)
struct MultitaskSavedTapSyncEditor: View {
    let identifier: String
    @ObservedObject private var manager = MultitaskWorkspaceManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var source: String?
    @State private var targets: [String] = []
    @State private var mode: LCTapSyncMode = .tapsOnly
    @State private var loaded = false

    private var snapshot: LCWindowWorkspace? { manager.workspaces.first { $0.identifier == identifier }?.snapshot }
    private var windows: [LCWorkspaceWindow] { snapshot?.windows ?? [] }
    private var sourceWindow: LCWorkspaceWindow? { windows.first { $0.dataUUID == source } }
    private var candidates: [LCWorkspaceWindow] {
        guard let sourceWindow else { return [] }
        return windows.filter { $0.bundleName == sourceWindow.bundleName && $0.dataUUID != sourceWindow.dataUUID }
    }
    private var canSave: Bool {
        guard snapshot != nil, manager.isStorageAvailable, !manager.isRestoring else { return false }
        if source == nil { return targets.isEmpty }
        let eligible = Set(candidates.map(\.dataUUID))
        return sourceWindow != nil && !targets.isEmpty && targets.allSatisfy { eligible.contains($0) }
    }

    var body: some View {
        Form {
            MultitaskTapSyncModeSection(mode: $mode)
            Section {
                ForEach(windows, id: \.dataUUID) { window in
                    Button { selectSource(window) } label: {
                        selectionRow(window, selected: source == window.dataUUID)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(source == window.dataUUID ? .isSelected : [])
                }
            } header: {
                Text("lc.tapSync.source".loc)
            } footer: {
                Text("lc.tapSync.savedGroupHelp".loc)
            }
            if sourceWindow != nil {
                Section {
                    if candidates.isEmpty {
                        Text("lc.tapSync.noSavedTargets".loc).foregroundStyle(.secondary)
                    } else {
                        Button("lc.tapSync.selectAll".loc) { targets = candidates.map(\.dataUUID) }
                    }
                    ForEach(candidates, id: \.dataUUID) { window in
                        let selected = targets.contains(window.dataUUID)
                        Button {
                            if selected { targets.removeAll { $0 == window.dataUUID } }
                            else { targets.append(window.dataUUID) }
                        } label: {
                            selectionRow(window, selected: selected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                } header: {
                    Text("lc.tapSync.targets".localizeWithFormat(targets.count))
                }
            }
            if source != nil {
                Section {
                    Button("lc.tapSync.clearGroup".loc) { source = nil; targets = [] }
                }
            }
        }
        .disabled(manager.isRestoring)
        .navigationTitle("lc.tapSync.savedGroup".loc)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("lc.tapSync.saveGroup".loc) { save() }.disabled(!canSave)
            }
        }
        .onAppear {
            guard !loaded else { return }
            manager.refreshList()
            let group = snapshot?.tapSyncGroup ?? [:]
            source = group["source"] as? String
            targets = group["targets"] as? [String] ?? []
            mode = group["mode"] as? String == "twoFingers" ? .twoFingers : group["mode"] as? String == "singleFinger" ? .singleFinger : .tapsOnly
            loaded = true
        }
    }

    private func selectionRow(_ window: LCWorkspaceWindow, selected: Bool) -> some View {
        HStack {
            MultitaskWorkspaceWindowRow(window: window, position: (windows.firstIndex { $0.dataUUID == window.dataUUID } ?? 0) + 1)
            Spacer(minLength: 8)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private func selectSource(_ window: LCWorkspaceWindow) {
        guard source != window.dataUUID else { return }
        if let previous = sourceWindow, previous.bundleName == window.bundleName {
            targets.removeAll { $0 == window.dataUUID }
            targets.append(previous.dataUUID)
        } else {
            targets = []
        }
        source = window.dataUUID
    }

    private func save() {
        guard canSave else { return }
        var group: [String: Any] = [:]
        if let source {
            group = ["source": source, "targets": targets]
            if mode == .singleFinger { group["mode"] = "singleFinger" }
            if mode == .twoFingers { group["mode"] = "twoFingers" }
        }
        if manager.setTapSyncGroup(group, for: identifier) { dismiss() }
    }
}
