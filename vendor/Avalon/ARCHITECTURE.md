# Architecture

How a triangle gets from a `Mesh` to a pixel on screen in Avalon R1.

```
   Mesh (SoA)
        │
        ▼
   1. MVP transform ............ Mat4.transformPoint      → clip space (x,y,z,w)
        │
        ▼
   2. Near-plane clip .......... Sutherland–Hodgman       → 0, 3 or 4 vertices
        │
        ▼
   3. Perspective divide ....... → screen coords + 1/w for depth/interpolation
        │
        ▼
   4. Back-face cull ........... signed-area test
        │
        ▼
   5. Edge-function raster ..... coverage + depth test + interpolate
        │
        ▼
   6. Upload ................... WritePixelsBuffer (one per frame)
```

## 1. Coordinates and conventions

- **Right-handed** view space, camera looks down **-Z**.
- `Mat4.perspective` is OpenGL-style, so clip `w == -viewZ`. A point in front of
  the camera therefore has `w > 0`.
- **Row-major** flat 16-number matrices, column-vector convention.
- Screen space has **y pointing down** (GUI convention). The divide step flips
  y: `sy = (0.5 - ndcY * 0.5) * H`.
- **Depth is stored as `1/w`**, not `z`. `1/w` is linear in screen space, so it
  interpolates correctly with the same barycentric weights used for everything
  else. A larger value is nearer. The depth plane is cleared to `0`, so any
  visible fragment (`1/w > 0`) passes the first test.

## 2. Near-plane clipping

Only one plane is clipped: `w > near`. The other five frustum planes are left to
the scissor (the rasterizer clamps to the bounding box), which is cheaper and
avoids guard-band artifacts.

The clip is a standard Sutherland–Hodgman pass over a 3-vertex polygon:

- all three in front → passes through untouched (3 vertices)
- all three behind → rejected
- mixed → produces 3 or 4 vertices

A polygon of `n` vertices is then fan-triangulated into `n - 2` triangles. All
attributes — position, `uv`, colour — are interpolated linearly in clip space,
which is the correct space to do it in.

## 3. Perspective-correct interpolation

Screen-space linear interpolation of `u`, `v` or colour is wrong under
perspective; it produces the classic "swimming texture" artifact. The fix is to
interpolate `attribute / w` and `1 / w` linearly, then divide:

```
u = ( Σ λᵢ · uᵢ/wᵢ ) / ( Σ λᵢ · 1/wᵢ )
```

`Renderer` therefore hands the rasterizer, per vertex, `uv * 1/w` and
`colour * 1/w` alongside `1/w` itself. The rasterizer computes one reciprocal per
pixel and one divide per attribute. The depth value it needs for the z-test is
exactly the denominator, so it is free.

## 4. Edge-function rasterization

For a triangle in screen space, define the edge function for the edge `i → j`:

```
E(x, y) = (xⱼ - xᵢ)·(y - yᵢ) - (yⱼ - yᵢ)·(x - xᵢ)
```

Its value at the third vertex is the signed area `A`. The barycentric weights are
`λ = E / A`, and a point is inside when all three edge functions share the sign
of `A`.

The rasterizer:

1. Computes `A`. If `A < 0` it swaps two vertices so the winding is always
   positive — this is what lets `cull = false` render both sides.
2. Clamps the bounding box to the framebuffer.
3. Evaluates the three edge functions once at the first pixel, then walks the
   span with **incremental adds only** (`dE/dx` per step, `dE/dy` per scanline).

The inner loop is therefore: three compares, one reciprocal, one depth compare,
and — only when the fragment wins — the attribute maths and two buffer writes.
That is the shape `--!native` turns into fast machine code.

## 5. Three rasterizer entry points

`Rasterizer` has three functions rather than one function with flags, so that no
branch on "do I have a texture" ever runs per pixel:

| Function | Interpolates | Use |
|---|---|---|
| `flat` | depth only | cheapest; one packed colour |
| `gouraud` | depth + RGB | smooth shading |
| `textured` | depth + UV + RGB | texture × vertex colour |

## 6. Buffers

| Buffer | Format | Notes |
|---|---|---|
| colour | `width*height*4` bytes, RGBA8 | `buffer.writeu32` — one op per pixel |
| depth | `width*height*4` bytes, f32 | stores `1/w`; cleared to `0` |
| texture | `width*height*4` bytes, packed RGBA | sampled with one `buffer.readu32` |

The colour plane is handed straight to `EditableImage:WritePixelsBuffer`, so
there is no per-pixel Lua work on upload and no intermediate copy.

## 7. Adaptive resolution

`Renderer:present()` measures the frame time. At most twice a second it compares
that against the frame budget for `targetFps` and nudges `scale`:

- over budget by >25% → scale × 0.85
- under budget by >30% → scale × 1.08
- otherwise → leave it alone

Changing the scale reallocates the framebuffer and the `EditableImage`, which is
why it is rate-limited rather than adjusted every frame.

## 8. Winding convention

Triangles are front-facing when wound **counter-clockwise as seen from outside**
the surface. All the built-in generators (`cube`, `plane`, `sphere`, `torus`)
follow this. With screen-space y pointing down, a front face yields a
**negative** signed area, which is why the culler rejects `area >= 0`.

## 9. Why structure-of-arrays

A mesh stores `positions`, `normals` and `uvs` as three parallel arrays rather
than one array of vertex tables. The transform loop then reads
`positions[i]` directly; an array-of-tables would add a table lookup per
attribute per vertex. At a few thousand triangles a frame that difference is
measurable, and it costs nothing in API clarity because `Mesh.fromVertices`
still accepts the friendly nested form.

## 10. Scratch reuse

`Renderer.new` allocates two sets of nine flat arrays (clip-space input and
screen-space output) plus the edge-function scalars. `drawMesh` reuses them for
every triangle of every mesh in every frame. Nothing is allocated inside the
draw loop, so a steady-state frame allocates nothing at all.

## Testing

`Tests/` contains a headless harness that stubs the handful of Roblox globals the
renderer touches, runs the real modules under the standalone Luau CLI, and
asserts on the produced framebuffer. See `Tests/README.md`.
