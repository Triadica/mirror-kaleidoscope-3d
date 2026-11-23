import Foundation
import Metal
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

struct ClipSpec: Codable {
    let slug: String
    let name: String
    let scene_id: UInt32
    let view_mode: UInt32?
    let max_bounces: UInt32?
    let coating_mode: UInt32?
    let keyframes: [Keyframe]
}

struct ShowcaseManifest: Codable {
    let title: String
    let width: Int?
    let height: Int?
    let fps: Int?
    let spp: UInt32?
    let fade_sec: Double?
    let clips: [ClipSpec]
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

func sampleClip(_ clip: ClipSpec, at tSec: Double) -> (pos: SIMD3<Float>, target: SIMD3<Float>, fov: Float, morph: Float, exp: Float, simTime: Float) {
    let kfs = clip.keyframes
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

func findFFmpeg() -> String {
    for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return "ffmpeg"
}

// Parse CLI args
var manifestPath = "scripts/cameras/showcase_12demos_20s.json"
var overrideWidth: Int? = nil
var overrideHeight: Int? = nil
var overrideFps: Int? = nil
var overrideSpp: UInt32? = nil
var codecMode = "videotoolbox" // "videotoolbox" (Apple Silicon HW HEVC 55Mbps) or "x265" (CRF 15)
var skipExisting = false
var onlyFilter: Set<String>? = nil

let args = CommandLine.arguments
var idx = 1
while idx < args.count {
    let a = args[idx]
    if a == "--manifest", idx + 1 < args.count {
        manifestPath = args[idx + 1]; idx += 1
    } else if a == "--5k" {
        overrideWidth = 5120; overrideHeight = 2880
    } else if a == "--width", idx + 1 < args.count {
        overrideWidth = Int(args[idx + 1]); idx += 1
    } else if a == "--height", idx + 1 < args.count {
        overrideHeight = Int(args[idx + 1]); idx += 1
    } else if a == "--fps", idx + 1 < args.count {
        overrideFps = Int(args[idx + 1]); idx += 1
    } else if a == "--spp", idx + 1 < args.count {
        overrideSpp = UInt32(args[idx + 1]); idx += 1
    } else if a == "--codec", idx + 1 < args.count {
        codecMode = args[idx + 1]; idx += 1
    } else if a == "--skip-existing" {
        skipExisting = true
    } else if a == "--only", idx + 1 < args.count {
        onlyFilter = Set(args[idx + 1].split(separator: ",").map { String($0) }); idx += 1
    }
    idx += 1
}

let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
let manifest = try JSONDecoder().decode(ShowcaseManifest.self, from: data)
let width = overrideWidth ?? manifest.width ?? 3840
let height = overrideHeight ?? manifest.height ?? 2160
let fps = overrideFps ?? manifest.fps ?? 30
let spp = overrideSpp ?? manifest.spp ?? 9
let fadeSec = manifest.fade_sec ?? 0.55

guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    fatalError("No Apple Metal GPU available")
}

let ffmpegBin = findFFmpeg()
print("=== \(manifest.title) ===")
print("GPU: \(device.name) | \(width)x\(height) @ \(fps)fps | \(spp)x RGSS | Codec: \(codecMode) | \(manifest.clips.count) clips")

let tComp = CFAbsoluteTimeGetCurrent()
let shaderSrc = try String(contentsOfFile: "shaders/mirror_kaleidoscope.metal", encoding: .utf8)
let library = try device.makeLibrary(source: shaderSrc, options: nil)
func makePipe(_ name: String) -> MTLComputePipelineState {
    try! device.makeComputePipelineState(function: library.makeFunction(name: name)!)
}

var scenePipes = [MTLComputePipelineState?](repeating: nil, count: 10)
let pipeLock = NSLock()
DispatchQueue.concurrentPerform(iterations: 10) { i in
    let p = makePipe("renderScene\(i)")
    pipeLock.lock()
    scenePipes[i] = p
    pipeLock.unlock()
}
let resolvedPipes = scenePipes.map { $0! }
let bloomExtPipe = makePipe("bloomExtract")
let bloomHPipe = makePipe("bloomBlurH")
let bloomVPipe = makePipe("bloomBlurV")
let compPipe = makePipe("compositeToDrawable")
print(String(format: "Compiled 10 Metal kernels in %.2fs\n", CFAbsoluteTimeGetCurrent() - tComp))

let hdrTex = makeTex(device, fmt: .rgba16Float, w: width, h: height, mode: .private)
let bloomA = makeTex(device, fmt: .rgba16Float, w: width / 2, h: height / 2, mode: .private)
let bloomB = makeTex(device, fmt: .rgba16Float, w: width / 2, h: height / 2, mode: .private)
let outTex = makeTex(device, fmt: .rgba8Unorm, w: width, h: height, mode: .shared)

let clipsDir = "output/video/clips"
try FileManager.default.createDirectory(atPath: clipsDir, withIntermediateDirectories: true)

let tg8 = MTLSize(width: 8, height: 8, depth: 1)
let tg16 = MTLSize(width: 16, height: 16, depth: 1)
let hdrGrid = MTLSize(width: width, height: height, depth: 1)
let bloomGrid = MTLSize(width: width / 2, height: height / 2, depth: 1)
let frameByteCount = width * height * 4

let totalWallStart = CFAbsoluteTimeGetCurrent()
var concatLines: [String] = []

for (clipIdx, clip) in manifest.clips.enumerated() {
    let mp4Path = "\(clipsDir)/\(clip.slug).mp4"
    concatLines.append("file '\(URL(fileURLWithPath: mp4Path).path)'")

    if let filter = onlyFilter, !filter.contains(clip.slug), !filter.contains(String(clip.slug.prefix(3))), !filter.contains(String(clip.slug.prefix(2))) {
        continue
    }
    if skipExisting && FileManager.default.fileExists(atPath: mp4Path) {
        print("[\(clipIdx + 1)/\(manifest.clips.count)] Skipping existing \(mp4Path)")
        continue
    }

    let duration = clip.keyframes.last?.time ?? 20.0
    let totalFrames = max(1, Int(round(duration * Double(fps))))
    print("[\(clipIdx + 1)/\(manifest.clips.count)] Rendering \(clip.slug) | \(Int(duration))s (\(totalFrames) frames @ \(width)x\(height) \(spp)xRGSS) -> \(mp4Path)")
    fflush(stdout)

    // Spawn ffmpeg stdin pipe directly from Metal GPU -> MP4 (zero temporary 4K PNG disk bloat!)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ffmpegBin)
    var ffArgs = [
        "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgba",
        "-s", "\(width)x\(height)", "-r", "\(fps)",
        "-i", "pipe:0",
    ]
    if codecMode == "x265" {
        ffArgs += ["-c:v", "libx265", "-preset", "medium", "-crf", "15", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1"]
    } else {
        // Apple Silicon hardware HEVC encoder: blazing fast + crisp 4K 55Mbps + native QuickTime playback
        ffArgs += ["-c:v", "hevc_videotoolbox", "-b:v", "55M", "-maxrate", "75M", "-pix_fmt", "yuv420p", "-tag:v", "hvc1"]
    }
    ffArgs += ["-movflags", "+faststart", mp4Path]
    proc.arguments = ffArgs

    let inPipe = Pipe()
    proc.standardInput = inPipe
    try proc.run()

    let pipeHandle = inPipe.fileHandleForWriting
    let writeQueue = DispatchQueue(label: "ffmpeg.pipe.writer")
    let inflightSem = DispatchSemaphore(value: 3) // allow up to 3 frames buffered so GPU never stalls on pipe write

    let scenePipe = resolvedPipes[min(Int(clip.scene_id), 9)]
    let bounces = clip.max_bounces ?? 36
    let coating = clip.coating_mode ?? 0
    let viewMode = clip.view_mode ?? 0

    let clipStart = CFAbsoluteTimeGetCurrent()
    var gpuSumMs = 0.0

    for f in 0..<totalFrames {
        let tSec = Double(f) / Double(fps)
        let s = sampleClip(clip, at: tSec)

        // Smooth cinema fade-in & fade-out envelope for seamless multi-demo stitching
        var fade: Float = 1.0
        if fadeSec > 1e-3 {
            if tSec < fadeSec { fade = smoothstep(Float(tSec / fadeSec)) }
            else if tSec > duration - fadeSec { fade = smoothstep(Float((duration - tSec) / fadeSec)) }
        }

        let fwd = simd_normalize(s.target - s.pos)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), fwd))
        let up = simd_normalize(simd_cross(fwd, right))

