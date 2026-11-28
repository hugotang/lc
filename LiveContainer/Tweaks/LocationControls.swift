import SwiftUI
import UIKit

@MainActor
final class LCLocationControlModel: ObservableObject {
    let session: LCLocationSession
    @Published var snapshot: [AnyHashable: Any] = [:]
    @Published var favorites: [[AnyHashable: Any]] = []
    @Published var moving = false
    @Published var error: String?
    @Published var speed = 1.4
    weak var joystick: LCLocationJoystickControl?
    private var observer: NSObjectProtocol?

    init(_ session: LCLocationSession) {
        self.session = session
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .LCLocationSessionDidChange, object: session, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func refresh() {
        snapshot = session.snapshot; favorites = session.favorites; moving = session.moving; error = session.error
    }
    var point: LCLocationPoint? { LCLocationPoint(snapshot) }
    var enabled: Bool { snapshot["enabled"] as? Bool == true }
    func stopJoystick() {
        joystick?.cancelTracking(with: nil)
        session.stopMoving()
    }
}

private struct LCLocationControlsView: View {
    @ObservedObject var model: LCLocationControlModel
    @State private var restoring = false
    let select: () -> Void
    let collapse: () -> Void
    let joystick: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("lc.location.title".lcLocationText, systemImage: "location.fill").font(.headline)
                    Spacer()
                    Button(action: collapse) { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                        .accessibilityLabel("lc.location.collapse".lcLocationText)
                        .accessibilityIdentifier("location.collapse")
                }
                Text(model.session.title).font(.headline).lineLimit(2)
                Text("lc.location.allAccounts".lcLocationText).font(.caption).foregroundStyle(.secondary)
                if let point = model.point {
                    if !point.name.isEmpty { Text(point.name).lineLimit(2) }
                    Text(point.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("location.liveCoordinate")
                }
                Text((model.enabled ? (model.moving ? "lc.location.moving" : "lc.location.stationary") : "lc.location.realLocation").lcLocationText)
                    .font(.callout).foregroundStyle(model.moving ? Color.blue : Color.secondary)
                    .accessibilityIdentifier("location.motionStatus")
                if let error = model.error { Text(error.lcLocationText).font(.caption).foregroundStyle(.red) }
                Button(action: select) { Label("lc.location.change".lcLocationText, systemImage: "map") }
                    .accessibilityIdentifier("location.liveChoose")
                if model.point != nil {
                    HStack {
                        Menu {
                            ForEach(Array(model.favorites.enumerated()), id: \.offset) { index, value in
                                if let point = LCLocationPoint(value) {
                                    Button(point.name.isEmpty ? point.text : point.name) { _ = model.session.select(point: value, enabled: true) }
                                }
                            }
                            Divider()
                            Button("lc.location.addFavorite".lcLocationText) { model.session.addFavorite() }
                            if !model.favorites.isEmpty {
                                Menu("lc.location.removeFavorite".lcLocationText) {
                                    ForEach(Array(model.favorites.enumerated()), id: \.offset) { index, value in
                                        if let point = LCLocationPoint(value) {
                                            Button(point.name.isEmpty ? point.text : point.name, role: .destructive) { model.session.removeFavorite(at: UInt(index)) }
                                        }
                                    }
                                }
                            }
                        } label: { Label("lc.location.favorites".lcLocationText, systemImage: "star") }
                        .accessibilityIdentifier("location.favorites")
                        Spacer()
                        Button(action: joystick) { Label("lc.location.joystick".lcLocationText, systemImage: "gamecontroller") }
                        .disabled(!model.enabled).accessibilityIdentifier("location.joystickToggle")
                    }
                }
                if model.point != nil {
                    Button {
                        model.session.stopMoving()
                        if model.enabled { restoring = true } else { _ = model.session.setEnabled(true) }
                    } label: {
                        Label((model.enabled ? "lc.location.restoreReal" : "lc.location.enable").lcLocationText,
                              systemImage: model.enabled ? "location.slash" : "location.fill")
                    }.accessibilityIdentifier("location.restoreReal")
                }
            }.padding()
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .confirmationDialog("lc.location.restoreRealConfirm".lcLocationText, isPresented: $restoring, titleVisibility: .visible) {
            Button("lc.location.restoreReal".lcLocationText, role: .destructive) { _ = model.session.setEnabled(false) }
                .accessibilityIdentifier("location.confirmRestoreReal")
            Button("lc.common.cancel".lcLocationText, role: .cancel) {}
        }
        .onDisappear { model.session.stopMoving() }
    }
}

