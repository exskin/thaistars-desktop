import Foundation
import AVFoundation
import Vision
import CoreImage
import ImageIO

// 探测：这一帧里 Vision 能不能把不同的人分成不同实例
let a = CommandLine.arguments
guard a.count >= 3, let t = Double(a[2]) else { exit(1) }
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
guard let cg = try? gen.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else {
    print("取帧失败"); exit(1)
}
if #available(macOS 12.0, *) {
    let req = VNGeneratePersonInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do {
        try handler.perform([req])
        guard let obs = req.results?.first else { print("没有结果"); exit(0) }
        print("检测到实例数量: \(obs.allInstances.count)  图像尺寸: \(obs.pixelBuffer)")
        for inst in obs.allInstances.sorted() {
            let mask = try obs.generateMaskedImage(ofInstances: [inst], from: handler, croppedToInstancesExtent: false)
            let ci = CIImage(cvPixelBuffer: mask)
            let ctx = CIContext()
            if let out = ctx.createCGImage(ci, from: ci.extent) {
                let path = "/tmp/instance_\(inst).png"
                let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, out, nil)
                CGImageDestinationFinalize(dest)
                print("实例 \(inst) 已存到 \(path)")
            }
        }
    } catch {
        print("分割失败: \(error)")
    }
} else {
    print("系统版本太旧，不支持 instance mask")
}
