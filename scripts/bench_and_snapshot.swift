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

struct SnapshotCase {
    let slug: String
    let name: String
    let sceneId: UInt32
    let viewMode: UInt32
    let maxBounces: UInt32
    let coating: UInt32
    let morph: Float
    let exposure: Float
    let fovDeg: Float
    let camPos: SIMD3<Float>
    let target: SIMD3<Float>
    let simTime: Float
}

let cases: [SnapshotCase] = [
    SnapshotCase(slug: "01a_platonic_portal_inside",  name: "Platonic Portal (Inside)",  sceneId: 0, viewMode: 0, maxBounces: 40, coating: 1, morph: 0.00, exposure: 1.05, fovDeg: 70, camPos: SIMD3( 0.78,  0.25, -1.18), target: SIMD3(0, 0, 0), simTime: 2.5),
    SnapshotCase(slug: "01b_platonic_portal_outside", name: "Platonic Portal (Outside)", sceneId: 0, viewMode: 1, maxBounces: 40, coating: 1, morph: 0.50, exposure: 1.05, fovDeg: 52, camPos: SIMD3( 2.95,  1.52, -5.05), target: SIMD3(0, 0, 0), simTime: 3.0),
    SnapshotCase(slug: "02_wada_basin_spheres",       name: "Wada Basin 4 Spheres",      sceneId: 1, viewMode: 0, maxBounces: 48, coating: 3, morph: 0.04, exposure: 1.02, fovDeg: 62, camPos: SIMD3(-0.56, -0.56, -0.56), target: SIMD3(0, 0, 0), simTime: 2.0),
    SnapshotCase(slug: "03_coxeter_hyperbolic",       name: "Coxeter Hyperbolic",        sceneId: 2, viewMode: 0, maxBounces: 40, coating: 0, morph: 0.45, exposure: 1.02, fovDeg: 74, camPos: SIMD3( 0.45,  0.28, -0.72), target: SIMD3(0.12, -0.05, 0.12), simTime: 2.5),
    SnapshotCase(slug: "04_dichroic_infinity_room",   name: "Dichroic Infinity Room",    sceneId: 3, viewMode: 0, maxBounces: 36, coating: 0, morph: 0.35, exposure: 1.00, fovDeg: 72, camPos: SIMD3( 1.05,  0.40, -1.95), target: SIMD3(0, 0.15, 0), simTime: 2.5),
    SnapshotCase(slug: "05_dichroic_crystal_cube",    name: "Dichroic Crystal Cube",     sceneId: 4, viewMode: 0, maxBounces: 24, coating: 0, morph: 0.45, exposure: 1.02, fovDeg: 48, camPos: SIMD3( 2.25,  1.45, -3.65), target: SIMD3(0, 0, 0), simTime: 2.5),
    SnapshotCase(slug: "06_spectral_diamond_fire",    name: "Spectral Diamond Fire",     sceneId: 5, viewMode: 0, maxBounces: 20, coating: 3, morph: 0.55, exposure: 1.05, fovDeg: 46, camPos: SIMD3( 2.35,  1.75, -3.40), target: SIMD3(0, -0.25, 0), simTime: 2.5),
    SnapshotCase(slug: "07_dichroic_caustics_wall",   name: "Dichroic Caustics Wall",    sceneId: 6, viewMode: 0, maxBounces: 16, coating: 0, morph: 0.35, exposure: 1.00, fovDeg: 54, camPos: SIMD3( 0.45,  0.42, -3.05), target: SIMD3(0, 0, 1.85), simTime: 2.0),
    SnapshotCase(slug: "08_eliasson_colour_tunnel",   name: "Eliasson Colour Tunnel",    sceneId: 7, viewMode: 0, maxBounces: 36, coating: 3, morph: 0.30, exposure: 1.02, fovDeg: 74, camPos: SIMD3( 0.25,  0.22,  2.80), target: SIMD3(0.12, 0.08, 7.30), simTime: 2.5),
    SnapshotCase(slug: "09_apollonian_packing",       name: "Apollonian Packing",        sceneId: 8, viewMode: 0, maxBounces: 32, coating: 0, morph: 0.25, exposure: 1.02, fovDeg: 54, camPos: SIMD3(-2.15,  0.55, -3.65), target: SIMD3(0, 0, 0), simTime: 2.5),
    SnapshotCase(slug: "10a_grin_curved_light",       name: "GRIN Curved Light",         sceneId: 9, viewMode: 0, maxBounces: 40, coating: 0, morph: 0.45, exposure: 1.05, fovDeg: 62, camPos: SIMD3( 1.90,  0.38, -3.10), target: SIMD3(0, 0, 0), simTime: 2.5),
    SnapshotCase(slug: "10b_corner_cube_retro_wall",  name: "Corner-Cube Retro Wall",    sceneId: 9, viewMode: 1, maxBounces: 40, coating: 0, morph: 0.45, exposure: 1.05, fovDeg: 60, camPos: SIMD3( 0.55,  0.38, -2.35), target: SIMD3(0, 0, 2.0), simTime: 2.5),
]