private struct LCLocationCompactJoystickView: View {
    @ObservedObject var model: LCLocationControlModel
    let settings: () -> Void
    let collapse: () -> Void
    let drag: (CGPoint, UIGestureRecognizer.State) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LCLocationDragHandle(drag: drag).frame(width: 44, height: 44)
                Spacer(minLength: 0)
                Button(action: settings) { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                    .accessibilityLabel("lc.location.controls".lcLocationText)
                    .accessibilityIdentifier("location.joystickSettings")
                Button(action: collapse) { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .accessibilityLabel("lc.location.collapse".lcLocationText)
                    .accessibilityIdentifier("location.collapse")
            }
            LCLocationJoystick(model: model)
            .frame(width: 140, height: 140)
            .accessibilityValue(model.point?.text ?? "")
            HStack(spacing: 0) {
                Menu {
                    Button("lc.location.walk".lcLocationText) { setSpeed(1.4) }
                    Button("lc.location.run".lcLocationText) { setSpeed(3) }
                    Button("lc.location.cycle".lcLocationText) { setSpeed(6) }
                } label: {
                    Label(String(format: "%g m/s", model.speed), systemImage: model.speed == 6 ? "bicycle" : "figure.walk")
                        .font(.caption).frame(minHeight: 44)
                }
                .accessibilityLabel("lc.location.speed".lcLocationText)
                .accessibilityIdentifier("location.joystickSpeed")
                Spacer(minLength: 0)
                Button { model.stopJoystick() } label: {
                    Image(systemName: "stop.fill").frame(width: 44, height: 44)
                }
                .disabled(!model.moving)
                .accessibilityLabel("lc.location.stopMoving".lcLocationText)
                .accessibilityIdentifier("location.stopMoving")
            }
        }
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("lc.location.joystick".lcLocationText + ": " + model.session.title)
        .accessibilityIdentifier("location.compactJoystick")
        .onDisappear { model.session.stopMoving() }
        .onChange(of: model.enabled) { enabled in if !enabled { settings() } }
        .onChange(of: model.error) { error in if error != nil { settings() } }
    }
    private func setSpeed(_ value: Double) { model.stopJoystick(); model.speed = value }
}

private struct LCLocationDragHandle: UIViewRepresentable {
    let drag: (CGPoint, UIGestureRecognizer.State) -> Void
    final class Coordinator: NSObject {
        var drag: (CGPoint, UIGestureRecognizer.State) -> Void
        init(_ drag: @escaping (CGPoint, UIGestureRecognizer.State) -> Void) { self.drag = drag }
        @objc func moved(_ gesture: UIPanGestureRecognizer) {
            drag(gesture.translation(in: gesture.view?.window), gesture.state)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(drag) }
    func makeUIView(context: Context) -> UIButton {
        let handle = UIButton(type: .system)
        handle.setImage(UIImage(systemName: "line.3.horizontal"), for: .normal)
        handle.accessibilityLabel = "lc.location.moveControls".lcLocationText
        handle.accessibilityIdentifier = "location.joystickDrag"
        handle.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.moved(_:))))
        return handle
    }
    func updateUIView(_ view: UIButton, context: Context) { context.coordinator.drag = drag }
}

// UIControl owns the touch from begin through cancel. This gives release,
// interruption and accessibility activation the same explicit stop path.
struct LCLocationJoystick: UIViewRepresentable {
    let model: LCLocationControlModel
    func makeUIView(context: Context) -> LCLocationJoystickControl {
        let control = LCLocationJoystickControl()
        model.joystick = control
        control.move = { [weak model] east, north in
            guard let model else { return }
            model.session.move(east: east, north: north, speed: model.speed)
        }
        control.stop = { [weak model] in model?.session.stopMoving() }
        return control
    }
    func updateUIView(_ control: LCLocationJoystickControl, context: Context) {}
    static func dismantleUIView(_ control: LCLocationJoystickControl, coordinator: ()) { control.cancelTracking(with: nil) }
}

