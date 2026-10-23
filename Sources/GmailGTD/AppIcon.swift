import SwiftUI
import AppKit

/// The app icon, drawn in code so there is one source for the Dock icon and the bundle's .icns.
/// A mail envelope with a check badge, on a standard macOS squircle. (Apple's licence doesn't allow SF Symbols
/// in app icons, so the artwork is plain shapes.)
struct AppIconView: View {
    private let blue = Color(red: 0.04, green: 0.52, blue: 1.0)
    private let lightBlue = Color(red: 0.39, green: 0.82, blue: 1.0)
    private let green = Color(red: 0.19, green: 0.82, blue: 0.35)

    var body: some View {
        ZStack {
            // macOS icons sit inside a 1024 canvas with a margin: the squircle is 824 wide.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [lightBlue, blue], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 20, y: 14)

            ZStack {
                RoundedRectangle(cornerRadius: 56, style: .continuous)
                    .fill(.white)
                    .frame(width: 500, height: 360)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                EnvelopeFlap()
                    .stroke(blue.opacity(0.85), style: StrokeStyle(lineWidth: 26, lineCap: .round, lineJoin: .round))
                    .frame(width: 500, height: 360)
            }
            .offset(y: -30)

            ZStack {
                Circle().fill(green).frame(width: 230, height: 230)
                Circle().strokeBorder(.white, lineWidth: 18).frame(width: 230, height: 230)
                Checkmark()
                    .stroke(.white, style: StrokeStyle(lineWidth: 34, lineCap: .round, lineJoin: .round))
                    .frame(width: 112, height: 82)
            }
            .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
            .offset(x: 215, y: 150)
        }
        .frame(width: 1024, height: 1024)
    }
}

private struct EnvelopeFlap: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.width * 0.10, y: r.height * 0.20))
        p.addLine(to: CGPoint(x: r.width * 0.50, y: r.height * 0.58))
        p.addLine(to: CGPoint(x: r.width * 0.90, y: r.height * 0.20))
        return p
    }
}

private struct Checkmark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: r.height * 0.55))
        p.addLine(to: CGPoint(x: r.width * 0.38, y: r.height))
        p.addLine(to: CGPoint(x: r.width, y: 0))
        return p
    }
}

@MainActor
enum AppIcon {
    /// The icon as an image at `pixels` x `pixels`.
    static func png(pixels: Int) -> Data? {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = CGFloat(pixels) / 1024
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// For the Dock, when running without an app bundle (`swift run`).
    static var image: NSImage? { png(pixels: 512).flatMap(NSImage.init(data:)) }

    /// Writes the files `iconutil` needs to build an .icns: `GmailGTD --export-icon <folder>.iconset`.
    static func exportIconset(to folder: String) {
        let sizes: [(String, Int)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
            ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
            ("512x512", 512), ("512x512@2x", 1024),
        ]
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for (name, pixels) in sizes {
            if let data = png(pixels: pixels) { try? data.write(to: URL(filePath: folder).appending(path: "icon_\(name).png")) }
        }
    }
}
