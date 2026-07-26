import Foundation
import CoreImage
import ImageIO

// 用法: preview <png> <out.png>  —— 把透明PNG合成到棋盘格底上，方便看真实抠图质量
let a = CommandLine.arguments
guard a.count >= 3 else { exit(1) }
let ci = CIImage(contentsOf: URL(fileURLWithPath: a[1]))!
let ext = ci.extent
// 棋盘格背景
let cb = CIFilter(name: "CICheckerboardGenerator")!
cb.setValue(CIColor(red: 0.85, green: 0.85, blue: 0.87), forKey: "inputColor0")
cb.setValue(CIColor(red: 0.70, green: 0.70, blue: 0.74), forKey: "inputColor1")
cb.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
cb.setValue(40.0, forKey: "inputWidth")
let bg = cb.outputImage!.cropped(to: ext)
let comp = ci.composited(over: bg)
let ctx = CIContext()
let cg = ctx.createCGImage(comp, from: ext)!
let url = URL(fileURLWithPath: a[2])
let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, cg, nil)
CGImageDestinationFinalize(dest)
print("ok")