final class LCLocationJoystickControl: UIControl {
    var move: ((Double, Double) -> Void)?
    var stop: (() -> Void)?
    private let knob = UIView()
    private let compass = UILabel()
    private var trackingCancelled = false
    private var pendingStep: DispatchWorkItem?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill; layer.cornerRadius = 74
        knob.backgroundColor = .systemBlue; knob.isUserInteractionEnabled = false; knob.layer.cornerRadius = 22
        compass.text = "N"; compass.font = .preferredFont(forTextStyle: .caption1); compass.textAlignment = .center
        addSubview(compass); addSubview(knob)
        accessibilityIdentifier = "location.joystick"
        isAccessibilityElement = true
        accessibilityLabel = "lc.location.joystick".lcLocationText
        accessibilityHint = "lc.location.holdToMove".lcLocationText
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "lc.location.stepNorth".lcLocationText, target: self, selector: #selector(north)),
            UIAccessibilityCustomAction(name: "lc.location.stepSouth".lcLocationText, target: self, selector: #selector(south)),
            UIAccessibilityCustomAction(name: "lc.location.stepEast".lcLocationText, target: self, selector: #selector(east)),
            UIAccessibilityCustomAction(name: "lc.location.stepWest".lcLocationText, target: self, selector: #selector(west))
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews(); layer.cornerRadius = bounds.width / 2
        compass.frame = CGRect(x: 0, y: 4, width: bounds.width, height: 20)
        if !isTracking { knob.frame = CGRect(x: bounds.midX - 22, y: bounds.midY - 22, width: 44, height: 44) }
    }
    private func update(_ touch: UITouch) {
        let location = touch.location(in: self), radius = max(1, bounds.width / 2 - 24)
        var dx = (location.x - bounds.midX) / radius, dy = (bounds.midY - location.y) / radius
        let magnitude = max(1, hypot(dx, dy)); dx /= magnitude; dy /= magnitude
        knob.center = CGPoint(x: bounds.midX + dx * radius, y: bounds.midY - dy * radius)
        move?(Double(dx), Double(dy))
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        pendingStep?.cancel(); pendingStep = nil; trackingCancelled = false
        update(touch); return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard !trackingCancelled else { return false }
        update(touch); return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { finish() }
    override func cancelTracking(with event: UIEvent?) { super.cancelTracking(with: event); finish() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { finish() } }
    private func finish() {
        pendingStep?.cancel(); pendingStep = nil; trackingCancelled = true
        stop?(); knob.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    private func step(_ east: Double, _ north: Double) -> Bool {
        pendingStep?.cancel()
        move?(east, north)
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        pendingStep = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
        return true
    }
    @objc private func north() -> Bool { step(0, 1) }
    @objc private func south() -> Bool { step(0, -1) }
    @objc private func east() -> Bool { step(1, 0) }
    @objc private func west() -> Bool { step(-1, 0) }
}

private final class LCLocationPassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event); return hit === self ? nil : hit
    }
}
private final class LCLocationOverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // iPad can insert a full-window UIKit container above the root view.
        // Gate touches by our visible controls before asking that hierarchy.
        if let controller = rootViewController as? LCLocationOverlayController,
           controller.presentedViewController == nil {
            let local = controller.view.convert(point, from: self)
            let inButton = !controller.button.isHidden && controller.button.frame.contains(local)
            let inPanel = controller.panel?.view.frame.contains(local) == true
            if !inButton && !inPanel { return nil }
        }
        let hit = super.hitTest(point, with: event); return hit === self ? nil : hit
    }
}

