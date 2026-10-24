import SwiftUI

// The same SwiftUI gesture drives the app and the real-touch test fixture.
// Offset the content during contact, then let the manager snap or hide on release.
struct LCDockDragModifier: ViewModifier {
    let enabled: Bool
    let geometryRevision: Int
    let begin: () -> Void
    let end: (CGSize) -> Void
    let cancel: () -> Void
    @GestureState private var touching = false
    @State private var offset = CGSize.zero
    @State private var active = false
    @State private var blocked = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .offset(offset)
            .gesture(DragGesture(minimumDistance: LCDockDragResult.minimumDistance, coordinateSpace: .global)
                .updating($touching) { _, touching, _ in touching = true }
                .onChanged { value in
                    guard enabled, !blocked else { return }
                    if !active {
                        active = true
                        begin()
                    }
                    offset = value.translation
                }
                .onEnded { value in
                    let shouldFinish = enabled && active && !blocked
                    active = false
                    blocked = false
                    offset = .zero
                    if shouldFinish { end(value.translation) }
                }, including: enabled ? .all : .subviews)
            .onChange(of: touching) { touching in
                if !touching {
                    if active { cancel() }
                    active = false
                    blocked = false
                    offset = .zero
                }
            }
            .onChange(of: geometryRevision) { _ in cancelCurrentDrag() }
            .onChange(of: enabled) { enabled in
                if !enabled { cancelCurrentDrag() }
            }
            .onDisappear { cancelCurrentDrag() }
    }

    private func cancelCurrentDrag() {
        if active { cancel() }
        blocked = touching
        active = false
        offset = .zero
    }
}
