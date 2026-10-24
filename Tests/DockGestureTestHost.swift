import SwiftUI
import WebKit

// A normal SwiftUI host isolates real Button/contextMenu/ScrollView arbitration
// around the production native gesture, without the game's private scene APIs.
@MainActor
private final class DockGestureFixture: ObservableObject {
    @Published var hidden = false
    @Published var taps = 0
    @Published var handleMoves = 0
    @Published var contextActions = 0
    @Published var hiddenDuringTouch = false
    @Published var gestureTrace = "No touch yet"
    @Published var revealTrace = "No reveal events"
    @Published var guestCount = 1
    @Published var guestDrags = 0
    @Published var guestTaps = 0
    @Published var reveals = 0
    @Published var guestsMinimized = false
    @Published var webGuestsReady = 0
    let right: Bool
    let width: CGFloat
    @Published var hideArrow: Bool
    let webGuests: Bool
    let hideGesture = LCDockDiagnosticHideGesture()
    let revealControl = LCDockDiagnosticRevealControl()
    weak var window: UIWindow?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        right = !arguments.contains("--left")
        width = arguments.contains("--narrow") ? 56 : 80
        hideArrow = arguments.contains("--hide-arrow")
        webGuests = arguments.contains("--web-guests")
        guestCount = arguments.contains("--restore-four") ? 4 : 1
    }

    func attach(to view: UIView) {
        hideGesture.attach(to: view, ignoredTopHeight: LCDockLayout.padding + LCDockLayout.handleHeight,
                           right: right) { [weak self, weak view] in
            let phase = (view?.window as? DockGestureTestWindow)?.lastTouchPhase
            let stillTouching = phase == .began || phase == .moved || phase == .stationary
            // Match the production manager's deferred hide/removal after UIKit
            // has recognized and cancelled the pressed SwiftUI control.
            DispatchQueue.main.async {
                self?.hideDock(duringTouch: stillTouching)
            }
        }
    }

    func hideDock(duringTouch: Bool = false) {
        hidden = true
        hiddenDuringTouch = duringTouch
        hideGesture.detach()
        refreshReveal()
    }

    func showDock() {
        revealControl.hide()
        hidden = false
    }

    func refreshReveal() {
        guard hidden, let window else { return }
        let insets = window.safeAreaInsets
        let placement = LCDockPlacement(right: right)
        let frame = placement.revealFrame(bounds: window.bounds,
            insets: LCDockInsets(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right))
        revealControl.accessibilityLabel = "Show Dock from Edge"
        revealControl.show(in: window, frame: frame, right: right, hideArrow: hideArrow) { [weak self] in
            DispatchQueue.main.async {
                self?.reveals += 1
                self?.showDock()
            }
        }
    }

    func restoreWorkspace() {
        guestCount = 4
        // Account restoration and host layout can refresh the hidden control
        // repeatedly. Exercise the same production show/update path.
        for _ in 0..<4 { refreshReveal() }
    }

    func setGuestsMinimized(_ minimized: Bool) {
        guestsMinimized = minimized
        refreshReveal()
    }

    func toggleArrow() {
        hideArrow.toggle()
        refreshReveal()
    }
}

// Ordinary guest-like views deliberately include pans that cancel controls.
// These cannot reproduce private remote-scene event deferring on a real iPad.
@MainActor
private final class FixtureGuestsController: UIViewController {
    weak var fixture: DockGestureFixture?
    private var guests: [UIButton] = []

    func updateGuests() {
        guard let fixture else { return }
        while guests.count < fixture.guestCount {
            let index = guests.count
            let guest = UIButton(type: .custom)
            guest.backgroundColor = index % 2 == 0 ? .systemGray5 : .systemGray4
            guest.setTitle("Guest \(index + 1)", for: .normal)
            guest.setTitleColor(.darkGray, for: .normal)
            guest.accessibilityIdentifier = "FixtureGuest\(index)"
            guest.addTarget(self, action: #selector(tapGuest), for: .touchUpInside)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(dragGuest(_:)))
            guest.addGestureRecognizer(pan)
            view.addSubview(guest)
            guests.append(guest)
        }
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for (index, guest) in guests.enumerated() {
            let columns = guests.count > 1 ? 2 : 1
            let rows = guests.count > 2 ? 2 : 1
            let size = CGSize(width: view.bounds.width / CGFloat(columns), height: view.bounds.height / CGFloat(rows))
            guest.frame = CGRect(x: CGFloat(index % columns) * size.width,
                                 y: CGFloat(index / columns) * size.height, width: size.width, height: size.height)
        }
    }

    @objc private func tapGuest() { fixture?.guestTaps += 1 }
    @objc private func dragGuest(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { fixture?.guestDrags += 1 }
    }
}

private struct FixtureGuestsHost: UIViewControllerRepresentable {
    @ObservedObject var fixture: DockGestureFixture

    func makeUIViewController(context: Context) -> FixtureGuestsController {
        let controller = FixtureGuestsController()
        controller.fixture = fixture
        controller.updateGuests()
        return controller
    }

