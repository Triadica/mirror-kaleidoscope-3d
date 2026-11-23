# Mirror Kaleidoscope 3D — 10 合 1 多镜面与折射色散深度光追实验室

基于 **Rust + Apple Metal** 的原生深度光学光追实验室，针对 Apple Silicon（Mac Studio M5 Max）优化：10 个独立场景 Compute Kernel、最高 **64 次解析弹跳**、**6 波段柯西光谱色散**、**全内反射（TIR）**、**二向色玻璃解析焦散**、**RK2 梯度折射率弯曲光线（GRIN）**、**1x / 4x / 9x 旋转网格超采样（RGSS）**、HDR Bloom、对比度自适应锐化（CAS）与 ACES 电影级色调映射。

## 项目结构

```text
mirror-kaleidoscope-3d/
├── Cargo.toml                            # Rust 项目配置与二进制入口
├── README.md                             # 项目说明与运行指南
├── shaders/
│   └── mirror_kaleidoscope.metal         # 10 个独立场景 Metal 光追核 + Bloom + CAS + ACES
├── src/
│   ├── main.rs                           # 窗口模式交互主程序（支持键鼠 + 原生手柄）
│   ├── renderer.rs                       # Metal 计算管线与 HDR 离屏渲染
│   ├── scene.rs                          # 10 场景预设、6-DOF 飞行与自动环绕相机
│   ├── gamepad.rs                        # 原生 macOS GameController 手柄绑定（零外部依赖）
│   ├── types.rs                          # CPU/GPU 对齐的 MirrorParams Uniform 结构
│   └── bin/
│       └── render_snapshots.rs           # Rust 多核 4K/5K/6K 静帧截图与 GPU 基准测试
└── scripts/
    ├── bench_and_snapshot.swift          # Swift 原生 4K/5K/6K 基准测试与多核 PNG 导出
    ├── render_camera_anim.swift          # 单段关键帧相机轨迹 4K PNG 序列渲染器
    ├── render_showcase_video.swift       # 12 段 × 20s 4K 9xRGSS 直推 ffmpeg 无损拼接管线
    └── cameras/
        ├── demo_diamond_orbit.json       # 单段钻石环绕示例轨迹（6s）
        └── showcase_12demos_20s.json     # 全部 12 视角 × 20s（4 分钟）4K 成片轨迹剧本
```

> 运行产物（4K 静帧、基准日志 `bench_log.jsonl`、编译后的 Swift 工具与 4K 成片）统一输出到 `output/` 目录（已加入 `.gitignore`）。

## 10 大光学场景（按键 `1`–`9`, `0`）

