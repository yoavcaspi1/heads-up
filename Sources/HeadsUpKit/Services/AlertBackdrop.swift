import AppKit
import CoreImage

/// The alert's frosted background: a picture shipped inside the app,
/// Gaussian-blurred. Chosen over a live blur of the screen contents because
/// every AppKit material that blurs live content adds a heavy tint (the
/// most transparent, HUD, still reads as grey glass), and capturing the
/// screen to blur it ourselves would need Screen Recording permission from
/// every user. Earlier builds blurred the user's own desktop picture, which
/// needed no permission either but made the alert look different on every
/// Mac and vanish entirely on a solid-colour desktop; a bundled picture
/// gives every user the same deliberate surface.
enum AlertBackdrop {
    /// Width the picture is scaled to before blurring. The blur hides
    /// anything finer, and a 5K source would cost hundreds of milliseconds
    /// at alert time for no visible gain.
    static let workingWidth: CGFloat = 1600
    /// Blur radius at the working width, in pixels.
    static let radius: Double = 28

    /// Resource name of the bundled picture, without its extension.
    static let resourceName = "AlertBackdrop"
    static let resourceExtension = "jpg"

    private static var cache: NSImage?

    /// The bundled picture, blurred. Cached after the first alert so a
    /// repeat alert costs nothing. Nil only when the resource bundle is
    /// missing or the picture cannot be decoded, which the caller treats
    /// as a reason to fall back to a system material.
    static func image() -> NSImage? {
        if let cache { return cache }
        guard let url = HeadsUpResources.url(named: resourceName, withExtension: resourceExtension),
              let source = NSImage(contentsOf: url),
              let blurred = blurred(source, workingWidth: workingWidth, radius: radius) else { return nil }
        cache = blurred
        return blurred
    }

    /// Pure image step, separated so checks can run it on a synthetic
    /// picture: scale to `workingWidth`, clamp the edges so the blur does
    /// not fade to transparent at the borders, blur, crop back.
    static func blurred(_ image: NSImage, workingWidth: CGFloat, radius: Double) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var ci = CIImage(cgImage: cg)
        let scale = min(1, workingWidth / ci.extent.width)
        if scale < 1 {
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = ci.extent
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let result = context.createCGImage(output, from: extent) else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: extent.width, height: extent.height))
    }
}
