import Foundation

enum LCAppReplacementPreferences {
    // These settings belong to the user's installation, not the incoming IPA.
    // Keep signing/patch metadata from the new bundle instead.
    static func merging(_ saved: [String: Any], into incoming: [String: Any]) -> [String: Any] {
        var result = incoming
        for key in ["LCUseWindowScreenSize", "LCAppWindowAspectRatio", "LCForceAmbientAudio", "LCKeepBackgroundAudio",
                    "LCAppLocation", "LCLocationRevision", "LCLocationQuickControl", "LCLocationFavorites"] {
            result[key] = saved[key]
        }
        return result
    }
}