1. **`1` — Platonic Infinity Portal（多面体无限镜雕塑）**：32 平面解析变形（`Q`/`E`：正十二面体 → 截半二十面体 → 正二十面体）；`V` 切换内部镜室 / 外部双面镜雕塑（灵感来源：[Anthony James](https://www.collater.al/en/portal-series-anthony-james-sculpture/)）。
2. **`2` — Wada Basin 4-Sphere Fractal（四镜面球和田盆分形）**：4 个两两相切镜面球与四面体彩色穹顶（[Paul Bourke](https://paulbourke.net/fractals/wada/)）。
3. **`3` — Coxeter & Hyperbolic Kaleidoscope（考克斯特/双曲万花筒）**：平面 $\pi/3$ [Coxeter](https://en.wikipedia.org/wiki/Coxeter_group) 等边镜室平滑过渡（`Q`/`E`）至内凹圆柱[双曲万花筒](https://geometricolor.wordpress.com/2017/11/22/further-hyperbolic-kaleidoscopes/)。
4. **`4` — Dichroic Infinity Mirror Room（二向色无限镜屋）**：八边形[二向色](https://www.findlight.net/blog/dichroic-mirrors-explained-a-comprehensive-guide/)镜厅 + 12 盏悬浮星灯 + 水镜涟漪地面（[Yayoi Kusama](https://www.tate.org.uk/whats-on/tate-modern/yayoi-kusama-infinity-mirror-rooms)）。
5. **`5` — Cold-Worked Dichroic Optical Crystal Cube（冷加工二向色水晶魔方）**：高折射率（`1.72`）铅水晶 RGB 色散 + TIR + 内部 8 层交叉二向色薄片（[Jack Storms](https://www.marcusashley.com/blogs/all/the-jack-storms-process-how-he-makes-exquisite-optical-glass-art)）。
6. **`6` — Brilliant-Cut Diamond 6-Band Spectral Dispersion（切面钻石 6 波段色散火彩）**：26 刻面 Tolkowsky 切工 + 6 波长柯西光谱追踪 + 地面 8+16 瓣彩虹焦散（[TU Wien ART](https://www.cg.tuwien.ac.at/research/rendering/ART/Gallery/Dispersion/)）。
7. **`7` — Dichroic Glass Light Caustics Mandala Wall（二向色玻璃焦散光阵）**：16 片倾斜二向色玻璃翼片实时投射解析透射 + 反射互补色光带（[Chris Wood](https://www.thisiscolossal.com/2022/06/chris-wood-dichroic-glass-installation/)）。
8. **`8` — Colour-Filter Mirror Tunnel（彩色滤光镜面星门通道）**：无限六边形镜面长廊 + 非对称半透彩色玻璃光圈与螺旋扭转（`Q`/`E`）（[Olafur Eliasson](https://www.luxuo.com/culture/art/kaleidoscopic-glass-installations-by-olafur-eliasson.html)）。
9. **`9` — 3D Apollonian Mirror & Crystal Sphere Packing（阿波罗尼奥斯镜球水晶堆）**：19 颗 Soddy 堆砌球体交替呈现铬镜与折射水晶透镜（[Apollonian Packing](https://paulbourke.net/fractals/apollony/)）。
10. **`0` — GRIN Curved-Light Crystal（`V=0`）& Corner-Cube Retroreflector Wall（`V=1`）**：RK2 连续[梯度折射率](https://en.wikipedia.org/wiki/Gradient-index_optics)爱因斯坦环弯曲光场 + 三面正交 $90^\circ$ [角锥逆反射](https://en.wikipedia.org/wiki/Retroreflector)宝石墙。

## 快速运行

### 1. 窗口模式交互（键鼠 + 原生手柄）

```bash
cd /Users/chenyong/ai-lectures/mirror-kaleidoscope-3d

# 默认窗口模式启动（1600x960 逻辑尺寸、4x RGSS）
cargo run --release

# 指定初始场景与采样精度
cargo run --release -- --scene 6 --spp 4 --width 1600 --height 960
```

- **键盘鼠标**：`1`–`9`/`0` 切场景 · `B`/`N` 调反射次数（4..64）· `C` 切镀膜 · `V` 切内外视角 · `Q`/`E` 实时调形态/色散/曲率 · `G` 切 1x/4x/9x RGSS · `O` 自动环绕 · `WASD`+`Space`/`Shift`+左键拖拽自由飞行 · `P` 暂停 · `R` 重置 · `Esc` 退出。
- **原生手柄（PS5 DualSense / Xbox / Switch Pro / 8BitDo）**：左摇杆移动 · 右摇杆视角 · `L2`/`R2` 垂直升降 · `L1`/`R1` 调形态参数 · 十字键左右切场景、上下调弹跳次数 · `A`/`B`/`X`/`Y` 切换环绕/视角/镀膜/超采样。

### 2. 4K / 5K / 6K 静帧截图与 Metal GPU 跑分

```bash
swiftc -O scripts/bench_and_snapshot.swift -o output/bench_snapshot
./output/bench_snapshot              # 默认 4K (3840x2160) 4x RGSS
./output/bench_snapshot --spp 9      # 4K 9x RGSS 极高锐度
./output/bench_snapshot --5k         # 5K (5120x2880)
```

### 3. 12 段 × 20 秒 4K 9x RGSS 成片自动渲染与无损拼接

```bash
swiftc -O scripts/render_showcase_video.swift -o output/render_showcase
./output/render_showcase                         # 4K 30fps 9x RGSS（Apple HW HEVC 55Mbps）
./output/render_showcase --only 01a,06           # 仅渲染指定片段
./output/render_showcase --skip-existing         # 断点续渲并重新无损拼接
./output/render_showcase --codec x265 --fps 60   # 10-bit x265 CRF 15 / 60fps
```