    func updateUIViewController(_ controller: FixtureGuestsController, context: Context) {
        controller.updateGuests()
    }
}

// WebKit adds real out-of-process rendered content below the host control.
// Its host-side input transport differs from the game's private scene hosting;
// this is additional coverage, not a reproduction of Monster Strike on iPad.
@MainActor
private final class FixtureWebGuestsController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    weak var fixture: DockGestureFixture?
    private var guests: [WKWebView] = []

    func updateGuests() {
        guard let fixture else { return }
        while guests.count < fixture.guestCount {
            let index = guests.count
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(self, name: "guestInput")
            let guest = WKWebView(frame: .zero, configuration: configuration)
            guest.navigationDelegate = self
            guest.accessibilityIdentifier = "FixtureWebGuest\(index)"
            guests.append(guest)
            view.addSubview(guest)
            guest.loadHTMLString("""
                <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
                <style>body{margin:0;background:#ddd;font:24px system-ui}div{height:300vh;padding:32px;box-sizing:border-box}</style>
                <div>Guest \(index + 1)</div><script>
                let start=null, dragged=false;
                document.addEventListener('touchstart',event=>{
                    start=[event.touches[0].clientX,event.touches[0].clientY]; dragged=false;
                },{passive:true});
                document.addEventListener('touchmove',event=>{
                    if(start&&!dragged&&Math.hypot(event.touches[0].clientX-start[0],event.touches[0].clientY-start[1])>=6){
                        dragged=true;window.webkit.messageHandlers.guestInput.postMessage('drag');
                    }
                },{passive:true});
                document.addEventListener('touchend',()=>{
                    if(start&&!dragged)window.webkit.messageHandlers.guestInput.postMessage('tap');start=null;
                },{passive:true});
                document.addEventListener('touchcancel',()=>{start=null;},{passive:true});
                </script>
                """, baseURL: nil)
        }
        guests.forEach { $0.isHidden = fixture.guestsMinimized }
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for (index, guest) in guests.enumerated() {
            let columns = guests.count > 1 ? 2 : 1
            let rows = guests.count > 2 ? 2 : 1
            let size = CGSize(width: view.bounds.width / CGFloat(columns), height: view.bounds.height / CGFloat(rows))
            guest.frame = CGRect(x: CGFloat(index % columns) * size.width,
                                 y: CGFloat(index / columns) * size.height, width: size.width, height: size.height)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { fixture?.webGuestsReady += 1 }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.body as? String == "tap" { fixture?.guestTaps += 1 }
        if message.body as? String == "drag" { fixture?.guestDrags += 1 }
    }

    func disconnectGuests() {
        for guest in guests {
            guest.stopLoading()
            guest.configuration.userContentController.removeScriptMessageHandler(forName: "guestInput")
            guest.navigationDelegate = nil
        }
    }
}

private struct FixtureWebGuestsHost: UIViewControllerRepresentable {
    @ObservedObject var fixture: DockGestureFixture

    func makeUIViewController(context: Context) -> FixtureWebGuestsController {
        let controller = FixtureWebGuestsController()
        controller.fixture = fixture
        controller.updateGuests()
        return controller
    }

    func updateUIViewController(_ controller: FixtureWebGuestsController, context: Context) { controller.updateGuests() }

    static func dismantleUIViewController(_ controller: FixtureWebGuestsController, coordinator: ()) { controller.disconnectGuests() }
}

private struct FixtureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct FixtureDock: View {
    @ObservedObject var fixture: DockGestureFixture

