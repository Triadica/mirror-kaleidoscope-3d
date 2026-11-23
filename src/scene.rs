use std::collections::HashSet;
use glam::Vec3;
use winit::keyboard::KeyCode;

use crate::types::MirrorParams;

pub const SCENE_NAMES: [&str; 10] = [
    "1: 多面体无限镜雕塑 (Platonic Portal)",
    "2: 四镜面球和田盆分形 (Wada Basins)",
    "3: 考克斯特/双曲万花筒 (Coxeter Hyperbolic)",
    "4: 二向色无限镜屋 (Dichroic Infinity Room)",
    "5: 冷加工二向色水晶魔方 (Dichroic Crystal Cube)",
    "6: 切面钻石6波段色散 (Spectral Diamond Fire)",
    "7: 二向色玻璃焦散光阵 (Dichroic Caustics Wall)",
    "8: 彩色滤光镜面星门通道 (Eliasson Colour Tunnel)",
    "9: 阿波罗尼奥斯镜球水晶堆 (Apollonian Packing)",
    "0: GRIN弯曲光场 / 角锥逆反射墙 (GRIN / Retro)",
];

pub const COATING_NAMES: [&str; 4] = [
    "二向色虹彩 (Dichroic)",
    "经典绿玻璃镜 (Green Glass)",
    "金蓝光谱镜 (Gold-Cobalt)",
    "高纯银镜 (Pure Silver)",
];

pub struct SceneState {
    pub scene_id: u32,
    pub max_bounces: u32,
    pub coating_mode: u32,
    pub view_mode: u32,
    pub morph_param: f32,
    pub exposure: f32,
    pub paused: bool,
    pub auto_orbit: bool,
    pub sim_time: f32,
    pub frame_index: u32,

    pub cam_pos: Vec3,
    pub yaw: f32,
    pub pitch: f32,
    pub fov_deg: f32,
    pub keys_down: HashSet<KeyCode>,
}

impl SceneState {
    pub fn new() -> Self {
        let mut s = Self {
            scene_id: 0,
            max_bounces: 32,
            coating_mode: 0,
            view_mode: 0,
            morph_param: 0.0,
            exposure: 1.05,
            paused: false,
            auto_orbit: true,
            sim_time: 0.0,
            frame_index: 0,
            cam_pos: Vec3::new(0.0, 0.25, -1.42),
            yaw: 0.0,
            pitch: -0.08,
            fov_deg: 68.0,
            keys_down: HashSet::new(),
        };
        s.apply_scene_preset(0);
        s
    }

