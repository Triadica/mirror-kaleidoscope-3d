use std::collections::VecDeque;
use std::ffi::c_void;
use std::path::Path;
use std::ptr::NonNull;
use std::time::Instant;

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_core_foundation::CGSize;
use objc2_foundation::NSString;
use objc2_metal::{
    MTLCommandBuffer, MTLCommandBufferStatus, MTLCommandEncoder, MTLCommandQueue,
    MTLCompileOptions, MTLComputeCommandEncoder, MTLComputePipelineState,
    MTLCreateSystemDefaultDevice, MTLDevice, MTLDrawable, MTLLibrary, MTLPixelFormat, MTLSize,
    MTLStorageMode, MTLTexture, MTLTextureDescriptor, MTLTextureUsage,
};
use objc2_quartz_core::{CAMetalDrawable, CAMetalLayer};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use raw_window_metal::Layer;
use winit::window::Window;

use crate::types::MirrorParams;

pub struct MetalRenderer {
    device: Retained<ProtocolObject<dyn MTLDevice>>,
    queue: Retained<ProtocolObject<dyn MTLCommandQueue>>,
    layer: Retained<CAMetalLayer>,

    scene_pipes: Vec<Retained<ProtocolObject<dyn MTLComputePipelineState>>>,
    bloom_extract_pipe: Retained<ProtocolObject<dyn MTLComputePipelineState>>,
    bloom_blur_h_pipe: Retained<ProtocolObject<dyn MTLComputePipelineState>>,
    bloom_blur_v_pipe: Retained<ProtocolObject<dyn MTLComputePipelineState>>,
    composite_pipe: Retained<ProtocolObject<dyn MTLComputePipelineState>>,

    hdr_tex: Option<Retained<ProtocolObject<dyn MTLTexture>>>,
    bloom_a: Option<Retained<ProtocolObject<dyn MTLTexture>>>,
    bloom_b: Option<Retained<ProtocolObject<dyn MTLTexture>>>,
    pub hdr_size: (u32, u32),
    drawable_size: (u32, u32),
    pub spp: u32,

    pending_gpu_cbs: VecDeque<Retained<ProtocolObject<dyn MTLCommandBuffer>>>,
    pub last_gpu_ms: f64,
    last_report: Instant,
    gpu_sum: f64,
    gpu_cnt: u32,
}

impl MetalRenderer {
    pub fn new(window: &Window) -> Self {
        let device = MTLCreateSystemDefaultDevice().expect("No Apple Metal GPU device found");
        let queue = device
            .newCommandQueue()
            .expect("Failed to create Metal command queue");

        let gpu_name = device.name().to_string();
        let mem_gb = device.recommendedMaxWorkingSetSize() as f64 / (1024.0 * 1024.0 * 1024.0);
        eprintln!(
            "[INIT] Metal GPU: {} | UnifiedMemBudget: {:.1} GB",
            gpu_name, mem_gb
        );

        let raw_layer = match window.window_handle().unwrap().as_raw() {
            RawWindowHandle::AppKit(handle) => unsafe { Layer::from_ns_view(handle.ns_view) },
            _ => panic!("Unsupported platform: macOS AppKit required"),
        };
        let layer_ptr: *mut CAMetalLayer = raw_layer.into_raw().as_ptr().cast();
        let layer: Retained<CAMetalLayer> = unsafe {
            Retained::from_raw(layer_ptr).expect("Failed to wrap CAMetalLayer")
        };
        layer.setDevice(Some(&device));
        layer.setPixelFormat(MTLPixelFormat::BGRA8Unorm);
        layer.setFramebufferOnly(false);

        let phys = window.inner_size();
        let dw = phys.width.max(1);
        let dh = phys.height.max(1);
        layer.setDrawableSize(CGSize::new(dw as f64, dh as f64));

        let shader_path = if Path::new("shaders/mirror_kaleidoscope.metal").exists() {
            "shaders/mirror_kaleidoscope.metal"
        } else {
            "mirror_kaleidoscope.metal"
        };
        let t0 = Instant::now();
        let shader_src = std::fs::read_to_string(shader_path)
            .expect("Failed to read shaders/mirror_kaleidoscope.metal");
        let opts = MTLCompileOptions::new();
        let library = device
            .newLibraryWithSource_options_error(&NSString::from_str(&shader_src), Some(&opts))
            .expect("Metal shader compilation failed");

        let make_pipe = |name: &str| -> Retained<ProtocolObject<dyn MTLComputePipelineState>> {
            let fn_obj = library
                .newFunctionWithName(&NSString::from_str(name))
                .unwrap_or_else(|| panic!("Missing Metal kernel '{}'", name));
            device
                .newComputePipelineStateWithFunction_error(&fn_obj)
                .unwrap_or_else(|e| panic!("Pipeline '{}' creation failed: {:?}", name, e))
        };

        let scene_pipes: Vec<_> = (0..10)
            .map(|i| make_pipe(&format!("renderScene{}", i)))
            .collect();
        let bloom_extract_pipe = make_pipe("bloomExtract");
        let bloom_blur_h_pipe = make_pipe("bloomBlurH");
        let bloom_blur_v_pipe = make_pipe("bloomBlurV");
        let composite_pipe = make_pipe("compositeToDrawable");

        eprintln!(
            "[INIT] Compiled 10 per-scene + 4 post-FX Metal pipelines in {:.2}s",
            t0.elapsed().as_secs_f64()
        );

        let mut renderer = Self {
            device,
            queue,
            layer,
            scene_pipes,
            bloom_extract_pipe,
            bloom_blur_h_pipe,
            bloom_blur_v_pipe,
            composite_pipe,
            hdr_tex: None,
            bloom_a: None,
            bloom_b: None,
            hdr_size: (0, 0),
            drawable_size: (dw, dh),
            spp: 4, // Default 2x2 SSAA on Mac Studio M5 Max for razor-sharp mirror filaments!
            pending_gpu_cbs: VecDeque::with_capacity(4),
            last_gpu_ms: 0.0,
            last_report: Instant::now(),
            gpu_sum: 0.0,
            gpu_cnt: 0,
        };
        renderer.ensure_textures();
        renderer
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        let w = width.max(1);
        let h = height.max(1);
        self.drawable_size = (w, h);
        self.layer.setDrawableSize(CGSize::new(w as f64, h as f64));
        self.ensure_textures();
    }

