import SwiftUI

// Use the production SwiftUI drag modifier and release policy, including the
// physical hosting-view placement. Private guest scenes still need device tests.
@MainActor
private final class DockGestureFixture: ObservableObject {
    @Published var hidden = false
    @Published var taps = 0
    @Published var moves = 0
    @Published var contextActions = 0
    @Published var hiddenDuringTouch = false
    @Published var geometryRevision = 0
    @Published var placement: LCDockPlacement
    @Published var bounds = CGRect.zero
    @Published var lastDrag = "No drag yet"
    let width: CGFloat
    let accountCount: Int
    let collapsed: Bool
    private var startFrame: CGRect?
    weak var window: DockGestureTestWindow?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        placement = LCDockPlacement(right: !arguments.contains("--left"), fraction: 0.5)
        width = arguments.contains("--narrow") ? 56 : 80
        accountCount = arguments.contains("--scrollable") ? 20 : 4
        collapsed = arguments.contains("--collapsed")
    }

    var layout: LCDockLayout {
        LCDockLayout(preferredWidth: width, availableHeight: max(0, bounds.height - 80),
                     accountCount: accountCount, showsLabels: true, collapsed: collapsed)
    }

    var frame: CGRect {
        placement.frame(size: CGSize(width: width, height: layout.height), bounds: bounds,
                        insets: LCDockInsets(), hidden: false)
    }

    func beginDrag() { startFrame = frame }

    func endDrag(_ translation: CGSize) {
        guard let startFrame else { return }
        self.startFrame = nil
        lastDrag = "release (\(translation.width), \(translation.height))"
        switch placement.endingDrag(frame: startFrame, translation: translation, bounds: bounds, insets: LCDockInsets()) {
        case .hide:
            hide()
        case .move(let moved):
            placement = moved
            moves += 1
        case .cancel:
            break
        }
    }

    func cancelDrag() { startFrame = nil }

    func hide() {
        let phase = window?.lastTouchPhase
        let stillTouching = phase == .began || phase == .moved || phase == .stationary
        DispatchQueue.main.async {
            self.hidden = true
            self.hiddenDuringTouch = stillTouching
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
            if fixture.collapsed {
                Button { fixture.taps += 1 } label: {
                    Image(systemName: "chevron.up").frame(maxWidth: .infinity).frame(height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("DockCollapse")
                .contextMenu { Button("Window action") { fixture.contextActions += 1 } }
            } else {
                Button { fixture.taps += 1 } label: {
                    Text("Collapse").frame(maxWidth: .infinity).frame(height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("DockCollapse")
                Menu {
                    Button("Layout") { fixture.contextActions += 1 }
                    Button("Hide Dock") { fixture.hide() }
                } label: {
                    Image(systemName: "ellipsis").frame(maxWidth: .infinity).frame(height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("DockMenu")
                ScrollView(.vertical, showsIndicators: fixture.layout.scrolls) {
                    VStack(spacing: LCDockLayout.spacing) {
                        ForEach(0..<fixture.accountCount) { index in
                            Button { fixture.taps += 1 } label: {
                                Text("Account \(index)").frame(maxWidth: .infinity)
                                    .frame(height: fixture.layout.rowHeight).contentShape(Rectangle())
                            }
                            .buttonStyle(FixtureButtonStyle())
                            .accessibilityIdentifier("DockAccount\(index)")
                            .contextMenu {
                                Button("Window action") { fixture.contextActions += 1 }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: fixture.layout.viewportHeight)
                .scrollDisabled(!fixture.layout.scrolls)
            }
        }
        .buttonStyle(.plain)
        .padding(LCDockLayout.padding)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 15))
        .foregroundStyle(.white)
        .frame(width: fixture.width, height: fixture.layout.height)
        .modifier(LCDockDragModifier(enabled: !fixture.hidden, geometryRevision: fixture.geometryRevision,
                                    begin: { fixture.beginDrag() }, end: { fixture.endDrag($0) },
                                    cancel: { fixture.cancelDrag() }))
        .accessibilityIdentifier("DockBody")
        .ignoresSafeArea()
    }
}

private struct FixtureDockHost: UIViewControllerRepresentable {
    @ObservedObject var fixture: DockGestureFixture
    func makeUIViewController(context: Context) -> UIHostingController<FixtureDock> {
        let controller = UIHostingController(rootView: FixtureDock(fixture: fixture))
        controller.view.backgroundColor = .clear
        return controller
    }
    func updateUIViewController(_ controller: UIHostingController<FixtureDock>, context: Context) {
        controller.view.isUserInteractionEnabled = !fixture.hidden
    }
}

private struct DockGestureTestRoot: View {
    @ObservedObject var fixture: DockGestureFixture
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.gray.opacity(0.15).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(fixture.hidden ? "hidden" : "visible").accessibilityIdentifier("DockStatus")
                    Text("\(fixture.taps)").accessibilityIdentifier("DockTaps")
                    Text("\(fixture.moves)").accessibilityIdentifier("DockMoves")
                    Text(fixture.placement.right ? "right" : "left").accessibilityIdentifier("DockSide")
                    Text("\(fixture.placement.fraction)").accessibilityIdentifier("DockFraction")
                    Text("\(fixture.contextActions)").accessibilityIdentifier("DockContextActions")
                    Text(fixture.hiddenDuringTouch ? "yes" : "no").accessibilityIdentifier("DockHiddenDuringTouch")
                    Text(fixture.lastDrag).accessibilityIdentifier("DockGestureTrace")
                    Button("Show Dock") { fixture.hidden = false }.accessibilityIdentifier("ShowDock")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !fixture.hidden {
                    FixtureDockHost(fixture: fixture).frame(width: fixture.width, height: fixture.layout.height)
                        .position(x: fixture.frame.midX, y: fixture.frame.midY)
                }
            }
            .onAppear { fixture.bounds = CGRect(origin: .zero, size: geometry.size) }
            .onChange(of: geometry.size) { size in
                fixture.cancelDrag()
                fixture.bounds = CGRect(origin: .zero, size: size)
                fixture.geometryRevision += 1
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
        let fixture = DockGestureFixture()
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