    pub fn apply_scene_preset(&mut self, id: u32) {
        self.scene_id = id.min(9);
        self.auto_orbit = true;
        match self.scene_id {
            0 => {
                // 1: Platonic Infinity Portal
                self.view_mode = 0;
                self.morph_param = 0.0;
                self.coating_mode = 1;
                self.max_bounces = 40;
                self.exposure = 1.05;
                self.fov_deg = 70.0;
                self.cam_pos = Vec3::new(0.0, 0.22, -1.42);
                self.look_at(Vec3::ZERO);
            }
            1 => {
                // 2: Wada Basin 4 Mutually Tangent Mirror Spheres
                self.view_mode = 0;
                self.morph_param = 0.04;
                self.coating_mode = 3;
                self.max_bounces = 48;
                self.exposure = 1.02;
                self.fov_deg = 62.0;
                self.cam_pos = Vec3::new(-0.56, -0.56, -0.56);
                self.look_at(Vec3::ZERO);
            }
            2 => {
                // 3: Coxeter & Hyperbolic Curved-Mirror Kaleidoscope
                self.view_mode = 0;
                self.morph_param = 0.45;
                self.coating_mode = 0;
                self.max_bounces = 40;
                self.exposure = 1.02;
                self.fov_deg = 74.0;
                self.cam_pos = Vec3::new(0.0, 0.15, -1.10);
                self.look_at(Vec3::ZERO);
            }
            3 => {
                // 4: Dichroic Infinity Mirror Room
                self.view_mode = 0;
                self.morph_param = 0.35;
                self.coating_mode = 0;
                self.max_bounces = 36;
                self.exposure = 1.00;
                self.fov_deg = 72.0;
                self.cam_pos = Vec3::new(0.0, 0.18, -2.28);
                self.look_at(Vec3::new(0.0, 0.15, 0.0));
            }
            4 => {
                // 5: Jack Storms Cold-Worked Dichroic Optical Crystal Cube
                self.view_mode = 0;
                self.morph_param = 0.45;
                self.coating_mode = 0;
                self.max_bounces = 24;
                self.exposure = 1.02;
                self.fov_deg = 48.0;
                self.cam_pos = Vec3::new(2.65, 1.55, -3.45);
                self.look_at(Vec3::ZERO);
            }
            5 => {
                // 6: Brilliant-Cut Diamond 6-Band Spectral Dispersion
                self.view_mode = 0;
                self.morph_param = 0.55;
                self.coating_mode = 3;
                self.max_bounces = 20;
                self.exposure = 1.05;
                self.fov_deg = 46.0;
                self.cam_pos = Vec3::new(0.0, 1.85, -3.95);
                self.look_at(Vec3::new(0.0, -0.25, 0.0));
            }
            6 => {
                // 7: Chris Wood Dichroic Glass Light Caustics Mandala Wall
                self.view_mode = 0;
                self.morph_param = 0.35;
                self.coating_mode = 0;
                self.max_bounces = 16;
                self.exposure = 1.00;
                self.fov_deg = 54.0;
                self.cam_pos = Vec3::new(0.0, 0.0, -3.15);
                self.look_at(Vec3::new(0.0, 0.0, 1.85));
            }
            7 => {
                // 8: Olafur Eliasson Colour-Filter Mirror Tunnel
                self.view_mode = 0;
                self.morph_param = 0.30;
                self.coating_mode = 3;
                self.max_bounces = 36;
                self.exposure = 1.02;
                self.fov_deg = 74.0;
                self.cam_pos = Vec3::new(0.0, 0.0, -2.0);
                self.look_at(Vec3::new(0.0, 0.0, 8.0));
            }
            8 => {
                // 9: 3D Apollonian / Soddy Mirror + Crystal Sphere Packing
                self.view_mode = 0;
                self.morph_param = 0.25;
                self.coating_mode = 0;
                self.max_bounces = 32;
                self.exposure = 1.02;
                self.fov_deg = 54.0;
                self.cam_pos = Vec3::new(-2.85, 1.45, -3.15);
                self.look_at(Vec3::ZERO);
            }
            _ => {
                // 0: GRIN Curved-Light Optical Crystal (V=0) / Corner-Cube Retroreflector Wall (V=1)
                self.view_mode = 0;
                self.morph_param = 0.45;
                self.coating_mode = 0;
                self.max_bounces = 40;
                self.exposure = 1.05;
                self.fov_deg = 62.0;
                self.cam_pos = Vec3::new(0.0, 0.45, -3.65);
                self.look_at(Vec3::ZERO);
            }
        }
        eprintln!(
            "[SCENE] Switched to {} | Bounces={} | Coating={} | Morph={:.2}",
            SCENE_NAMES[self.scene_id as usize],
            self.max_bounces,
            COATING_NAMES[self.coating_mode as usize],
            self.morph_param
        );
    }

