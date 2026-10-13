# Avalon R1

A high-performance **software 3D renderer for Roblox**, written in Luau. It
renders real, textured, depth-tested 3D scenes **entirely inside a GUI** — no
parts, no meshes in the workspace, no engine lighting. Just an `EditableImage`
that the rasterizer writes pixel by pixel, at speed.

It is built to be the rendering layer under things like retro emulators
(PS1/N64-class software rasterization), tool previews, mini-games, custom
engines and anything else that needs a real 3D pipeline inside Roblox.

```lua
local Avalon = require(game.ReplicatedStorage.Avalon)

local renderer = Avalon.new(parentFrame, { width = 480, height = 360 })
renderer:setCamera(Avalon.Camera.new({ position = Vector3.new(0, 2, 8) }))

local cube = Avalon.Mesh.cube(Vector3.new(2, 2, 2))
local tex = Avalon.Texture.checker(64, 64, 8, Vector3.new(1, 1, 1), Vector3.new(0.2, 0.2, 0.2))

game:GetService("RunService").RenderStepped:Connect(function()
    renderer:beginFrame()
    renderer:drawMesh(cube, { shading = "textured", texture = tex })
    renderer:present()
end)
```

## Why it is fast

| Technique | What it buys |
|---|---|
| **Edge-function rasterization** | Per-pixel cost is a few adds and one compare — no per-pixel divides on the coverage test |
| **`--!native` on the hot paths** | The rasterizer is compiled to machine code, not interpreted bytecode |
| **32-bit buffer writes** | One `buffer.writeu32` per pixel; colour and depth are packed words |
| **1/w depth + perspective-correct UV** | Correct texturing with a single reciprocal per pixel |
| **Structure-of-arrays meshes** | The transform loop walks flat arrays, no table indirection |
| **Zero allocation per frame** | Scratch buffers are reused; nothing is created inside the draw loop |
| **One upload per frame** | `EditableImage:WritePixelsBuffer` — a single GPU-side copy |
| **Adaptive resolution** | Drops internal resolution when the frame budget is missed, raises it when there is headroom |

## Features

- **Full transform pipeline** — model → world → view → clip → screen, with a
  proper perspective projection.
- **Near-plane clipping** — Sutherland–Hodgman against the near plane, so
  geometry that crosses the camera is cut cleanly instead of smearing.
- **Back-face culling** with a consistent counter-clockwise winding convention.
- **Depth buffer** — meshes interpenetrate correctly, in any draw order.
- **Perspective-correct texture mapping** — nearest sampling with repeat/clamp
  wrap.
- **Three shading modes** — `flat`, `gouraud` (smooth), and `textured`
  (texture × interpolated vertex colour).
- **Per-vertex lighting** — directional light + ambient, applied per vertex.
- **Procedural meshes** — `cube`, `plane`, `sphere`, `torus`, or bring your own
  indexed geometry.
- **Textures from anywhere** — procedural, from an existing `EditableImage`, or
  loaded from any image asset with `Texture.load(assetId)`.
- **Adaptive resolution scaling** so it stays smooth on phones and tablets.

## Install

### Rojo (recommended)

```bash
rojo build default.project.json -o AvalonR1.rbxlx
```

Open the place in Studio and press **Play** — the bundled demo
(`src/Demo`) renders a spinning, textured, lit scene.

For live editing:

```bash
rojo serve default.project.json
```

### Manual

Copy `src/Avalon` into `ReplicatedStorage` as a `ModuleScript` named `Avalon`
(with the other files as its children). Copy `src/Demo` into
`StarterPlayerScripts` if you want the demo.

## Requirements

- `EditableImage` must be available (`AssetService:CreateEditableImage`). This
  is a modern-engine feature; the renderer needs it.
- Roblox client (this is a client-side renderer).
- Nothing else — no packages, no HTTP, no server.

## API

### `Avalon.new(parent, options?) -> Renderer`

| Option | Default | Meaning |
|---|---|---|
| `width`, `height` | `480`, `360` | Internal render resolution (before scaling) |
| `resolutionScale` | `1` | Starting scale applied to the internal resolution |
| `minScale`, `maxScale` | `0.35`, `1` | Adaptive-resolution bounds |
| `adaptive` | `true` | Enable automatic resolution scaling |
| `targetFps` | `60` | Frame-rate target the adaptive scaler aims for |
| `background` | `Color3.fromRGB(8,8,12)` | Clear colour |
| `light` | `(-0.4, -1, -0.6)` | Directional light **direction** (normalised) |
| `ambient` | `0.22` | Ambient term, `0..1` |
| `camera` | a default `Camera` | Initial camera |

