import AppKit
import CoreImage

/// Canvas that draws the screenshot plus annotations and handles mouse interaction.
///
/// The view is **flipped** (top-left origin, y down) so view coordinates equal image coordinates
/// in points. When rendering to a CoreGraphics bitmap (bottom-left origin) the context is flipped
/// explicitly in `renderedImage()`.
final class EditorView: NSView, NSTextFieldDelegate {
    let baseImage: CGImage
    let scale: CGFloat
    let state: ToolState

    private(set) var annotations: [Annotation] = [] { didSet { onChange?() } }
    private var undoStack: [[Annotation]] = []
    private var selectedID: UUID? { didSet { needsDisplay = true } }

    /// Pixelated copy of the base image, used to paint mosaic regions.
    private lazy var pixelatedImage: CGImage? = Self.pixelate(baseImage, blockSize: 14 * scale)

    // Interaction state
    private var draft: Annotation?
    private var dragAnchor: CGPoint?
    private var didPushForDrag = false

    // Inline text editing
    private var textField: NSTextField?
    private var editingTextID: UUID?

    /// Called whenever annotations change (used to refresh toolbar state).
    var onChange: (() -> Void)?

    var canUndo: Bool { !undoStack.isEmpty }
    var isEditingText: Bool { textField != nil }

    init(image: CGImage, scale: CGFloat, state: ToolState) {
        self.baseImage = image
        self.scale = max(scale, 1)
        self.state = state
        let size = NSSize(width: CGFloat(image.width) / self.scale, height: CGFloat(image.height) / self.scale)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var imageSize: NSSize { frame.size }

    // MARK: - Public editing API

    func undo() {
        commitTextEditing()
        guard let previous = undoStack.popLast() else { return }
        annotations = previous
        selectedID = nil
        needsDisplay = true
    }

    func clear() {
        commitTextEditing()
        guard !annotations.isEmpty else { return }
        pushUndo()
        annotations.removeAll()
        selectedID = nil
        needsDisplay = true
    }

    func deleteSelection() {
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        pushUndo()
        annotations.remove(at: index)
        self.selectedID = nil
        needsDisplay = true
    }

    /// Applies the current color/width to the selected annotation, if any.
    func applyStyleToSelection() {
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        pushUndo()
        annotations[index].color = state.color
        annotations[index].lineWidth = state.lineWidth
        needsDisplay = true
    }

    /// Flattens the image and annotations into a new bitmap at full pixel resolution.
    func renderedImage() -> CGImage? {
        commitTextEditing()
        let width = baseImage.width, height = baseImage.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        // CoreGraphics bitmaps are bottom-left origin: flip to match the view's top-left space,
        // and scale so that one point maps to `scale` pixels.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawContents(showSelection: false)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawContents(showSelection: true)
    }

    private func drawContents(showSelection: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bounds = NSRect(origin: .zero, size: imageSize)
        drawImage(baseImage, in: bounds, context: ctx)

        for annotation in annotations where annotation.id != editingTextID {
            draw(annotation, context: ctx)
        }
        if let draft { draw(draft, context: ctx) }

        if showSelection, let selectedID, let selected = annotations.first(where: { $0.id == selectedID }) {
            let path = NSBezierPath(rect: selected.bounds.insetBy(dx: -3, dy: -3))
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    /// Draws a CGImage into a flipped context without it appearing upside-down.
    private func drawImage(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private func draw(_ a: Annotation, context ctx: CGContext) {
        a.color.setStroke()
        a.color.setFill()

        switch a.tool {
        case .select:
            break

        case .pen:
            let path = Self.smoothPath(through: a.points)
            path.lineWidth = a.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case .rect:
            let path = NSBezierPath(rect: a.rect)
            path.lineWidth = a.lineWidth
            path.lineJoinStyle = .round
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: a.rect)
            path.lineWidth = a.lineWidth
            path.stroke()

        case .line:
            guard let p0 = a.points.first, let p1 = a.points.last else { return }
            let path = NSBezierPath()
            path.move(to: p0)
            path.line(to: p1)
            path.lineWidth = a.lineWidth
            path.lineCapStyle = .round
            path.stroke()

        case .arrow:
            guard let p0 = a.points.first, let p1 = a.points.last else { return }
            let (shaft, head) = Self.arrowParts(from: p0, to: p1, lineWidth: a.lineWidth)
            shaft.stroke()
            head.fill()
            head.stroke()

        case .text:
            guard let origin = a.points.first, let text = a.text, !text.isEmpty else { return }
            (text as NSString).draw(at: origin, withAttributes: a.textAttributes)

        case .mosaic:
            let r = a.rect.intersection(NSRect(origin: .zero, size: imageSize))
            guard !r.isNull, r.width > 0, r.height > 0, let pixelated = pixelatedImage else { return }
            ctx.saveGState()
            ctx.clip(to: r)
            drawImage(pixelated, in: NSRect(origin: .zero, size: imageSize), context: ctx)
            ctx.restoreGState()
        }
    }

    // MARK: - Geometry helpers

    /// Quadratic smoothing through segment midpoints.
    static func smoothPath(through points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.line(to: first)
            return path
        }
        if points.count == 2 {
            path.line(to: points[1])
            return path
        }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            let current = path.currentPoint
            // Convert quadratic (control = points[i]) to cubic.
            let c1 = CGPoint(x: current.x + 2.0 / 3.0 * (points[i].x - current.x),
                             y: current.y + 2.0 / 3.0 * (points[i].y - current.y))
            let c2 = CGPoint(x: mid.x + 2.0 / 3.0 * (points[i].x - mid.x),
                             y: mid.y + 2.0 / 3.0 * (points[i].y - mid.y))
            path.curve(to: mid, controlPoint1: c1, controlPoint2: c2)
        }
        path.line(to: points[points.count - 1])
        return path
    }

    /// Returns the shaft and a filled triangular head. The shaft stops at the head's base so the
    /// round line cap never pokes through the tip.
    static func arrowParts(from p0: CGPoint, to p1: CGPoint, lineWidth: CGFloat) -> (NSBezierPath, NSBezierPath) {
        let length = hypot(p1.x - p0.x, p1.y - p0.y)
        let angle = atan2(p1.y - p0.y, p1.x - p0.x)
        let headLength = min(max(12, lineWidth * 4.5), max(length * 0.6, 1))
        let headHalfAngle: CGFloat = .pi / 7

        let base = CGPoint(x: p1.x - cos(angle) * headLength * 0.85, y: p1.y - sin(angle) * headLength * 0.85)
        let left = CGPoint(x: p1.x - headLength * cos(angle - headHalfAngle),
                           y: p1.y - headLength * sin(angle - headHalfAngle))
        let right = CGPoint(x: p1.x - headLength * cos(angle + headHalfAngle),
                            y: p1.y - headLength * sin(angle + headHalfAngle))

        let shaft = NSBezierPath()
        shaft.move(to: p0)
        shaft.line(to: base)
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round

        let head = NSBezierPath()
        head.move(to: p1)
        head.line(to: left)
        head.line(to: base)
        head.line(to: right)
        head.close()
        head.lineWidth = max(1, lineWidth / 2)
        head.lineJoinStyle = .round
        return (shaft, head)
    }

    static func pixelate(_ image: CGImage, blockSize: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(4, blockSize), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: nil).createCGImage(output, from: input.extent)
    }