    pub fn toggle_view_mode(&mut self) {
        self.view_mode = 1 - self.view_mode;
        match self.scene_id {
            0 => {
                if self.view_mode == 1 {
                    self.cam_pos = Vec3::new(0.0, 1.35, -5.85);
                    self.fov_deg = 52.0;
                } else {
                    self.cam_pos = Vec3::new(0.0, 0.22, -1.42);
                    self.fov_deg = 70.0;
                }
                self.look_at(Vec3::ZERO);
            }
            1 => {
                if self.view_mode == 1 {
                    self.cam_pos = Vec3::new(-2.35, 1.55, -2.65);
                    self.fov_deg = 50.0;
                } else {
                    self.cam_pos = Vec3::new(-0.56, -0.56, -0.56);
                    self.fov_deg = 62.0;
                }
                self.look_at(Vec3::ZERO);
            }
            4 => {
                if self.view_mode == 1 {
                    self.cam_pos = Vec3::new(0.32, 0.18, -0.52);
                    self.fov_deg = 72.0;
                } else {
                    self.cam_pos = Vec3::new(2.65, 1.55, -3.45);
                    self.fov_deg = 48.0;
                }
                self.look_at(Vec3::ZERO);
            }
            5 => {
                if self.view_mode == 1 {
                    self.cam_pos = Vec3::new(0.0, 0.10, -0.32);
                    self.fov_deg = 76.0;
                } else {
                    self.cam_pos = Vec3::new(0.0, 1.85, -3.95);
                    self.fov_deg = 46.0;
                }
                self.look_at(Vec3::ZERO);
            }
            8 => {
                if self.view_mode == 1 {
                    self.cam_pos = Vec3::new(-0.55, -0.55, -0.55);
                    self.fov_deg = 66.0;
                } else {
                    self.cam_pos = Vec3::new(-2.85, 1.45, -3.15);
                    self.fov_deg = 54.0;
                }
                self.look_at(Vec3::ZERO);
            }
            9 => {
                if self.view_mode == 1 {
                    // Corner-Cube Retroreflector Wall
                    self.cam_pos = Vec3::new(0.0, 0.0, -2.45);
                    self.fov_deg = 60.0;
                    self.look_at(Vec3::new(0.0, 0.0, 2.0));
                } else {
                    // GRIN Curved-Light Optical Crystal
                    self.cam_pos = Vec3::new(0.0, 0.45, -3.65);
                    self.fov_deg = 62.0;
                    self.look_at(Vec3::ZERO);
                }
            }
            _ => {}
        }
        eprintln!(
            "[VIEW] Mode -> {}",
            if self.scene_id == 9 {
                if self.view_mode == 0 { "GRIN Curved-Light Crystal" } else { "Corner-Cube Retroreflector Wall" }
            } else if self.view_mode == 0 {
                "Primary View"
            } else {
                "Alternate View (Portal / Inside)"
            }
        );
    }

    pub fn step_bounces(&mut self, delta: i32) {
        const PRESETS: [u32; 7] = [4, 8, 16, 24, 32, 48, 64];
        let mut idx = PRESETS
            .iter()
            .position(|&v| v >= self.max_bounces)
            .unwrap_or(4) as i32;
        idx = (idx + delta).clamp(0, (PRESETS.len() - 1) as i32);
        self.max_bounces = PRESETS[idx as usize];
        eprintln!("[OPTICS] Max Bounces -> {}", self.max_bounces);
    }

    pub fn cycle_coating(&mut self) {
        self.coating_mode = (self.coating_mode + 1) % 4;
        eprintln!("[OPTICS] Mirror Coating -> {}", COATING_NAMES[self.coating_mode as usize]);
    }

    pub fn look_at(&mut self, target: Vec3) {
        let dir = (target - self.cam_pos).normalize_or_zero();
        if dir.length_squared() > 1e-6 {
            self.yaw = dir.x.atan2(dir.z);
            self.pitch = dir.y.clamp(-0.98, 0.98).asin();
        }
    }

    pub fn mouse_look(&mut self, dx: f32, dy: f32) {
        self.auto_orbit = false;
        self.yaw += dx * 0.0045;
        self.pitch = (self.pitch - dy * 0.0045).clamp(-1.48, 1.48);
    }

    pub fn apply_gamepad(&mut self, gp: &crate::gamepad::GamepadInput, dt: f32) {
        if !gp.connected {
            return;
        }
        if gp.prev_scene {
            let next = (self.scene_id + 9) % 10;
            self.apply_scene_preset(next);
        }
        if gp.next_scene {
            let next = (self.scene_id + 1) % 10;
            self.apply_scene_preset(next);
        }
        if gp.bounce_up {
            self.step_bounces(1);
        }
        if gp.bounce_down {
            self.step_bounces(-1);
        }
        if gp.toggle_orbit {
            self.auto_orbit = !self.auto_orbit;
            eprintln!("[GAMEPAD] Auto-Orbit -> {}", self.auto_orbit);
        }
        if gp.toggle_view {
            self.toggle_view_mode();
        }
        if gp.cycle_coating {
            self.cycle_coating();
        }
        if gp.morph_delta.abs() > 0.01 {
            self.morph_param = (self.morph_param + gp.morph_delta * dt * 0.45).clamp(0.0, 1.0);
        }

        let stick_active = gp.move_x.abs() > 0.001
            || gp.move_y.abs() > 0.001
            || gp.look_x.abs() > 0.001
            || gp.look_y.abs() > 0.001
            || gp.vertical.abs() > 0.001;
        if stick_active {
            self.auto_orbit = false;
            self.yaw += gp.look_x * 1.85 * dt;
            self.pitch = (self.pitch + gp.look_y * 1.45 * dt).clamp(-1.48, 1.48);

            let (sy, cy) = self.yaw.sin_cos();
            let (sp, cp) = self.pitch.sin_cos();
            let forward = Vec3::new(sy * cp, sp, cy * cp).normalize();
            let right = Vec3::Y.cross(forward).normalize_or_zero();
            let speed = if self.scene_id == 1 && self.view_mode == 0 { 0.85 } else { 2.2 };
            let move_vec = forward * gp.move_y + right * gp.move_x + Vec3::Y * gp.vertical;
            self.cam_pos += move_vec * speed * dt;
        }
    }

