import Foundation
import CoreGraphics

// Keep hit targets and account identity independent of the number of open windows.
struct LCDockLayout {
    static let minimumHitSize: CGFloat = 44
    static let padding: CGFloat = 6
    static let spacing: CGFloat = 8
    static let revealHitWidth: CGFloat = 44

    let width: CGFloat
    let iconSize: CGFloat
    let rowHeight: CGFloat
    let viewportHeight: CGFloat
    let height: CGFloat
    let scrolls: Bool
    let compact: Bool

    init(preferredWidth: CGFloat, availableHeight: CGFloat, accountCount: Int,
         showsLabels: Bool, collapsed: Bool) {
        let requested = preferredWidth.isFinite ? preferredWidth : 80
        width = max(56, min(120, requested))
        iconSize = max(28, min(88, min(width - Self.padding * 2, width * 0.75)))
        rowHeight = max(Self.minimumHitSize, iconSize) + (showsLabels ? 18 : 0)
        let count = max(0, accountCount)
        let listHeight = CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * Self.spacing
        let fixedHeight = Self.padding * 2 + Self.minimumHitSize * 2 + Self.spacing * 2
        let available = availableHeight.isFinite ? max(0, availableHeight) : 0
        compact = collapsed || available < fixedHeight + Self.minimumHitSize
        let listSpace = max(0, available - fixedHeight)
        viewportHeight = compact ? 0 : min(listHeight, listSpace)
        height = compact ? min(available, Self.padding * 2 + Self.minimumHitSize) :
            min(available, fixedHeight + viewportHeight)
        scrolls = !compact && listHeight > viewportHeight
    }
}

struct LCDockPlacement: Equatable {
    var right = true
    var fraction: Double = 0.5

    init(right: Bool = true, fraction: Double = 0.5) {
        self.right = right
        self.fraction = fraction.isFinite ? max(0, min(1, fraction)) : 0.5
    }

    init(saved: [String: Any]?) {
        self.init(right: saved?["edge"] as? String != "left",
                  fraction: (saved?["fraction"] as? NSNumber)?.doubleValue ?? 0.5)
    }

    var propertyList: [String: Any] { ["edge": right ? "right" : "left", "fraction": fraction] }

    func frame(size: CGSize, bounds: CGRect, insets: LCDockInsets, hidden: Bool) -> CGRect {
        let minY = bounds.minY + insets.top + 8
        let maxY = max(minY, bounds.maxY - insets.bottom - size.height - 8)
        let x = right ? bounds.maxX - insets.right - size.width : bounds.minX + insets.left
        return CGRect(x: x + (hidden ? (right ? 1 : -1) * max(0, size.width - LCDockLayout.revealHitWidth) : 0),
                      y: minY + (maxY - minY) * fraction, width: size.width, height: size.height)
    }

    func revealFrame(bounds: CGRect, insets: LCDockInsets) -> CGRect {
        frame(size: CGSize(width: LCDockLayout.revealHitWidth, height: LCDockLayout.minimumHitSize),
              bounds: bounds, insets: insets, hidden: false)
    }

    static func from(frame: CGRect, bounds: CGRect, insets: LCDockInsets) -> LCDockPlacement {
        let minY = bounds.minY + insets.top + 8
        let travel = max(0, bounds.height - insets.top - insets.bottom - frame.height - 16)
        return LCDockPlacement(right: frame.midX >= bounds.midX,
                               fraction: travel > 0 ? (frame.minY - minY) / travel : 0.5)
    }

    func endingDrag(frame: CGRect, translation: CGSize, bounds: CGRect, insets: LCDockInsets) -> LCDockDragResult {
        guard translation.width.isFinite, translation.height.isFinite,
              frame.width > 0, frame.height > 0, bounds.width > 0, bounds.height > 0 else { return .cancel }
        // Match the original whole-Dock drag: recognition already requires 5pt,
        // so an outward release needs no second distance or velocity threshold.
        let horizontal = abs(translation.width) > abs(translation.height)
        let outward = right ? translation.width : -translation.width
        if horizontal && outward > 0 && hypot(translation.width, translation.height) >= LCDockDragResult.minimumDistance {
            return .hide
        }
        let dragged = frame.offsetBy(dx: translation.width, dy: translation.height)
        let side = horizontal ? dragged.midX >= bounds.midX : right
        let moved = Self.from(frame: dragged, bounds: bounds, insets: insets)
        return .move(Self(right: side, fraction: moved.fraction))
    }
}

enum LCDockDragResult: Equatable {
    static let minimumDistance: CGFloat = 5
    case hide
    case move(LCDockPlacement)
    case cancel
}

// UIKit-free geometry can also be checked without an iOS simulator.
struct LCDockInsets {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0
}

final class LCDockPlacementStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    private func key(landscape: Bool) -> String { landscape ? "LCDockLandscapePosition" : "LCDockPortraitPosition" }
    func load(landscape: Bool) -> LCDockPlacement { LCDockPlacement(saved: defaults.dictionary(forKey: key(landscape: landscape))) }
    func save(_ placement: LCDockPlacement, landscape: Bool) { defaults.set(placement.propertyList, forKey: key(landscape: landscape)) }
    func reset() {
        defaults.removeObject(forKey: key(landscape: false))
        defaults.removeObject(forKey: key(landscape: true))
    }
}

final class LCDockAccountRegistry {
    private let defaults: UserDefaults
    private let key = "LCDockAccountIdentifiers"
    init(defaults: UserDefaults) { self.defaults = defaults }

    func number(for identifier: String, application: String, knownIdentifiers: [String]) -> Int {
        var registry = defaults.dictionary(forKey: key) ?? [:]
        var identifiers: [String] = []
        // Preserve assigned numbers when accounts close, swap, disappear or relaunch.
        // Deleted entries are small identifiers only; no account data is retained here.
        for value in (registry[application] as? [String] ?? []) + knownIdentifiers + [identifier] {
            if !value.isEmpty && value.count <= 256 && !identifiers.contains(value) { identifiers.append(value) }
        }
        if (registry[application] as? [String]) != identifiers {
            registry[application] = identifiers
            defaults.set(registry, forKey: key)
        }
        return (identifiers.firstIndex(of: identifier) ?? 0) + 1
    }
}