    // MARK: - Mouse

    private func point(for event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), imageSize.width), y: min(max(p.y, 0), imageSize.height))
    }

    private func topmostAnnotation(at p: CGPoint) -> Annotation? {
        annotations.last { $0.contains(p) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(for: event)

        // Clicking anywhere commits an in-progress text edit first.
        if isEditingText {
            commitTextEditing()
            if state.tool == .text { return }
        }

        switch state.tool {
        case .select:
            if let hit = topmostAnnotation(at: p) {
                selectedID = hit.id
                if event.clickCount == 2, hit.tool == .text {
                    beginTextEditing(hit)
                    return
                }
                dragAnchor = p
                didPushForDrag = false
            } else {
                selectedID = nil
            }

        case .text:
            if let hit = topmostAnnotation(at: p), hit.tool == .text {
                beginTextEditing(hit)
            } else {
                let annotation = Annotation(tool: .text, points: [p], color: state.color,
                                            lineWidth: state.lineWidth, text: "")
                pushUndo()
                annotations.append(annotation)
                beginTextEditing(annotation, isNew: true)
            }

        case .pen:
            selectedID = nil
            draft = Annotation(tool: .pen, points: [p], color: state.color, lineWidth: state.lineWidth)

        case .rect, .ellipse, .line, .arrow, .mosaic:
            selectedID = nil
            draft = Annotation(tool: state.tool, points: [p, p], color: state.color, lineWidth: state.lineWidth)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(for: event)

        if state.tool == .select, let anchor = dragAnchor, let selectedID,
           let index = annotations.firstIndex(where: { $0.id == selectedID }) {
            if !didPushForDrag {
                pushUndo()
                didPushForDrag = true
            }
            annotations[index].translate(by: CGVector(dx: p.x - anchor.x, dy: p.y - anchor.y))
            dragAnchor = p
            needsDisplay = true
            return
        }

        guard var d = draft else { return }
        if d.tool == .pen {
            if let last = d.points.last, hypot(p.x - last.x, p.y - last.y) < 1 { return }
            d.points.append(p)
        } else {
            var end = p
            // Shift constrains: squares/circles, or 45° lines/arrows.
            if event.modifierFlags.contains(.shift), let start = d.points.first {
                end = Self.constrained(start: start, end: p, tool: d.tool)
            }
            d.points[d.points.count - 1] = end
        }
        draft = d
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        guard let d = draft else { return }
        draft = nil

        let valid: Bool
        if d.tool == .pen {
            valid = !d.points.isEmpty
        } else if let a = d.points.first, let b = d.points.last {
            valid = hypot(b.x - a.x, b.y - a.y) >= 3
        } else {
            valid = false
        }
        if valid {
            pushUndo()
            annotations.append(d)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            deleteSelection()
        default:
            super.keyDown(with: event)
        }
    }

    private static func constrained(start: CGPoint, end: CGPoint, tool: Tool) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        switch tool {
        case .rect, .ellipse, .mosaic:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        default:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        }
    }

    // MARK: - Undo

    private func pushUndo() {
        undoStack.append(annotations)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    // MARK: - Text editing

    private func beginTextEditing(_ annotation: Annotation, isNew: Bool = false) {
        guard let origin = annotation.points.first else { return }
        if !isNew { pushUndo() }
        editingTextID = annotation.id
        selectedID = annotation.id

        let field = NSTextField(string: annotation.text ?? "")
        field.font = NSFont.systemFont(ofSize: annotation.fontSize, weight: .semibold)
        field.textColor = annotation.color
        field.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        field.drawsBackground = true
        field.isBordered = true
        field.isBezeled = false
        field.focusRingType = .none
        field.placeholderString = "Type text"
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.sizeToFit()
        let width = max(160, field.frame.width + 20)
        // View is flipped, so the origin is the top-left corner of the text.
        field.frame = NSRect(x: origin.x - 2, y: origin.y - 1, width: width, height: field.frame.height)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// Ends inline editing and writes the text back; empty text removes the annotation.
    func commitTextEditing() {
        guard let field = textField, let id = editingTextID else { return }
        let value = field.stringValue
        textField = nil
        editingTextID = nil
        field.delegate = nil
        field.removeFromSuperview()
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                annotations.remove(at: index)
                selectedID = nil
            } else {
                annotations[index].text = value
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEditing()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let size = (field.stringValue as NSString).size(withAttributes: [.font: field.font as Any])
        field.frame.size.width = max(160, size.width + 24)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
            commitTextEditing()
            return true
        }
        return false
    }
}
