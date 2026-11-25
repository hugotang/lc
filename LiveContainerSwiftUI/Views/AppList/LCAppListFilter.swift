import Foundation

enum LCAppStorageFilter: String, CaseIterable {
    case all, shared, privateApps
    var titleKey: String { "lc.appList.filter.\(rawValue)" }
}

struct LCAppListFilter {
    var storage: LCAppStorageFilter = .all
    var needsJIT = false
    var query = ""
    var isActive: Bool { storage != .all || needsJIT || !query.isEmpty }

    func matches(name: String, bundleIdentifier: String?, isShared: Bool, needsJIT: Bool) -> Bool {
        guard storage == .all || (storage == .shared ? isShared : !isShared),
              !self.needsJIT || needsJIT else { return false }
        return query.isEmpty || name.localizedCaseInsensitiveContains(query) ||
            (bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
    }
}
