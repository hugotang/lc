import SwiftUI

// Minimal persistence boundary around the production settings and picker views.
final class LCAppModel: ObservableObject {
    @Published var uiCustomLocation: [AnyHashable: Any] = [:]
    @Published var uiDontInjectTweakLoader = false
    @Published var uiIs32bit = false
}

extension String {
    var loc: String { NSLocalizedString(self, comment: "") }
}

@main
struct LocationPickerTestHost: App {
    @StateObject private var model = LCAppModel()
    var body: some Scene {
        WindowGroup {
            NavigationView {
                LCAppLocationSettingsView(model: model)
            }.navigationViewStyle(.stack)
        }
    }
}
