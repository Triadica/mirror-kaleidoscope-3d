#![allow(dead_code)]

#[path = "../gamepad.rs"]
mod gamepad;
#[path = "../types.rs"]
mod types;
#[path = "../scene.rs"]
mod scene;

use std::ffi::c_void;
use std::fs::{self, File};
use std::io::{BufWriter, Write};
use std::path::Path;
use std::ptr::NonNull;
use std::time::Instant;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_foundation::NSString;
use objc2_metal::{
    MTLCommandBuffer, MTLCommandEncoder, MTLCommandQueue, MTLCompileOptions,
    MTLComputeCommandEncoder, MTLComputePipelineState, MTLCreateSystemDefaultDevice, MTLDevice,
    MTLLibrary, MTLOrigin, MTLPixelFormat, MTLRegion, MTLSize, MTLStorageMode, MTLTexture,
    MTLTextureDescriptor, MTLTextureUsage,
};

use crate::scene::{SceneState, SCENE_NAMES};
use crate::types::MirrorParams;

struct SnapshotCase {
    slug: &'static str,
    scene_id: u32,
    view_mode: u32,
    sim_time: f32,
    morph_override: Option<f32>,
}

const CASES: &[SnapshotCase] = &[
    SnapshotCase { slug: "01a_platonic_portal_inside",   scene_id: 0, view_mode: 0, sim_time: 2.5, morph_override: Some(0.0) },
    SnapshotCase { slug: "01b_platonic_portal_outside",  scene_id: 0, view_mode: 1, sim_time: 3.0, morph_override: Some(0.5) },
    SnapshotCase { slug: "02_wada_basin_spheres",        scene_id: 1, view_mode: 0, sim_time: 2.0, morph_override: None },
    SnapshotCase { slug: "03_coxeter_hyperbolic",        scene_id: 2, view_mode: 0, sim_time: 2.5, morph_override: None },
    SnapshotCase { slug: "04_dichroic_infinity_room",    scene_id: 3, view_mode: 0, sim_time: 2.5, morph_override: None },
    SnapshotCase { slug: "05_dichroic_crystal_cube",     scene_id: 4, view_mode: 0, sim_time: 2.5, morph_override: None },
    SnapshotCase { slug: "06_spectral_diamond_fire",     scene_id: 5, view_mode: 0, sim_time: 2.5, morph_override: None },
    SnapshotCase { slug: "07_dichroic_caustics_wall",    scene_id: 6, view_mode: 0, sim_time: 2.0, morph_override: None },
    SnapshotCase { slug: "08_eliasson_colour_tunnel",    scene_id: 7, view_mode: 0, sim_time: 2.5, morph_override: None },
    SnapshotCase { slug: "09_apollonian_packing",        scene_id: 8, view_mode: 0, sim_time: 2.5, morph_override: None },
    SnapshotCase { slug: "10a_grin_curved_light",        scene_id: 9, view_mode: 0, sim_time: 2.5, morph_override: None },
    SnapshotCase { slug: "10b_corner_cube_retro_wall",   scene_id: 9, view_mode: 1, sim_time: 2.5, morph_override: None },
];

