import SwiftUI
import UIKit

/// The paper has material. Per the Living Dossier art direction (Pell), the
/// cream carries a faint fiber tooth — "felt, not seen" (~8%). Per Felix, it's
/// rendered ONCE into a cached tiling image and multiplied, never a live
/// per-surface Canvas (which would cost on every scroll). Uniform across
/// surfaces: texture is identity, not a tier signal.
enum PaperTexture {
    /// A small noise tile, generated once at first access and reused everywhere.
    static let tile: UIImage = makeTile()

    private static func makeTile() -> UIImage {
        let size = CGSize(width: 160, height: 160)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            // Faint ink specks over a transparent tile. Multiplied onto cream
            // they read as paper fiber. Density + alpha kept low so the grain
            // is subliminal at the 8% overlay opacity below.
            for _ in 0 ..< 2600 {
                let x = CGFloat.random(in: 0 ..< size.width)
                let y = CGFloat.random(in: 0 ..< size.height)
                let dot = CGFloat.random(in: 0.5 ... 1.3)
                let alpha = CGFloat.random(in: 0.03 ... 0.10)
                cg.setFillColor(UIColor(red: 0.10, green: 0.08, blue: 0.06, alpha: alpha).cgColor)
                cg.fillEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
            }
        }
    }
}

/// The base paper surface: cream + the cached grain, multiplied. Use as a
/// screen background via `.myoPaper()`. Cards (creamElevated) sit on top as
/// smoother sheets, which gives the base its slightly rougher read.
struct PaperBackground: View {
    var body: some View {
        MyoTheme.Colors.cream
            .overlay(
                Image(uiImage: PaperTexture.tile)
                    .resizable(resizingMode: .tile)
                    .opacity(0.8)
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            )
            .ignoresSafeArea()
    }
}

extension View {
    /// Set the grained cream paper as this view's background.
    func myoPaper() -> some View {
        background(PaperBackground())
    }
}