func makeParams(c: SnapshotCase, width: UInt32, height: UInt32, spp: UInt32) -> MirrorParams {
    let fwd = simd_normalize(c.target - c.camPos)
    let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), fwd))
    let up = simd_normalize(simd_cross(fwd, right))
    return MirrorParams(
        width: width,
        height: height,
        scene_id: c.sceneId,
        max_bounces: c.maxBounces,
        coating_mode: c.coating,
        spp: spp,
        view_mode: c.viewMode,
        frame_index: 1,
        time: c.simTime,
        fov: c.fovDeg * .pi / 180.0,
        morph_param: c.morph,
        exposure: c.exposure,
        cam_pos: SIMD4(c.camPos.x, c.camPos.y, c.camPos.z, 0),
        cam_forward: SIMD4(fwd.x, fwd.y, fwd.z, 0),
        cam_right: SIMD4(right.x, right.y, right.z, 0),
        cam_up: SIMD4(up.x, up.y, up.z, 0)
    )
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

var width = 3840
var height = 2160
var snapSpp: UInt32 = 4
let args = CommandLine.arguments
var argIdx = 1
while argIdx < args.count {
    if args[argIdx] == "--5k" {
        width = 5120
        height = 2880
    } else if args[argIdx] == "--6k" {
        width = 6016
        height = 3384
    } else if args[argIdx] == "--spp", argIdx + 1 < args.count, let s = UInt32(args[argIdx + 1]) {
        snapSpp = s; argIdx += 1
    } else if args[argIdx] == "--width", argIdx + 1 < args.count, let w = Int(args[argIdx + 1]) {
        width = w; argIdx += 1
    } else if args[argIdx] == "--height", argIdx + 1 < args.count, let h = Int(args[argIdx + 1]) {
        height = h; argIdx += 1
    }
    argIdx += 1
}
let benchIters = 5

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    fatalError("No Apple Metal GPU available")
}

let memGB = Double(device.recommendedMaxWorkingSetSize) / (1024.0 * 1024.0 * 1024.0)
let mpix = Double(width * height) / 1_000_000.0
print(String(format: "=== Mirror Kaleidoscope 3D — Metal GPU Benchmark & High-Res Snapshots ===\nGPU: %@ | UnifiedMemBudget: %.1f GB | %dx%d (%.2f MP)", device.name, memGB, width, height, mpix))

let tComp = CFAbsoluteTimeGetCurrent()
let shaderSrc = try String(contentsOfFile: "shaders/mirror_kaleidoscope.metal", encoding: .utf8)
let library = try device.makeLibrary(source: shaderSrc, options: nil)

func makePipe(_ name: String) -> MTLComputePipelineState {
    let fn = library.makeFunction(name: name)!
    return try! device.makeComputePipelineState(function: fn)
}

var scenePipes = [MTLComputePipelineState?](repeating: nil, count: 10)
let pipeLock = NSLock()
DispatchQueue.concurrentPerform(iterations: 10) { idx in
    let p = makePipe("renderScene\(idx)")
    pipeLock.lock()
    scenePipes[idx] = p
    pipeLock.unlock()
}
let resolvedScenePipes: [MTLComputePipelineState] = scenePipes.map { $0! }
let bloomExtPipe = makePipe("bloomExtract")
let bloomHPipe = makePipe("bloomBlurH")
let bloomVPipe = makePipe("bloomBlurV")
let compPipe = makePipe("compositeToDrawable")
print(String(format: "Shader compile (10 dedicated kernels in parallel): %.1f ms\n", (CFAbsoluteTimeGetCurrent() - tComp) * 1000.0))

let hdrTex = makeTex(device, fmt: .rgba16Float, w: width, h: height, mode: .private)
let bloomA = makeTex(device, fmt: .rgba16Float, w: width / 2, h: height / 2, mode: .private)
let bloomB = makeTex(device, fmt: .rgba16Float, w: width / 2, h: height / 2, mode: .private)
let outTex = makeTex(device, fmt: .rgba8Unorm, w: width, h: height, mode: .shared)

let tg8 = MTLSize(width: 8, height: 8, depth: 1)
let tg16 = MTLSize(width: 16, height: 16, depth: 1)
let hdrGrid = MTLSize(width: width, height: height, depth: 1)
let bloomGrid = MTLSize(width: width / 2, height: height / 2, depth: 1)

