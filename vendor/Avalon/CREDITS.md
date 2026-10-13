# Credits

Avalon R1 contains **no third-party code**. Every line in `src/` was written for
this project. What it does borrow is *knowledge*: the techniques, benchmarks and
hard-won lessons that other Roblox developers published while proving a software
renderer is viable inside Luau. This file records what each of them contributed,
so the debt is explicit.

## Projects and write-ups that shaped this renderer

### `break-core/DrawTriangle` — the public, fast EditableImage triangle rasterizer

**Contribution: the rasterization strategy.**

The author benchmarked scanline rasterization against Roblox's internal
`DrawTriangle` and demonstrated two things that are central to Avalon R1:

1. **Scanline / edge-function fill beats per-pixel barycentric evaluation**,
   because it turns thousands of draw calls into a few hundred and keeps the
   inner loop to additions and a compare.
2. **`--!native` is not optional.** Their own benchmark showed the same code ran
   *slower* than Roblox's implementation until native codegen was enabled, after
   which it ran roughly twice as fast.

Avalon R1 uses the same edge-function formulation (with the `1/w` depth and
perspective-correct interpolation added on top) and applies `--!native` to
`Rasterizer` and `Mat4`.

* DevForum: "Fast EditableImage Triangle Rasterizer"
* Repository: https://github.com/break-core/DrawTriangle

### `nrmu9/Ro2DEngine` — high-performance software rendering for EditableImage

**Contribution: buffer discipline.**

Ro2D's README documents the memory-side techniques that keep a pixel engine
affordable: **pooled upload buffers** so a frame allocates nothing, and reading
and writing pixels **32 bits at a time** rather than byte by byte, "one RGBA
value per buffer op".

Avalon R1 adopts both: the colour plane is written with a single
`buffer.writeu32` per pixel, and the per-frame scratch arrays in `Renderer` are
allocated once in the constructor and reused for every triangle.

* Repository: https://github.com/nrmu9/Ro2DEngine

### `yoits9090/plumber` — a Nintendo 64 emulator running inside Roblox

**Contribution: proof of the end goal, and the framebuffer contract.**

Plumber is the closest existing thing to what Avalon R1 is meant to enable: a
real console rasterized in software inside Roblox and presented through an
`EditableImage`, with **texture mapping and a depth buffer** in the rasterizer
and a reduced-resolution fast path (160×120 alongside 320×240).

That architecture — render to a software framebuffer, then upload it with
`WritePixelsBuffer()` — is exactly Avalon R1's model, and its fast-path idea is
echoed in Avalon R1's adaptive resolution scaling.

* Repository: https://github.com/yoits9090/plumber

### OSGL — Open-Source Graphical Library

**Contribution: the ecosystem baseline.**

OSGL established the practical baseline for what an EditableImage library has to
do — a window abstraction over the image, safe buffer access, and error handling
for the buffer-bound errors that bite every pixel renderer. It also set the
expectation that a public EditableImage library must be fast *and* pleasant to
use. Avalon R1 is not a pixel-drawing library, but its `Framebuffer` / `Texture`
split follows the same separation of "surface" from "what you draw into it".

* DevForum: "OSGL - EditableImage graphics library"

### CanvasDraw (and the wider EditableImage community)

**Contribution: the historical baseline.**

CanvasDraw was the long-standing answer to "how do I draw pixels in Roblox", and
the many DevForum threads comparing it with OSGL, Ro2D and the triangle
rasterizer are what make the performance landscape legible. The recurring lesson
from those threads — that the language itself is the bottleneck, so the wins come
from doing fewer operations per pixel and letting native codegen handle the rest —
is the premise of this project.

## What Avalon R1 adds

The work above is why this is possible. Avalon R1 tries to go further:

- **A real 3D pipeline**, not a pixel or triangle primitive: MVP transform,
  near-plane clipping, back-face culling, depth buffer, perspective-correct
  texturing, per-vertex lighting.
- **Near-plane clipping**, so geometry crossing the camera is cut rather than
  smeared across the screen.
- **Adaptive resolution** that measures frame time and trades pixels for frame
  rate automatically.
- **A scene-level API** — `Camera`, `Mesh`, `Texture`, `Renderer` — instead of
  raw per-pixel or per-triangle calls.
- **A headless test suite** so the maths and the pipeline can be verified
  outside Roblox.

If you maintain any of the projects above and feel this description is
inaccurate or that you would like different attribution, please open an issue
and it will be corrected.
