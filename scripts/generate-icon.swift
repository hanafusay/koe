#!/usr/bin/env swift
// generate-icon.swift — koe! アプリアイコン & メニューバーアイコン生成
//
// Usage:
//   swift generate-icon.swift app    <output-png>     -- 1024x1024 アプリアイコン
//   swift generate-icon.swift menu   <output-png>     -- メニューバーテンプレート (44x44)
//   swift generate-icon.swift menu1x <output-png>     -- メニューバーテンプレート (22x22)

import AppKit

guard CommandLine.arguments.count > 2 else {
    fputs("Usage: swift generate-icon.swift <app|menu|menu1x> <output-png>\n", stderr)
    exit(1)
}

let mode = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

func render(size: Int, to path: String, _ draw: (CGContext, CGFloat) -> Void) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext, CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Generated: \(path)")
}

/// 録音中の表示と同じ、中央ほど長い 5 本の棒。
func drawBars(in ctx: CGContext, rect: CGRect, color: CGColor) {
    let heights: [CGFloat] = [0.34, 0.62, 1.0, 0.62, 0.34]
    let barWidth = rect.width * 0.12
    let gap = (rect.width - barWidth * CGFloat(heights.count)) / CGFloat(heights.count - 1)
    ctx.setFillColor(color)
    for (index, height) in heights.enumerated() {
        let barHeight = rect.height * 0.86 * height
        let bar = CGRect(
            x: rect.minX + CGFloat(index) * (barWidth + gap),
            y: rect.midY - barHeight / 2,
            width: barWidth,
            height: barHeight
        )
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
    }
}

func generateAppIcon() {
    render(size: 1024, to: outputPath) { ctx, s in
        // macOS のアイコン格子に合わせ、外周に余白を取った角丸に描く。
        let inset = s * 0.1
        let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let shape = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1), CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
        ctx.restoreGState()

        drawBars(in: ctx, rect: body.insetBy(dx: body.width * 0.27, dy: body.height * 0.27), color: CGColor(gray: 1, alpha: 1))
    }
}

func generateMenuBarIcon(scale: Int) {
    render(size: 22 * scale, to: outputPath) { ctx, s in
        drawBars(in: ctx, rect: CGRect(x: s * 0.14, y: s * 0.14, width: s * 0.72, height: s * 0.72), color: CGColor(gray: 0, alpha: 1))
    }
}

switch mode {
case "app":
    generateAppIcon()
case "menu":
    generateMenuBarIcon(scale: 2)
case "menu1x":
    generateMenuBarIcon(scale: 1)
default:
    fputs("Unknown mode: \(mode). Use 'app', 'menu', or 'menu1x'.\n", stderr)
    exit(1)
}
