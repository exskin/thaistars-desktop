import Foundation
import AVFoundation
import Vision
import CoreImage
import ImageIO

// 用法: frames <video> <outDir> <fps> <targetHeight>
// 抽幀→雙通道摳圖(人物∪亮度,去黑底)→銳化邊→全局裁剪→縮放→存PNG序列
let a = CommandLine.arguments
guard a.count >= 5, let fps = Double(a[3]), let targetH = Double(a[4]) else {
    FileHandle.standardError.write("usage: frames <video> <outDir> <fps> <targetH>\n".data(using: .utf8)!); exit(1)
}
let videoPath = a[1], outDir = a[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func savePNG(_ cg: CGImage, _ path: String) {
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
}

func keyBlack(_ ci: CIImage) -> CIImage {
    let m1 = CIFilter(name: "CIColorMatrix")!
    m1.setValue(ci, forKey: kCIInputImageKey)
    m1.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
    m1.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
    m1.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
    m1.setValue(CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0), forKey: "inputAVector")
    let m2 = CIFilter(name: "CIColorMatrix")!
    m2.setValue(m1.outputImage!, forKey: kCIInputImageKey)
    m2.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
    m2.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
    m2.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
    m2.setValue(CIVector(x: 0, y: 0, z: 0, w: 9), forKey: "inputAVector")
    m2.setValue(CIVector(x: 0, y: 0, z: 0, w: -0.75), forKey: "inputBiasVector")
    let c = CIFilter(name: "CIColorClamp")!; c.setValue(m2.outputImage!, forKey: kCIInputImageKey)
    return c.outputImage!
}
// 銳化灰度mask的邊（提高對比，去柔邊霧）
func sharpenMask(_ m: CIImage) -> CIImage {
    let f = CIFilter(name: "CIColorMatrix")!
    f.setValue(m, forKey: kCIInputImageKey)
    f.setValue(CIVector(x: 4, y: 0, z: 0, w: 0), forKey: "inputRVector")
    f.setValue(CIVector(x: 0, y: 4, z: 0, w: 0), forKey: "inputGVector")
    f.setValue(CIVector(x: 0, y: 0, z: 4, w: 0), forKey: "inputBVector")
    f.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
    f.setValue(CIVector(x: -1.4, y: -1.4, z: -1.4, w: 0), forKey: "inputBiasVector")
    let c = CIFilter(name: "CIColorClamp")!; c.setValue(f.outputImage!, forKey: kCIInputImageKey)
    return c.outputImage!
}
func applyMask(_ ci: CIImage, _ maskGray: CIImage) -> CIImage {
    let ta = CIFilter(name: "CIMaskToAlpha")!; ta.setValue(maskGray, forKey: kCIInputImageKey)
    let s = CIFilter(name: "CISourceInCompositing")!
    s.setValue(ci, forKey: kCIInputImageKey)
    s.setValue(ta.outputImage!, forKey: kCIInputBackgroundImageKey)
    return s.outputImage!
}

// 把 CGImage 畫進 RGBA8 緩衝，返回 (bytes,w,h,bpr)
func rgba(_ cg: CGImage) -> ([UInt8], Int, Int, Int) {
    let w = cg.width, h = cg.height, bpr = w * 4
    var buf = [UInt8](repeating: 0, count: bpr * h)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: bpr, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf, w, h, bpr)
}

let sem = DispatchSemaphore(value: 0)
Task {
    defer { sem.signal() }
    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    var dur = 0.0
    do { dur = try await CMTimeGetSeconds(asset.load(.duration)) } catch { err("加載失敗"); return }
    guard dur > 0 else { err("讀不到視頻"); return }
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    let ctx = CIContext()
    let seg = VNGeneratePersonSegmentationRequest()
    seg.qualityLevel = .accurate; seg.outputPixelFormat = kCVPixelFormatType_OneComponent8

    let n = max(1, Int((dur * fps).rounded()))
    var smalls: [CGImage] = []
    var scaleUsed: CGFloat = 1
    // 第一遍：摳圖 + 縮小
    for i in 0..<n {
        let t = min(Double(i) / fps, dur - 0.05)
        let cmt = CMTime(seconds: max(0, t), preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: cmt, actualTime: nil) else { err("frame \(i) 取幀失敗"); continue }
        let ci = CIImage(cgImage: cg)
        let luma = keyBlack(ci)
        var person: CIImage? = nil
        let h = VNImageRequestHandler(cgImage: cg, options: [:])
        if (try? h.perform([seg])) != nil, let mask = seg.results?.first?.pixelBuffer {
            var mci = CIImage(cvPixelBuffer: mask)
            let sx = ci.extent.width / mci.extent.width, sy = ci.extent.height / mci.extent.height
            mci = mci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            person = applyMask(ci, sharpenMask(mci))
        }
        let combined = person != nil ? person!.composited(over: luma) : luma
        scaleUsed = targetH / ci.extent.height
        let scaled = combined.transformed(by: CGAffineTransform(scaleX: scaleUsed, y: scaleUsed))
        if let s = ctx.createCGImage(scaled, from: scaled.extent) { smalls.append(s) }
    }
    guard !smalls.isEmpty else { err("沒摳到任何幀"); return }

    // 全局內容包圍盒（alpha>30）
    var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
    for s in smalls {
        let (b, w, h, bpr) = rgba(s)
        for y in 0..<h { for x in 0..<w {
            if b[y*bpr + x*4 + 3] > 30 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }}
    }
    let pad = 4
    minX = max(0, minX - pad); minY = max(0, minY - pad)
    let W = smalls[0].width, H = smalls[0].height
    maxX = min(W - 1, maxX + pad); maxY = min(H - 1, maxY + pad)
    let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    err("幀數=\(smalls.count) 裁剪框=\(crop)")

    // 第二遍：裁剪 + 存
    var idx = 0
    for s in smalls {
        if let c = s.cropping(to: crop) {
            savePNG(c, "\(outDir)/f\(String(format: "%03d", idx)).png"); idx += 1
        }
    }
    print("完成：\(idx) 幀 → \(outDir)，單幀尺寸 \(Int(crop.width))x\(Int(crop.height))")
}
sem.wait()
