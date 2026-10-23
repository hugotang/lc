//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import Combine

// MARK: - App Info Provider
class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.livecontainer.appinfoprovider.cachequeue", attributes: .concurrent)
    
    private init() {}
    
    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }
    
    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) {
            return cachedInfo
        }
        
        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                
                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByName[appName] }) {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            
            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = appInfo }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        
        for appModel in allApps {
            if appModel.uiContainers.contains(where: { $0.folderName == dataUUID }) ||
                (appModel.appInfo.containerInfo as? [[String: Any]] ?? []).contains(where: { $0["folderName"] as? String == dataUUID }) {
                return appModel.appInfo
            }
        }
        
        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
            }
        }
        return nil
    }
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.infoCacheByUUID.removeAll()
            self.infoCacheByName.removeAll()
        }
    }
}

// MARK: - App Model for Dock
@objc class DockAppModel: NSObject, ObservableObject, Identifiable {
    var id: String { appUUID }
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    let view: UIView?
    @Published var accountNumber = 1
    @Published var containerName = ""
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
}

// MARK: - MultitaskDockView Manager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject {
    @objc public static let shared = MultitaskDockManager()
    
    @Published var apps: [DockAppModel] = []
    @Published var isVisible: Bool = false
    @Published @objc var isCollapsed: Bool = false
    @Published var isDockHidden: Bool = false
    @Published var settingsChanged: Bool = false
    @Published private(set) var isAdjustingGridDividers: Bool = false
    @Published private(set) var canAdjustGridDividers: Bool = false
    @Published private(set) var isChoosingGridSwap: Bool = false
    @Published private(set) var canUndoGridSwap: Bool = false
    @Published private(set) var geometryRevision = 0
    @Published private(set) var isOnRightSide = true
    @Published private(set) var sourceContainer: String?
    @Published private(set) var targetContainers: [String] = []

    var isEditingGrid: Bool { isAdjustingGridDividers || isChoosingGridSwap }

    @objc public var windowHostingView = VirtualWindowsHostView()
    internal var hostingController: UIHostingController<AnyView>?
    private let placementStore = LCDockPlacementStore(defaults: LCUtils.appGroupUserDefault)
    private let accountRegistry = LCDockAccountRegistry(defaults: LCUtils.appGroupUserDefault)
    private var subscriptions = Set<AnyCancellable>()
    private let revealControl = LCDockRevealControl(frame: .zero)
    private var dragStartFrame: CGRect?
    private var dragStartBounds = CGRect.zero
    private var dragCancelled = false
    private weak var lastHostWindow: UIWindow?
    private var lastWindowBounds = CGRect.zero
    private var lastSafeAreaInsets = UIEdgeInsets.zero
    private var geometryUpdatePending = false
    private var metadataSubscriptions = Set<AnyCancellable>()

    public struct Constants {
        static let defaultDockWidth: CGFloat = 80
        
        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1
        
        static let standardSpringDamping: CGFloat = 0.8
        static let showHideSpringDamping: CGFloat = 0.7
        static let standardSpringVelocity: CGFloat = 0.3
        static let showHideSpringVelocity: CGFloat = 0.5
        
        static let initialScale: CGFloat = 0.8
        static let bringToFrontScale: CGFloat = 1.02
    }
    
    // Original dock width from user settings (without auto-adjustment)
    private var originalDockWidth: CGFloat {
        let storedValue = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
        return storedValue > 0 ? CGFloat(storedValue) : Constants.defaultDockWidth
    }
    
    var dockLayout: LCDockLayout {
        let showsLabels = LCUtils.appGroupUserDefault.object(forKey: "LCDockShowAccountLabels") == nil ||
            LCUtils.appGroupUserDefault.bool(forKey: "LCDockShowAccountLabels")
        return LCDockLayout(preferredWidth: originalDockWidth,
                            availableHeight: max(0, safeAreaHeight - 16), accountCount: apps.count,
                            showsLabels: showsLabels, collapsed: isCollapsed || isDockHidden)
    }
    public var dockWidth: CGFloat { dockLayout.width }
    public var adaptiveIconSize: CGFloat { dockLayout.iconSize }

    public var keyWindow: UIWindow? {
        windowHostingView.window ?? hostingController?.view.window ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.windows.first { $0.isKeyWindow }
    }

    public var safeAreaInsets: UIEdgeInsets {
        if #available(iOS 11.0, *) {
            return keyWindow?.safeAreaInsets ?? .zero
        }
        return .zero
    }

    private var safeAreaHeight: CGFloat {
        (keyWindow?.bounds.height ?? 0) - safeAreaInsets.top - safeAreaInsets.bottom
    }
    private var isLandscape: Bool { (keyWindow?.bounds.width ?? 0) > (keyWindow?.bounds.height ?? 0) }
    private var placementInsets: LCDockInsets {
        LCDockInsets(top: safeAreaInsets.top, left: safeAreaInsets.left,
                     bottom: safeAreaInsets.bottom, right: safeAreaInsets.right)
    }
    
    override init() {
        super.init()
        isCollapsed = windowHostingView.automaticallyTilesWindows
        if let root = keyWindow?.rootViewController?.view {
            (root.subviews.first ?? root).addSubview(windowHostingView)
        }
        setupDockView()
        DataManager.shared.model.$isHiddenAppUnlocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAccountMetadata() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .LCTapSyncDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let coordinator = LCTapSyncCoordinator.shared
                if self.sourceContainer != coordinator.sourceContainer { self.sourceContainer = coordinator.sourceContainer }
                if self.targetContainers != coordinator.targetContainers { self.targetContainers = coordinator.targetContainers }
            }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: LCUtils.appGroupUserDefault
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            if self.isVisible {
                self.hostGeometryDidChange()
            }
        }
    }
    
    @objc private func userDefaultsDidChange() {
        DispatchQueue.main.async {
            self.refreshAccountMetadata()
            self.settingsChanged.toggle()
            if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    private func setupDockView() {
        DispatchQueue.main.async {
            let dockView = AnyView(MultitaskDockSwiftView()
                .environmentObject(self))
            
            self.hostingController = UIHostingController(rootView: dockView)
            self.hostingController?.view.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
            self.hostingController?.view.backgroundColor = .clear
        }
    }

    private func updateDockFrame(animated: Bool = true) {
        guard let hostingController, let window = keyWindow else { return }
        let layout = dockLayout
        let placement = placementStore.load(landscape: isLandscape)
        isOnRightSide = placement.right
        let newFrame = placement.frame(size: CGSize(width: layout.width, height: layout.height),
                                       bounds: window.bounds, insets: placementInsets, hidden: isDockHidden)
        hostingController.view.isUserInteractionEnabled = isVisible && !isDockHidden
        applyNewFrame(newFrame, for: hostingController, animated: animated)
        if isVisible && isDockHidden {
            revealControl.accessibilityLabel = "lc.multitask.showDock".loc
            revealControl.show(in: window, frame: placement.revealFrame(bounds: window.bounds, insets: placementInsets),
                               right: placement.right, hideArrow: LCUtils.appGroupUserDefault.bool(forKey: "LCHideCollapsedDock")) { [weak self] in
                self?.showDockFromHidden()
            }
        } else {
            revealControl.hide()
        }
    }

    // Called by the attached host after rotation, Stage Manager resizing or inset changes.
    @objc public func hostGeometryDidChange() {
        guard let window = keyWindow,
              window !== lastHostWindow || window.bounds != lastWindowBounds || window.safeAreaInsets != lastSafeAreaInsets,
              !geometryUpdatePending else { return }
        geometryUpdatePending = true
        DispatchQueue.main.async {
            self.geometryUpdatePending = false
            guard let window = self.keyWindow else { return }
            self.lastHostWindow = window
            self.lastWindowBounds = window.bounds
            self.lastSafeAreaInsets = window.safeAreaInsets
            self.cancelDockDrag()
            self.geometryRevision &+= 1
            if self.isVisible { self.updateDockFrame(animated: false) }
        }
    }

    func dragDock(by translation: CGSize) {
        guard !isDockHidden, !dragCancelled, let window = keyWindow, let view = hostingController?.view else { return }
        if dragStartFrame == nil {
            view.layer.removeAllAnimations()
            dragStartFrame = view.frame
            dragStartBounds = window.bounds
        }
        guard dragStartBounds == window.bounds, let start = dragStartFrame else { cancelDockDrag(); return }
        let minY = window.bounds.minY + safeAreaInsets.top + 8
        let maxY = max(minY, window.bounds.maxY - safeAreaInsets.bottom - start.height - 8)
        var frame = start.offsetBy(dx: translation.width, dy: translation.height)
        frame.origin.y = max(minY, min(maxY, frame.origin.y))
        frame.origin.x = max(window.bounds.minX + safeAreaInsets.left,
                             min(window.bounds.maxX - safeAreaInsets.right - frame.width, frame.origin.x))
        view.frame = frame
    }

    func finishDockDrag() {
        defer { dragStartFrame = nil; dragCancelled = false }
        guard !dragCancelled, let frame = hostingController?.view.frame,
              let window = keyWindow, dragStartFrame != nil, dragStartBounds == window.bounds else { return }
        placementStore.save(.from(frame: frame, bounds: window.bounds, insets: placementInsets), landscape: isLandscape)
        updateDockFrame()
    }

    private func cancelDockDrag() {
        if dragStartFrame != nil { dragCancelled = true }
        dragStartFrame = nil
    }

    func moveDock(right: Bool, fraction: Double) {
        cancelDockDrag()
        placementStore.save(LCDockPlacement(right: right, fraction: fraction), landscape: isLandscape)
        updateDockFrame()
    }

    @objc public func resetDockPosition() {
        cancelDockDrag()
        placementStore.reset()
        isDockHidden = false
        if let view = hostingController?.view { view.superview?.bringSubviewToFront(view) }
        geometryRevision &+= 1
        if isVisible { updateDockFrame() }
    }

    private func observeAccountMetadata() {
        metadataSubscriptions.removeAll()
        let applications = Set(apps.compactMap { $0.appInfo?.relativeBundlePath })
        for model in DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
            where applications.contains(model.appInfo.relativeBundlePath) {
            model.$uiContainers.dropFirst().receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.observeAccountMetadata()
                    self?.refreshAccountMetadata()
                }.store(in: &metadataSubscriptions)
            for container in model.uiContainers {
                container.$name.dropFirst().receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.refreshAccountMetadata() }.store(in: &metadataSubscriptions)
            }
        }
    }

    private func refreshAccountMetadata() {
        for app in apps {
            let models = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
            let model = models.first { $0.appInfo.relativeBundlePath == app.appInfo?.relativeBundlePath }
            let info = model?.appInfo ?? app.appInfo
            let known = info?.containerInfo as? [[String: Any]] ?? []
            let identifiers = model?.uiContainers.map(\.folderName) ?? known.compactMap { $0["folderName"] as? String }
            let number = accountRegistry.number(for: app.appUUID,
                                                application: info?.relativeBundlePath ?? app.appName,
                                                knownIdentifiers: identifiers)
            let name = model?.uiContainers.first { $0.folderName == app.appUUID }?.name ??
                known.first { $0["folderName"] as? String == app.appUUID }?["name"] as? String ?? ""
            if app.accountNumber != number { app.accountNumber = number }
            if app.containerName != name { app.containerName = name }
            (app.view?._viewDelegate() as? DecoratedAppSceneViewController)?.updateAccountTitle()
        }
    }

    @objc(accountTitleForContainer:) public func accountTitle(forContainer container: String) -> String {
        guard let app = apps.first(where: { $0.appUUID == container }) else { return "lc.dock.account".loc }
        if app.appInfo?.isHidden == true && !DataManager.shared.model.isHiddenAppUnlocked {
            return "lc.workspace.hiddenApp".loc
        }
        let name = app.containerName.isEmpty ? app.appName : app.containerName
        return "#\(app.accountNumber) · \(name)"
    }

    private func applyNewFrame(_ newFrame: CGRect, for hostingController: UIHostingController<AnyView>, animated: Bool) {
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                hostingController.view.frame = newFrame
            }
        } else {
            hostingController.view.frame = newFrame
        }
    }
    
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }
    
    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        
        DispatchQueue.main.async {
            self.apps.removeAll { $0.appUUID == appUUID }
            self.observeAccountMetadata()
            
            if self.apps.isEmpty {
                self.hideDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    @objc public func showDock() {
        guard isDockEnabled() else { return }
        guard !isVisible, let hostingController = hostingController else { return }
        
        guard let keyWindow = self.keyWindow else { return }
        
        DispatchQueue.main.async {
            self.isVisible = true
            if hostingController.view.superview == nil {
                keyWindow.addSubview(hostingController.view)
            }
            self.hostGeometryDidChange()
            self.updateDockFrame(animated: false)
            hostingController.view.alpha = 0
            hostingController.view.transform = UIAccessibility.isReduceMotionEnabled ? .identity :
                CGAffineTransform(scaleX: Constants.initialScale, y: Constants.initialScale)
            
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 1
                hostingController.view.transform = .identity
            }
        }
    }
    
    @objc public func hideDock() {
        guard isVisible, let hostingController = hostingController else { return }
        
        DispatchQueue.main.async {
            self.windowHostingView.finishGridEditing()
            self.cancelDockDrag()
            self.revealControl.hide()
            self.isDockHidden = false
            hostingController.view.isUserInteractionEnabled = false
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 0
                hostingController.view.transform = UIAccessibility.isReduceMotionEnabled ? .identity :
                    CGAffineTransform(scaleX: Constants.initialScale, y: Constants.initialScale)
            } completion: { _ in
                self.isVisible = false
                hostingController.view.transform = .identity
            }
        }
    }

    // Find and bring corresponding multitask view to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        guard let targetView = apps.first(where: { $0.appUUID == uuid })?.view,
              let window = targetView.window ?? keyWindow else { return false }
        passURLSchemeToView(targetView)
        animateViewAppearance(targetView, from: center, in: window)
        return true
    }

    private func passURLSchemeToView(_ view: UIView) {
        if let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
                decoratedVC.appSceneVC.openURLScheme(launchUrl)
            }
        }
    }

    private func animateViewAppearance(_ view: UIView, from center: CGPoint?, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false
        
        // when a fullscreen multitask app is brought to front, optionally hide other windows
        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized && !windowHostingView.automaticallyTilesWindows {
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC)
        }

        if isHidden && windowHostingView.automaticallyTilesWindows {
            view.layer.removeAllAnimations()
            bringViewToFront(view, in: window)
            if let decoratedVC, PiPManager.shared!.isPiP(withDecoratedVC: decoratedVC) {
                PiPManager.shared!.stopPiP()
            } else {
                view.transform = .identity
                view.alpha = 1
                view.isHidden = false
                windowHostingView.setNeedsGridLayout()
                windowHostingView.layoutIfNeeded()
            }
            return
        }
        
        if isHidden {
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            let origFrame = view.frame
            let pipManager = PiPManager.shared!
            if let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
            } else {
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                view.isHidden = false
                let smaller = min(view.frame.size.width, view.frame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
                if let center { view.center = center }
            }
            
            self.bringViewToFront(view, in: window)
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: .curveEaseInOut,
                animations: {
                    view.alpha = 1.0
                    view.transform = .identity
                    view.frame = origFrame
                },
                completion: { _ in
                    self.windowHostingView.setNeedsLayout()
                    self.windowHostingView.layoutIfNeeded()
                    self.collapseDockForGrid()
                }
            )
        } else {
            bringViewToFront(view, in: window)
            if decoratedVC?.isInGridLayout == true {
                collapseDockForGrid()
                return
            }
            
            UIView.animate(withDuration: Constants.shortAnimationDuration1, animations: {
                let scale = Constants.bringToFrontScale
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
            }) { _ in
                UIView.animate(withDuration: Constants.shortAnimationDuration2) {
                    view.transform = .identity
                }
            }
        }
    }

    private func bringViewToFront(_ view: UIView, in window: UIWindow) {
        if let superview = view.superview {
            superview.bringSubviewToFront(view)
        }
        if let windowSuperview = window.superview {
            windowSuperview.bringSubviewToFront(window)
        }
    }
    
    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        
        let appName = appInfo?.displayName() ?? "Unknown App"
        DispatchQueue.main.async {
            guard !self.apps.contains(where: { $0.appUUID == appUUID }) else { return }
            let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)
            self.apps.append(appModel)
            self.observeAccountMetadata()
            self.refreshAccountMetadata()
            
            if self.apps.count == 1 {
                self.showDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        DispatchQueue.main.async {
            self.apps.forEach { app in
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                   vc != except {
                    app.view?.layer.removeAllAnimations()
                    vc.minimizeWindow()
                }
            }
        }
    }
    
    @objc public func collapseDockForGrid() {
        DispatchQueue.main.async {
            guard self.windowHostingView.hasVisibleGridWindows, !self.isCollapsed else { return }
            self.isCollapsed = true
            self.notifyDockCollapseChanged()
        }
    }

    @objc public func gridLayoutDidChange() {
        // The host calls this during UIKit layout. Publish after that layout pass completes.
        DispatchQueue.main.async {
            let canAdjust = self.windowHostingView.canAdjustGridDividers
            if self.canAdjustGridDividers != canAdjust {
                self.canAdjustGridDividers = canAdjust
            }
            let adjusting = self.windowHostingView.isAdjustingGridDividers
            let choosingSwap = self.windowHostingView.isChoosingGridSwap
            let canUndoSwap = self.windowHostingView.canUndoGridSwap
            if self.canUndoGridSwap != canUndoSwap {
                self.canUndoGridSwap = canUndoSwap
            }
            guard self.isAdjustingGridDividers != adjusting || self.isChoosingGridSwap != choosingSwap else { return }
            self.isAdjustingGridDividers = adjusting
            self.isChoosingGridSwap = choosingSwap
            if adjusting || choosingSwap {
                self.isDockHidden = false
                self.isCollapsed = true
                self.notifyDockCollapseChanged()
            }
        }
    }

    @objc public func toggleDockCollapse() {
        DispatchQueue.main.async {
            self.isCollapsed.toggle()
            self.notifyDockCollapseChanged()
        }
    }
    
    @objc public func notifyDockCollapseChanged() {
        self.updateDockFrame()
        // find fullscreen apps and hide its UINavigationBar
        self.apps.forEach { app in
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
               vc.isMaximized, !vc.view.isHidden, vc.view.alpha > 0, !vc.appSceneVC.shouldIgnoreSceneUpdates {
                vc.updateVerticalConstraints()
            }
        }
    }
    
    // Toggle dock hide/show state
    @objc public func toggleDockVisibility() {
        DispatchQueue.main.async {
            self.windowHostingView.finishGridEditing()
            self.isDockHidden.toggle()
            self.updateDockFrame()
        }
    }
    
    @objc public func showDockFromHidden() {
        DispatchQueue.main.async {
            self.isDockHidden = false
            if let view = self.hostingController?.view { view.superview?.bringSubviewToFront(view) }
            self.updateDockFrame()
        }
    }
    
    @objc public func hideDockToSide() {
        DispatchQueue.main.async {
            self.windowHostingView.finishGridEditing()
            self.isDockHidden = true
            self.updateDockFrame()
        }
    }
    
    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

