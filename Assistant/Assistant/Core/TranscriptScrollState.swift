import CoreGraphics

/// Follows live activity at the bottom without interrupting someone scrolling through history.
struct TranscriptScrollState {
    var followsLatest = true
    private var previousFrame: CGRect?
    private static let bottomTolerance: CGFloat = 48

    /// Content growth is not a user scroll; only an offset change at a stable height changes intent.
    mutating func update(frame: CGRect, viewportHeight: CGFloat) {
        let nearBottom = frame.maxY <= viewportHeight + Self.bottomTolerance
        let heightChanged = previousFrame.map { abs($0.height - frame.height) > 0.5 } ?? true
        if let previousFrame, !heightChanged, abs(previousFrame.minY - frame.minY) > 0.5 {
            followsLatest = nearBottom
        } else if nearBottom {
            followsLatest = true
        }
        previousFrame = frame
    }
}
