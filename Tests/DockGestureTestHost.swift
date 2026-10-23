import SwiftUI

// A normal SwiftUI host isolates real Button/contextMenu/ScrollView arbitration
// around the production native gesture, without the game's private scene APIs.
@MainActor
private final class DockGestureFixture: ObservableObject {
    @Published var hidden = false
    @Published var taps = 0
    @Published var handleMoves = 0
    @Published var contextActions = 0
    @Published var hiddenDuringTouch = false
    let right: Bool
    let width: CGFloat
    let hideGesture = LCDockHideGesture()

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        right = !arguments.contains("--left")
        width = arguments.contains("--narrow") ? 56 : 80
    }

    func attach(to view: UIView) {
        hideGesture.attach(to: view, ignoredTopHeight: LCDockLayout.padding + LCDockLayout.handleHeight,
                           right: right) { [weak self, weak view] in
            let phase = (view?.window as? DockGestureTestWindow)?.lastTouchPhase
            let stillTouching = phase == .began || phase == .moved || phase == .stationary
            // Match the production manager's deferred hide/removal after UIKit
            // has recognized and cancelled the pressed SwiftUI control.
            DispatchQueue.main.async {
                self?.hidden = true
                self?.hiddenDuringTouch = stillTouching
                self?.hideGesture.detach()
            }
        }
    }
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
                Button("Layout") {}
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
            Color.gray.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(fixture.hidden ? "hidden" : "visible").accessibilityIdentifier("DockStatus")
                Text("\(fixture.taps)").accessibilityIdentifier("DockTaps")
                Text("\(fixture.handleMoves)").accessibilityIdentifier("DockHandleMoves")
                Text("\(fixture.contextActions)").accessibilityIdentifier("DockContextActions")
                Text(fixture.hiddenDuringTouch ? "yes" : "no").accessibilityIdentifier("DockHiddenDuringTouch")
                Button("Show Dock") { fixture.hidden = false }
                    .accessibilityIdentifier("ShowDock")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !fixture.hidden {
                FixtureDockHost(fixture: fixture).frame(width: fixture.width, height: 428)
            }
        }
        .ignoresSafeArea()
    }
}

private final class DockGestureTestWindow: UIWindow {
    var lastTouchPhase: UITouch.Phase?
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches { lastTouchPhase = event.allTouches?.first?.phase }
        super.sendEvent(event)
    }
}

private final class DockGestureTestSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = DockGestureTestWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: DockGestureTestRoot(fixture: DockGestureFixture()))
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
