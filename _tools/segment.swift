import Foundation
import AVFoundation
import Vision
import CoreImage
import ImageIO

// 用法: segment <video> <outDir> <count>
// 双通道抠图：Vision人物分割(保头发/身体) ∪ 亮度抠黑(保茶壶/水流)，黑背景→透明
let args = CommandLine.arguments
guard args.count >= 4, let count = Int(args[3]) else {
    FileHandle.standardError.write("usage: segment <video> <outDir> <count>\n".data(using: .utf8)!)
    exit(1)
}
let videoPath = args[1]
let outDir = args[2]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func savePNG(_ cg: CGImage, _ path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

// 亮度抠黑：原色不变，alpha=亮度(锐化)，纯黑→透明
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
    m2.setValue(CIVector(x: 0, y: 0, z: 0, w: -0.7), forKey: "inputBiasVector")
    let clamp = CIFilter(name: "CIColorClamp")!
    clamp.setValue(m2.outputImage!, forKey: kCIInputImageKey)
    return clamp.outputImage!
}

// 用一张灰度mask给原图套alpha
func applyMask(_ ci: CIImage, _ maskGray: CIImage) -> CIImage {
    let toAlpha = CIFilter(name: "CIMaskToAlpha")!          // 亮度→alpha, 输出白色
    toAlpha.setValue(maskGray, forKey: kCIInputImageKey)
    let srcIn = CIFilter(name: "CISourceInCompositing")!    // 原图 ∩ mask的alpha
    srcIn.setValue(ci, forKey: kCIInputImageKey)
    srcIn.setValue(toAlpha.outputImage!, forKey: kCIInputBackgroundImageKey)
    return srcIn.outputImage!
}

let sem = DispatchSemaphore(value: 0)
Task {
    defer { sem.signal() }
    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    var dur = 0.0
    do { dur = try await CMTimeGetSeconds(asset.load(.duration)) }
    catch { err("加载失败: \(error)"); return }
    guard dur > 0 else { err("读不到视频"); return }

    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let ctx = CIContext()
    let seg = VNGeneratePersonSegmentationRequest()
    seg.qualityLevel = .accurate
    seg.outputPixelFormat = kCVPixelFormatType_OneComponent8

    var saved = 0
    for i in 0..<count {
        let t = count > 1 ? dur * Double(i) / Double(count - 1) : dur / 2
        let cmt = CMTime(seconds: min(max(0, t), dur - 0.05), preferredTimescale: 600)
        let cg: CGImage
        do { cg = try gen.copyCGImage(at: cmt, actualTime: nil) }
        catch { err("frame \(i): 取帧失败"); continue }
        let ci = CIImage(cgImage: cg)

        // 通道A：亮度抠黑
        let lumaImg = keyBlack(ci)
        // 通道B：人物分割
        var personImg: CIImage? = nil
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        if (try? handler.perform([seg])) != nil, let mask = seg.results?.first?.pixelBuffer {
            var maskCI = CIImage(cvPixelBuffer: mask)
            let sx = ci.extent.width / maskCI.extent.width
            let sy = ci.extent.height / maskCI.extent.height
            maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            personImg = applyMask(ci, maskCI)
        }
        // 并集：人物 over 亮度（同一原色 → alpha取并集）
        let combined = personImg != nil ? personImg!.composited(over: lumaImg) : lumaImg
        guard let outCG = ctx.createCGImage(combined, from: ci.extent) else {
            err("frame \(i): 渲染失败"); continue
        }
        savePNG(outCG, "\(outDir)/frame_\(String(format: "%02d", i)).png")
        saved += 1
    }
    print("完成，抠出 \(saved)/\(count) 帧 → \(outDir)")
}
sem.wait()
