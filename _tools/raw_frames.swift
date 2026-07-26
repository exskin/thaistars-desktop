import Foundation
import AVFoundation
import ImageIO

// 用法: raw_frames <video> <outDir> <count>  —— 抽原始幀(不摳圖),文件名帶時間戳,看字幕用
let a = CommandLine.arguments
guard a.count >= 4, let count = Int(a[3]) else { exit(1) }
try? FileManager.default.createDirectory(atPath: a[2], withIntermediateDirectories: true)
func savePNG(_ cg: CGImage, _ p: String) {
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p) as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
}
let sem = DispatchSemaphore(value: 0)
Task {
    defer { sem.signal() }
    let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
    let dur = try! await CMTimeGetSeconds(asset.load(.duration))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
    gen.maximumSize = CGSize(width: 400, height: 700)
    for i in 0..<count {
        let t = min(Double(i) / Double(count - 1) * dur, dur - 0.02)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: max(0, t), preferredTimescale: 600), actualTime: nil) else { continue }
        let ms = Int(t * 1000)
        savePNG(cg, "\(a[2])/t\(String(format: "%04d", ms))ms.png")
    }
    print("done, dur=\(dur)s")
}
sem.wait()
