import Foundation

/// Frames are in the host's coordinates, excluding the focused stack's bars.
struct PaneLayout {
    let horizontal: Bool
    let divider: CGRect
    let headings: [CGRect]
    let lists: [CGRect]

    static func clamped(_ fraction: CGFloat) -> CGFloat { min(0.78, max(0.22, fraction)) }

    init(region: CGRect, host: CGSize, fraction: CGFloat) {
        horizontal = host.width > host.height
        let edge: CGRectEdge = horizontal ? .minXEdge : .minYEdge
        let length = horizontal ? region.width : region.height
        let gap = min(20, length / 5)
        let (first, rest) = region.divided(atDistance: ((length - gap) * Self.clamped(fraction)).rounded(), from: edge)
        let (bar, second) = rest.divided(atDistance: gap, from: edge)
        divider = bar
        let panes = [first, second].map { $0.divided(atDistance: min(32, $0.height / 3), from: .minYEdge) }
        headings = panes.map(\.slice)
        lists = panes.map(\.remainder)
    }
}
