//
//  MultitaskAppWindow.swift
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
import SwiftUI

@available(iOS 16.1, *)
struct MultitaskAppInfo {
    var displayName: String
    var dataUUID: String
    var bundleId: String
    
    init(displayName: String, dataUUID: String, bundleId: String) {
        self.displayName = displayName
        self.dataUUID = dataUUID
        self.bundleId = bundleId
    }
}

@available(iOS 16.1, *)
final class NativeAppWindowSession: ObservableObject {
    // Only the main-actor recovery tasks read/write this reservation.
    private static var activeRecovery: String?
    let id = UUID().uuidString
    let info: MultitaskAppInfo
    @Published private(set) var state = LCNativeWindowState()
    @Published var errorMessage: String?
    @Published private(set) var restarting = false
    // Retain a closing controller until its asynchronous cleanup callback.
    // SwiftUI can dismantle the view before PluginKit reports the exit.
    var controller: AppSceneViewController?
    private var callbacks: [(NSNumber, Error?) -> Void] = []
    private var recoveryTask: Task<Void, Never>?
    var hostSceneIdentifier: String?

    init(info: MultitaskAppInfo) { self.info = info }

    func prepareLaunch(callback: ((NSNumber, Error?) -> Void)?) {
        if state.phase == .running, controller?.isAppRunning != true {
            controller?.appTerminationCleanUp()
            exited(attempt: state.attempt)
        }
        if state.phase == .terminated { state.beginLaunch(); errorMessage = nil }
        if let callback {
            if state.phase == .running, let controller { callback(NSNumber(value: controller.pid), nil) }
            else { callbacks.append(callback) }
        }
    }

    func initialized(_ vc: AppSceneViewController, attempt: UUID, error: Error?) {
        guard state.initialized(attempt: attempt, succeeded: error == nil, now: ProcessInfo.processInfo.systemUptime) else { return }
        errorMessage = error?.localizedDescription
        if error != nil { MultitaskDockManager.shared.removeRunningApp(info.dataUUID) }
        let pending = callbacks
        callbacks.removeAll()
        pending.forEach { $0(NSNumber(value: vc.pid), error) }
    }

    func exited(attempt: UUID) {
        if state.attempt == attempt { controller = nil }
        if state.phase == .closed, state.attempt == attempt {
            MultitaskWindowManager.remove(self)
            return
        }
        guard state.exited(attempt: attempt, now: ProcessInfo.processInfo.systemUptime) else { return }
        MultitaskDockManager.shared.removeRunningApp(info.dataUUID)
    }

