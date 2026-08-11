#!/usr/bin/env swift

import AppKit
import Foundation

private let canvasWidth = 1_284
private let canvasHeight = 2_778

struct Slide {
    let source: String
    let output: String
    let headline: String
    let subhead: String
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let foreground: NSColor
    let mutedForeground: NSColor
    let pillBackground: NSColor
    let pillForeground: NSColor
    let glow: NSColor
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

private func rectFromTop(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: x, y: CGFloat(canvasHeight) - y - height, width: width, height: height)
}

private func drawText(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    lineHeight: CGFloat,
    kerning: CGFloat = 0
) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    paragraph.lineBreakMode = .byWordWrapping

    NSAttributedString(
        string: text,
        attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: kerning,
        ]
    ).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
}

private func render(_ slide: Slide, sourceDirectory: URL, outputDirectory: URL) throws {
    let sourceURL = sourceDirectory.appendingPathComponent(slide.source)
    guard let screenshot = NSImage(contentsOf: sourceURL) else {
        throw NSError(domain: "MarketingScreenshots", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not open \(sourceURL.path)",
        ])
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let cgContext = CGContext(
        data: nil,
        width: canvasWidth,
        height: canvasHeight,
        bitsPerComponent: 8,
        bytesPerRow: canvasWidth * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw NSError(domain: "MarketingScreenshots", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not create the output bitmap",
        ])
    }
    let context = NSGraphicsContext(cgContext: cgContext, flipped: false)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let bounds = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
    NSGradient(colors: [slide.backgroundBottom, slide.backgroundTop])?.draw(in: bounds, angle: 90)

    slide.glow.withAlphaComponent(0.18).setFill()
    NSBezierPath(ovalIn: rectFromTop(x: 790, y: -130, width: 690, height: 690)).fill()
    slide.glow.withAlphaComponent(0.10).setFill()
    NSBezierPath(ovalIn: rectFromTop(x: -260, y: 1_970, width: 760, height: 760)).fill()

    let pillRect = rectFromTop(x: 96, y: 82, width: 396, height: 76)
    slide.pillBackground.setFill()
    NSBezierPath(roundedRect: pillRect, xRadius: 38, yRadius: 38).fill()
    drawText(
        "✦  WHISPER POLISH",
        in: rectFromTop(x: 130, y: 100, width: 330, height: 42),
        font: .systemFont(ofSize: 30, weight: .semibold),
        color: slide.pillForeground,
        lineHeight: 36,
        kerning: 1.2
    )

    drawText(
        slide.headline,
        in: rectFromTop(x: 96, y: 210, width: 1_090, height: 250),
        font: .systemFont(ofSize: 104, weight: .bold),
        color: slide.foreground,
        lineHeight: 112,
        kerning: -2.0
    )
    drawText(
        slide.subhead,
        in: rectFromTop(x: 100, y: 490, width: 1_030, height: 120),
        font: .systemFont(ofSize: 40, weight: .medium),
        color: slide.mutedForeground,
        lineHeight: 52,
        kerning: -0.2
    )

    let deviceRect = rectFromTop(x: 172, y: 708, width: 940, height: 2_030)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 42
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    NSColor(hex: 0x151918).setFill()
    NSBezierPath(roundedRect: deviceRect, xRadius: 104, yRadius: 104).fill()
    NSGraphicsContext.restoreGraphicsState()

    let screenRect = deviceRect.insetBy(dx: 20, dy: 20)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: screenRect, xRadius: 86, yRadius: 86).addClip()
    screenshot.draw(in: screenRect, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.26).setStroke()
    let rim = NSBezierPath(roundedRect: deviceRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 102, yRadius: 102)
    rim.lineWidth = 3
    rim.stroke()

    guard let cgImage = cgContext.makeImage() else {
        throw NSError(domain: "MarketingScreenshots", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Could not create \(slide.output)",
        ])
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MarketingScreenshots", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Could not encode \(slide.output)",
        ])
    }
    try png.write(to: outputDirectory.appendingPathComponent(slide.output), options: .atomic)
}

let appStoreDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppStore")
    .standardizedFileURL
let sourceDirectory = appStoreDirectory.appendingPathComponent("Screenshots/iphone-65", isDirectory: true)
let outputDirectory = appStoreDirectory.appendingPathComponent("Screenshots/iphone-65-marketing", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let ink = NSColor(hex: 0x101716)
let teal = NSColor(hex: 0x0E8178)
let cream = NSColor(hex: 0xFFF8EC)
let white = NSColor.white

let slides = [
    Slide(
        source: "01-notes.png",
        output: "01-talk-naturally.png",
        headline: "Talk naturally.\nWrite clearly.",
        subhead: "Private, on-device transcription turns speech into editable notes.",
        backgroundTop: NSColor(hex: 0x0E8178),
        backgroundBottom: NSColor(hex: 0x075E59),
        foreground: white,
        mutedForeground: NSColor(hex: 0xD7F5EF),
        pillBackground: white.withAlphaComponent(0.16),
        pillForeground: white,
        glow: NSColor(hex: 0x86E1D4)
    ),
    Slide(
        source: "02-polished-email.png",
        output: "02-clear-writing.png",
        headline: "Rough thoughts in.\nClear writing out.",
        subhead: "Turn a rambling voice note into email-ready copy in seconds.",
        backgroundTop: NSColor(hex: 0xFFF8EC),
        backgroundBottom: NSColor(hex: 0xEFE3D0),
        foreground: ink,
        mutedForeground: NSColor(hex: 0x415652),
        pillBackground: teal,
        pillForeground: white,
        glow: NSColor(hex: 0xF2B45B)
    ),
    Slide(
        source: "03-choose-style.png",
        output: "03-match-the-moment.png",
        headline: "Match the moment.",
        subhead: "Choose email, Slack, social, summaries—or make your own style.",
        backgroundTop: NSColor(hex: 0xDDF3EE),
        backgroundBottom: NSColor(hex: 0xBFDCD6),
        foreground: ink,
        mutedForeground: NSColor(hex: 0x315A55),
        pillBackground: ink,
        pillForeground: white,
        glow: teal
    ),
    Slide(
        source: "04-cloud-plan.png",
        output: "04-simple-cloud-plan.png",
        headline: "300 cloud polishes.\n$4.99 a month.",
        subhead: "No API key required. One predictable monthly plan.",
        backgroundTop: NSColor(hex: 0x15201E),
        backgroundBottom: NSColor(hex: 0x080D0C),
        foreground: white,
        mutedForeground: NSColor(hex: 0xB9D5D0),
        pillBackground: teal,
        pillForeground: white,
        glow: teal
    ),
    Slide(
        source: "05-bullet-summary.png",
        output: "05-actionable-summaries.png",
        headline: "Turn rambling notes\ninto action.",
        subhead: "Create a crisp, useful bullet summary in a single tap.",
        backgroundTop: NSColor(hex: 0xF5D58E),
        backgroundBottom: NSColor(hex: 0xDEAA55),
        foreground: ink,
        mutedForeground: NSColor(hex: 0x4E3A1D),
        pillBackground: ink,
        pillForeground: cream,
        glow: cream
    ),
]

for slide in slides {
    try render(slide, sourceDirectory: sourceDirectory, outputDirectory: outputDirectory)
    print("Rendered \(slide.output)")
}
