#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Divide the space between the status area and the single bottom toolbar.
/// The two resulting regions include each directory's own navigation bar.
struct PaneLayout {
    let dividerTop: CGFloat
    let dividerHeight: CGFloat
    let available: CGFloat

    static func clamped(_ fraction: CGFloat) -> CGFloat { min(0.78, max(0.22, fraction)) }

    init(top: CGFloat, bottom: CGFloat, fraction: CGFloat) {
        let height = max(0, bottom - top)
        dividerHeight = min(20, height / 5)
        available = height - dividerHeight
        dividerTop = top + (available * Self.clamped(fraction)).rounded()
    }
}
