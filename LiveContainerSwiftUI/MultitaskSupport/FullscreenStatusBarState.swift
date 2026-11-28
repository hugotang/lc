import SwiftUI

// SwiftUI owns the main host's status-bar appearance. Publish outside UIKit's
// layout pass, and bind the request to one scene rather than the whole process.
@objc final class LCFullscreenStatusBarState: NSObject, ObservableObject {
    @objc static let shared = LCFullscreenStatusBarState()
    @Published private(set) var hiddenSceneIdentifier: String?
    private weak var pendingScene: UIWindowScene?
    private var pendingHidden = false
    private var updatePending = false

    @objc(updateWithHidden:inScene:) func update(hidden: Bool, inScene scene: UIWindowScene?) {
        pendingScene = scene
        pendingHidden = hidden
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async {
            self.updatePending = false
            let identifier = self.pendingHidden ? self.pendingScene?.session.persistentIdentifier : nil
            if self.hiddenSceneIdentifier != identifier { self.hiddenSceneIdentifier = identifier }
        }
    }
}
