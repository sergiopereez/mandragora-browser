// Makes the app's drawings from the pictures in art/: the icon (the knight on
// the dragon, on cream), the seal (the knight and the sword, close up) and
// the four of the welcome. Ink is told from paper by its darkness, so the
// wood-cut's specks stay.
//
//   swiftc -O Icon/art.swift -o /tmp/art && /tmp/art Icon/art Sources/Assets.xcassets
import AppKit
import CoreImage

let args = CommandLine.arguments
let art = args[1], out = args[2]

/// A picture as ink: 0 paper, 1 ink, `up` times larger for clean edges.
struct Ink {
    var w: Int, h: Int, a: [Float]

    init(_ path: String, up: Int) {
        let image = CIImage(contentsOf: URL(fileURLWithPath: path))!
        let big = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": up, "inputAspectRatio": 1])
        w = Int(image.extent.width) * up
        h = Int(image.extent.height) * up
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(big, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)
        a = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let alpha = Float(px[i * 4 + 3]) / 255
            // Premultiplied: what isn't there counts as paper.
            let l = (0.2126 * Float(px[i * 4]) + 0.7152 * Float(px[i * 4 + 1]) + 0.0722 * Float(px[i * 4 + 2])) / 255 + (1 - alpha)
            let t = min(1, max(0, (0.62 - l) / 0.30))
            a[i] = t * t * (3 - 2 * t)
        }
    }

    /// The box around the ink, in this picture's pixels, from the top left.
    var box: CGRect {
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        for y in 0..<h { for x in 0..<w where a[y * w + x] > 0.5 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// As a picture in one colour.
    func image(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = CGFloat(a[i])
            px[i * 4] = UInt8(r * v * 255); px[i * 4 + 1] = UInt8(g * v * 255); px[i * 4 + 2] = UInt8(b * v * 255); px[i * 4 + 3] = UInt8(v * 255)
        }
        let data = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: data, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// A canvas with `part` of the ink drawn into `place` (both from the top left).
func canvas(_ width: Int, _ height: Int, opaque: Bool, _ draw: (CGContext) -> Void) -> CGImage {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
    c.interpolationQuality = .high
    draw(c)
    return c.makeImage()!
}

func put(_ image: CGImage, _ part: CGRect, into place: CGRect, in c: CGContext, height: Int) {
    let s = place.width / part.width
    let whole = CGRect(x: place.minX - part.minX * s, y: place.minY - part.minY * s, width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)
    c.draw(image, in: CGRect(x: whole.minX, y: CGFloat(height) - whole.maxY, width: whole.width, height: whole.height))
}

func save(_ image: CGImage, _ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func json(_ text: String, _ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
}

func template(_ name: String) {
    json("""
    {
      "images" : [
        { "filename" : "mark.png", "idiom" : "universal", "scale" : "3x" }
      ],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : { "template-rendering-intent" : "template" }
    }

    """, "\(out)/\(name).imageset/Contents.json")
}

// MARK: the icon

let dragon = Ink("\(art)/dragon.png", up: 2)
let box = dragon.box
let ink = dragon.image(0.114, 0.102, 0.090)
let side = 1024
/// How tall the rider and the dragon stand in the icon.
let tall: CGFloat = 0.735 * 1024
let wide = tall * box.width / box.height
let place = CGRect(x: (1024 - wide) / 2, y: (1024 - tall) / 2 - 4, width: wide, height: tall)
let light = canvas(side, side, opaque: true) { c in
    c.setFillColor(CGColor(srgbRed: 245 / 255, green: 243 / 255, blue: 238 / 255, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: side, height: side))
    put(ink, box, into: place, in: c, height: side)
}
save(light, "\(out)/AppIcon.appiconset/icon-light.png")
save(light, "\(out)/AppIcon.appiconset/icon-dark.png")
let white = dragon.image(1, 1, 1)
save(canvas(side, side, opaque: true) { c in
    c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: side, height: side))
    put(white, box, into: place, in: c, height: side)
}, "\(out)/AppIcon.appiconset/icon-tinted.png")

// MARK: the seal: the rider and the sword, to the button's very edge

/// What is the dragon's beside the rider, left out of the seal: at that
/// size it is only noise. Traced in the picture's own pixels.
func without(_ shapes: [[(Double, Double)]], _ ink: Ink, up: Double) -> Ink {
    var ink = ink
    for shape in shapes {
        for y in 0..<ink.h { for x in 0..<ink.w {
            let px = Double(x) / up, py = Double(y) / up
            var inside = false, j = shape.count - 1
            for i in 0..<shape.count {
                let (xi, yi) = shape[i], (xj, yj) = shape[j]
                if (yi > py) != (yj > py), px < (xj - xi) * (py - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
            if inside { ink.a[y * ink.w + x] = 0 }
        } }
    }
    return ink
}
let alone = args.count > 6 && args[6] == "all" ? dragon : without([
    // The head, the horns and the neck.
    [(360, 450), (578, 450), (592, 500), (600, 545), (604, 566), (600, 590), (596, 612), (588, 700), (360, 700)],
    // The wing.
    [(742, 500), (900, 500), (900, 700), (716, 700), (722, 640), (704, 610), (706, 572), (716, 560), (734, 548)],
], dragon, up: 2)
let black = alone.image(0, 0, 0)
/// The circle the button shows, in the picture's own pixels.
let seal = args.count > 5 ? (x: Double(args[3])!, y: Double(args[4])!, r: Double(args[5])!) : (x: 662.0, y: 470.0, r: 150.0)
save(canvas(144, 144, opaque: false) { c in
    let part = CGRect(x: (seal.x - seal.r) * 2, y: (seal.y - seal.r) * 2, width: seal.r * 4, height: seal.r * 4)
    put(black, part, into: CGRect(x: 0, y: 0, width: 144, height: 144), in: c, height: 144)
}, "\(out)/SealMark.imageset/mark.png")
template("SealMark")

// MARK: the welcome

/// Each in a box of 150 points, by eye about the same weight.
for (name, file, size) in [("WelcomeLens", "lens", 128.0), ("WelcomeGauntlet", "gauntlet", 146.0), ("WelcomeBook", "book", 150.0), ("WelcomeChain", "chain", 134.0)] {
    let picture = Ink("\(art)/\(file).png", up: 1)
    let b = picture.box
    let s = size * 3 / max(b.width, b.height)
    let w = b.width * s, h = b.height * s
    save(canvas(450, 450, opaque: false) { c in
        put(picture.image(0, 0, 0), b, into: CGRect(x: (450 - w) / 2, y: (450 - h) / 2, width: w, height: h), in: c, height: 450)
    }, "\(out)/\(name).imageset/mark.png")
    template(name)
}
print("box", box)
