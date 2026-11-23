/// Byte-for-byte synced with `MirrorParams` in `shaders/mirror_kaleidoscope.metal`.
#[repr(C, align(16))]
#[derive(Copy, Clone, Debug)]
pub struct MirrorParams {
    pub width: u32,
    pub height: u32,
    pub scene_id: u32,     // 0=Platonic Portal, 1=Wada Spheres, 2=Coxeter/Hyperbolic, 3=Dichroic Room
    pub max_bounces: u32,  // 8..64 deep specular bounces
    pub coating_mode: u32, // 0=Dichroic Rainbow, 1=Architectural Green Mirror, 2=Gold-Cobalt, 3=Pure Silver
    pub spp: u32,          // 1, 4 (2x2), or 9 (3x3) supersampling
    pub view_mode: u32,    // 0=Inside Chamber, 1=Outside Two-Way Portal
    pub frame_index: u32,
    pub time: f32,
    pub fov: f32,
    pub morph_param: f32,  // 0.0..1.0 scene-specific geometry/optical slider
    pub exposure: f32,
    pub cam_pos: [f32; 4],     // xyz = pos, w = roll
    pub cam_forward: [f32; 4], // xyz = forward
    pub cam_right: [f32; 4],   // xyz = right
    pub cam_up: [f32; 4],      // xyz = up
}