    pub fn update(&mut self, dt: f32) {
        if !self.paused {
            self.sim_time += dt;
        }
        self.frame_index = self.frame_index.wrapping_add(1);

        if self.keys_down.contains(&KeyCode::KeyQ) || self.keys_down.contains(&KeyCode::BracketLeft) {
            self.morph_param = (self.morph_param - dt * 0.42).clamp(0.0, 1.0);
        }
        if self.keys_down.contains(&KeyCode::KeyE) || self.keys_down.contains(&KeyCode::BracketRight) {
            self.morph_param = (self.morph_param + dt * 0.42).clamp(0.0, 1.0);
        }

        let move_keys = [
            KeyCode::KeyW,
            KeyCode::KeyS,
            KeyCode::KeyA,
            KeyCode::KeyD,
            KeyCode::Space,
            KeyCode::ShiftLeft,
            KeyCode::ShiftRight,
        ];
        if move_keys.iter().any(|k| self.keys_down.contains(k)) {
            self.auto_orbit = false;
        }

        if self.auto_orbit {
            let t = self.sim_time;
            match self.scene_id {
                0 => {
                    if self.view_mode == 0 {
                        let a = t * 0.24;
                        let r = 1.38 + 0.16 * (t * 0.35).sin();
                        self.cam_pos = Vec3::new(a.sin() * r, 0.38 * (t * 0.29).sin(), -a.cos() * r);
                        self.look_at(Vec3::new(0.0, 0.05 * (t * 0.4).cos(), 0.0));
                    } else {
                        let a = t * 0.18;
                        self.cam_pos = Vec3::new(a.sin() * 5.85, 1.25 + 0.45 * (t * 0.22).sin(), -a.cos() * 5.85);
                        self.look_at(Vec3::ZERO);
                    }
                }
                1 => {
                    if self.view_mode == 0 {
                        let base_dir = Vec3::new(-1.0, -1.0, -1.0).normalize();
                        let u = Vec3::new(1.0, -1.0, 0.0).normalize();
                        let v = base_dir.cross(u).normalize();
                        let sway = u * (0.14 * (t * 0.33).sin()) + v * (0.14 * (t * 0.27).cos());
                        let dist = 0.92 + 0.16 * (t * 0.21).sin();
                        self.cam_pos = (base_dir + sway).normalize() * dist;
                        self.look_at(Vec3::ZERO);
                    } else {
                        let a = t * 0.22;
                        self.cam_pos = Vec3::new(a.sin() * 3.85, 1.35 * (t * 0.17).sin(), -a.cos() * 3.85);
                        self.look_at(Vec3::ZERO);
                    }
                }
                2 => {
                    let a = t * 0.22;
                    let r = 0.78 + 0.14 * (t * 0.31).sin();
                    self.cam_pos = Vec3::new(a.sin() * r, 0.48 * (t * 0.25).sin(), -a.cos() * r);
                    self.look_at(Vec3::new(0.18 * (t * 0.3).cos(), -0.10 * (t * 0.23).sin(), 0.18 * (t * 0.3).sin()));
                }
                3 => {
                    let a = t * 0.19;
                    let r = 2.18 + 0.22 * (t * 0.28).sin();
                    self.cam_pos = Vec3::new(a.sin() * r, 0.18 + 0.42 * (t * 0.23).sin(), -a.cos() * r);
                    self.look_at(Vec3::new(0.0, 0.15, 0.0));
                }
                4 => {
                    if self.view_mode == 0 {
                        let a = t * 0.22;
                        self.cam_pos = Vec3::new(a.sin() * 4.35, 1.15 + 0.55 * (t * 0.25).sin(), -a.cos() * 4.35);
                        self.look_at(Vec3::ZERO);
                    } else {
                        let a = t * 0.28;
                        self.cam_pos = Vec3::new(a.sin() * 0.62, 0.22 * (t * 0.35).sin(), -a.cos() * 0.62);
                        self.look_at(Vec3::ZERO);
                    }
                }
                5 => {
                    if self.view_mode == 0 {
                        let a = t * 0.24;
                        self.cam_pos = Vec3::new(a.sin() * 4.15, 1.45 + 0.65 * (t * 0.20).sin(), -a.cos() * 4.15);
                        self.look_at(Vec3::new(0.0, -0.25, 0.0));
                    } else {
                        let a = t * 0.30;
                        self.cam_pos = Vec3::new(a.sin() * 0.38, 0.05 + 0.18 * (t * 0.27).sin(), -a.cos() * 0.38);
                        self.look_at(Vec3::new(0.0, 0.10, 0.0));
                    }
                }
                6 => {
                    // Gentle gallery pan across the Chris Wood Dichroic Caustics Mandala Wall
                    self.cam_pos = Vec3::new(0.95 * (t * 0.24).sin(), 0.48 * (t * 0.19).cos(), -3.05 + 0.35 * (t * 0.15).sin());
                    self.look_at(Vec3::new(0.0, 0.0, 1.85));
                }
                7 => {
                    // Smooth forward flight down Olafur Eliasson's infinite coloured mirror tunnel!
                    let z = t * 1.15;
                    self.cam_pos = Vec3::new(0.32 * (t * 0.35).sin(), 0.28 * (t * 0.27).cos(), z);
                    self.look_at(Vec3::new(0.15 * (t * 0.22).cos(), 0.12 * (t * 0.31).sin(), z + 4.5));
                }
                8 => {
                    if self.view_mode == 0 {
                        let a = t * 0.21;
                        self.cam_pos = Vec3::new(a.sin() * 4.25, 1.25 * (t * 0.18).sin(), -a.cos() * 4.25);
                        self.look_at(Vec3::ZERO);
                    } else {
                        let a = t * 0.26;
                        self.cam_pos = Vec3::new(-0.55 + 0.12 * a.sin(), -0.55 + 0.12 * a.cos(), -0.55);
                        self.look_at(Vec3::ZERO);
                    }
                }
                _ => {
                    if self.view_mode == 0 {
                        let a = t * 0.22;
                        self.cam_pos = Vec3::new(a.sin() * 3.65, 0.65 * (t * 0.25).sin(), -a.cos() * 3.65);
                        self.look_at(Vec3::ZERO);
                    } else {
                        self.cam_pos = Vec3::new(0.85 * (t * 0.28).sin(), 0.45 * (t * 0.21).cos(), -2.35);
                        self.look_at(Vec3::new(0.0, 0.0, 2.0));
                    }
                }
            }
            return;
        }

        // Manual 6-DOF flight
        let (sy, cy) = self.yaw.sin_cos();
        let (sp, cp) = self.pitch.sin_cos();
        let forward = Vec3::new(sy * cp, sp, cy * cp).normalize();
        let right = Vec3::Y.cross(forward).normalize_or_zero();
        let speed = if self.scene_id == 1 && self.view_mode == 0 { 0.85 } else { 2.2 };

        let mut vel = Vec3::ZERO;
        if self.keys_down.contains(&KeyCode::KeyW) { vel += forward; }
        if self.keys_down.contains(&KeyCode::KeyS) { vel -= forward; }
        if self.keys_down.contains(&KeyCode::KeyD) { vel += right; }
        if self.keys_down.contains(&KeyCode::KeyA) { vel -= right; }
        if self.keys_down.contains(&KeyCode::Space) { vel += Vec3::Y; }
        if self.keys_down.contains(&KeyCode::ShiftLeft) || self.keys_down.contains(&KeyCode::ShiftRight) {
            vel -= Vec3::Y;
        }
        if vel.length_squared() > 1e-6 {
            self.cam_pos += vel.normalize() * speed * dt;
        }

        if self.view_mode == 0 {
            match self.scene_id {
                0 if self.cam_pos.length() > 1.88 => self.cam_pos = self.cam_pos.normalize() * 1.88,
                2 => {
                    let xz = glam::Vec2::new(self.cam_pos.x, self.cam_pos.z);
                    if xz.length() > 1.38 {
                        let c = xz.normalize() * 1.38;
                        self.cam_pos.x = c.x;
                        self.cam_pos.z = c.y;
                    }
                    self.cam_pos.y = self.cam_pos.y.clamp(-2.15, 2.15);
                }
                3 => {
                    let xz = glam::Vec2::new(self.cam_pos.x, self.cam_pos.z);
                    if xz.length() > 2.95 {
                        let c = xz.normalize() * 2.95;
                        self.cam_pos.x = c.x;
                        self.cam_pos.z = c.y;
                    }
                    self.cam_pos.y = self.cam_pos.y.clamp(-1.70, 2.00);
                }
                7 => {
                    let xy = glam::Vec2::new(self.cam_pos.x, self.cam_pos.y);
                    if xy.length() > 1.55 {
                        let c = xy.normalize() * 1.55;
                        self.cam_pos.x = c.x;
                        self.cam_pos.y = c.y;
                    }
                }
                _ => {}
            }
        }
    }

