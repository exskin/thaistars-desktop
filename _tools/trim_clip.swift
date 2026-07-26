import Foundation
import AVFoundation

// 用法: trim_clip <video> <out.mov> <startSec> <endSec>  —— 裁一段(含画面+声音)
let a = CommandLine.arguments
guard a.count >= 5, let s = Double(a[3]), let e = Double(a[4]) else {
    FileHandle.standardError.write("usage: trim_clip <video> <out.mov> <start> <end>\n".data(using: .utf8)!); exit(1)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let outURL = URL(fileURLWithPath: a[2])
try? FileManager.default.removeItem(at: outURL)
guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
    FileHandle.standardError.write("建不了导出会话\n".data(using: .utf8)!); exit(1)
}
export.outputURL = outURL
export.outputFileType = .mov
let start = CMTime(seconds: s, preferredTimescale: 600)
let dur = CMTime(seconds: e - s, preferredTimescale: 600)
export.timeRange = CMTimeRange(start: start, duration: dur)
let sem = DispatchSemaphore(value: 0)
export.exportAsynchronously {
    if export.status == .completed { print("裁剪完成 [\(s)~\(e)s] → \(outURL.path)") }
    else { FileHandle.standardError.write("失败: \(String(describing: export.error))\n".data(using: .utf8)!) }
    sem.signal()
}
sem.wait()