@MainActor
private final class LCLocationOverlayController: UIViewController, UIAdaptivePresentationControllerDelegate {
    let session: LCLocationSession
    let model: LCLocationControlModel
    let button = UIButton(type: .system)
    var panel: UIViewController?
    var expanded = false
    var compact = false
    var anchor = CGPoint(x: 1, y: 0.65)
    private var compactAnchor = CGPoint(x: 0, y: 0.8)
    private var dragStart = CGPoint.zero
    private var lastQuickControl: Bool
    weak var previousKeyWindow: UIWindow?
    var tokens: [NSObjectProtocol] = []
    init(_ session: LCLocationSession) {
        self.session = session; model = LCLocationControlModel(session)
        lastQuickControl = session.quickControlEnabled
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = LCLocationPassThroughView(); view.backgroundColor = .clear }
    override func viewDidLoad() {
        super.viewDidLoad()
        button.setImage(UIImage(systemName: "location.fill"), for: .normal)
        button.backgroundColor = .secondarySystemBackground; button.layer.cornerRadius = 24
        button.accessibilityLabel = "lc.location.title".lcLocationText + ": " + session.title
        button.accessibilityIdentifier = "location.quickControl"
        button.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        view.addSubview(button)
        tokens.append(NotificationCenter.default.addObserver(forName: .LCLocationSessionDidChange, object: session, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.lastQuickControl != self.session.quickControlEnabled else { return }
                self.lastQuickControl = self.session.quickControlEnabled
                if !self.lastQuickControl { LCLocationUI.hideControls(for: self.session) }
            }
        })
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let scene = note.object as? UIScene, scene !== self.view.window?.windowScene { return }
                    self.collapse()
                }
            })
        }
    }
    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 8, dy: 8)
        button.frame = CGRect(x: safe.minX + max(0, safe.width - 48) * anchor.x,
                              y: safe.minY + max(0, safe.height - 48) * anchor.y, width: 48, height: 48)
        let size = CGSize(width: min(compact ? 184 : 340, safe.width), height: min(compact ? 228 : 430, safe.height))
        if compact {
            panel?.view.frame = CGRect(x: safe.minX + max(0, safe.width - size.width) * compactAnchor.x,
                                      y: safe.minY + max(0, safe.height - size.height) * compactAnchor.y,
                                      width: size.width, height: size.height)
        } else {
            panel?.view.frame = CGRect(x: anchor.x > 0.5 ? safe.maxX - size.width : safe.minX,
                                      y: min(max(safe.minY, button.frame.midY - size.height / 2), safe.maxY - size.height),
                                      width: size.width, height: size.height)
        }
    }
    @objc func drag(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let point = gesture.location(in: view), safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 32, dy: 32)
        anchor = CGPoint(x: min(1, max(0, (point.x - safe.minX) / max(1, safe.width))),
                         y: min(1, max(0, (point.y - safe.minY) / max(1, safe.height))))
        view.setNeedsLayout()
    }
    @objc func toggle() { expanded ? collapse() : expand() }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        collapse(); super.viewWillTransition(to: size, with: coordinator)
    }
    func expand() {
        guard !expanded || compact else { return }
        session.stopMoving(); removePanel(); expanded = true; compact = false; button.isHidden = true; session.refresh()
        NotificationCenter.default.post(name: NSNotification.Name("LCLocationControlsWillExpand"), object: session)
        let controller = UIHostingController(rootView: LCLocationControlsView(model: model, select: { [weak self] in self?.choose() }, collapse: { [weak self] in self?.collapse() }, joystick: { [weak self] in self?.showJoystick() }))
        installPanel(controller)
    }
    private func showJoystick() {
        session.stopMoving(); session.refresh(); model.refresh()
        guard model.enabled else { return }
        removePanel(); compact = true; expanded = true; button.isHidden = true
        let controller = UIHostingController(rootView: LCLocationCompactJoystickView(model: model,
            settings: { [weak self] in self?.expand() }, collapse: { [weak self] in self?.collapse() },
            drag: { [weak self] translation, state in self?.dragJoystick(translation, state: state) }))
        installPanel(controller)
    }
    private func installPanel(_ controller: UIViewController) {
        controller.view.backgroundColor = .clear; addChild(controller); view.addSubview(controller.view); controller.didMove(toParent: self)
        panel = controller; view.setNeedsLayout()
    }
    private func dragJoystick(_ translation: CGPoint, state: UIGestureRecognizer.State) {
        guard let panel else { return }
        if state == .began { model.stopJoystick(); dragStart = panel.view.frame.origin }
        guard state == .began || state == .changed || state == .ended else { return }
        let safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 8, dy: 8)
        compactAnchor = CGPoint(x: min(1, max(0, (dragStart.x + translation.x - safe.minX) / max(1, safe.width - panel.view.frame.width))),
                                y: min(1, max(0, (dragStart.y + translation.y - safe.minY) / max(1, safe.height - panel.view.frame.height))))
        view.setNeedsLayout()
    }
    private func removePanel() {
        panel?.willMove(toParent: nil); panel?.view.removeFromSuperview(); panel?.removeFromParent(); panel = nil
    }
    func collapse() {
        session.stopMoving(); expanded = false; compact = false
        if presentedViewController != nil { dismiss(animated: false); restoreKeyWindow() }
        removePanel()
        button.isHidden = !session.quickControlEnabled
        view.window?.isHidden = !session.quickControlEnabled
    }
    func choose() {
        session.stopMoving()
        let picker = LCLocationUI.picker(withInitial: session.snapshot, completion: { [weak self] point in
            _ = self?.session.select(point: point, enabled: true)
        }, dismissal: nil)
        previousKeyWindow = view.window?.windowScene?.windows.first { $0.isKeyWindow && $0 !== self.view.window }
        view.window?.makeKey()
        present(picker, animated: true)
        picker.presentationController?.delegate = self
        if let controller = picker as? LCLocationPickerController { controller.closed = { [weak self] in self?.restoreKeyWindow() } }
    }
    func restoreKeyWindow() { previousKeyWindow?.makeKey(); previousKeyWindow = nil }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { restoreKeyWindow() }
}