        var p = MirrorParams(
            width: UInt32(width), height: UInt32(height),
            scene_id: clip.scene_id, max_bounces: bounces,
            coating_mode: coating, spp: spp, view_mode: viewMode,
            frame_index: UInt32(f), time: s.simTime,
            fov: s.fov * .pi / 180.0, morph_param: s.morph, exposure: s.exp * fade,
            cam_pos: SIMD4(s.pos.x, s.pos.y, s.pos.z, 0),
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
        gpuSumMs += max(0.0, (cb.gpuEndTime - cb.gpuStartTime) * 1000.0)

        inflightSem.wait()
        var frameData = Data(count: frameByteCount)
        frameData.withUnsafeMutableBytes { ptr in
            outTex.getBytes(ptr.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        writeQueue.async {
            try? pipeHandle.write(contentsOf: frameData)
            inflightSem.signal()
        }

        if (f + 1) % (fps * 5) == 0 || f + 1 == totalFrames {
            let pct = Double(f + 1) * 100.0 / Double(totalFrames)
            print(String(format: "    %5.1f%% (%d/%d) | Avg GPU: %.2f ms/f | Elapsed: %.1fs",
                         pct, f + 1, totalFrames, gpuSumMs / Double(f + 1), CFAbsoluteTimeGetCurrent() - clipStart))
            fflush(stdout)
        }
    }

    writeQueue.sync {}
    try? pipeHandle.close()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        print("  [WARN] ffmpeg exited with status \(proc.terminationStatus) for \(clip.slug)")
    } else {
        let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - clipStart)
        let avgMs = String(format: "%.2f", gpuSumMs / Double(totalFrames))
        print("  -> Saved \(mp4Path) in \(elapsed)s (Avg GPU: \(avgMs) ms/f)\n")
    }
    fflush(stdout)
}

