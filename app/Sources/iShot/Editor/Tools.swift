import AppKit

/// Editor tools.
enum Tool: String, CaseIterable {
    case select, pen, rect, ellipse, line, arrow, text, mosaic

    var title: String {
        switch self {
        case .select: return "Select"
        case .pen: return "Pen"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .mosaic: return "Mosaic"
        }
    }

    /// SF Symbol name used in the toolbar.
    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .mosaic: return "checkerboard.rectangle"
        }
    }

    /// Tools defined by a start/end drag (two points).
    var isTwoPoint: Bool {
        switch self {
        case .rect, .ellipse, .line, .arrow, .mosaic: return true
        default: return false
        }
    }
}

/// Current drawing state shared by the toolbar and the editor view.
final class ToolState {
    var tool: Tool = .rect { didSet { onChange?() } }
    var color: NSColor = .systemRed { didSet { onChange?() } }
    var lineWidth: CGFloat = 3 { didSet { onChange?() } }

    /// Font size used for text annotations, derived from the line width.
    var fontSize: CGFloat { max(12, lineWidth * 6) }

    var onChange: (() -> Void)?
}
