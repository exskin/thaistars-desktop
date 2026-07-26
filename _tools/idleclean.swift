import Foundation
import AVFoundation
import CoreImage
import ImageIO

// 用法: idleclean <video> <outDir> <fps> <targetHeight> <hueMin> <hueMax>
// 摳圖(色度鍵) → 每幀只保留最大的一塊不透明區域(去掉畫面外闖入的小塊干擾) → 全局裁剪 → 縮放 → 存PNG
let a = CommandLine.arguments
guard a.count >= 7, let fps = Double(a[3]), let targetH = Double(a[4]),
      let hueMin = Float(a[5]), let hueMax = Float(a[6]) else {
    FileHandle.standardError.write("usage: idleclean <video> <outDir> <fps> <targetH> <hueMin> <hueMax>\n".data(using: .utf8)!); exit(1)
}
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
func toRGBA(_ cg: CGImage) -> ([UInt8], Int, Int, Int) {
    let w = cg.width, h = cg.height, bpr = w * 4
    var buf = [UInt8](repeating: 0, count: bpr * h)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return (buf, w, h, bpr)
}
func fromRGBA(_ buf: [UInt8], _ w: Int, _ h: Int, _ bpr: Int) -> CGImage? {
    var mut = buf
    let ctx = CGContext(data: &mut, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()
}

// 只保留面積最大的連通塊，其餘(比如畫面邊緣闖入的一小截手臂)清成透明
func keepLargestComponent(_ buf: inout [UInt8], _ w: Int, _ h: Int, _ bpr: Int) {
    var label = [Int32](repeating: 0, count: w * h)
    var compSize: [Int32: Int] = [:]
    var next: Int32 = 1
    var stack: [Int32] = []
    stack.reserveCapacity(1024)
    func idx(_ x: Int, _ y: Int) -> Int { y * w + x }
    for y0 in 0..<h {
        for x0 in 0..<w {
            let i0 = idx(x0, y0)
            if label[i0] != 0 { continue }
            if buf[y0 * bpr + x0 * 4 + 3] <= 40 { continue }   // 透明像素不算
            let cur = next; next += 1
            var size = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(Int32(i0)); label[i0] = cur
            while let top = stack.popLast() {
                size += 1
                let x = Int(top) % w, y = Int(top) / w
                for (dx, dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || nx >= w || ny < 0 || ny >= h { continue }
                    let ni = idx(nx, ny)
                    if label[ni] != 0 { continue }
                    if buf[ny * bpr + nx * 4 + 3] <= 40 { continue }
                    label[ni] = cur
                    stack.append(Int32(ni))
                }
            }
            compSize[cur] = size
        }
    }
    guard let biggest = compSize.max(by: { $0.value < $1.value })?.key else { return }
    for y in 0..<h { for x in 0..<w {
        let i = idx(x, y)
        if label[i] != biggest, label[i] != 0 {
            buf[y * bpr + x * 4 + 3] = 0
            buf[y * bpr + x * 4 + 0] = 0
            buf[y * bpr + x * 4 + 1] = 0
            buf[y * bpr + x * 4 + 2] = 0
        }
    }}
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
    let keyer = greenKeyFilter()

    let n = max(1, Int((dur * fps).rounded()))
    var smalls: [CGImage] = []
    for i in 0..<n {
        let t = min(Double(i) / fps, dur - 0.05)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: max(0, t), preferredTimescale: 600), actualTime: nil)
        else { err("frame \(i) 取幀失敗"); continue }
        keyer.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        guard let keyed = keyer.outputImage else { continue }
        let scale = targetH / keyed.extent.height
        let scaled = keyed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let s = ctx.createCGImage(scaled, from: scaled.extent) else { continue }
        var (buf, w, h, bpr) = toRGBA(s)
        keepLargestComponent(&buf, w, h, bpr)
        guard let cleaned = fromRGBA(buf, w, h, bpr) else { continue }
        smalls.append(cleaned)
    }
    guard !smalls.isEmpty else { err("沒摳到任何幀"); return }

    var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
    for s in smalls {
        let (b, w, h, bpr) = toRGBA(s)
        for y in 0..<h { for x in 0..<w where b[y*bpr + x*4 + 3] > 40 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }}
    }
    let pad = 4, W = smalls[0].width, H = smalls[0].height
    minX = max(0, minX - pad); minY = max(0, minY - pad)
    maxX = min(W - 1, maxX + pad); maxY = min(H - 1, maxY + pad)
    let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    err("幀數=\(smalls.count) 裁剪框=\(crop)")

    var idx2 = 0
    for s in smalls where s.cropping(to: crop) != nil {
        savePNG(s.cropping(to: crop)!, "\(outDir)/f\(String(format: "%03d", idx2)).png"); idx2 += 1
    }
    print("完成：\(idx2) 幀 → \(outDir)，單幀 \(Int(crop.width))x\(Int(crop.height))")
}
sem.wait()