    pub fn build_params(&self, width: u32, height: u32, spp: u32) -> MirrorParams {
        let (sy, cy) = self.yaw.sin_cos();
        let (sp, cp) = self.pitch.sin_cos();
        let forward = Vec3::new(sy * cp, sp, cy * cp).normalize();
        let right = Vec3::Y.cross(forward).normalize_or_zero();
        let right = if right.length_squared() < 1e-6 { Vec3::X } else { right };
        let up = forward.cross(right).normalize();

        MirrorParams {
            width,
            height,
            scene_id: self.scene_id,
            max_bounces: self.max_bounces,
            coating_mode: self.coating_mode,
            spp,
            view_mode: self.view_mode,
            frame_index: self.frame_index,
            time: self.sim_time,
            fov: self.fov_deg.to_radians(),
            morph_param: self.morph_param,
            exposure: self.exposure,
            cam_pos: [self.cam_pos.x, self.cam_pos.y, self.cam_pos.z, 0.0],
            cam_forward: [forward.x, forward.y, forward.z, 0.0],
            cam_right: [right.x, right.y, right.z, 0.0],
            cam_up: [up.x, up.y, up.z, 0.0],
        }
    }

    pub fn status_title(&self, fps: f64, gpu_ms: f64, hdr_h: u32, spp: u32) -> String {
        let morph_label = match self.scene_id {
            0 => format!("多面体形态={:.0}%", self.morph_param * 100.0),
            1 => format!("球隙={:.0}%", self.morph_param * 100.0),
            2 => format!("双曲曲率={:.0}%", self.morph_param * 100.0),
            3 => format!("镀膜厚度={:.0}%", self.morph_param * 100.0),
            4 => format!("切片倾角={:.0}%", self.morph_param * 100.0),
            5 => format!("色散火彩={:.0}%", self.morph_param * 100.0),
            6 => format!("玻璃片转角={:.0}%", self.morph_param * 100.0),
            7 => format!("通道扭转={:.0}%", self.morph_param * 100.0),
            8 => format!("球堆呼吸={:.0}%", self.morph_param * 100.0),
            _ => if self.view_mode == 0 {
                format!("GRIN引力梯度={:.0}%", self.morph_param * 100.0)
            } else {
                format!("角锥密度={:.0}%", self.morph_param * 100.0)
            },
        };
        format!(
            "{} | {}次反射 | {} | {} | {}p {}xSPP | {:.0} FPS ({:.1}ms GPU)",
            SCENE_NAMES[self.scene_id as usize],
            self.max_bounces,
            COATING_NAMES[self.coating_mode as usize],
            morph_label,
            hdr_h,
            spp,
            fps,
            gpu_ms
        )
    }
}
