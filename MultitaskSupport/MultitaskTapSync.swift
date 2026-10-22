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

    func refresh() { revision &+= 1 }

    func selectSource(_ window: LCWorkspaceWindow) {
        guard source != window.dataUUID else { return }
        coordinator.selectSource(window.dataUUID, targets: [])
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
        if coordinator.isActive || coordinator.isStarting { coordinator.pause() }
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
}

@available(iOS 16.0, *)
struct MultitaskTapSyncActions: View {
    @ObservedObject private var manager = MultitaskTapSyncManager.shared

    var body: some View {
        Button { manager.presentPanel() } label: {
            Label("lc.tapSync.title".loc, systemImage: "hand.tap")
        }
        if manager.coordinator.isActive || manager.coordinator.isStarting {
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
private struct MultitaskTapSyncPanel: View {
    @ObservedObject private var manager = MultitaskTapSyncManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(manager.coordinator.statusKey.loc, systemImage: "hand.tap")
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
                Section {
                    if manager.windows.isEmpty {
                        Text("lc.tapSync.noWindows".loc).foregroundStyle(.secondary)
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
                        ForEach(Array(manager.candidates.enumerated()), id: \.element.dataUUID) { index, window in
                            let selected = manager.targets.contains(window.dataUUID)
                            Button { manager.toggleTarget(window) } label: {
                                selectionRow(window, position: index + 1, selected: selected, needsReplay: true)
                            }
                            .buttonStyle(.plain)
                            .disabled(!selected && !manager.coordinator.canReplay(forContainer: window.dataUUID))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    } header: {
                        Text("lc.tapSync.targets".localizeWithFormat(manager.targets.count))
                    } footer: {
                        Text("lc.tapSync.targetsHelp".loc)
                    }
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
