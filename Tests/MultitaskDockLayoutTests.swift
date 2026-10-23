import Foundation
import CoreGraphics

@main
enum MultitaskDockLayoutTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        // More accounts must scroll without shrinking the same user's icon or touch target.
        let four = LCDockLayout(preferredWidth: 80, availableHeight: 700, accountCount: 4, showsLabels: true, collapsed: false)
        let many = LCDockLayout(preferredWidth: 80, availableHeight: 320, accountCount: 20, showsLabels: true, collapsed: false)
        require(four.width == many.width && four.iconSize == many.iconSize, "Window count changed icon size")
        require(!four.scrolls && many.scrolls && many.viewportHeight >= 44, "Overflow must remain reachable by scrolling")
        require(many.height <= 320 && many.rowHeight >= 44, "Overflow escaped the host or shrank targets")
        let narrow = LCDockLayout(preferredWidth: 20, availableHeight: 320, accountCount: 4, showsLabels: false, collapsed: false)
        require(narrow.width - LCDockLayout.padding * 2 >= 44 && narrow.rowHeight >= 44, "Legacy small widths must retain 44pt targets")
        let short = LCDockLayout(preferredWidth: 80, availableHeight: 200, accountCount: 4, showsLabels: true, collapsed: false)
        require(short.compact && short.viewportHeight == 0 && short.height <= 200, "A short host must use the account menu")
        let collapsed = LCDockLayout(preferredWidth: 80, availableHeight: 700, accountCount: 4, showsLabels: true, collapsed: true)
        require(collapsed.compact && !collapsed.scrolls && collapsed.height < four.height, "Collapsed dock is not compact")
        let invalid = LCDockLayout(preferredWidth: .nan, availableHeight: .infinity, accountCount: -1, showsLabels: true, collapsed: false)
        require(invalid.width.isFinite && invalid.height.isFinite && invalid.height >= 0, "Invalid geometry was not bounded")
        let wide = LCDockLayout(preferredWidth: 120, availableHeight: 500, accountCount: 1, showsLabels: false, collapsed: false)
        require(wide.width == 120 && wide.rowHeight >= wide.iconSize, "Preferred width was lost")

        let bounds = CGRect(x: 30, y: 20, width: 1024, height: 768)
        let insets = LCDockInsets(top: 24, left: 12, bottom: 20, right: 16)
        let size = CGSize(width: four.width, height: four.height)
        for right in [false, true] {
            for fraction in [0.0, 0.25, 0.5, 1.0] {
                let placement = LCDockPlacement(right: right, fraction: fraction)
                let frame = placement.frame(size: size, bounds: bounds, insets: insets, hidden: false)
                require(bounds.contains(frame), "Placement escaped bounds")
                require(frame.minY >= bounds.minY + insets.top + 8 && frame.maxY <= bounds.maxY - insets.bottom - 8,
                        "Placement ignored vertical safe area")
                let restored = LCDockPlacement.from(frame: frame, bounds: bounds, insets: insets)
                require(restored.right == right && abs(restored.fraction - fraction) < 0.0001, "Dragged position cannot round trip")
                let hidden = placement.frame(size: size, bounds: bounds, insets: insets, hidden: true)
                let safe = CGRect(x: bounds.minX + insets.left, y: bounds.minY,
                                  width: bounds.width - insets.left - insets.right, height: bounds.height)
                require(abs(hidden.intersection(safe).width - 44) < 0.001, "Hidden reveal target is smaller than 44pt")
            }
        }
        require(LCDockPlacement(saved: ["edge": "left", "fraction": 9]).fraction == 1, "Saved fraction must clamp")
        require(LCDockPlacement(saved: ["fraction": Double.nan]).fraction == 0.5, "Nonfinite saved fraction was retained")

        // The reveal control stays fully on screen, independent of Dock width,
        // offscreen placement, safe-area cutouts and portrait/landscape hosts.
        let hosts: [(CGRect, LCDockInsets)] = [
            (CGRect(x: 0, y: 0, width: 393, height: 852), LCDockInsets(top: 59, bottom: 34)),
            (CGRect(x: 0, y: 0, width: 852, height: 393), LCDockInsets(left: 59, bottom: 21, right: 59)),
            (bounds, insets),
            (CGRect(x: 0, y: 0, width: 444, height: 320), LCDockInsets(top: 24, bottom: 20))
        ]
        for (host, exclusions) in hosts {
            let safe = CGRect(x: host.minX + exclusions.left, y: host.minY + exclusions.top,
                              width: host.width - exclusions.left - exclusions.right,
                              height: host.height - exclusions.top - exclusions.bottom)
            for right in [false, true] {
                for fraction in [0.0, 0.25, 0.5, 1.0] {
                    let reveal = LCDockPlacement(right: right, fraction: fraction).revealFrame(bounds: host, insets: exclusions)
                    require(safe.contains(reveal) && reveal.size == CGSize(width: 44, height: 44),
                            "Reveal control escaped the host or lost its native 44pt target")
                    require(right ? reveal.maxX == safe.maxX : reveal.minX == safe.minX,
                            "Reveal control is not at its saved edge")
                }
            }
        }

        let suite = "com.livecontainer.tests.dock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let positions = LCDockPlacementStore(defaults: defaults)
        let portrait = LCDockPlacement(right: false, fraction: 0.2)
        let landscape = LCDockPlacement(right: true, fraction: 0.8)
        positions.save(portrait, landscape: false)
        positions.save(landscape, landscape: true)
        let relaunched = LCDockPlacementStore(defaults: UserDefaults(suiteName: suite)!)
        require(relaunched.load(landscape: false) == portrait && relaunched.load(landscape: true) == landscape,
                "Orientations were overwritten or failed to survive relaunch")
        defaults.set("keep", forKey: "LCTapSyncLastSelectionTest")
        positions.reset()
        require(positions.load(landscape: false) == LCDockPlacement() && positions.load(landscape: true) == LCDockPlacement(),
                "Reset did not clear both orientations")
        require(defaults.string(forKey: "LCTapSyncLastSelectionTest") == "keep", "Reset changed another preference")

        let registry = LCDockAccountRegistry(defaults: defaults)
        let known = ["A", "B", "C", "D"]
        // Open D first: the user's saved container order, rather than launch order, assigns numbers.
        require(registry.number(for: "D", application: "game.app", knownIdentifiers: known) == 4, "Launch order changed account number")
        require(registry.number(for: "A", application: "game.app", knownIdentifiers: known) == 1, "First account number changed")
        let reopened = LCDockAccountRegistry(defaults: UserDefaults(suiteName: suite)!)
        require(reopened.number(for: "C", application: "game.app", knownIdentifiers: ["D", "C", "A"]) == 3,
                "Removing or swapping containers renumbered another account")
        require(reopened.number(for: "E", application: "game.app", knownIdentifiers: ["E", "C", "D"]) == 5,
                "New account reused a closed account number")
        require(reopened.number(for: "A", application: "other.app", knownIdentifiers: ["A"]) == 1,
                "Unrelated applications share a number sequence")
        let oldRegistry = defaults.dictionary(forKey: "LCDockAccountIdentifiers") as NSDictionary?
        require(reopened.number(for: "C", application: "game.app", knownIdentifiers: ["C", "", "C"]) == 3,
                "Duplicate/empty IDs changed identity")
        require(oldRegistry == defaults.dictionary(forKey: "LCDockAccountIdentifiers") as NSDictionary?,
                "Repeated lookup rewrote registry content")
        print("Dock geometry, 44pt targets, scrolling, placement, orientation persistence, reset and stable account identity passed")
    }
}