fn make_tex(
    device: &ProtocolObject<dyn MTLDevice>,
    fmt: MTLPixelFormat,
    w: usize,
    h: usize,
    mode: MTLStorageMode,
) -> Retained<ProtocolObject<dyn MTLTexture>> {
    let desc = unsafe {
        MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
            fmt,
            w.max(1),
            h.max(1),
            false,
        )
    };
    desc.setUsage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
    desc.setStorageMode(mode);
    device
        .newTextureWithDescriptor(&desc)
        .expect("Failed to create Metal texture")
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut width: u32 = 3840;
    let mut height: u32 = 2160;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--5k" => { width = 5120; height = 2880; }
            "--6k" => { width = 6016; height = 3384; }
            "--width" if i + 1 < args.len() => { i += 1; width = args[i].parse().unwrap_or(3840); }
            "--height" if i + 1 < args.len() => { i += 1; height = args[i].parse().unwrap_or(2160); }
            _ => {}
        }
        i += 1;
    }
    let bench_iters: usize = 5;

    let device = MTLCreateSystemDefaultDevice().expect("No Apple Metal GPU found");
    let queue = device.newCommandQueue().expect("Failed to create Metal command queue");
    let gpu_name = device.name().to_string();
    let mem_gb = device.recommendedMaxWorkingSetSize() as f64 / (1024.0 * 1024.0 * 1024.0);
    println!(
        "=== Mirror Kaleidoscope 3D Snapshot & GPU Benchmark ===\nGPU: {} | UnifiedMemBudget: {:.1} GB | Resolution: {}x{} ({:.2} MP)",
        gpu_name, mem_gb, width, height, (width as f64 * height as f64) / 1_000_000.0
    );

    let shader_path = if Path::new("shaders/mirror_kaleidoscope.metal").exists() {
        "shaders/mirror_kaleidoscope.metal"
    } else {
        "mirror_kaleidoscope.metal"
    };
    let t_comp = Instant::now();
    let shader_src =
        fs::read_to_string(shader_path).expect("Failed to read shaders/mirror_kaleidoscope.metal");
    let opts = MTLCompileOptions::new();
    let library = device
        .newLibraryWithSource_options_error(&NSString::from_str(&shader_src), Some(&opts))
        .expect("Metal shader compilation failed");

    let make_pipe = |name: &str| -> Retained<ProtocolObject<dyn MTLComputePipelineState>> {
        let f = library
            .newFunctionWithName(&NSString::from_str(name))
            .unwrap_or_else(|| panic!("Missing Metal kernel '{}'", name));
        device
            .newComputePipelineStateWithFunction_error(&f)
            .unwrap_or_else(|e| panic!("Pipeline '{}' failed: {:?}", name, e))
    };

    let scene_pipes: Vec<_> = (0..10)
        .map(|idx| make_pipe(&format!("renderScene{}", idx)))
        .collect();
    let bloom_extract_pipe = make_pipe("bloomExtract");
    let bloom_blur_h_pipe = make_pipe("bloomBlurH");
    let bloom_blur_v_pipe = make_pipe("bloomBlurV");
    let composite_pipe = make_pipe("compositeToDrawable");
    let compile_ms = t_comp.elapsed().as_secs_f64() * 1000.0;
    println!("Shader compile (10 dedicated scene kernels): {:.1}ms\n", compile_ms);

    let w_usize = width as usize;
    let h_usize = height as usize;
    let hdr_tex = make_tex(&device, MTLPixelFormat::RGBA16Float, w_usize, h_usize, MTLStorageMode::Private);
    let bloom_a = make_tex(&device, MTLPixelFormat::RGBA16Float, w_usize / 2, h_usize / 2, MTLStorageMode::Private);
    let bloom_b = make_tex(&device, MTLPixelFormat::RGBA16Float, w_usize / 2, h_usize / 2, MTLStorageMode::Private);
    let out_tex = make_tex(&device, MTLPixelFormat::RGBA8Unorm, w_usize, h_usize, MTLStorageMode::Shared);

    let bytes_per_row = w_usize * 4;
    let full_region = MTLRegion {
        origin: MTLOrigin { x: 0, y: 0, z: 0 },
        size: MTLSize { width: w_usize, height: h_usize, depth: 1 },
    };

    let tg8 = MTLSize { width: 8, height: 8, depth: 1 };
    let tg16 = MTLSize { width: 16, height: 16, depth: 1 };
    let hdr_grid = MTLSize { width: w_usize, height: h_usize, depth: 1 };
    let bloom_grid = MTLSize { width: w_usize / 2, height: h_usize / 2, depth: 1 };

    fs::create_dir_all("output/snapshots").expect("create output/snapshots");
    let log_file = File::create("output/bench_log.jsonl").expect("create output/bench_log.jsonl");
    let mut log_w = BufWriter::new(log_file);
    let mut png_threads: Vec<std::thread::JoinHandle<()>> = Vec::new();

    let run_once = |params: &MirrorParams| -> f64 {
        let cb = queue.commandBuffer().expect("CommandBuffer");
        if let Some(enc) = cb.computeCommandEncoder() {
            enc.setComputePipelineState(&scene_pipes[(params.scene_id as usize).min(9)]);
            unsafe {
                enc.setTexture_atIndex(Some(&hdr_tex), 0);
                enc.setBytes_length_atIndex(
                    NonNull::new(params as *const MirrorParams as *mut c_void).unwrap(),
                    std::mem::size_of::<MirrorParams>(),
                    0,
                );
                enc.dispatchThreads_threadsPerThreadgroup(hdr_grid, tg8);
            }
            enc.endEncoding();
        }
        if let Some(enc) = cb.computeCommandEncoder() {
            enc.setComputePipelineState(&bloom_extract_pipe);
            unsafe {
                enc.setTexture_atIndex(Some(&hdr_tex), 0);
                enc.setTexture_atIndex(Some(&bloom_a), 1);
                enc.dispatchThreads_threadsPerThreadgroup(bloom_grid, tg16);
            }
            enc.endEncoding();
        }
        if let Some(enc) = cb.computeCommandEncoder() {
            enc.setComputePipelineState(&bloom_blur_h_pipe);
            unsafe {
                enc.setTexture_atIndex(Some(&bloom_a), 0);
                enc.setTexture_atIndex(Some(&bloom_b), 1);
                enc.dispatchThreads_threadsPerThreadgroup(bloom_grid, tg16);
            }
            enc.endEncoding();
        }
        if let Some(enc) = cb.computeCommandEncoder() {
            enc.setComputePipelineState(&bloom_blur_v_pipe);
            unsafe {
                enc.setTexture_atIndex(Some(&bloom_b), 0);
                enc.setTexture_atIndex(Some(&bloom_a), 1);
                enc.dispatchThreads_threadsPerThreadgroup(bloom_grid, tg16);
            }
            enc.endEncoding();
        }
        if let Some(enc) = cb.computeCommandEncoder() {
            enc.setComputePipelineState(&composite_pipe);
            unsafe {
                enc.setTexture_atIndex(Some(&hdr_tex), 0);
                enc.setTexture_atIndex(Some(&bloom_a), 1);
                enc.setTexture_atIndex(Some(&out_tex), 2);
                enc.setBytes_length_atIndex(
                    NonNull::new(params as *const MirrorParams as *mut c_void).unwrap(),
                    std::mem::size_of::<MirrorParams>(),
                    0,
                );
                enc.dispatchThreads_threadsPerThreadgroup(hdr_grid, tg16);
            }
            enc.endEncoding();
        }
        cb.commit();
        cb.waitUntilCompleted();
        ((cb.GPUEndTime() - cb.GPUStartTime()) * 1000.0).max(0.0)
    };

    println!(
        "{:<30} | {:>7} | {:>10} | {:>10} | {:>8} | {}",
        "Snapshot Case", "Bounces", "1xSPP GPU", "4xSPP GPU", "4x FPS", "Output PNG"
    );
    println!("{}", "-".repeat(102));

    for case in CASES {
        let mut st = SceneState::new();
        st.apply_scene_preset(case.scene_id);
        if case.view_mode != st.view_mode {
            st.toggle_view_mode();
        }
        if let Some(m) = case.morph_override {
            st.morph_param = m;
        }
        st.sim_time = case.sim_time;
        st.update(0.0);

        let p1 = st.build_params(width, height, 1);
        let _ = run_once(&p1);
        let mut sum1 = 0.0;
        for _ in 0..bench_iters {
            sum1 += run_once(&p1);
        }
        let avg1 = sum1 / bench_iters as f64;

        let p4 = st.build_params(width, height, 4);
        let _ = run_once(&p4);
        let mut sum4 = 0.0;
        let mut max4: f64 = 0.0;
        for _ in 0..bench_iters {
            let ms = run_once(&p4);
            sum4 += ms;
            max4 = max4.max(ms);
        }
        let avg4 = sum4 / bench_iters as f64;
        let fps4 = 1000.0 / avg4.max(0.01);

        let mut frame_buf = vec![0u8; h_usize * bytes_per_row];
        unsafe {
            out_tex.getBytes_bytesPerRow_fromRegion_mipmapLevel(
                NonNull::new(frame_buf.as_mut_ptr() as *mut c_void).unwrap(),
                bytes_per_row,
                full_region,
                0,
            );
        }

        let png_path = format!("output/snapshots/{}.png", case.slug);
        let png_path_thread = png_path.clone();
        png_threads.push(std::thread::spawn(move || {
            let file = File::create(&png_path_thread).expect("PNG create failed");
            let mut enc = png::Encoder::new(BufWriter::new(file), width, height);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            enc.set_compression(png::Compression::Fast);
            let mut wr = enc.write_header().expect("PNG header failed");
            wr.write_image_data(&frame_buf).expect("PNG write failed");
        }));

        println!(
            "{:<30} | {:>7} | {:>7.2} ms | {:>7.2} ms | {:>6.1} | {}",
            case.slug, st.max_bounces, avg1, avg4, fps4, png_path
        );
        writeln!(
            log_w,
            "{{\"slug\":\"{}\",\"scene_id\":{},\"name\":\"{}\",\"view_mode\":{},\"width\":{},\"height\":{},\"bounces\":{},\"gpu_1x_ms\":{:.3},\"gpu_4x_ms\":{:.3},\"gpu_4x_max_ms\":{:.3},\"fps_4x\":{:.1},\"png\":\"{}\"}}",
            case.slug,
            case.scene_id,
            SCENE_NAMES[case.scene_id as usize],
            case.view_mode,
            width,
            height,
            st.max_bounces,
            avg1,
            avg4,
            max4,
            fps4,
            png_path
        )
        .unwrap();
    }
    for h in png_threads {
        h.join().expect("PNG encoder thread panicked");
    }
    log_w.flush().unwrap();
    println!("\nSaved 12 {}x{} (4x SSAA, multi-core PNG) snapshots -> output/snapshots/", width, height);
    println!("Saved structured GPU benchmark log -> output/bench_log.jsonl");
}