    pub fn cycle_spp(&mut self) {
        self.spp = match self.spp {
            1 => 4,
            4 => 9,
            _ => 1,
        };
        eprintln!("[QUALITY] Supersampling -> {}x SPP", self.spp);
    }

    fn ensure_textures(&mut self) {
        // Render at up to 5K/4K native Retina HDR on Mac Studio
        let dw = self.drawable_size.0.max(1) as f32;
        let dh = self.drawable_size.1.max(1) as f32;
        let scale = (2880.0 / dh).min(1.0);
        let rw = ((dw * scale) as u32).max(320);
        let rh = ((dh * scale) as u32).max(180);
        if self.hdr_size == (rw, rh) && self.hdr_tex.is_some() {
            return;
        }
        self.hdr_size = (rw, rh);
        self.hdr_tex = Some(make_private_tex(&self.device, rw as usize, rh as usize));
        self.bloom_a = Some(make_private_tex(
            &self.device,
            (rw / 2).max(1) as usize,
            (rh / 2).max(1) as usize,
        ));
        self.bloom_b = Some(make_private_tex(
            &self.device,
            (rw / 2).max(1) as usize,
            (rh / 2).max(1) as usize,
        ));
    }

    fn poll_gpu_times(&mut self) {
        while let Some(front) = self.pending_gpu_cbs.front() {
            let status = front.status();
            if status == MTLCommandBufferStatus::Completed {
                let cb = self.pending_gpu_cbs.pop_front().unwrap();
                let ms = ((cb.GPUEndTime() - cb.GPUStartTime()) * 1000.0).max(0.0);
                if ms > 0.0 {
                    self.last_gpu_ms = self.last_gpu_ms * 0.85 + ms * 0.15;
                    self.gpu_sum += ms;
                    self.gpu_cnt += 1;
                }
            } else if status == MTLCommandBufferStatus::Error {
                self.pending_gpu_cbs.pop_front();
            } else {
                break;
            }
        }
    }

