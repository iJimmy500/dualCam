import UIKit
import SwiftUI
import Foundation

enum MediaType {
    case photo, video
}

enum AspectRatio: String, CaseIterable, Identifiable {
    case full = "Full"

    var id: String { rawValue }

    var ratio: CGFloat? { nil }
}

enum LayoutMode: String, CaseIterable, Identifiable {
    case pip   = "Picture in Picture"
    case spotH = "Spotlight"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pip:   return "pip"
        case .spotH: return "rectangle.topthird.inset.filled"
        }
    }

    var shortLabel: String {
        switch self {
        case .pip:   return "PiP"
        case .spotH: return "Spotlight"
        }
    }
}

enum PipFrameStyle: String, CaseIterable, Identifiable {
    case none   = "None"
    case solid  = "Solid"
    case thick  = "Thick"
    case double = "Double"
    case dashed = "Dashed"
    case glass  = "Glass"
    case glow   = "Glow"
    case neon   = "Neon"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .none:   return "square.dashed"
        case .solid:  return "square"
        case .thick:  return "square.fill"
        case .double: return "square.on.square"
        case .dashed: return "square.dotted"
        case .glass:  return "square.topthird.inset.filled"
        case .glow:   return "sparkle"
        case .neon:   return "bolt.square"
        }
    }
}

struct AnyShape: Shape {
    private let pathClosure: (CGRect) -> Path
    
    init<S: Shape>(_ shape: S) {
        self.pathClosure = { rect in shape.path(in: rect) }
    }
    
    func path(in rect: CGRect) -> Path {
        pathClosure(rect)
    }
}

enum PipShape: String, CaseIterable, Identifiable {
    case roundedRect = "Rounded Rect"
    case circle      = "Circle"
    
    var id: String { rawValue }
    
    var systemImage: String {
        switch self {
        case .roundedRect: return "rectangle.portrait"
        case .circle:      return "circle"
        }
    }
    
    var shape: AnyShape {
        switch self {
        case .roundedRect: return AnyShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        case .circle:      return AnyShape(Circle())
        }
    }
}

extension UIBezierPath {
    static func pathForShape(_ shape: PipShape, in rect: CGRect, cornerRadius: CGFloat = 20) -> UIBezierPath {
        switch shape {
        case .roundedRect:
            return UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
        case .circle:
            return UIBezierPath(ovalIn: rect)
        }
    }
}

enum PipFrameColor: String, CaseIterable, Identifiable {
    case white  = "White"
    case silver = "Silver"
    case black  = "Black"
    case gold   = "Gold"
    case blue   = "Blue"
    case rose   = "Rose"
    case mint   = "Mint"
    case orange = "Orange"

    var id: String { rawValue }

    var uiColor: UIColor {
        switch self {
        case .white:  return .white
        case .silver: return UIColor(white: 0.72, alpha: 1)
        case .black:  return UIColor(white: 0.08, alpha: 1)
        case .gold:   return UIColor(red: 1,    green: 0.84, blue: 0.0,  alpha: 1)
        case .blue:   return UIColor(red: 0.2,  green: 0.6,  blue: 1.0,  alpha: 1)
        case .rose:   return UIColor(red: 1,    green: 0.35, blue: 0.55, alpha: 1)
        case .mint:   return UIColor(red: 0.18, green: 0.88, blue: 0.66, alpha: 1)
        case .orange: return UIColor(red: 1,    green: 0.55, blue: 0.1,  alpha: 1)
        }
    }

    var color: Color {
        switch self {
        case .white:  return .white
        case .silver: return Color(white: 0.72)
        case .black:  return Color(white: 0.08)
        case .gold:   return Color(red: 1,    green: 0.84, blue: 0)
        case .blue:   return Color(red: 0.2,  green: 0.6,  blue: 1)
        case .rose:   return Color(red: 1,    green: 0.35, blue: 0.55)
        case .mint:   return Color(red: 0.18, green: 0.88, blue: 0.66)
        case .orange: return Color(red: 1,    green: 0.55, blue: 0.1)
        }
    }

    // Swatch dot shown in settings — slightly adapted for visibility on dark bg
    var swatchColor: Color {
        self == .black ? Color(white: 0.22) : color
    }
}

enum CameraPair: String, CaseIterable, Identifiable {
    case frontAndBack          = "Front + Back"
    case wideAndUltrawide      = "Wide + Ultra"
    case ultraAndFront         = "Ultra + Front"
    case wideAndTelephoto      = "Wide + Tele"
    case telephotoAndFront     = "Tele + Front"
    case ultrawideAndTelephoto = "Ultra + Tele"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .frontAndBack:          return "arrow.triangle.2.circlepath.camera"
        case .wideAndUltrawide:      return "camera.aperture"
        case .ultraAndFront:         return "camera.on.rectangle"
        case .wideAndTelephoto:      return "camera.filters"
        case .telephotoAndFront:     return "camera.on.rectangle.fill"
        case .ultrawideAndTelephoto: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var shortLabel: String {
        switch self {
        case .frontAndBack:          return "F + B"
        case .wideAndUltrawide:      return "W + U"
        case .ultraAndFront:         return "U + F"
        case .wideAndTelephoto:      return "W + T"
        case .telephotoAndFront:     return "T + F"
        case .ultrawideAndTelephoto: return "U + T"
        }
    }

    var requiresTelephoto: Bool {
        switch self {
        case .wideAndTelephoto, .telephotoAndFront, .ultrawideAndTelephoto: return true
        default: return false
        }
    }
}

@MainActor
class MediaItem: Identifiable, ObservableObject, Equatable {
    let id = UUID()
    let type: MediaType
    let createdAt = Date()
    let cameraPair: CameraPair

    // Photos — primaryImage holds the composited result
    var primaryImage: UIImage?
    var secondaryImage: UIImage?

    // Videos — both streams kept for playback
    var primaryVideoURL: URL?
    var secondaryVideoURL: URL?

    var thumbnail: UIImage?

    init(type: MediaType, pair: CameraPair) {
        self.type = type
        self.cameraPair = pair
    }
    
    // MARK: - Equatable
    
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        return lhs.id == rhs.id
    }
}
