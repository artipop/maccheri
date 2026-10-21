import AppKit
import CoreVideo
import SimStreamClient

/// Shows decoded frames as the contents of a plain CALayer (the IOSurface goes straight to the
/// compositor, no queueing) and turns the mouse into touches.
final class VideoView: NSView {
    /// Normalised to the device screen, 0…1 from the top-left.
    var onTouch: ((Touch.Phase, Double, Double) -> Void)?
    private var current: CVPixelBuffer?
    private var aspect: CGSize?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        // Nothing to animate: a new frame replaces the old one at once.
        layer?.actions = ["contents": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ frame: SimStreamClient.Frame) {
        // Keep the buffer alive while its surface is on screen, so the decoder doesn't reuse it.
        current = frame.image
        layer?.contents = CVPixelBufferGetIOSurface(frame.image)?.takeUnretainedValue()
        let size = CGSize(width: CVPixelBufferGetWidth(frame.image), height: CVPixelBufferGetHeight(frame.image))
        if aspect != size {
            aspect = size
            window?.contentAspectRatio = size
            fitWindow(to: size)
        }
    }

    func clear() {
        current = nil
        layer?.contents = nil
        aspect = nil
        window?.resizeIncrements = NSSize(width: 1, height: 1)
    }

    /// Resizes the window to the device's proportions, keeping its height.
    private func fitWindow(to size: CGSize) {
        guard let window else { return }
        var frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let width = (content.height * size.width / size.height).rounded()
        frame.size.width += width - content.width
        window.setFrame(frame, display: true, animate: false)
    }

    /// The part of the view the video occupies (aspect fit).
    private var videoRect: CGRect {
        guard let aspect, aspect.width > 0, aspect.height > 0 else { return bounds }
        let scale = min(bounds.width / aspect.width, bounds.height / aspect.height)
        let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func send(_ phase: Touch.Phase, _ event: NSEvent) {
        guard aspect != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = videoRect
        onTouch?(phase, (point.x - rect.minX) / rect.width, (point.y - rect.minY) / rect.height)
    }

    override func mouseDown(with event: NSEvent) { send(.began, event) }
    override func mouseDragged(with event: NSEvent) { send(.moved, event) }
    override func mouseUp(with event: NSEvent) { send(.ended, event) }
}