// Stitch all existing clips losslessly into one master 4K showcase video
let existingLines = concatLines.filter { line in
    let path = line.replacingOccurrences(of: "file '", with: "").replacingOccurrences(of: "'", with: "")
    return FileManager.default.fileExists(atPath: path)
}
let concatPath = "output/video/concat_list.txt"
try existingLines.joined(separator: "\n").appending("\n").write(toFile: concatPath, atomically: true, encoding: .utf8)

let finalMp4 = "output/video/mirror_kaleidoscope_4k_showcase.mp4"
if !existingLines.isEmpty {
    print("Stitching \(existingLines.count) clips losslessly -> \(finalMp4) ...")
    fflush(stdout)
    let stitch = Process()
    stitch.executableURL = URL(fileURLWithPath: ffmpegBin)
    stitch.standardInput = FileHandle.nullDevice
    stitch.arguments = ["-nostdin", "-y", "-loglevel", "warning", "-f", "concat", "-safe", "0", "-i", concatPath, "-c", "copy", "-movflags", "+faststart", finalMp4]
    try stitch.run()
    stitch.waitUntilExit()
    if stitch.terminationStatus == 0 {
        let totalSec = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - totalWallStart)
        print("\n=== Master 4K Showcase Ready: \(finalMp4) (Total wall time: \(totalSec)s) ===")
    } else {
        print("[WARN] ffmpeg concat exited with status \(stitch.terminationStatus)")
    }
}