    var body: some View {
        VStack(spacing: LCDockLayout.spacing) {
            Image(systemName: "line.3.horizontal")
                .frame(maxWidth: .infinity)
                .frame(height: LCDockLayout.handleHeight)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { _ in fixture.handleMoves += 1 })
                .accessibilityIdentifier("DockHandle")
            Button { fixture.taps += 1 } label: {
                Text("Collapse").frame(maxWidth: .infinity).frame(height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("DockCollapse")
            Menu {
                Button("Layout") { fixture.contextActions += 1 }
            } label: {
                Image(systemName: "ellipsis").frame(maxWidth: .infinity).frame(height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("DockMenu")
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: LCDockLayout.spacing) {
                    ForEach(0..<20) { index in
                        Button { fixture.taps += 1 } label: {
                            Text("Account \(index)").frame(maxWidth: .infinity).frame(height: 78)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(FixtureButtonStyle())
                        .accessibilityIdentifier("DockAccount\(index)")
                        .contextMenu {
                            Button("Window action") { fixture.contextActions += 1 }
                                .accessibilityIdentifier("DockContextAction")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 260)
        }
        .buttonStyle(.plain)
        .padding(LCDockLayout.padding)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 15))
        .foregroundStyle(.white)
        .frame(width: fixture.width, height: 428)
        .ignoresSafeArea()
    }
}

private struct FixtureDockHost: UIViewControllerRepresentable {
    @ObservedObject var fixture: DockGestureFixture

    func makeUIViewController(context: Context) -> UIHostingController<FixtureDock> {
        let controller = UIHostingController(rootView: FixtureDock(fixture: fixture))
        controller.view.backgroundColor = .clear
        fixture.attach(to: controller.view)
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<FixtureDock>, context: Context) {
        controller.view.isUserInteractionEnabled = !fixture.hidden
    }

    static func dismantleUIViewController(_ controller: UIHostingController<FixtureDock>, coordinator: ()) {
        for gesture in controller.view.gestureRecognizers ?? [] where gesture is LCDockHideGesture {
            (gesture as? LCDockHideGesture)?.detach()
        }
    }
}

private struct DockGestureTestRoot: View {
    @ObservedObject var fixture: DockGestureFixture

    var body: some View {
        ZStack(alignment: fixture.right ? .trailing : .leading) {
            if fixture.webGuests {
                FixtureWebGuestsHost(fixture: fixture).ignoresSafeArea()
            } else {
                FixtureGuestsHost(fixture: fixture).ignoresSafeArea()
            }
            VStack(spacing: 16) {
                Text(fixture.hidden ? "hidden" : "visible").accessibilityIdentifier("DockStatus")
                Text("\(fixture.taps)").accessibilityIdentifier("DockTaps")
                Text("\(fixture.handleMoves)").accessibilityIdentifier("DockHandleMoves")
                Text("\(fixture.contextActions)").accessibilityIdentifier("DockContextActions")
                Text(fixture.hiddenDuringTouch ? "yes" : "no").accessibilityIdentifier("DockHiddenDuringTouch")
                Text(fixture.gestureTrace).lineLimit(1).frame(width: 300)
                    .accessibilityIdentifier("DockGestureTrace")
                Text(fixture.revealTrace).lineLimit(1).frame(width: 300)
                    .accessibilityIdentifier("DockRevealTrace")
                Text("\(fixture.guestCount)").accessibilityIdentifier("GuestCount")
                Text("\(fixture.guestDrags)").accessibilityIdentifier("GuestDrags")
                Text("\(fixture.guestTaps)").accessibilityIdentifier("GuestTaps")
                Text("\(fixture.reveals)").accessibilityIdentifier("DockReveals")
                Button("Show Dock") { fixture.showDock() }
                    .accessibilityIdentifier("ShowDock")
                Button("Hide Dock") { fixture.hideDock() }
                    .accessibilityIdentifier("HideDock")
                Button("Restore Four Guests") { fixture.restoreWorkspace() }
                    .accessibilityIdentifier("RestoreWorkspace")
                if fixture.webGuests {
                    Text("\(fixture.webGuestsReady)").accessibilityIdentifier("WebGuestsReady")
                    Text(fixture.guestsMinimized ? "minimized" : "running").accessibilityIdentifier("GuestVisibility")
                    Text(fixture.hideArrow ? "hidden" : "visible").accessibilityIdentifier("ArrowVisibility")
                    Button("Minimize Guests") { fixture.setGuestsMinimized(true) }.accessibilityIdentifier("MinimizeGuests")
                    Button("Restore Guests") { fixture.setGuestsMinimized(false) }.accessibilityIdentifier("RestoreGuests")
                    Button("Toggle Arrow") { fixture.toggleArrow() }.accessibilityIdentifier("ToggleArrow")
                }
            }
            .frame(width: 300)
            .frame(maxWidth: .infinity)
            if !fixture.hidden {
                FixtureDockHost(fixture: fixture).frame(width: fixture.width, height: 428)
            }
        }
        .ignoresSafeArea()
    }
}

private final class DockGestureTestWindow: UIWindow {
    var lastTouchPhase: UITouch.Phase?
    weak var fixture: DockGestureFixture?
    private var lastBounds = CGRect.zero
    private var lastInsets = UIEdgeInsets.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds != lastBounds || safeAreaInsets != lastInsets {
            lastBounds = bounds
            lastInsets = safeAreaInsets
            fixture?.refreshReveal()
        }
    }
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches { lastTouchPhase = event.allTouches?.first?.phase }
        super.sendEvent(event)
        if lastTouchPhase == .ended || lastTouchPhase == .cancelled {
            let trace = fixture?.hideGesture.traceSummary ?? "No fixture"
            let revealTrace = fixture?.revealControl.traceSummary ?? "No fixture"
            DispatchQueue.main.async { [weak fixture] in
                fixture?.gestureTrace = trace
                fixture?.revealTrace = revealTrace
            }
        }
    }
}

private final class DockGestureTestSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = DockGestureTestWindow(windowScene: scene)
        let fixture = DockGestureFixture()
        window.fixture = fixture
        fixture.window = window
        window.rootViewController = UIHostingController(rootView: DockGestureTestRoot(fixture: fixture))
        self.window = window
        window.makeKeyAndVisible()
    }
}

private final class DockGestureTestAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "DockGestures", sessionRole: session.role)
        configuration.delegateClass = DockGestureTestSceneDelegate.self
        return configuration
    }
}

@main
private enum DockGestureTestMain {
    @MainActor static func main() {
        _ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(DockGestureTestAppDelegate.self))
    }
}