// MARK: - SwiftUI Dock View
@available(iOS 16.0, *)
public struct MultitaskDockSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager

    public var body: some View {
        let layout = dockManager.dockLayout
        Group {
            if dockManager.isDockHidden {
                Color.clear
            } else {
                VStack(spacing: LCDockLayout.spacing) {
                    dragHandle
                    if layout.compact {
                        if !dockManager.isCollapsed {
                            Menu {
                                DockAccountsMenu()
                                Divider()
                                DockGlobalActions()
                            } label: {
                                DockControlIcon(symbol: "rectangle.stack", color: .blue)
                            }
                            .accessibilityLabel("lc.dock.globalControls".loc)
                        } else {
                            Button {
                                if dockManager.isEditingGrid { dockManager.windowHostingView.finishGridEditing() }
                                else { dockManager.toggleDockCollapse() }
                            } label: {
                                DockControlIcon(symbol: dockManager.isChoosingGridSwap ? "xmark" :
                                                dockManager.isAdjustingGridDividers ? "checkmark" : "chevron.up",
                                                color: dockManager.isEditingGrid ? .orange : .blue)
                            }
                            .accessibilityLabel((dockManager.isChoosingGridSwap ? "lc.multitask.cancelGridSwap" :
                                dockManager.isAdjustingGridDividers ? "lc.multitask.doneAdjustingGrid" : "lc.multitask.showDock").loc)
                            .contextMenu { DockGlobalActions() }
                        }
                    } else {
                        Button { dockManager.toggleDockCollapse() } label: {
                            DockControlIcon(symbol: "chevron.down", color: .gray)
                        }
                        .accessibilityLabel("lc.dock.collapse".loc)
                        Menu { DockGlobalActions() } label: {
                            DockControlIcon(symbol: "ellipsis", color: .blue)
                        }
                        .accessibilityLabel("lc.dock.globalControls".loc)
                        ScrollView(.vertical, showsIndicators: layout.scrolls) {
                            VStack(spacing: LCDockLayout.spacing) {
                                ForEach(dockManager.apps) { app in AppIconView(app: app) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(height: layout.viewportHeight)
                        .scrollDisabled(!layout.scrolls)
                    }
                }
                .buttonStyle(.plain)
                .padding(LCDockLayout.padding)
                .modifier { content in
                    if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                        content.glassEffect(.regular, in: .rect(cornerRadius: 15))
                    } else {
                        content.background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 15))
                            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.25), lineWidth: 1))
                    }
                }
            }
        }
        .frame(width: layout.width, height: layout.height)
        .ignoresSafeArea()
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity)
            .frame(height: LCDockLayout.handleHeight)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { dockManager.dragDock(by: $0.translation) }
                .onEnded { _ in dockManager.finishDockDrag() })
            .accessibilityLabel("lc.dock.drag".loc)
            .accessibilityHint("lc.dock.dragHint".loc)
            .accessibilityAction(named: Text("lc.tapSync.moveTopLeft".loc)) { dockManager.moveDock(right: false, fraction: 0) }
            .accessibilityAction(named: Text("lc.tapSync.moveTopRight".loc)) { dockManager.moveDock(right: true, fraction: 0) }
            .accessibilityAction(named: Text("lc.tapSync.moveBottomLeft".loc)) { dockManager.moveDock(right: false, fraction: 1) }
            .accessibilityAction(named: Text("lc.tapSync.moveBottomRight".loc)) { dockManager.moveDock(right: true, fraction: 1) }
            .onDisappear { dockManager.finishDockDrag() }
            .id(dockManager.geometryRevision)
    }

    public init() {}
}

