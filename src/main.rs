mod gamepad;
mod renderer;
mod scene;
mod types;

use std::sync::Arc;
use std::time::Instant;

use winit::application::ApplicationHandler;
use winit::dpi::LogicalSize;
use winit::event::{ElementState, MouseButton, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{KeyCode, PhysicalKey};
use winit::window::{Window, WindowId};

use crate::gamepad::GamepadManager;
use crate::renderer::MetalRenderer;
use crate::scene::SceneState;

struct LaunchConfig {
    scene_id: u32,
    width: f64,
    height: f64,
    maximized: bool,
    spp: u32,
}

impl LaunchConfig {
    fn from_args() -> Self {
        let mut cfg = Self {
            scene_id: 0,
            width: 1600.0,
            height: 960.0,
            maximized: false, // Default windowed mode for easy multitasking + 4K quality
            spp: 4,
        };
        let args: Vec<String> = std::env::args().collect();
        let mut i = 1;
        while i < args.len() {
            match args[i].as_str() {
                "--scene" if i + 1 < args.len() => {
                    if let Ok(s) = args[i + 1].parse::<u32>() {
                        cfg.scene_id = s.saturating_sub(1).min(9);
                    }
                    i += 1;
                }
                "--width" if i + 1 < args.len() => {
                    if let Ok(w) = args[i + 1].parse::<f64>() {
                        cfg.width = w.max(640.0);
                    }
                    i += 1;
                }
                "--height" if i + 1 < args.len() => {
                    if let Ok(h) = args[i + 1].parse::<f64>() {
                        cfg.height = h.max(360.0);
                    }
                    i += 1;
                }
                "--spp" if i + 1 < args.len() => {
                    if let Ok(s) = args[i + 1].parse::<u32>() {
                        cfg.spp = match s {
                            1 | 4 | 9 => s,
                            _ => 4,
                        };
                    }
                    i += 1;
                }
                "--maximized" => cfg.maximized = true,
                "--windowed" => cfg.maximized = false,
                _ => {}
            }
            i += 1;
        }
        cfg
    }
}

struct App {
    cfg: LaunchConfig,
    window: Option<Arc<Window>>,
    renderer: Option<MetalRenderer>,
    scene: SceneState,
    gamepad: GamepadManager,
    dragging: bool,
    last_cursor: Option<(f64, f64)>,
    last_frame: Instant,
    smoothed_fps: f64,
    title_tick: u32,
}

impl App {
    fn new(cfg: LaunchConfig) -> Self {
        let mut scene = SceneState::new();
        scene.apply_scene_preset(cfg.scene_id);
        Self {
            cfg,
            window: None,
            renderer: None,
            scene,
            gamepad: GamepadManager::new(),
            dragging: false,
            last_cursor: None,
            last_frame: Instant::now(),
            smoothed_fps: 60.0,
            title_tick: 0,
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title("多镜面深度光追万花筒 · Rust + Apple Metal")
            .with_inner_size(LogicalSize::new(self.cfg.width, self.cfg.height))
            .with_maximized(self.cfg.maximized);
        let window = Arc::new(
            event_loop
                .create_window(attrs)
                .expect("Failed to create window"),
        );
        let mut renderer = MetalRenderer::new(&window);
        renderer.spp = self.cfg.spp;

        eprintln!("================================================================");
        eprintln!("  10 合 1 多镜面 & 折射色散深度光追实验室 (Rust + Apple Metal)");
        eprintln!("  [1-9, 0] 切换 10 种光学镜室/水晶/焦散/GRIN/角锥案例");
        eprintln!("  [B/N]    调整反射次数 (4..64)  | [C] 切换 4 种镜面镀膜");
        eprintln!("  [V]      切换内/外视角 (或场景0中切换 GRIN弯曲光 <-> 角锥逆反射)");
        eprintln!("  [Q/E]    实时调节形态/色散/曲率/焦散角度/扭转/梯度");
        eprintln!("  [G]      切换 1x / 4x / 9x RGSS | [O] 自动环绕 | [WASD+拖拽] 飞行");
        eprintln!("  [手柄]   左摇杆移动 | 右摇杆视角 | L2/R2升降 | L1/R1形态 | 十字键切场景");
        eprintln!("  [P]      暂停动画 | [R] 重置场景 | [Esc] 退出");
        eprintln!("================================================================");

        self.window = Some(window);
        self.renderer = Some(renderer);
        self.last_frame = Instant::now();
    }

    fn window_event(
        &mut self,
        event_loop: &ActiveEventLoop,
        _window_id: WindowId,
        event: WindowEvent,
    ) {
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::Resized(new_size) => {
                if let Some(renderer) = self.renderer.as_mut() {
                    renderer.resize(new_size.width, new_size.height);
                }
            }
            WindowEvent::MouseInput { state, button, .. } => {
                if button == MouseButton::Left {
                    self.dragging = state == ElementState::Pressed;
                    if !self.dragging {
                        self.last_cursor = None;
                    }
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                if self.dragging {
                    if let Some((lx, ly)) = self.last_cursor {
                        let dx = (position.x - lx) as f32;
                        let dy = (position.y - ly) as f32;
                        self.scene.mouse_look(dx, dy);
                    }
                }
                self.last_cursor = Some((position.x, position.y));
            }
            WindowEvent::KeyboardInput { event, .. } => {
                if let PhysicalKey::Code(code) = event.physical_key {
                    match event.state {
                        ElementState::Pressed => {
                            self.scene.keys_down.insert(code);
                            if !event.repeat {
                                match code {
                                    KeyCode::Digit1 => self.scene.apply_scene_preset(0),
                                    KeyCode::Digit2 => self.scene.apply_scene_preset(1),
                                    KeyCode::Digit3 => self.scene.apply_scene_preset(2),
                                    KeyCode::Digit4 => self.scene.apply_scene_preset(3),
                                    KeyCode::Digit5 => self.scene.apply_scene_preset(4),
                                    KeyCode::Digit6 => self.scene.apply_scene_preset(5),
                                    KeyCode::Digit7 => self.scene.apply_scene_preset(6),
                                    KeyCode::Digit8 => self.scene.apply_scene_preset(7),
                                    KeyCode::Digit9 => self.scene.apply_scene_preset(8),
                                    KeyCode::Digit0 => self.scene.apply_scene_preset(9),
                                    KeyCode::KeyB => self.scene.step_bounces(-1),
                                    KeyCode::KeyN => self.scene.step_bounces(1),
                                    KeyCode::KeyC => self.scene.cycle_coating(),
                                    KeyCode::KeyV => self.scene.toggle_view_mode(),
                                    KeyCode::KeyO => {
                                        self.scene.auto_orbit = !self.scene.auto_orbit;
                                        eprintln!("[CAM] Auto-Orbit -> {}", self.scene.auto_orbit);
                                    }
                                    KeyCode::KeyP => {
                                        self.scene.paused = !self.scene.paused;
                                        eprintln!("[ANIM] Paused -> {}", self.scene.paused);
                                    }
                                    KeyCode::KeyG => {
                                        if let Some(r) = self.renderer.as_mut() {
                                            r.cycle_spp();
                                        }
                                    }
                                    KeyCode::KeyR => {
                                        let id = self.scene.scene_id;
                                        self.scene.apply_scene_preset(id);
                                    }
                                    KeyCode::Escape => event_loop.exit(),
                                    _ => {}
                                }
                            }
                        }
                        ElementState::Released => {
                            self.scene.keys_down.remove(&code);
                        }
                    }
                }
            }
            WindowEvent::RedrawRequested => {
                let now = Instant::now();
                let raw_dt = now
                    .duration_since(self.last_frame)
                    .as_secs_f64()
                    .max(1.0 / 240.0);
                let dt = (raw_dt as f32).min(0.05);
                self.last_frame = now;
                self.smoothed_fps = self.smoothed_fps * 0.90 + (1.0 / raw_dt) * 0.10;

                let gp = self.gamepad.poll();
                self.scene.apply_gamepad(&gp, dt);
                if gp.cycle_spp {
                    if let Some(r) = self.renderer.as_mut() {
                        r.cycle_spp();
                    }
                }

                self.scene.update(dt);

                if let Some(renderer) = self.renderer.as_mut() {
                    let (hw, hh) = renderer.hdr_size;
                    let params = self
                        .scene
                        .build_params(hw.max(320), hh.max(180), renderer.spp);
                    renderer.render_frame(&params);

                    self.title_tick += 1;
                    if self.title_tick >= 12 {
                        self.title_tick = 0;
                        if let Some(win) = self.window.as_ref() {
                            win.set_title(&self.scene.status_title(
                                self.smoothed_fps,
                                renderer.last_gpu_ms,
                                renderer.hdr_size.1,
                                renderer.spp,
                            ));
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(window) = self.window.as_ref() {
            window.request_redraw();
        }
    }
}

fn main() {
    let cfg = LaunchConfig::from_args();
    let event_loop = EventLoop::new().expect("Failed to create winit EventLoop");
    event_loop.set_control_flow(ControlFlow::Poll);
    let mut app = App::new(cfg);
    event_loop.run_app(&mut app).expect("EventLoop error");
}