    @MainActor func restart(automatically: Bool) {
        guard state.phase == .terminated, !restarting else { return }
        let defaults = LCUtils.appGroupUserDefault
        if automatically {
            guard defaults.bool(forKey: "LCSkipTerminatedScreen"), defaults.bool(forKey: "LCRestartTerminatedApp"),
                  state.reserveAutomaticRestart(now: ProcessInfo.processInfo.systemUptime) else { return }
        } else {
            state.resetAutomaticRestarts()
        }
        restarting = true
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { restarting = false; recoveryTask = nil }
            do {
                // Let the previous scene finish cleanup before signing/launching a replacement.
                try await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, state.phase == .terminated else { return }
                if automatically {
                    guard defaults.bool(forKey: "LCSkipTerminatedScreen"), defaults.bool(forKey: "LCRestartTerminatedApp") else { return }
                }
                guard defaults.integer(forKey: "LCMultitaskMode") == MultitaskMode.nativeWindow.rawValue else {
                    errorMessage = "lc.multitaskAppWindow.nativeModeRequired".loc
                    return
                }
                guard let app = MultitaskRelaunchManager.lookupAppModel(bundleId: info.bundleId),
                      app.appInfo.defaultClassicMode == 0,
                      app.uiContainers.contains(where: { $0.folderName == info.dataUUID }) else {
                    errorMessage = "lc.multitaskAppWindow.appUnavailable".loc
                    return
                }
                // Multiple native accounts can exit together. runApp ignores
                // concurrent launches of one app, so wait for its current launch.
                let deadline = ProcessInfo.processInfo.systemUptime + 30
                while Self.activeRecovery != nil || app.isAppRunning || app.isSigningInProgress {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        errorMessage = "lc.multitaskAppWindow.launchBusy".loc
                        return
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                Self.activeRecovery = id
                defer { if Self.activeRecovery == id { Self.activeRecovery = nil } }
                // runApp retains the existing signing, container selection and JIT flow.
                try await app.runApp(multitask: true, containerFolderName: info.dataUUID, launchAllowed: { [weak self] in
                    guard let self else { return false }
                    return self.state.phase == .terminated &&
                        defaults.integer(forKey: "LCMultitaskMode") == MultitaskMode.nativeWindow.rawValue &&
                        (!automatically || (defaults.bool(forKey: "LCSkipTerminatedScreen") && defaults.bool(forKey: "LCRestartTerminatedApp")))
                })
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func close() {
        guard state.phase != .closed else { return }
        // Keep the container reserved until asynchronous guest cleanup completes.
        // Otherwise a new window can race the old extension's termination.
        state.close()
        recoveryTask?.cancel()
        controller?.terminate()
        let pending = callbacks
        callbacks.removeAll()
        pending.forEach { $0(NSNumber(value: 0), CancellationError()) }
        if controller == nil { MultitaskWindowManager.remove(self) }
        MultitaskDockManager.shared.removeRunningApp(info.dataUUID)
    }
}

@available(iOS 16.1, *)
@objc class MultitaskWindowManager: NSObject {
    @Environment(\.openWindow) static var openWindow
    static private(set) var sessions: [String: NativeAppWindowSession] = [:]
    
    @objc class func openAppWindow(displayName: String, dataUUID: String, bundleId: String, pidCallback: ((NSNumber, Error?) -> Void)?) -> Bool {
        if sessions.values.contains(where: { $0.info.dataUUID == dataUUID && $0.state.phase == .closed }) {
            pidCallback?(NSNumber(value: 0), CancellationError())
            return false
        }
        DataManager.shared.model.enableMultipleWindow = true
        let session = sessions.values.first { $0.info.dataUUID == dataUUID && $0.info.bundleId == bundleId && $0.state.phase != .closed } ??
            NativeAppWindowSession(info: MultitaskAppInfo(displayName: displayName, dataUUID: dataUUID, bundleId: bundleId))
        sessions[session.id] = session
        session.prepareLaunch(callback: pidCallback)
        openWindow(id: "appView", value: session.id)
        return true
    }
    
    @objc class func openExistingAppWindow(dataUUID: String) -> Bool {
        guard let session = sessions.values.first(where: { $0.info.dataUUID == dataUUID }) else { return false }
        if session.state.phase == .closed { return true }
        guard session.state.phase == .launching || session.state.phase == .running else { return false }
        if session.state.phase == .running, session.controller?.isAppRunning != true {
            session.controller?.appTerminationCleanUp()
            session.exited(attempt: session.state.attempt)
            return false
        }
        openWindow(id: "appView", value: session.id)
        return true
    }

    static func remove(_ session: NativeAppWindowSession) {
        if sessions[session.id] === session { sessions.removeValue(forKey: session.id) }
    }
}

@available(iOS 16.1, *)
struct AppSceneViewSwiftUI: UIViewControllerRepresentable {
    let session: NativeAppWindowSession
    let attempt: UUID
    
    class Coordinator: NSObject, AppSceneViewControllerDelegate {
        let session: NativeAppWindowSession
        let attempt: UUID
        init(session: NativeAppWindowSession, attempt: UUID) { self.session = session; self.attempt = attempt }
        
        func appSceneVCAppDidExit(_: AppSceneViewController!) {
            session.exited(attempt: attempt)
        }
        
        func appSceneVC(_ vc: AppSceneViewController!, didInitializeWithError error: (any Error)!) {
            DispatchQueue.main.async {
                guard self.session.state.attempt == self.attempt, self.session.state.phase == .running else { return }
                self.session.hostSceneIdentifier = vc.view.window?.windowScene?.session.persistentIdentifier
                (vc.view.window?.windowScene?.statusBarManager as? LCStatusBarManager)?.nativeWindowViewController = vc
            }
            session.initialized(vc, attempt: attempt, error: error)
        }
        
        func appSceneVCWillActivateScene(_ vc: AppSceneViewController!) {
            vc.updateSettings { settings in
                guard let settings else { return }
                let defaultInsets = vc.view.window?.safeAreaInsets ?? .zero
                settings.peripheryInsets = defaultInsets
                settings.safeAreaInsetsPortrait = defaultInsets
                settings.deviceOrientation = UIDevice.current.orientation
                settings.setInterfaceOrientation(UIApplication.shared.statusBarOrientation)
                if(settings.interfaceOrientation().isLandscape) {
                    settings.setFrame(CGRect(x: 0, y: 0, width: vc.view.frame.size.height, height: vc.view.frame.size.width))
                } else {
                    settings.setFrame(CGRect(x: 0, y: 0, width: vc.view.frame.size.width, height: vc.view.frame.size.height))
                }
            }
            // fix live resize
            vc.contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        
        func appSceneVC(_ vc: AppSceneViewController!, didUpdateFrom settings: UIMutableApplicationSceneSettings!, transitionContext context: Any!, lifecycleActionType actionType: UInt32) {
            settings.interruptionPolicy = 0
            //settings.peripheryInsets = vc.view.window?.safeAreaInsets ?? .zero
            vc.presenter.scene.updateSettings(settings, withTransitionContext: context, completion: nil)
            // Not sure what actionType 2 is, but it's only set when this scene enters foreground, so we can pass URL scheme here
            if actionType == 2, let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
                UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
                vc.openURLScheme(launchUrl)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, attempt: attempt)
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = AppSceneViewController(bundleId: session.info.bundleId, dataUUID: session.info.dataUUID, delegate: context.coordinator, deferLaunch: true)!
        session.controller = vc
        DispatchQueue.main.async {
            guard session.state.attempt == attempt, session.state.phase == .launching else { return }
            vc.startApp()
        }
        return vc
    }
    
    func updateUIViewController(_ vc: UIViewController, context _: Context) {
    }

    static func dismantleUIViewController(_ vc: UIViewController, coordinator: Coordinator) {
        if let manager = vc.viewIfLoaded?.window?.windowScene?.statusBarManager as? LCStatusBarManager,
           manager.nativeWindowViewController === vc { manager.nativeWindowViewController = nil }
        if coordinator.session.state.attempt == coordinator.attempt,
           coordinator.session.state.phase == .launching || coordinator.session.state.phase == .running {
            coordinator.session.close()
        }
        (vc as? AppSceneViewController)?.terminate()
    }
}

@available(iOS 16.1, *)
struct MultitaskAppWindow: View {
    let id: String
    var body: some View {
        if let session = MultitaskWindowManager.sessions[id] {
            NativeAppWindowContent(session: session)
        } else {
            MissingNativeAppWindow()
        }
    }
}

@available(iOS 16.1, *)
private struct NativeAppWindowContent: View {
    @ObservedObject var session: NativeAppWindowSession
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @Environment(\.scenePhase) var scenePhase
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = false
    @AppStorage("LCRestartTerminatedApp", store: LCUtils.appGroupUserDefault) var restartTerminatedApp = false
    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)

    var body: some View {
        Group {
            if session.state.phase == .launching || session.state.phase == .running {
                AppSceneViewSwiftUI(session: session, attempt: session.state.attempt)
                .id(session.state.attempt)
                .background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all, edges: .all)
            } else {
                VStack(spacing: 16) {
                    Text("lc.multitaskAppWindow.appTerminated".loc).font(.title)
                    if let error = session.errorMessage {
                        Text(error).font(.system(.body, design: .monospaced))
                        Button("lc.common.copy".loc) { UIPasteboard.general.string = error }
                    }
                    if session.restarting { ProgressView() }
                    Button("lc.multitaskAppWindow.restart".loc) { session.restart(automatically: false) }
                        .disabled(session.restarting || session.state.phase == .closed)
                        .accessibilityIdentifier("nativeWindow.restart")
                    Button("lc.common.close".loc, action: closeWindow)
                }
                .buttonStyle(.bordered)
                .padding()
                .onAppear(perform: recoverIfNeeded)
            }
        }
        .navigationTitle(session.info.displayName)
        .onAppear { captureHostScene() }
        .onChange(of: scenePhase) { phase in if phase == .active { recoverIfNeeded() } }
        .onReceive(pub) { note in
            if let scene = note.object as? UIWindowScene,
               scene.session.persistentIdentifier == session.hostSceneIdentifier {
                session.close()
            }
        }
    }

    private func captureHostScene() {
        if let scene = sceneDelegate.window?.windowScene { session.hostSceneIdentifier = scene.session.persistentIdentifier }
    }

    private func recoverIfNeeded() {
        captureHostScene()
        guard scenePhase == .active, session.state.phase == .terminated, skipTerminatedScreen,
              session.errorMessage == nil, session.state.ranBeforeTermination else { return }
        if restartTerminatedApp { session.restart(automatically: true) }
        else { closeWindow() }
    }

    private func closeWindow() {
        guard let scene = sceneDelegate.window?.windowScene else { return }
        session.close()
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { error in
            session.errorMessage = error.localizedDescription
        }
    }
}

// Restored system scenes have no live guest after the host process was killed.
@available(iOS 16.1, *)
private struct MissingNativeAppWindow: View {
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @Environment(\.openWindow) var openWindow
    var body: some View {
        ProgressView().task {
            if !DataManager.shared.model.mainWindowOpened { openWindow(id: "Main") }
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let session = sceneDelegate.window?.windowScene?.session {
                UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
            }
        }
    }
}

@objcMembers
class MultitaskRelaunchManager: NSObject {
    private static var pendingKeys: Set<String> = []
    private static let pendingLock = NSLock()
    
    static func scheduleRelaunchIfNeeded(bundleId: String, dataUUID: String, isManualTermination: Bool) {
        let defaults = LCUtils.appGroupUserDefault
        let multitaskMode = MultitaskMode(rawValue: defaults.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        guard defaults.bool(forKey: "LCSkipTerminatedScreen"),
              defaults.bool(forKey: "LCRestartTerminatedApp"),
              multitaskMode == .virtualWindow,
              !isManualTermination else { return }
        
        let key = "\(bundleId)#\(dataUUID)"
        guard markPendingIfNeeded(key: key) else { return }
        
        Task {
            defer { clearPending(key: key) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await relaunchApp(bundleId: bundleId, dataUUID: dataUUID)
        }
    }
    
    private static func markPendingIfNeeded(key: String) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        if pendingKeys.contains(key) {
            return false
        }
        pendingKeys.insert(key)
        return true
    }
    
    private static func clearPending(key: String) {
        pendingLock.lock()
        pendingKeys.remove(key)
        pendingLock.unlock()
    }
    
    private static func relaunchApp(bundleId: String, dataUUID: String) async {
        guard let appModel = await MainActor.run(body: { lookupAppModel(bundleId: bundleId) }),
              appModel.appInfo.lastLaunched.distance(to: .now) > 2
        else {
            return
        }
        
        do {
            try await appModel.runApp(multitask: true, containerFolderName: dataUUID)
        } catch {
            print("Failed to restart \(bundleId): \(error)")
        }
    }
    
    @MainActor static func lookupAppModel(bundleId: String) -> LCAppModel? {
        let sharedModel = DataManager.shared.model
        if let app = sharedModel.apps.first(where: { $0.appInfo.relativeBundlePath == bundleId }) {
            return app
        }
        return sharedModel.hiddenApps.first(where: { $0.appInfo.relativeBundlePath == bundleId })
    }
}
