import CoreGraphics
import Foundation

enum PathFavoritesTransition {
    static let duration: TimeInterval = 0.5
    static let collapsedScale: CGFloat = 0.055

    static func collapsed(frame: CGRect, source: CGRect?) -> CGAffineTransform {
        let target = source.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: frame.midX, y: frame.maxY)
        return CGAffineTransform(
            a: collapsedScale, b: 0, c: 0, d: collapsedScale,
            tx: target.x - frame.midX,
            ty: target.y - frame.midY,
        )
    }

    static func dismissal(frame: CGRect, source: CGRect?, shadowPadding: CGFloat) -> CGAffineTransform {
        guard let source, !source.isEmpty, !source.isNull, !source.isInfinite else {
            return collapsed(frame: frame, source: nil)
        }
        let scale = min(
            collapsedScale,
            source.width / (frame.width + 2 * shadowPadding),
            source.height / (frame.height + 2 * shadowPadding),
        )
        return CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: source.midX - frame.midX,
            ty: source.midY - frame.midY,
        )
    }

    static func dismissalClip(in bounds: CGRect, source: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX, y: bounds.minY, width: bounds.width,
            height: max(0, min(bounds.height, source.maxY - bounds.minY)),
        )
    }
}