@available(iOS 16.0, *)
private struct DockControlIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: LCDockLayout.minimumHitSize)
            .background(color.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}

@available(iOS 16.0, *)
private struct DockAccountsMenu: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    var body: some View {
        ForEach(dockManager.apps) { app in
            Button(dockManager.accountTitle(forContainer: app.appUUID)) {
                _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID)
            }
        }
    }
}

@available(iOS 16.0, *)
private struct DockGlobalActions: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("LCDockShowAccountLabels", store: LCUtils.appGroupUserDefault) private var showsLabels = true
    @AppStorage("LCMultitaskOverlayMode", store: LCUtils.appGroupUserDefault) private var overlay = false

    var body: some View {
        Menu {
            DockGridActions()
        } label: {
            Label("lc.multitask.gridControls".loc, systemImage: "square.grid.2x2")
        }
        Menu {
            MultitaskTapSyncActions()
        } label: {
            Label("lc.tapSync.title".loc, systemImage: "hand.tap")
        }
        Menu {
            MultitaskPerformanceActions()
        } label: {
            Label("lc.performance.title".loc, systemImage: "gauge.with.dots.needle.33percent")
        }
        Menu {
            MultitaskWorkspaceActions()
        } label: {
            Label("lc.workspace.title".loc, systemImage: "folder")
        }
        Menu {
            Toggle("lc.dock.showAccountLabels".loc, isOn: $showsLabels)
            Toggle("lc.settings.multitaskOverlay".loc, isOn: $overlay)
            Menu {
                Button("lc.tapSync.moveTopLeft".loc) { dockManager.moveDock(right: false, fraction: 0) }
                Button("lc.tapSync.moveTopRight".loc) { dockManager.moveDock(right: true, fraction: 0) }
                Button("lc.tapSync.moveBottomLeft".loc) { dockManager.moveDock(right: false, fraction: 1) }
                Button("lc.tapSync.moveBottomRight".loc) { dockManager.moveDock(right: true, fraction: 1) }
                Button("lc.dock.resetPosition".loc) { dockManager.resetDockPosition() }
            } label: { Label("lc.dock.position".loc, systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
            Button { dockManager.hideDockToSide() } label: {
                Label("lc.dock.hide".loc, systemImage: "eye.slash")
            }
        } label: {
            Label("lc.dock.settings".loc, systemImage: "slider.horizontal.3")
        }
        Button { dockManager.minimizeAllWindows() } label: {
            Label("lc.multitask.minimizeAll".loc, systemImage: "rectangle.stack.badge.minus")
        }
    }
}

@available(iOS 16.0, *)
private struct DockGridActions: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("LCGridSingleRowInLandscape", store: LCUtils.appGroupUserDefault) private var singleRowInLandscape = false
    @AppStorage("LCGridReservePortraitTop", store: LCUtils.appGroupUserDefault) private var reservePortraitTop = true
    @AppStorage("LCGridReservePortraitBottom", store: LCUtils.appGroupUserDefault) private var reservePortraitBottom = false

    var body: some View {
        Button {
            perform { dockManager.windowHostingView.arrangeWindowsInGrid() }
        } label: {
            Label("lc.multitask.arrangeWindowsInGrid".loc, systemImage: "square.grid.2x2")
        }
        Picker(selection: $singleRowInLandscape) {
            Text("lc.multitask.landscapeLayout.automatic".loc).tag(false)
            Text("lc.multitask.landscapeLayout.singleRow".loc).tag(true)
        } label: {
            Label("lc.multitask.landscapeLayout".loc, systemImage: "rectangle.split.3x1")
        }
        .pickerStyle(.menu)
        Menu {
            Toggle("lc.multitask.reservePortraitTop".loc, isOn: $reservePortraitTop)
            Toggle("lc.multitask.reservePortraitBottom".loc, isOn: $reservePortraitBottom)
        } label: {
            Label("lc.multitask.portraitReservedAreas".loc, systemImage: "rectangle.portrait")
        }
        Button {
            perform { dockManager.windowHostingView.toggleGridDividerAdjustment() }
        } label: {
            Label((dockManager.isAdjustingGridDividers ? "lc.multitask.doneAdjustingGrid" : "lc.multitask.adjustGridDividers").loc,
                  systemImage: dockManager.isAdjustingGridDividers ? "checkmark" : "slider.horizontal.3")
        }
        .disabled(!dockManager.canAdjustGridDividers && !dockManager.isAdjustingGridDividers)
        Button {
            perform {
                if dockManager.isChoosingGridSwap {
                    dockManager.windowHostingView.cancelGridWindowSwap()
                } else {
                    dockManager.windowHostingView.beginGridWindowSwap()
                }
            }
        } label: {
            Label((dockManager.isChoosingGridSwap ? "lc.multitask.cancelGridSwap" : "lc.multitask.swapWindows").loc,
                  systemImage: dockManager.isChoosingGridSwap ? "xmark" : "arrow.left.arrow.right")
        }
        .disabled(!dockManager.canAdjustGridDividers && !dockManager.isChoosingGridSwap)
        Button {
            perform { dockManager.windowHostingView.resetGridProportions() }
        } label: {
            Label("lc.multitask.resetGridProportions".loc, systemImage: "arrow.counterclockwise")
        }
        .disabled(!dockManager.canAdjustGridDividers)
        Button {
            perform { dockManager.windowHostingView.undoLastGridWindowSwap() }
        } label: {
            Label("lc.multitask.undoGridSwap".loc, systemImage: "arrow.uturn.backward")
        }
        .disabled(!dockManager.canUndoGridSwap)
    }

    private func perform(_ action: () -> Void) {
        action()
        dockManager.settingsChanged.toggle()
        dockManager.collapseDockForGrid()
    }
}


