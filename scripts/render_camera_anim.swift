import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

struct MirrorParams {
    var width: UInt32
    var height: UInt32
    var scene_id: UInt32
    var max_bounces: UInt32
    var coating_mode: UInt32
    var spp: UInt32
    var view_mode: UInt32
    var frame_index: UInt32
    var time: Float
    var fov: Float
    var morph_param: Float
    var exposure: Float
    var cam_pos: SIMD4<Float>
    var cam_forward: SIMD4<Float>
    var cam_right: SIMD4<Float>
    var cam_up: SIMD4<Float>
}

struct Keyframe: Codable {
    let time: Double
    let cam_pos: [Float]
    let target: [Float]
    let fov_deg: Float?
    let morph: Float?
    let exposure: Float?
    let sim_time: Float?
}

struct CameraScript: Codable {
    let name: String
    let scene_id: UInt32
    let view_mode: UInt32?
    let max_bounces: UInt32?
    let coating_mode: UInt32?
    let width: Int?
    let height: Int?
    let fps: Int?
    let spp: UInt32?
    let keyframes: [Keyframe]
}

func v3(_ a: [Float]) -> SIMD3<Float> {
    SIMD3<Float>(a.count > 0 ? a[0] : 0, a.count > 1 ? a[1] : 0, a.count > 2 ? a[2] : 0)
}

func catmullRom(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    let t2 = t * t
    let t3 = t2 * t
    return 0.5 * ((2.0 * p1)
        + (-p0 + p2) * t
        + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
        + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
}

func smoothstep(_ t: Float) -> Float {
    let x = max(0.0, min(1.0, t))
    return x * x * (3.0 - 2.0 * x)
}

func sampleScript(_ script: CameraScript, at tSec: Double) -> (pos: SIMD3<Float>, target: SIMD3<Float>, fov: Float, morph: Float, exp: Float, simTime: Float) {
    let kfs = script.keyframes
    guard kfs.count >= 2 else {
        let k = kfs[0]
        return (v3(k.cam_pos), v3(k.target), k.fov_deg ?? 60, k.morph ?? 0.35, k.exposure ?? 1.0, k.sim_time ?? Float(tSec))
    }
    var seg = 0
    for i in 0..<(kfs.count - 1) {
        if tSec >= kfs[i].time { seg = i }
    }
    let i0 = max(0, seg - 1)
    let i1 = seg
    let i2 = min(kfs.count - 1, seg + 1)
    let i3 = min(kfs.count - 1, seg + 2)

    let dt = max(1e-6, kfs[i2].time - kfs[i1].time)
    let u = Float(max(0.0, min(1.0, (tSec - kfs[i1].time) / dt)))
    let su = smoothstep(u)

    let pos = catmullRom(v3(kfs[i0].cam_pos), v3(kfs[i1].cam_pos), v3(kfs[i2].cam_pos), v3(kfs[i3].cam_pos), u)
    let tgt = catmullRom(v3(kfs[i0].target), v3(kfs[i1].target), v3(kfs[i2].target), v3(kfs[i3].target), u)
    let fov = (kfs[i1].fov_deg ?? 60) * (1 - su) + (kfs[i2].fov_deg ?? 60) * su
    let morph = (kfs[i1].morph ?? 0.35) * (1 - su) + (kfs[i2].morph ?? 0.35) * su
    let exp = (kfs[i1].exposure ?? 1.0) * (1 - su) + (kfs[i2].exposure ?? 1.0) * su
    let st = (kfs[i1].sim_time ?? Float(kfs[i1].time)) * (1 - u) + (kfs[i2].sim_time ?? Float(kfs[i2].time)) * u
    return (pos, tgt, fov, morph, exp, st)
}

func makeTex(_ dev: MTLDevice, fmt: MTLPixelFormat, w: Int, h: Int, mode: MTLStorageMode) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    d.storageMode = mode
    return dev.makeTexture(descriptor: d)!
}

func savePNG(bytes: UnsafeMutableRawPointer, width: Int, height: Int, path: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let ctx = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs, bitmapInfo: info.rawValue)!
    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
let scriptPath = args.count > 1 ? args[1] : "scripts/cameras/demo_diamond_orbit.json"
let scriptData = try Data(contentsOf: URL(fileURLWithPath: scriptPath))
let script = try JSONDecoder().decode(CameraScript.self, from: scriptData)

let width = script.width ?? 3840
let height = script.height ?? 2160
let fps = script.fps ?? 30
let spp = script.spp ?? 4
let bounces = script.max_bounces ?? 36
let coating = script.coating_mode ?? 0
let viewMode = script.view_mode ?? 0
let duration = script.keyframes.last?.time ?? 5.0
let totalFrames = max(1, Int(round(duration * Double(fps))))

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    fatalError("No Apple Metal GPU available")
}

print("=== Mirror Kaleidoscope 3D — Scripted 4K Camera Animation Renderer ===")
print("Script: \(scriptPath) | Scene: \(script.scene_id) | \(width)x\(height) @ \(fps)fps | \(spp)x RGSS | \(totalFrames) frames")

