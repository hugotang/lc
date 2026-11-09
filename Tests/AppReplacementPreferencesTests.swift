import Foundation

let saved: [String: Any] = [
    "LCUseWindowScreenSize": false, "LCAppWindowAspectRatio": [11, 16],
    "LCForceAmbientAudio": true, "LCKeepBackgroundAudio": true,
    "LCAppLocation": ["enabled": true, "latitude": 22.0, "longitude": 114.0],
    "LCLocationRevision": "saved-position", "LCLocationQuickControl": true,
    "LCLocationFavorites": [["latitude": 23.0, "longitude": 115.0]],
    "LCPatchRevision": 7, "LCGuestExtensionPatchRevision": 1,
    "LCJITLessSignID": "old-signature"
]
let incoming: [String: Any] = [
    "LCPatchRevision": 0, "LCJITLessSignID": "new-signature", "newBundleValue": "keep",
    "LCAppWindowAspectRatio": [9, 16], "LCLocationQuickControl": false
]
let restored = LCAppReplacementPreferences.merging(saved, into: incoming)
for key in ["LCUseWindowScreenSize", "LCAppWindowAspectRatio", "LCForceAmbientAudio", "LCKeepBackgroundAudio",
            "LCAppLocation", "LCLocationRevision", "LCLocationQuickControl", "LCLocationFavorites"] {
    precondition(NSDictionary(dictionary: [key: restored[key]!]).isEqual(to: [key: saved[key]!]))
}
precondition(restored["LCPatchRevision"] as? Int == 0)
precondition(restored["LCJITLessSignID"] as? String == "new-signature")
precondition(restored["LCGuestExtensionPatchRevision"] == nil)
precondition(restored["newBundleValue"] as? String == "keep")
let encoded = try PropertyListSerialization.data(fromPropertyList: restored, format: .binary, options: 0)
let decoded = try PropertyListSerialization.propertyList(from: encoded, options: [], format: nil) as! [String: Any]
precondition(NSDictionary(dictionary: decoded).isEqual(to: restored))
let cleared = LCAppReplacementPreferences.merging([:], into: incoming)
precondition(cleared["LCAppWindowAspectRatio"] == nil)
precondition(cleared["LCLocationQuickControl"] == nil)
precondition(cleared["newBundleValue"] as? String == "keep")
print("App replacement preserves ratio, audio, location and shortcut preferences without stale signing metadata")
