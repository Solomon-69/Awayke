// PopoverStyle.swift. One shape, one fill: the popover's arrow and body are painted by the SAME
// view, so there is no seam where they meet.
//
// Why a seam appeared: NSPopover draws its own arrow and body chrome, and the hosted SwiftUI content
// sits on top of the body only. Two separately painted surfaces never match exactly, so a hairline
// showed where the arrow met the body. With `hasFullSizeContent` the content extends under the arrow,
// and the root view paints one continuous material behind everything (arrow included).
import SwiftUI
import AppKit

enum PopoverStyle {
    /// Tests flip this off to capture the old look for comparison.
    nonisolated(unsafe) static var joined = true

    @MainActor static func apply(_ popover: NSPopover) {
        if joined { popover.hasFullSizeContent = true }
    }
}

/// The single fill behind the whole popover, arrow included.
struct PopoverBackdrop: ViewModifier {
    func body(content: Content) -> some View {
        if PopoverStyle.joined {
            content.background { Rectangle().fill(.regularMaterial).ignoresSafeArea() }
        } else {
            content
        }
    }
}
