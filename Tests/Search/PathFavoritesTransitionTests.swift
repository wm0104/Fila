import CoreGraphics
import Testing

@Suite("Favorites transition path anchor")
struct PathFavoritesTransitionTests {
    @Test func dismissalFitsTheVisiblePathIncludingShadow() {
        let frame = CGRect(x: 40, y: 100, width: 270, height: 400)
        let source = CGRect(x: 180, y: 530, width: 80, height: 12)
        let old = PathFavoritesTransition.collapsed(frame: frame, source: source)
        #expect(frame.midY + old.ty + frame.height * old.d / 2 > source.maxY)

        let padding: CGFloat = 44
        let transform = PathFavoritesTransition.dismissal(frame: frame, source: source, shadowPadding: padding)
        let width = (frame.width + 2 * padding) * transform.a
        let height = (frame.height + 2 * padding) * transform.d
        let cx = frame.midX + transform.tx
        let cy = frame.midY + transform.ty
        #expect(cx == source.midX)
        #expect(cy == source.midY)
        #expect(cx - width / 2 >= source.minX - 0.0001)
        #expect(cx + width / 2 <= source.maxX + 0.0001)
        #expect(cy - height / 2 >= source.minY - 0.0001)
        #expect(cy + height / 2 <= source.maxY + 0.0001)
    }

    @Test func dismissalFitsLongShortAndPartiallyVisiblePaths() {
        let frame = CGRect(x: 80, y: 100, width: 270, height: 400)
        for source in [
            CGRect(x: 15, y: 530, width: 15, height: 15),
            CGRect(x: 100, y: 530, width: 210, height: 15),
            CGRect(x: 310, y: 530, width: 3, height: 15),
        ] {
            let transform = PathFavoritesTransition.dismissal(frame: frame, source: source, shadowPadding: 44)
            #expect(transform.a > 0)
            #expect(transform.a <= PathFavoritesTransition.collapsedScale)
            #expect((frame.width + 88) * transform.a <= source.width + 0.0001)
            #expect((frame.height + 88) * transform.d <= source.height + 0.0001)
            #expect(frame.midX + transform.tx == source.midX)
        }
    }

    @Test func dismissalClipStopsOvershootWithoutClippingTheWholeContainer() {
        let bounds = CGRect(x: 10, y: 20, width: 390, height: 844)
        let source = CGRect(x: 240, y: 730, width: 80, height: 16)
        let clip = PathFavoritesTransition.dismissalClip(in: bounds, source: source)
        #expect(clip.minX == bounds.minX)
        #expect(clip.minY == bounds.minY)
        #expect(clip.width == bounds.width)
        #expect(clip.maxY == source.maxY)
        // A deliberately exaggerated spring overshoot still cannot show below the path.
        let overshoot = CGRect(x: 240, y: source.minY, width: 80, height: 40)
        let visible = overshoot.intersection(clip)
        #expect(visible.maxY == source.maxY)
    }

    @Test func unavailableDismissalAnchorPreservesTheExistingFallback() {
        let frame = CGRect(x: 120, y: 350, width: 260, height: 350)
        #expect(PathFavoritesTransition.dismissal(frame: frame, source: nil, shadowPadding: 44)
            == PathFavoritesTransition.collapsed(frame: frame, source: nil))
    }

    @Test func collapseEndsAtTheTappedPathRatherThanTheScreenBottom() {
        let frame = CGRect(x: 160, y: 350, width: 260, height: 350)
        let source = CGRect(x: 210, y: 710, width: 160, height: 40)
        let transform = PathFavoritesTransition.collapsed(frame: frame, source: source)
        #expect(frame.midX + transform.tx == source.midX)
        #expect(frame.midY + transform.ty == source.midY)
        #expect(transform.a == PathFavoritesTransition.collapsedScale)
        #expect(transform.d == PathFavoritesTransition.collapsedScale)
    }

    @Test func longAndShortPathsHaveDifferentOrigins() {
        let frame = CGRect(x: 120, y: 350, width: 260, height: 350)
        let right = CGRect(x: 300, y: 710, width: 90, height: 40)
        let left = CGRect(x: 80, y: 710, width: 50, height: 40)
        let a = PathFavoritesTransition.collapsed(frame: frame, source: right)
        let b = PathFavoritesTransition.collapsed(frame: frame, source: left)
        #expect(a.tx > b.tx)
        #expect(frame.midX + a.tx == right.midX)
        #expect(frame.midX + b.tx == left.midX)
        #expect(a.ty == b.ty)
    }

    @Test func missingAnchorStaysAtThePanelEdge() {
        let frame = CGRect(x: 120, y: 350, width: 260, height: 350)
        let transform = PathFavoritesTransition.collapsed(frame: frame, source: nil)
        #expect(transform.tx == 0)
        #expect(frame.midY + transform.ty == frame.maxY)
        #expect(PathFavoritesTransition.duration == 0.5)
    }
}
