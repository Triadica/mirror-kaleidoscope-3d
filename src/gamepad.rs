//! Native macOS GameController.framework gamepad reader (zero external crates).
//! Supports PS5 DualSense, Xbox Series/One, Nintendo Switch Pro, 8BitDo, and MFi controllers.

use objc2::msg_send;
use objc2::runtime::{AnyClass, AnyObject, Bool};

#[link(name = "GameController", kind = "framework")]
extern "C" {}

#[derive(Default, Debug, Clone, Copy)]
pub struct GamepadInput {
    pub connected: bool,
    /// Left stick X (-1..1, strafe right) & Y (-1..1, move forward)
    pub move_x: f32,
    pub move_y: f32,
    /// Right stick X (-1..1, yaw right) & Y (-1..1, pitch up)
    pub look_x: f32,
    pub look_y: f32,
    /// R2 - L2 (-1..1, vertical ascend/descend)
    pub vertical: f32,
    /// R1 - L1 (-1..1, morph / dispersion / curvature slider)
    pub morph_delta: f32,
    /// Edge-triggered discrete actions
    pub next_scene: bool,
    pub prev_scene: bool,
    pub bounce_up: bool,
    pub bounce_down: bool,
    pub toggle_orbit: bool,
    pub toggle_view: bool,
    pub cycle_coating: bool,
    pub cycle_spp: bool,
}

pub struct GamepadManager {
    was_connected: bool,
    prev_dpad_l: bool,
    prev_dpad_r: bool,
    prev_dpad_u: bool,
    prev_dpad_d: bool,
    prev_a: bool,
    prev_b: bool,
    prev_x: bool,
    prev_y: bool,
}

impl GamepadManager {
    pub fn new() -> Self {
        Self {
            was_connected: false,
            prev_dpad_l: false,
            prev_dpad_r: false,
            prev_dpad_u: false,
            prev_dpad_d: false,
            prev_a: false,
            prev_b: false,
            prev_x: false,
            prev_y: false,
        }
    }

    pub fn poll(&mut self) -> GamepadInput {
        let mut out = GamepadInput::default();
        unsafe {
            let Some(cls) = AnyClass::get(c"GCController") else {
                return out;
            };
            let controllers: *mut AnyObject = msg_send![cls, controllers];
            if controllers.is_null() {
                return out;
            }
            let count: usize = msg_send![controllers, count];
            if count == 0 {
                if self.was_connected {
                    eprintln!("[GAMEPAD] Controller disconnected");
                    self.was_connected = false;
                }
                return out;
            }

            let ctrl: *mut AnyObject = msg_send![controllers, objectAtIndex: 0usize];
            if ctrl.is_null() {
                return out;
            }
            let gp: *mut AnyObject = msg_send![ctrl, extendedGamepad];
            if gp.is_null() {
                return out;
            }

            if !self.was_connected {
                eprintln!("[GAMEPAD] Connected macOS GameController (LeftStick=Move, RightStick=Look, L2/R2=Up/Down, L1/R1=Morph, DPad=Scene/Bounce, A/B/X/Y=Orbit/View/Coating/SPP)");
                self.was_connected = true;
            }
            out.connected = true;

            let lstick: *mut AnyObject = msg_send![gp, leftThumbstick];
            let rstick: *mut AnyObject = msg_send![gp, rightThumbstick];
            let (lx, ly) = read_stick(lstick);
            let (rx, ry) = read_stick(rstick);
            out.move_x = lx;
            out.move_y = ly;
            out.look_x = rx;
            out.look_y = ry;

            let ltrig: *mut AnyObject = msg_send![gp, leftTrigger];
            let rtrig: *mut AnyObject = msg_send![gp, rightTrigger];
            let lt = read_button_val(ltrig);
            let rt = read_button_val(rtrig);
            out.vertical = deadzone_1d(rt - lt, 0.08);

            let lb: *mut AnyObject = msg_send![gp, leftShoulder];
            let rb: *mut AnyObject = msg_send![gp, rightShoulder];
            let l_pressed = read_button_pressed(lb);
            let r_pressed = read_button_pressed(rb);
            out.morph_delta = (if r_pressed { 1.0 } else { 0.0 }) - (if l_pressed { 1.0 } else { 0.0 });

            let dpad: *mut AnyObject = msg_send![gp, dpad];
            let (dl, dr, du, dd) = if !dpad.is_null() {
                let b_l: *mut AnyObject = msg_send![dpad, left];
                let b_r: *mut AnyObject = msg_send![dpad, right];
                let b_u: *mut AnyObject = msg_send![dpad, up];
                let b_d: *mut AnyObject = msg_send![dpad, down];
                (
                    read_button_pressed(b_l),
                    read_button_pressed(b_r),
                    read_button_pressed(b_u),
                    read_button_pressed(b_d),
                )
            } else {
                (false, false, false, false)
            };

            let ba = read_button_pressed(msg_send![gp, buttonA]);
            let bb = read_button_pressed(msg_send![gp, buttonB]);
            let bx = read_button_pressed(msg_send![gp, buttonX]);
            let by = read_button_pressed(msg_send![gp, buttonY]);

            out.prev_scene = dl && !self.prev_dpad_l;
            out.next_scene = dr && !self.prev_dpad_r;
            out.bounce_up = du && !self.prev_dpad_u;
            out.bounce_down = dd && !self.prev_dpad_d;
            out.toggle_orbit = ba && !self.prev_a;
            out.toggle_view = bb && !self.prev_b;
            out.cycle_coating = bx && !self.prev_x;
            out.cycle_spp = by && !self.prev_y;

            self.prev_dpad_l = dl;
            self.prev_dpad_r = dr;
            self.prev_dpad_u = du;
            self.prev_dpad_d = dd;
            self.prev_a = ba;
            self.prev_b = bb;
            self.prev_x = bx;
            self.prev_y = by;
        }
        out
    }
}

unsafe fn read_stick(pad: *mut AnyObject) -> (f32, f32) {
    if pad.is_null() {
        return (0.0, 0.0);
    }
    let x_axis: *mut AnyObject = msg_send![pad, xAxis];
    let y_axis: *mut AnyObject = msg_send![pad, yAxis];
    let raw_x: f32 = if !x_axis.is_null() { msg_send![x_axis, value] } else { 0.0 };
    let raw_y: f32 = if !y_axis.is_null() { msg_send![y_axis, value] } else { 0.0 };
    let mag = (raw_x * raw_x + raw_y * raw_y).sqrt();
    let dead = 0.14;
    if mag <= dead {
        return (0.0, 0.0);
    }
    let scaled = ((mag - dead) / (1.0 - dead)).min(1.0);
    // Cubic-blended response curve for precise small camera adjustments + fast turns
    let curve = scaled * (0.45 + 0.55 * scaled * scaled);
    (raw_x / mag * curve, raw_y / mag * curve)
}

unsafe fn read_button_val(btn: *mut AnyObject) -> f32 {
    if btn.is_null() {
        return 0.0;
    }
    msg_send![btn, value]
}

unsafe fn read_button_pressed(btn: *mut AnyObject) -> bool {
    if btn.is_null() {
        return false;
    }
    let p: Bool = msg_send![btn, isPressed];
    p.as_bool()
}

fn deadzone_1d(v: f32, dead: f32) -> f32 {
    if v.abs() <= dead {
        0.0
    } else {
        v.signum() * ((v.abs() - dead) / (1.0 - dead)).min(1.0)
    }
}