// MARK: - Icon Cache Manager
class IconCacheManager {
    static let shared = IconCacheManager()
    private var cache: [String: UIImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache.queue", attributes: .concurrent)
    
    private init() {}
    
    func getIcon(for key: String) -> UIImage? {
        return cacheQueue.sync {
            return cache[key]
        }
    }
    
    func setIcon(_ icon: UIImage, for key: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache[key] = icon
        }
    }
    
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
}
// MARK: - App Icon View
@available(iOS 16.0, *)
struct AppIconView: View {
    @ObservedObject var app: DockAppModel
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @EnvironmentObject var dockManager: MultitaskDockManager
    @ObservedObject private var sharedModel = DataManager.shared.model
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    @AppStorage("LCDockShowAccountLabels", store: LCUtils.appGroupUserDefault) private var showsLabels = true
    
    private var iconSize: CGFloat {
        return dockManager.adaptiveIconSize
    }
    private var isIdentityHidden: Bool { app.appInfo?.isHidden == true && !sharedModel.isHiddenAppUnlocked }
    private var title: String { dockManager.accountTitle(forContainer: app.appUUID) }
    private var isSource: Bool { dockManager.sourceContainer == app.appUUID }
    
    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dockManager.windowHostingView.finishGridEditing()
            _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID)
            dockManager.collapseDockForGrid()
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if isIdentityHidden {
                            Image(systemName: "lock.fill").foregroundStyle(.white)
                        } else if isLoading && appIcon == nil {
                            LoadingIconView()
                        } else if let icon = appIcon {
                            IconImageView(icon: icon)
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(.gray.opacity(0.3))
                        }
                    }
                    .frame(width: iconSize, height: iconSize)
                    if !isIdentityHidden {
                        Text("\(app.accountNumber)")
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white).padding(.horizontal, 4).frame(minHeight: 18)
                            .background(.black.opacity(0.85), in: Capsule())
                    }
                }
                .frame(height: max(LCDockLayout.minimumHitSize, iconSize))
                .overlay(alignment: .topLeading) {
                    if isSource && !isIdentityHidden {
                        Image(systemName: "hand.point.up.left.fill").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white).padding(3).background(.blue, in: Circle())
                    }
                }
                if showsLabels {
                    Text(isIdentityHidden ? "lc.workspace.hiddenApp".loc : app.containerName.isEmpty ? app.appName : app.containerName)
                        .font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.white).frame(height: 16)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: dockManager.dockLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(DockIconButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isSource ? "lc.tapSync.source".loc : dockManager.targetContainers.contains(app.appUUID) ? "lc.tapSync.follower".loc : "")
        .accessibilityHint("lc.multitask.windowControlsHint".loc)
        .contextMenu {
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                DockWindowActions(app: app, windowController: vc)
            }
        }
        .animation(.easeInOut(duration: MultitaskDockManager.Constants.standardAnimationDuration), value: dockManager.settingsChanged)
        .onAppear {
            loadAppIcon()
        }
        .onChange(of: darkModeIcon) { _ in loadAppIcon() }
        .onChange(of: isIdentityHidden) { _ in loadAppIcon() }
    }
    
    private func loadAppIcon() {
        guard !isIdentityHidden else { appIcon = nil; isLoading = false; return }
        let wantsDarkIcon = darkModeIcon
        let cacheKey = "\(app.appInfo?.relativeBundlePath ?? app.appName)_\(wantsDarkIcon)"
        
        if let cachedIcon = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cachedIcon
            self.isLoading = false
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var finalIcon: UIImage?
            
            if let appInfo = self.app.appInfo {
                finalIcon = appInfo.iconIsDarkIcon(wantsDarkIcon)
            } else {
                if let foundAppInfo = AppInfoProvider.shared.findAppInfo(appName: self.app.appName, dataUUID: self.app.appUUID) {
                    finalIcon = foundAppInfo.iconIsDarkIcon(wantsDarkIcon)
                }
            }
            
            DispatchQueue.main.async {
                guard !self.isIdentityHidden else { self.appIcon = nil; self.isLoading = false; return }
                guard self.darkModeIcon == wantsDarkIcon else { return }
                self.isLoading = false
                if let icon = finalIcon {
                    self.appIcon = icon
                    IconCacheManager.shared.setIcon(icon, for: cacheKey)
                }
            }
        }
    }
}

