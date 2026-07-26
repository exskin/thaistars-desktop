import Foundation
import AVFoundation
import CoreImage
import ImageIO

// 用法: greenframes <video> <outDir> <fps> <targetHeight> [hueMin] [hueMax] [cropLeftFrac] [cropRightFrac] [--nokey]
// 抽帧→(可选)左右裁边→色度键(去背景,保留人物/道具/水流)→全局裁剪→缩放→存PNG序列
// hueMin/hueMax 可选，默认 0.40/0.54（青绿幕）；橄榄绿等其他底色可自行传入 0-1 的色相区间
// cropLeftFrac/cropRightFrac 可选(0~1)：画面里有别人闯入镜头时，先按比例裁掉那一侧，再抠图
// --nokey：不去背景，原始画面直接存（放在参数任意位置都行）
var argv = CommandLine.arguments
let noKey = argv.contains { $0 == "--nokey" }
argv.removeAll { $0 == "--nokey" }
let a = argv
guard a.count >= 5, let fps = Double(a[3]), let targetH = Double(a[4]) else {
    FileHandle.standardError.write("usage: greenframes <video> <outDir> <fps> <targetH> [hueMin] [hueMax] [cropLeftFrac] [cropRightFrac] [--nokey]\n".data(using: .utf8)!); exit(1)
}
let hueMin = a.count >= 6 ? (Float(a[5]) ?? 0.40) : 0.40
let hueMax = a.count >= 7 ? (Float(a[6]) ?? 0.54) : 0.54
let cropLeftFrac = a.count >= 8 ? (Double(a[7]) ?? 0) : 0
let cropRightFrac = a.count >= 9 ? (Double(a[8]) ?? 0) : 0
// 可选第9参数：亮度低于此值的像素(近黑色,如闯入的黑衣袖)也抠掉,0=关闭
let blackVMax = a.count >= 10 ? (Float(a[9]) ?? 0) : 0
let videoPath = a[1], outDir = a[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func savePNG(_ cg: CGImage, _ path: String) {
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
}
func rgb2hsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h: Float = 0
    if d != 0 {
        if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
        h /= 6; if h < 0 { h += 1 }
    }
    return (h, mx == 0 ? 0 : d / mx, mx)
}
// 构建青绿色度键立方体：背景H≈0.476,S高 → alpha0；其余 alpha1
func greenKeyFilter() -> CIFilter {
    let size = 64
    var cube = [Float](); cube.reserveCapacity(size*size*size*4)
    for z in 0..<size {
        let b = Float(z) / Float(size - 1)
        for y in 0..<size {
            let g = Float(y) / Float(size - 1)
            for x in 0..<size {
                let r = Float(x) / Float(size - 1)
                let (h, s, v) = rgb2hsv(r, g, b)
                let isBg = (h >= hueMin && h <= hueMax) && s >= 0.30 && v >= 0.20
                let alpha: Float = isBg ? 0 : 1
                cube.append(r * alpha); cube.append(g * alpha); cube.append(b * alpha); cube.append(alpha)
            }
        }
    }
    let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
    let f = CIFilter(name: "CIColorCube")!
    f.setValue(size, forKey: "inputCubeDimension")
    f.setValue(data, forKey: "inputCubeData")
    return f
}
func rgba(_ cg: CGImage) -> ([UInt8], Int, Int, Int) {
    let w = cg.width, h = cg.height, bpr = w * 4
    var buf = [UInt8](repeating: 0, count: bpr * h)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return (buf, w, h, bpr)
}
// 后处理：只在画面左侧 zoneFrac 范围内，把近黑像素(闯入的黑衣袖)清成透明；人物深发在中间不受影响
func removeBlackInLeftZone(_ cg: CGImage, vMax: Float, zoneFrac: Double) -> CGImage? {
    var (buf, w, h, bpr) = rgba(cg)
    let zoneX = Int(Double(w) * zoneFrac)
    for y in 0..<h {
        for x in 0..<zoneX {
            let i = y * bpr + x * 4
            let a = buf[i + 3]
            if a == 0 { continue }
            let r = buf[i], g = buf[i+1], b = buf[i+2]
            let mx = Float(max(r, g, b)) / 255  // premultiplied下近似亮度
            let isDark = mx <= vMax * Float(a) / 255
            let isGreenish = g > r && g >= b     // 绿幕混进黑袖边缘的绿边(肤色r占优、白裙三色接近,不受影响)
            if isDark || isGreenish {
                buf[i] = 0; buf[i+1] = 0; buf[i+2] = 0; buf[i+3] = 0
            }
        }
    }
    let ctx2 = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx2.makeImage()
}

let sem = DispatchSemaphore(value: 0)
Task {
    defer { sem.signal() }
    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    var dur = 0.0
    do { dur = try await CMTimeGetSeconds(asset.load(.duration)) } catch { err("加载失败"); return }
    guard dur > 0 else { err("读不到视频"); return }
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    let ctx = CIContext()
    let keyer = greenKeyFilter()

    let n = max(1, Int((dur * fps).rounded()))
    var smalls: [CGImage] = []
    for i in 0..<n {
        let t = min(Double(i) / fps, dur - 0.05)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: max(0, t), preferredTimescale: 600), actualTime: nil)
        else { err("frame \(i) 取帧失败"); continue }
        var full = CIImage(cgImage: cg)
        if cropLeftFrac > 0 || cropRightFrac > 0 {
            let w = full.extent.width
            let x0 = full.extent.minX + w * CGFloat(cropLeftFrac)
            let x1 = full.extent.maxX - w * CGFloat(cropRightFrac)
            full = full.cropped(to: CGRect(x: x0, y: full.extent.minY, width: max(1, x1 - x0), height: full.extent.height))
        }
        var keyed = full
        if !noKey {
            keyer.setValue(full, forKey: kCIInputImageKey)
            guard let k = keyer.outputImage else { continue }
            keyed = k
        }
        let scale = targetH / keyed.extent.height
        let scaled = keyed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if var s = ctx.createCGImage(scaled, from: scaled.extent) {
            if blackVMax > 0, let cleaned = removeBlackInLeftZone(s, vMax: blackVMax, zoneFrac: 0.35) { s = cleaned }
            smalls.append(s)
        }
    }
    guard !smalls.isEmpty else { err("没抠到任何帧"); return }

    // 全局内容包围盒
    var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
    for s in smalls {
        let (b, w, h, bpr) = rgba(s)
        for y in 0..<h { for x in 0..<w where b[y*bpr + x*4 + 3] > 40 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }}
    }
    let pad = 4, W = smalls[0].width, H = smalls[0].height
    minX = max(0, minX - pad); minY = max(0, minY - pad)
    maxX = min(W - 1, maxX + pad); maxY = min(H - 1, maxY + pad)
    let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    err("帧数=\(smalls.count) 裁剪框=\(crop)")

    var idx = 0
    for s in smalls where s.cropping(to: crop) != nil {
        savePNG(s.cropping(to: crop)!, "\(outDir)/f\(String(format: "%03d", idx)).png"); idx += 1
    }
    print("完成：\(idx) 帧 → \(outDir)，单帧 \(Int(crop.width))x\(Int(crop.height))")
}
sem.wait()