### Renderer methods

| Method | Purpose |
|---|---|
| `beginFrame()` | Clears colour + depth, resets per-frame stats |
| `drawMesh(mesh, opts?)` | Transforms, clips, culls and rasterizes an indexed mesh |
| `present()` | Uploads the colour buffer to the `EditableImage` and runs the adaptive scaler |
| `setCamera(camera)` | Swap the active camera |
| `setLight(dir)` | Change the light direction |
| `setBackground(color)` | Change the clear colour |
| `setResolutionScale(scale)` | Force an internal-resolution scale |
| `destroy()` | Tear down the GUI + image |

`renderer.stats` exposes `triangles` (submitted), `drawn` (survived culling),
`clipped` and `ms` (last frame time).

### `drawMesh` options

| Option | Default | Meaning |
|---|---|---|
| `transform` | identity | Model matrix (`Mat4`) |
| `shading` | `"flat"` | `"flat"` \| `"gouraud"` \| `"textured"` |
| `texture` | `nil` | `Texture`, required for `"textured"` |
| `color` | white | `Color3` tint multiplied into the shading |
| `cull` | `true` | Back-face culling |

### Modules

| Module | Role |
|---|---|
| `Avalon.Mat4` | Row-major 4×4 matrices: `identity`, `mul`, `perspective`, `lookAt`, `translation`, `scale`, `rotationX/Y/Z`, `fromCFrame`, `transformPoint` |
| `Avalon.Camera` | Position, look-at target, FOV, near/far; builds the view-projection |
| `Avalon.Mesh` | Indexed geometry (structure-of-arrays) + `cube`/`plane`/`sphere`/`torus` |
| `Avalon.Texture` | u32-backed images: `new`, `checker`, `fromEditableImage`, `load`, `sample` |
| `Avalon.Framebuffer` | Colour (RGBA8) + depth (f32 `1/w`) planes |
| `Avalon.Rasterizer` | The hot core: `flat`, `gouraud`, `textured` triangle fills |
| `Avalon.Renderer` | The pipeline and frame loop |

### Building your own mesh

```lua
local mesh = Avalon.Mesh.fromVertices({
    { p = Vector3.new(-1, 0, 0), n = Vector3.new(0, 1, 0), uv = Vector2.new(0, 0) },
    { p = Vector3.new( 1, 0, 0), n = Vector3.new(0, 1, 0), uv = Vector2.new(1, 0) },
    { p = Vector3.new( 0, 1, 0), n = Vector3.new(0, 1, 0), uv = Vector2.new(0.5, 1) },
}, { 1, 2, 3 })
```

Wind triangles **counter-clockwise as seen from outside** — that is the
front-face convention the culler uses.

## Performance notes

- **Pick a resolution that matches the look you want.** A 320×240 or 480×360
  internal buffer upscaled with `Pixelated` resampling looks deliberately
  retro *and* is far cheaper than a 1024×1024 buffer. Retro hardware did the
  same thing.
- **Prefer `flat`** when you do not need smooth shading or texture detail — it
  is the cheapest path.
- **Keep meshes reasonably sized.** The pipeline is per-triangle; a few thousand
  triangles per frame is comfortable, tens of thousands is not.
- **Let adaptive resolution do its job.** It reacts a couple of times a second,
  so it will not thrash.
- **Reuse meshes and textures.** They are immutable data; build once.

`--!native` is applied to `Mat4` and `Rasterizer`, which are where the time
goes. If you fork this and add a hot loop, annotate it the same way.

## How it works

```
Mesh ──▶ MVP transform ──▶ near-plane clip ──▶ perspective divide
                                                        │
                                              back-face cull
                                                        │
                                            edge-function rasterizer
                                                        │
                                      depth test + colour/depth write
                                                        │
                                    EditableImage:WritePixelsBuffer
```

Full walkthrough: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Credits

Avalon R1 was written from scratch, but it stands on the shoulders of the
Roblox developers who proved a software renderer is viable in Luau. Their
published work and write-ups shaped the techniques used here — see
[CREDITS.md](CREDITS.md) for the full list and what each contributed.

## License

MIT — see [LICENSE](LICENSE). No third-party code is bundled; no ROM, BIOS or
copyrighted asset is included anywhere in this repository.