func runOnce(_ params: MirrorParams) -> Double {
    var p = params
    let cb = queue.makeCommandBuffer()!
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(resolvedScenePipes[min(Int(p.scene_id), 9)])
        enc.setTexture(hdrTex, index: 0)
        enc.setBytes(&p, length: MemoryLayout<MirrorParams>.stride, index: 0)
        enc.dispatchThreads(hdrGrid, threadsPerThreadgroup: tg8)
        enc.endEncoding()
    }
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(bloomExtPipe)
        enc.setTexture(hdrTex, index: 0)
        enc.setTexture(bloomA, index: 1)
        enc.dispatchThreads(bloomGrid, threadsPerThreadgroup: tg16)
        enc.endEncoding()
    }
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(bloomHPipe)
        enc.setTexture(bloomA, index: 0)
        enc.setTexture(bloomB, index: 1)
        enc.dispatchThreads(bloomGrid, threadsPerThreadgroup: tg16)
        enc.endEncoding()
    }
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(bloomVPipe)
        enc.setTexture(bloomB, index: 0)
        enc.setTexture(bloomA, index: 1)
        enc.dispatchThreads(bloomGrid, threadsPerThreadgroup: tg16)
        enc.endEncoding()
    }
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(compPipe)
        enc.setTexture(hdrTex, index: 0)
        enc.setTexture(bloomA, index: 1)
        enc.setTexture(outTex, index: 2)
        enc.setBytes(&p, length: MemoryLayout<MirrorParams>.stride, index: 0)
        enc.dispatchThreads(hdrGrid, threadsPerThreadgroup: tg16)
        enc.endEncoding()
    }
    cb.commit()
    cb.waitUntilCompleted()
    return max(0.0, (cb.gpuEndTime - cb.gpuStartTime) * 1000.0)
}

try FileManager.default.createDirectory(atPath: "output/snapshots", withIntermediateDirectories: true)
var jsonLines: [String] = []
let pngGroup = DispatchGroup()
let pngQueue = DispatchQueue.global(qos: .userInitiated)

print(String(format: "%-30s | %7s | %10s | %10s | %7s | %s",
             ("Snapshot Case" as NSString).utf8String!,
             ("Bounces" as NSString).utf8String!,
             ("1xSPP GPU" as NSString).utf8String!,
             ("\(snapSpp)xSPP GPU" as NSString).utf8String!,
             ("\(snapSpp)x FPS" as NSString).utf8String!,
             ("Output PNG" as NSString).utf8String!))
print(String(repeating: "-", count: 102))

for c in cases {
    let p1 = makeParams(c: c, width: UInt32(width), height: UInt32(height), spp: 1)
    _ = runOnce(p1)
    var sum1 = 0.0
    for _ in 0..<benchIters { sum1 += runOnce(p1) }
    let avg1 = sum1 / Double(benchIters)

    let p4 = makeParams(c: c, width: UInt32(width), height: UInt32(height), spp: snapSpp)
    _ = runOnce(p4)
    var sum4 = 0.0
    var max4 = 0.0
    for _ in 0..<benchIters {
        let ms = runOnce(p4)
        sum4 += ms
        max4 = max(max4, ms)
    }
    let avg4 = sum4 / Double(benchIters)
    let fps4 = 1000.0 / max(avg4, 0.01)

    let pngPath = "output/snapshots/\(c.slug).png"
    var frameBytes = [UInt8](repeating: 0, count: width * height * 4)
    frameBytes.withUnsafeMutableBytes { ptr in
        outTex.getBytes(ptr.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    // Encode 4K PNGs concurrently across all CPU cores while GPU immediately starts the next scene!
    let wCap = width, hCap = height
    pngGroup.enter()
    pngQueue.async {
        var copy = frameBytes
        copy.withUnsafeMutableBytes { ptr in
            savePNG(bytes: ptr.baseAddress!, width: wCap, height: hCap, path: pngPath)
        }
        pngGroup.leave()
    }

    print(String(format: "%-30s | %7d | %7.2f ms | %7.2f ms | %6.1f | %s",
                 (c.slug as NSString).utf8String!,
                 c.maxBounces,
                 avg1,
                 avg4,
                 fps4,
                 (pngPath as NSString).utf8String!))

    let line = String(format: "{\"slug\":\"%@\",\"scene_id\":%d,\"name\":\"%@\",\"view_mode\":%d,\"width\":%d,\"height\":%d,\"bounces\":%d,\"gpu_1x_ms\":%.3f,\"gpu_4x_ms\":%.3f,\"gpu_4x_max_ms\":%.3f,\"fps_4x\":%.1f,\"png\":\"%@\"}",
                      c.slug, c.sceneId, c.name, c.viewMode, width, height, c.maxBounces, avg1, avg4, max4, fps4, pngPath)
    jsonLines.append(line)
}

pngGroup.wait()
try jsonLines.joined(separator: "\n").appending("\n").write(toFile: "output/bench_log.jsonl", atomically: true, encoding: .utf8)
print("\nSaved 12 \(width)x\(height) snapshots (multi-core PNG) -> output/snapshots/ & log -> output/bench_log.jsonl")
