import Foundation
import AVFoundation

// 用法: extract_audio <video> <out.m4a>
let a = CommandLine.arguments
guard a.count >= 3 else { FileHandle.standardError.write("usage: extract_audio <video> <out.m4a>\n".data(using: .utf8)!); exit(1) }
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let outURL = URL(fileURLWithPath: a[2])
try? FileManager.default.removeItem(at: outURL)

let sem = DispatchSemaphore(value: 0)
guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
    FileHandle.standardError.write("建不了导出会话\n".data(using: .utf8)!); exit(1)
}
export.outputURL = outURL
export.outputFileType = .m4a
export.exportAsynchronously {
    if export.status == .completed { print("音频已导出 → \(outURL.path)") }
    else { FileHandle.standardError.write("导出失败: \(String(describing: export.error))\n".data(using: .utf8)!) }
    sem.signal()
}
sem.wait()