private final class LCLocationPickerController: UIHostingController<LCLocationPickerView> {
    var closed: (() -> Void)?
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if presentingViewController == nil { closed?() } }
}

@objc(LCLocationUI)
@MainActor public final class LCLocationUI: NSObject {
    private static var windows: [String: LCLocationOverlayWindow] = [:]
    private static var guestTokens: [NSObjectProtocol] = []
    private static var guestSessions = Set<String>()
    private static var disconnectToken: NSObjectProtocol?
    @objc(pickerWithInitial:completion:dismissal:)
    public static func picker(withInitial initial: [AnyHashable: Any], completion: @escaping ([AnyHashable: Any]) -> Void,
                              dismissal: (() -> Void)?) -> UIViewController {
        weak var presented: UIViewController?
        let controller = LCLocationPickerController(rootView: LCLocationPickerView(initial: LCLocationPoint(initial), initialEnabled: initial["enabled"] as? Bool == true, close: {
            if let dismissal { dismissal() } else { presented?.dismiss(animated: true) }
        }) { completion($0.settings(enabled: true)) })
        presented = controller
        return controller
    }
    @objc(showControlsForSession:inScene:)
    public static func showControls(for session: LCLocationSession, in scene: UIWindowScene) {
        showShortcut(for: session, in: scene)
        let key = session.bundlePath + ":" + scene.session.persistentIdentifier
        (windows[key]?.rootViewController as? LCLocationOverlayController)?.expand()
    }
    @objc(synchronizeShortcutForSession:inScene:)
    public static func synchronizeShortcut(for session: LCLocationSession, in scene: UIWindowScene) {
        if session.quickControlEnabled { showShortcut(for: session, in: scene) }
        else {
            // A settings-page appearance only reconciles its own scene.
            // Preference changes use hideControls to close every scene.
            for key in Array(windows.keys) where windows[key]?.windowScene === scene { removeWindow(key) }
        }
    }
    @objc(showShortcutForSession:inScene:)
    public static func showShortcut(for session: LCLocationSession, in scene: UIWindowScene) {
        if disconnectToken == nil {
            disconnectToken = NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
                DispatchQueue.main.async {
                    guard let scene = note.object as? UIWindowScene else { return }
                    for key in Array(windows.keys) where windows[key]?.windowScene === scene { removeWindow(key) }
                }
            }
        }
        // One location control per scene keeps shortcuts and panels from
        // overlapping when switching between apps in the virtual workspace.
        for other in Array(windows.keys) where windows[other]?.windowScene === scene &&
            (windows[other]?.rootViewController as? LCLocationOverlayController)?.session !== session { removeWindow(other) }
        let key = session.bundlePath + ":" + scene.session.persistentIdentifier
        if let window = windows[key] {
            window.isHidden = false
            if let controller = window.rootViewController as? LCLocationOverlayController, !controller.expanded { controller.button.isHidden = false }
            return
        }
        let window = LCLocationOverlayWindow(windowScene: scene)
        window.windowLevel = .normal + 5
        window.rootViewController = LCLocationOverlayController(session)
        window.backgroundColor = .clear; window.isHidden = false; windows[key] = window
    }
    private static func removeWindow(_ key: String) {
        (windows[key]?.rootViewController as? LCLocationOverlayController)?.collapse()
        windows[key]?.isHidden = true; windows[key]?.windowScene = nil; windows[key] = nil
    }
    @objc(hideControlsForSession:)
    public static func hideControls(for session: LCLocationSession) {
        for key in Array(windows.keys) where key.hasPrefix(session.bundlePath + ":") {
            removeWindow(key)
        }
    }
    @objc(installGuestControlsForSession:)
    public static func installGuestControls(for session: LCLocationSession) {
        guard guestSessions.insert(session.bundlePath).inserted else { return }
        var lastQuickControl = session.quickControlEnabled
        let update: @MainActor () -> Void = {
            guard session.quickControlEnabled else { hideControls(for: session); return }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
                synchronizeShortcut(for: session, in: scene)
            }
        }
        guestTokens.append(NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { update() }
        })
        guestTokens.append(NotificationCenter.default.addObserver(forName: .LCLocationSessionDidChange, object: session, queue: .main) { _ in
            DispatchQueue.main.async {
                guard lastQuickControl != session.quickControlEnabled else { return }
                lastQuickControl = session.quickControlEnabled; update()
            }
        })
        update()
    }
}
