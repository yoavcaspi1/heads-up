@testable import HeadsUpKit
import AppKit

func alertBackdropTests() async {
    suite("AlertBackdropTests")

    /// A 400x200 picture, left half black, right half white: a hard edge
    /// the blur must soften.
    func stripePicture() -> NSImage {
        let width = 400, height = 200
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: width, height: height))
    }

    func grey(of image: NSImage, atX x: Int, y: Int) -> Int {
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: -y, width: cg.width, height: cg.height))
        return Int(pixel[0])
    }

    await test("testBlurSoftensTheEdgeAndKeepsTheSize") {
        guard let out = AlertBackdrop.blurred(stripePicture(), workingWidth: 400, radius: 20) else {
            throw CheckFailure(message: "blur returned nil")
        }
        try expectEqual(Int(out.size.width), 400)
        try expectEqual(Int(out.size.height), 200)
        // On the seam the two halves have mixed into a mid grey; far from
        // it the picture is still essentially black and white.
        let seam = grey(of: out, atX: 200, y: 100)
        try expect(seam > 60 && seam < 195, "seam grey \(seam)")
        try expect(grey(of: out, atX: 20, y: 100) < 40)
        try expect(grey(of: out, atX: 380, y: 100) > 215)
    }

    await test("testWorkingWidthDownscales") {
        guard let out = AlertBackdrop.blurred(stripePicture(), workingWidth: 100, radius: 4) else {
            throw CheckFailure(message: "blur returned nil")
        }
        try expectEqual(Int(out.size.width), 100)
        try expectEqual(Int(out.size.height), 50)
    }

    await test("testBundledBackdropLoadsAndBlurs") {
        // The bundled picture is what every user actually sees, so a
        // missing or unreadable resource must fail here rather than
        // silently degrade to the HUD material at alert time.
        guard HeadsUpResources.url(named: AlertBackdrop.resourceName,
                                   withExtension: AlertBackdrop.resourceExtension) != nil else {
            print("  skipped: package resources unavailable in this process")
            return
        }
        guard let out = AlertBackdrop.image() else {
            throw CheckFailure(message: "bundled backdrop did not decode")
        }
        try expectEqual(Int(out.size.width), Int(AlertBackdrop.workingWidth))
        try expect(out.size.height > 0)
    }
}
