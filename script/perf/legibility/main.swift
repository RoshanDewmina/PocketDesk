import Foundation
import CoreGraphics
import ImageIO
import Vision

// Scores screenshots of the bench chart with the same Vision scorer the phone uses.
// Build and run with script/perf/legibility.sh; see its usage text.

struct Options {
    var seed: UInt16?
    var readMarker = false
    var json = false
    var paths: [String] = []
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--seed":
            index += 1
            guard index < arguments.count else { break }
            let text = arguments[index]
            options.seed = text.hasPrefix("0x") ? UInt16(text.dropFirst(2), radix: 16) : UInt16(text)
        case "--marker": options.readMarker = true
        case "--json": options.json = true
        default: options.paths.append(argument)
        }
        index += 1
    }
    return options
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func luma(of image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }
    // A bitmap context's memory runs top-down, which is the reader's top-left origin.
    return (pixels, width, height)
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
guard !options.paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: legibility [--seed N|0xNNN] [--marker] [--json] image.png ...\n".utf8))
    exit(64)
}

var reports: [[String: Any]] = []
for path in options.paths {
    guard let image = loadImage(path) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        continue
    }
    var seed = options.seed
    var markerNote = "seed from --seed"
    if options.readMarker || seed == nil, let plane = luma(of: image) {
        let marker = plane.pixels.withUnsafeBufferPointer {
            BenchMarker.read(luma: $0.baseAddress!, width: plane.width, height: plane.height, bytesPerRow: plane.width)
        }
        if let marker {
            seed = marker.chartSeed
            markerNote = "seed \(marker.chartSeed) read from the marker (time \(marker.timeMs) ms, flash \(marker.flash), motion \(marker.motion))"
        } else if seed == nil {
            markerNote = "no marker strip found; pass --seed"
        }
    }
    guard let seed else {
        FileHandle.standardError.write(Data("\(path): \(markerNote)\n".utf8))
        continue
    }
    do {
        let result = try LegibilityScore.score(image: image, seed: seed)
        let cer = result.cerBySize
        var report: [String: Any] = ["path": path, "seed": Int(seed), "note": markerNote, "cer": cer,
                                     "exact": result.cells.filter { $0.cer == 0 }.count, "cells": result.cells.count]
        report["rows"] = result.cells.map { ["id": $0.cell.id, "truth": $0.cell.text, "read": $0.recognized ?? "", "cer": ($0.cer * 1000).rounded() / 10] }
        reports.append(report)
        if !options.json {
            print("\(path): \(markerNote)")
            let order = ["9pt", "11pt", "13pt", "15pt", "coloured11pt"]
            print("  CER  " + order.compactMap { key in cer[key].map { "\(key) \(String(format: "%.1f", $0))%" } }.joined(separator: "  ") +
                  "  · exact \(result.cells.filter { $0.cer == 0 }.count)/\(result.cells.count)")
            for score in result.cells where score.cer > 0 {
                print("    \(score.cell.id) \(score.cell.text) → \(score.recognized ?? "unread") (\(String(format: "%.0f", score.cer * 100))%)")
            }
        }
    } catch {
        FileHandle.standardError.write(Data("\(path): Vision failed: \(error)\n".utf8))
    }
}
if options.json, let data = try? JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]) {
    print(String(data: data, encoding: .utf8) ?? "[]")
}
