import SwiftUI

// Minimal persistence boundary around the production settings and picker views.
final class LCAppModel: ObservableObject {
    let appInfo = LCLocationTestInfo()
    @Published var uiCustomLocation: [AnyHashable: Any] = [:] {
        didSet { appInfo.customLocation = uiCustomLocation }
    }
    @Published var uiDontInjectTweakLoader = false
    @Published var uiIs32bit = false
}

final class LCLocationTestInfo {
    let path = NSTemporaryDirectory() + UUID().uuidString
    init() {
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSDictionary(dictionary: ["test": true]).write(toFile: path + "/LCAppInfo.plist", atomically: true)
    }
    func bundlePath() -> String { path }
    func displayName() -> String { "Location Test App" }
    var customLocation: [AnyHashable: Any] {
        get { LCLocationSession.session(path: path, title: displayName()).settings }
        set {
            let session = LCLocationSession.session(path: path, title: displayName())
            if !newValue.isEmpty && !NSDictionary(dictionary: newValue).isEqual(to: session.settings) {
                _ = session.select(point: newValue, enabled: newValue["enabled"] as? Bool == true)
            }
        }
    }
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