private struct DockIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

@available(iOS 16.0, *)
private struct DockWindowActions: View {
    @ObservedObject var app: DockAppModel
    let windowController: DecoratedAppSceneViewController
    @EnvironmentObject var dockManager: MultitaskDockManager

    var body: some View {
        let vc = windowController
        let isHidden = vc.view.isHidden || vc.view.alpha < 0.1 || vc.appSceneVC.shouldIgnoreSceneUpdates
        Text(dockManager.accountTitle(forContainer: app.appUUID))
        if isHidden {
            Button {
                perform { _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID) }
            } label: {
                Label("lc.multitask.restoreWindow".loc, systemImage: "arrow.up.forward.app")
            }
        } else {
            Button {
                perform {
                    vc.view.superview?.bringSubviewToFront(vc.view)
                    vc.maximizeWindow()
                }
            } label: {
                Label((vc.isMaximized ? "lc.multitask.restoreWindow" : "lc.multitask.maximizeWindow").loc,
                      systemImage: vc.isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            Button {
                perform { vc.minimizeWindow() }
            } label: {
                Label("lc.multitask.minimizeWindow".loc, systemImage: "minus.circle")
            }
        }
        if vc.appSceneVC.isAppRunning {
            if !isHidden {
                Button {
                    perform { vc.togglePictureInPicture() }
                } label: {
                    Label("lc.multitask.enablePip".loc, systemImage: "pip.enter")
                }
                Menu {
                    ForEach([50, 75, 100, 125, 150, 175, 200], id: \.self) { percent in
                        Button {
                            perform { vc.updateContentScale(CGFloat(percent) / 100) }
                        } label: {
                            if abs(vc.scaleRatio - CGFloat(percent) / 100) < 0.01 {
                                Label("\(percent)%", systemImage: "checkmark")
                            } else {
                                Text("\(percent)%")
                            }
                        }
                    }
                } label: {
                    Label("lc.multitask.scale".loc, systemImage: "textformat.size")
                }
            }
        }
        if vc.appSceneVC.isAppRunning {
            MultitaskTapSyncWindowActions(container: app.appUUID)
            Menu {
                Button {
                    UIPasteboard.general.string = String(vc.appSceneVC.pid)
                } label: { Label("lc.multitask.copyPid".loc, systemImage: "doc.on.doc") }
            } label: { Label("lc.dock.diagnostics".loc, systemImage: "wrench.and.screwdriver") }
        }
        Divider()
        Button(role: .destructive) {
            perform {
                if PiPManager.shared!.isPiP(withDecoratedVC: vc) {
                    PiPManager.shared!.stopPiP()
                }
                vc.closeWindow()
            }
        } label: {
            Label("lc.common.close".loc, systemImage: "xmark.circle")
        }
    }

    private func perform(_ action: () -> Void) {
        action()
        dockManager.settingsChanged.toggle()
        dockManager.collapseDockForGrid()
    }
}

// MARK: - Loading Icon View
struct LoadingIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
        }
    }
}
