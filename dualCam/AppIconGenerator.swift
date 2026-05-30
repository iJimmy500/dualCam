import UIKit
import SwiftUI

// MARK: - App Icon Generator
// Run this in a playground or app to generate your icon files

class AppIconGenerator {
    static func generateIcon() -> UIImage? {
        let size = CGSize(width: 1024, height: 1024)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            let ctx = context.cgContext
            
            // Background gradient (dual camera theme)
            let colors = [
                UIColor.systemBlue.cgColor,
                UIColor.systemPurple.cgColor,
                UIColor.systemIndigo.cgColor
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: colors as CFArray,
                                    locations: [0.0, 0.5, 1.0])!
            
            ctx.drawLinearGradient(gradient,
                                 start: CGPoint(x: 0, y: 0),
                                 end: CGPoint(x: size.width, y: size.height),
                                 options: [])
            
            // Rounded rectangle background
            let cornerRadius: CGFloat = size.width * 0.18
            let roundedRect = UIBezierPath(roundedRect: rect.insetBy(dx: 20, dy: 20),
                                         cornerRadius: cornerRadius)
            UIColor.black.withAlphaComponent(0.2).setFill()
            roundedRect.fill()
            
            // Dual camera circles
            let camera1Center = CGPoint(x: size.width * 0.35, y: size.height * 0.4)
            let camera2Center = CGPoint(x: size.width * 0.65, y: size.height * 0.4)
            let cameraRadius: CGFloat = size.width * 0.12
            
            // Camera bodies
            UIColor.white.setFill()
            UIBezierPath(arcCenter: camera1Center, radius: cameraRadius,
                        startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
            UIBezierPath(arcCenter: camera2Center, radius: cameraRadius,
                        startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
            
            // Camera lenses
            UIColor.black.setFill()
            UIBezierPath(arcCenter: camera1Center, radius: cameraRadius * 0.6,
                        startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
            UIBezierPath(arcCenter: camera2Center, radius: cameraRadius * 0.6,
                        startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
            
            // Lens reflections
            UIColor.white.withAlphaComponent(0.3).setFill()
            let reflection1 = CGPoint(x: camera1Center.x - cameraRadius * 0.2,
                                    y: camera1Center.y - cameraRadius * 0.2)
            let reflection2 = CGPoint(x: camera2Center.x - cameraRadius * 0.2,
                                    y: camera2Center.y - cameraRadius * 0.2)
            UIBezierPath(arcCenter: reflection1, radius: cameraRadius * 0.2,
                        startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
            UIBezierPath(arcCenter: reflection2, radius: cameraRadius * 0.2,
                        startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
            
            // App title
            let titleRect = CGRect(x: 0, y: size.height * 0.7,
                                 width: size.width, height: size.height * 0.2)
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.alignment = .center
            
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.width * 0.08, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: titleStyle,
                .shadow: {
                    let shadow = NSShadow()
                    shadow.shadowColor = UIColor.black.withAlphaComponent(0.5)
                    shadow.shadowOffset = CGSize(width: 2, height: 2)
                    shadow.shadowBlurRadius = 4
                    return shadow
                }()
            ]
            "DualCam".draw(in: titleRect, withAttributes: titleAttrs)
        }
    }
}

// MARK: - Usage in SwiftUI
struct IconPreview: View {
    var body: some View {
        if let icon = AppIconGenerator.generateIcon() {
            Image(uiImage: icon)
                .resizable()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}

#Preview {
    IconPreview()
}