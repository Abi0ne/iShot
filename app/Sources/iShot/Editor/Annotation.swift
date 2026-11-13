import AppKit

/// A single annotation drawn over the screenshot.
/// Points are stored in **image coordinates** (points, top-left origin, y down),
/// matching the flipped `EditorView`.
struct Annotation: Identifiable {
    let id: UUID
    var tool: Tool
    /// pen: polyline; rect/ellipse/line/arrow/mosaic: [start, end]; text: [origin]
    var points: [CGPoint]
    var color: NSColor
    var lineWidth: CGFloat
    /// Only used by `.text`.
    var text: String?

    init(id: UUID = UUID(), tool: Tool, points: [CGPoint], color: NSColor, lineWidth: CGFloat, text: String? = nil) {
        self.id = id
        self.tool = tool
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
    }

    /// Normalized rectangle spanned by the first and last point.
    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    var fontSize: CGFloat { max(12, lineWidth * 6) }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color]
    }

    /// Bounding box used for hit testing and selection.
    var bounds: CGRect {
        switch tool {
        case .text:
            guard let origin = points.first else { return .zero }
            let size = ((text?.isEmpty == false ? text! : " ") as NSString).size(withAttributes: textAttributes)
            return CGRect(origin: origin, size: size)
        case .pen:
            guard let first = points.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -lineWidth, dy: -lineWidth)
        default:
            return rect.insetBy(dx: -lineWidth, dy: -lineWidth)
        }
    }

    /// Hit test with a small tolerance.
    func contains(_ point: CGPoint) -> Bool {
        let tolerance = max(6, lineWidth * 2)
        switch tool {
        case .line, .arrow:
            guard let a = points.first, let b = points.last else { return false }
            return Self.distance(from: point, toSegment: a, b) <= tolerance
        case .pen:
            for (a, b) in zip(points, points.dropFirst()) where Self.distance(from: point, toSegment: a, b) <= tolerance {
                return true
            }
            return false
        case .rect, .ellipse:
            // Hit the outline or the inside, so small shapes are easy to grab.
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        default:
            return bounds.insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    mutating func translate(by delta: CGVector) {
        points = points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
