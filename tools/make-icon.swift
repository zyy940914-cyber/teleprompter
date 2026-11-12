import AppKit
import CoreGraphics

// 生成 1024x1024 App 图标（渐变底 + 提词文字行 + 悬浮小窗）
let size: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(data: nil,
                          width: Int(size), height: Int(size),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)

// 背景渐变
let c1 = CGColor(colorSpace: cs, components: [0.42, 0.28, 0.91, 1])!
let c2 = CGColor(colorSpace: cs, components: [0.91, 0.35, 0.54, 1])!
if let grad = CGGradient(colorsSpace: cs, colors: [c1, c2] as CFArray, locations: [0, 1]) {
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
}

// 文字行
ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 0.95])!)
let lineHeight: CGFloat = 62
let lineGap: CGFloat = 46
let widths: [CGFloat] = [560, 660, 500, 620, 380]
var y = size * 0.66
for w in widths {
    let r = CGRect(x: size * 0.16, y: y, width: w, height: lineHeight)
    let p = CGPath(roundedRect: r, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil)
    ctx.addPath(p)
    ctx.fillPath()
    y -= (lineHeight + lineGap)
}

// 悬浮小窗
let pipRect = CGRect(x: size * 0.50, y: size * 0.10, width: size * 0.40, height: size * 0.28)
let pipPath = CGPath(roundedRect: pipRect, cornerWidth: 34, cornerHeight: 34, transform: nil)
ctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 0, 0.35])!)
ctx.addPath(pipPath)
ctx.fillPath()

ctx.setStrokeColor(CGColor(colorSpace: cs, components: [1, 1, 1, 0.92])!)
ctx.setLineWidth(9)
ctx.addPath(pipPath)
ctx.strokePath()

// 小窗里的文字行
ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 0.9])!)
for (i, w) in [0.28, 0.30, 0.20].enumerated() {
    let r = CGRect(x: pipRect.minX + 26, y: pipRect.maxY - 40 - CGFloat(i) * 40,
                   width: pipRect.width * CGFloat(w) * 2.2, height: 18)
    let p = CGPath(roundedRect: r, cornerWidth: 9, cornerHeight: 9, transform: nil)
    ctx.addPath(p)
    ctx.fillPath()
}

guard let cgImage = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon1024.png"
try data.write(to: URL(fileURLWithPath: outPath))
// FileManager 写入
print("icon written to \(outPath)")