    pub fn render_frame(&mut self, params: &MirrorParams) {
        self.poll_gpu_times();
        self.ensure_textures();

        let Some(drawable) = self.layer.nextDrawable() else {
            return;
        };
        let (Some(hdr), Some(b_a), Some(b_b)) = (
            self.hdr_tex.as_ref(),
            self.bloom_a.as_ref(),
            self.bloom_b.as_ref(),
        ) else {
            return;
        };
        let Some(cb) = self.queue.commandBuffer() else {
            return;
        };

        let tg8 = MTLSize { width: 8, height: 8, depth: 1 };
        let tg16 = MTLSize { width: 16, height: 16, depth: 1 };
        let hdr_grid = MTLSize { width: hdr.width(), height: hdr.height(), depth: 1 };
        let bloom_grid = MTLSize { width: b_a.width(), height: b_a.height(), depth: 1 };
        let out_tex = drawable.texture();
        let out_grid = MTLSize { width: out_tex.width(), height: out_tex.height(), depth: 1 };

        // Pass 1: Deep Multi-Bounce Ray Tracing (dedicated per-scene kernel for max GPU occupancy)
        if let Some(enc) = cb.computeCommandEncoder() {
            let pipe = &self.scene_pipes[(params.scene_id as usize).min(self.scene_pipes.len() - 1)];
            enc.setComputePipelineState(pipe);
            unsafe {
                enc.setTexture_atIndex(Some(hdr), 0);
                enc.setBytes_length_atIndex(
                    NonNull::new(params as *const MirrorParams as *mut c_void).unwrap(),
                    std::mem::size_of::<MirrorParams>(),
                    0,
                );
                enc.dispatchThreads_threadsPerThreadgroup(hdr_grid, tg8);
            }
            enc.endEncoding();
        }

        // Pass 2-4: Half-Res HDR Bloom Extract + Separable Blur
        if let Some(enc) = cb.computeCommandEncoder() {
            enc.setComputePipelineState(&self.bloom_extract_pipe);
            unsafe {
                enc.setTexture_atIndex(Some(hdr), 0);
                enc.setTexture_atIndex(Some(b_a), 1);
                enc.dispatchThreads_threadsPerThreadgroup(bloom_grid, tg16);
            }
            enc.endEncoding();
        }
        if let Some(enc) = cb.computeCommandEncoder() {
            enc.setComputePipelineState(&self.bloom_blur_h_pipe);
            unsafe {
                enc.setTexture_atIndex(Some(b_a), 0);
                enc.setTexture_atIndex(Some(b_b), 1);
                enc.dispatchThreads_threadsPerThreadgroup(bloom_grid, tg16);
            }
            enc.endEncoding();
        }
        if let Some(enc) = cb.computeCommandEncoder() {
            enc.setComputePipelineState(&self.bloom_blur_v_pipe);
            unsafe {
                enc.setTexture_atIndex(Some(b_b), 0);
                enc.setTexture_atIndex(Some(b_a), 1);
                enc.dispatchThreads_threadsPerThreadgroup(bloom_grid, tg16);
            }
            enc.endEncoding();
        }

        // Pass 5: ACES Filmic Tonemapping + Edge AA + Dither -> Drawable
        if let Some(enc) = cb.computeCommandEncoder() {
            enc.setComputePipelineState(&self.composite_pipe);
            unsafe {
                enc.setTexture_atIndex(Some(hdr), 0);
                enc.setTexture_atIndex(Some(b_a), 1);
                enc.setTexture_atIndex(Some(&out_tex), 2);
                enc.setBytes_length_atIndex(
                    NonNull::new(params as *const MirrorParams as *mut c_void).unwrap(),
                    std::mem::size_of::<MirrorParams>(),
                    0,
                );
                enc.dispatchThreads_threadsPerThreadgroup(out_grid, tg16);
            }
            enc.endEncoding();
        }

        let mtl_drawable: &ProtocolObject<dyn MTLDrawable> = ProtocolObject::from_ref(&*drawable);
        cb.presentDrawable(mtl_drawable);
        cb.commit();

        if self.pending_gpu_cbs.len() >= 4 {
            self.pending_gpu_cbs.pop_front();
        }
        self.pending_gpu_cbs.push_back(cb);

        if self.last_report.elapsed().as_secs_f64() >= 2.0 && self.gpu_cnt > 0 {
            let avg_gpu = self.gpu_sum / self.gpu_cnt as f64;
            let mrays = (hdr.width() * hdr.height()) as f64 * params.spp as f64 / 1_000_000.0;
            eprintln!(
                "[PERF] Scene={} | {} bounces | {}x{} ({}xSPP, {:.2} MRays/f) | GPU={:.2}ms",
                params.scene_id + 1,
                params.max_bounces,
                hdr.width(),
                hdr.height(),
                params.spp,
                mrays,
                avg_gpu
            );
            self.last_report = Instant::now();
            self.gpu_sum = 0.0;
            self.gpu_cnt = 0;
        }
    }
}

fn make_private_tex(
    device: &ProtocolObject<dyn MTLDevice>,
    w: usize,
    h: usize,
) -> Retained<ProtocolObject<dyn MTLTexture>> {
    let desc = unsafe {
        MTLTextureDescriptor::texture2DDescriptorWithPixelFormat_width_height_mipmapped(
            MTLPixelFormat::RGBA16Float,
            w.max(1),
            h.max(1),
            false,
        )
    };
    desc.setUsage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
    desc.setStorageMode(MTLStorageMode::Private);
    device
        .newTextureWithDescriptor(&desc)
        .expect("Failed to allocate Metal texture")
}