let shaderSrc = try String(contentsOfFile: "shaders/mirror_kaleidoscope.metal", encoding: .utf8)
let library = try device.makeLibrary(source: shaderSrc, options: nil)
func makePipe(_ name: String) -> MTLComputePipelineState {
    try! device.makeComputePipelineState(function: library.makeFunction(name: name)!)
}
let scenePipe = makePipe("renderScene\(min(Int(script.scene_id), 9))")
let bloomExtPipe = makePipe("bloomExtract")
let bloomHPipe = makePipe("bloomBlurH")
let bloomVPipe = makePipe("bloomBlurV")
let compPipe = makePipe("compositeToDrawable")

let hdrTex = makeTex(device, fmt: .rgba16Float, w: width, h: height, mode: .private)
let bloomA = makeTex(device, fmt: .rgba16Float, w: width / 2, h: height / 2, mode: .private)
let bloomB = makeTex(device, fmt: .rgba16Float, w: width / 2, h: height / 2, mode: .private)
let outTex = makeTex(device, fmt: .rgba8Unorm, w: width, h: height, mode: .shared)

let outDir = "output/anim/\(script.name)"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let tg8 = MTLSize(width: 8, height: 8, depth: 1)
let tg16 = MTLSize(width: 16, height: 16, depth: 1)
let hdrGrid = MTLSize(width: width, height: height, depth: 1)
let bloomGrid = MTLSize(width: width / 2, height: height / 2, depth: 1)

let pngGroup = DispatchGroup()
let pngQueue = DispatchQueue.global(qos: .userInitiated)
let tStart = CFAbsoluteTimeGetCurrent()
var gpuTotalMs = 0.0

for f in 0..<totalFrames {
    let tSec = Double(f) / Double(fps)
    let sample = sampleScript(script, at: tSec)
    let fwd = simd_normalize(sample.target - sample.pos)
    let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), fwd))
    let up = simd_normalize(simd_cross(fwd, right))

    var p = MirrorParams(
        width: UInt32(width), height: UInt32(height),
        scene_id: script.scene_id, max_bounces: bounces,
        coating_mode: coating, spp: spp, view_mode: viewMode,
        frame_index: UInt32(f), time: sample.simTime,
        fov: sample.fov * .pi / 180.0, morph_param: sample.morph, exposure: sample.exp,
        cam_pos: SIMD4(sample.pos.x, sample.pos.y, sample.pos.z, 0),
        cam_forward: SIMD4(fwd.x, fwd.y, fwd.z, 0),
        cam_right: SIMD4(right.x, right.y, right.z, 0),
        cam_up: SIMD4(up.x, up.y, up.z, 0)
    )

    let cb = queue.makeCommandBuffer()!
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(scenePipe)
        enc.setTexture(hdrTex, index: 0)
        enc.setBytes(&p, length: MemoryLayout<MirrorParams>.stride, index: 0)
        enc.dispatchThreads(hdrGrid, threadsPerThreadgroup: tg8)
        enc.endEncoding()
    }
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(bloomExtPipe)
        enc.setTexture(hdrTex, index: 0); enc.setTexture(bloomA, index: 1)
        enc.dispatchThreads(bloomGrid, threadsPerThreadgroup: tg16); enc.endEncoding()
    }
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(bloomHPipe)
        enc.setTexture(bloomA, index: 0); enc.setTexture(bloomB, index: 1)
        enc.dispatchThreads(bloomGrid, threadsPerThreadgroup: tg16); enc.endEncoding()
    }
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(bloomVPipe)
        enc.setTexture(bloomB, index: 0); enc.setTexture(bloomA, index: 1)
        enc.dispatchThreads(bloomGrid, threadsPerThreadgroup: tg16); enc.endEncoding()
    }
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(compPipe)
        enc.setTexture(hdrTex, index: 0); enc.setTexture(bloomA, index: 1); enc.setTexture(outTex, index: 2)
        enc.setBytes(&p, length: MemoryLayout<MirrorParams>.stride, index: 0)
        enc.dispatchThreads(hdrGrid, threadsPerThreadgroup: tg16); enc.endEncoding()
    }
    cb.commit()
    cb.waitUntilCompleted()
    gpuTotalMs += max(0.0, (cb.gpuEndTime - cb.gpuStartTime) * 1000.0)

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { ptr in
        outTex.getBytes(ptr.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    let path = String(format: "%@/frame_%05d.png", outDir, f)
    pngGroup.enter()
    pngQueue.async {
        var copy = bytes
        copy.withUnsafeMutableBytes { ptr in
            savePNG(bytes: ptr.baseAddress!, width: width, height: height, path: path)
        }
        pngGroup.leave()
    }

    if (f + 1) % max(1, fps) == 0 || f + 1 == totalFrames {
        print(String(format: "Rendered %d/%d frames | Avg GPU: %.2f ms/frame", f + 1, totalFrames, gpuTotalMs / Double(f + 1)))
    }
}

pngGroup.wait()
let wallSec = CFAbsoluteTimeGetCurrent() - tStart
print(String(format: "\nDone! %d frames -> %@ in %.2fs (Avg GPU: %.2f ms/f)", totalFrames, outDir, wallSec, gpuTotalMs / Double(totalFrames)))
print("Assemble 4K video with ffmpeg:")
print("  ffmpeg -y -framerate \(fps) -i \(outDir)/frame_%05d.png -c:v libx265 -crf 16 -pix_fmt yuv420p -tag:v hvc1 output/anim/\(script.name)_4k.mp4")
