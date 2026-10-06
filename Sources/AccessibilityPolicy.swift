import Foundation
import CoreGraphics

enum ChromeAccessibility {
    static func windows<Element>(application: Element, role: (Element) -> String?, read: (Element) -> [Element]?) -> [Element]? {
        // BrowserCrApplication::accessibilityRole enables Chromium's native AX
        // mode. Reading AXWindows alone can leave only the page title exposed.
        _ = role(application)
        return read(application)
    }

    static func windowTitles<Element>(window: Element, role: (Element) -> String?, strings: (Element) -> [String], children: (Element) -> [Element]) -> [String] {
        let containers: Set<String> = ["AXWindow", "AXGroup", "AXSplitGroup", "AXUnknown"]
        var queue: [(Element, Int)] = [(window, 0)]
        var index = 0
        var titles = Set<String>()
        while index < queue.count && index < 32 {
            let (element, depth) = queue[index]; index += 1
            guard depth == 0 || containers.contains(role(element) ?? "") else { continue }
            for title in strings(element) where !title.isEmpty { titles.insert(title) }
            guard depth < 4 else { continue }
            // Never descend into AXWebArea, tab strips, toolbars or page controls.
            let remaining = max(0, 32 - queue.count)
            queue.append(contentsOf: children(element).prefix(remaining).map { ($0, depth + 1) })
        }
        return Array(titles)
    }
}

enum MissionControlAccessibility {
    // macOS 27 exposes mc.display directly under WindowManager. Earlier
    // systems expose it below Dock's mc group. An empty mc stub is not live MC.
    static func displays<Element>(in root: Element, identifier: (Element) -> String?, children: (Element) -> [Element]) -> [Element] {
        var queue: [(Element, Int)] = [(root, 0)]
        var index = 0
        var result: [Element] = []
        while index < queue.count && index < 128 {
            let (element, depth) = queue[index]; index += 1
            if identifier(element) == "mc.display" {
                if children(element).contains(where: { identifier($0) == "mc.spaces" }) { result.append(element) }
                // Window thumbnails also live here. Do not traverse them.
                continue
            }
            guard depth < 6 else { continue }
            queue.append(contentsOf: children(element).prefix(max(0, 128 - queue.count)).map { ($0, depth + 1) })
        }
        return result
    }

    static func liveRoot<Element>(in roots: [Element], identifier: (Element) -> String?, children: (Element) -> [Element]) -> Element? {
        roots.first { !displays(in: $0, identifier: identifier, children: children).isEmpty }
    }

    static func display<Element>(in candidates: [Element], targetID: UInt32, targetFrame: CGRect,
                                 displayID: (Element) -> UInt32?, frame: (Element) -> CGRect?) -> Element? {
        let exact = candidates.filter { displayID($0) == targetID }
        if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        // Some system versions omit AXDisplayID. Both these frames use the AX /
        // Quartz top-left coordinate system and include the menu bar and Dock.
        guard valid(targetFrame) else { return nil }
        let geometric = candidates.filter { element in
            guard displayID(element) == nil, let candidate = frame(element), valid(candidate) else { return false }
            return abs(candidate.minX - targetFrame.minX) <= 2 && abs(candidate.minY - targetFrame.minY) <= 2
                && abs(candidate.width - targetFrame.width) <= 2 && abs(candidate.height - targetFrame.height) <= 2
        }
        return geometric.count == 1 ? geometric[0] : nil
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}

enum MissionControlLabelPolicy {
    static func frame(thumbnail: CGRect, screen: CGRect, primaryHeight: CGFloat) -> CGRect? {
        guard thumbnail.width >= 40, thumbnail.height >= 16,
              thumbnail.minX.isFinite, thumbnail.minY.isFinite,
              thumbnail.width.isFinite, thumbnail.height.isFinite else { return nil }
        // AX uses a top-left origin; AppKit uses a bottom-left origin.
        let native = CGRect(x: thumbnail.minX, y: primaryHeight - thumbnail.maxY,
                            width: thumbnail.width, height: thumbnail.height)
        guard screen.intersects(native) else { return nil }
        let width = min(max(native.width - 8, 48), 230, screen.width)
        let x = min(max(native.midX - width / 2, screen.minX), screen.maxX - width)
        let y = min(max(native.minY + 4, screen.minY), screen.maxY - 24)
        return CGRect(x: x, y: y, width: width, height: 24)
    }

    static func paired(desktops: [Desktop], frames: [CGRect], displayID: String) -> [(Desktop, CGRect)] {
        let ordered = desktops.filter { $0.displayID == displayID }.sorted { $0.ordinal < $1.ordinal }
        // Hide during a changing Space list instead of putting a name on the
        // wrong thumbnail. Include fullscreen entries when matching positions.
        guard ordered.count == frames.count else { return [] }
        return zip(ordered, frames).filter { !$0.0.fullScreen }
    }
}
