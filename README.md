# Screen Space Global Illumination (SSGI) for Garry's Mod

Real-time indirect lighting and occlusion, traced against the depth buffer.

* [Visibility Bitmask](https://arxiv.org/pdf/2301.11376) (Therrien et al., 2023) for the horizon search
* Temporal reprojection through the previous frame's view-projection
* [Edge-Avoiding À-Trous Wavelet Transform](https://jo.dreggn.org/home/2010_atrous.pdf) (Dammertz et al., 2010) as the spatial denoiser
* Joint bilateral upsample from the trace resolution back to full res

### Requirements
- [Garry's Mod](https://steamcommunity.com/app/4000) — use the `x86-64 Chromium + 64-bit binaries` branch.
- [GShader Library](https://github.com/Akabenko/GShader-library) — G-buffer (`_rt_WPDepth`, `_rt_NormalsTangents`) and the `pp_vs30` vertex shader.
- [NikNaks](https://github.com/Nak2/NikNaks) — required by GShader Library.

Drop the addon in `garrysmod/addons/`, then enable it under **Post Processing → Shaders → Screen Space Global Illumination**.

Turn the stock MSAA off and use SMAA or FXAA instead — MRT and multisampled
framebuffers can conflict, and the G-buffer needs MRT. Set it in **Options →
Video**, not the console: `mat_antialias` is not archived to a `.cfg` and a
console change is gone on the next launch.

---

## Pipeline

Everything runs from `PostDrawReconstructionEffects`, which fires inside
`PreDrawTranslucentRenderables` — the framebuffer holds the lit opaque pass and
the G-buffer is already built.

| # | Pass | Resolution | Output |
|---|---|---|---|
| 1 | `ssgi_trace_*`  | trace res | `.rgb` indirect radiance, `.a` occlusion |
| 2 | `ssgi_temporal` | trace res | history-accumulated signal |
| 3 | `ssgi_atrous_*` | trace res | denoised signal (N iterations, doubling stride) |
| 4 | `ssgi_composite`| full res  | bilateral upsample + apply, straight to the framebuffer |
| 5 | `ssgi_copyz`    | trace res | linear depth snapshot for next frame |

### 1. Trace

The visibility bitmask keeps track of which angular sectors of the hemisphere are
already occluded, so an occluder only contributes light for the sectors it is the
*first* to cover. That is what stops the double counting that makes plain
HBAO/HBIL over-darken, and it lets light through gaps between separate occluders.

`ps_3_0` has no integer instructions, so `countbits` and `<<` are off the table.
The mask is four `float4`s instead — 16 sectors holding *fractional* coverage,
which is strictly better than hard bits: it antialiases the sector boundaries,
which is exactly the banding you would otherwise have to dither away.

The sectors are uniform in `sin²θ` rather than in `θ`. Under the cosine-weighted
projected solid angle measure that makes every sector carry the same weight, so
the integral collapses to `covered / 16` and no `acos` appears anywhere in the
inner loop.

Slice counts are always even. Slice *k* and slice *k + slices/2* then point in
exactly opposite screen directions, and antithetic pairs like that cancel most of
the first-order error in a horizon search — which is what keeps the result from
swinging around as the camera rotates.

The world radius is projected to pixels and clamped at both ends, then the world
radius is **recomputed from the clamped pixel radius**. Without that step the
march is clamped while the falloff still uses the radius it asked for, and the
two drift apart as you approach a surface — occlusion visibly changes size and
snaps. The floor is what keeps distant geometry from dropping the effect
entirely; sky is skipped outright (`_rt_WPDepth.a == 0.00025`).

### 2. Temporal

The single biggest noise win available. `_rt_WPDepth` already stores a world
position per pixel, so the previous frame's screen position is one matrix
multiply — no velocity buffer, no motion vectors, exact for static geometry,
which is most of a Source map.

Disocclusion is caught by comparing the depth the surface *should* have had last
frame (`clip.w` of the reprojected position is exactly perpendicular view depth
under GShader's projection) against the depth `ssgi_copyz` recorded there.
Ghosting from moving objects and from lighting changes is caught by clamping the
history into the neighbourhood of the current frame.

Sampling is offset by blue noise rotated per frame with the R2 low-discrepancy
sequence, so successive frames sample complementary directions and the history
actually converges instead of averaging the same error.

### 3. Denoise

À-trous with a doubling stride: each pass is a small kernel, but the support
grows geometrically. 3×3 run three times reaches 15×15; the 5×5 variant reaches
33×33. Weights combine depth, normal and luminance similarity.

### 4. Upsample

A plain bilinear stretch drags occlusion across depth discontinuities and
produces the halos that make cheap SSAO look glued on. The four nearest low-res
taps are reweighted by how well their depth and normal match the full-res pixel
being shaded, and only then blended.

---

## Console variables

| ConVar | Default | Notes |
|---|---|---|
| `pp_ssgi` | `0` | Master switch |
| `pp_ssgi_quality` | `2` | 1 low (4×4), 2 medium (4×6), 3 high (6×8), 4 ultra (8×12) — slices × steps |
| `pp_ssgi_scale` | `1` | Trace resolution: 0 full, 1 half, 2 quarter |
| `pp_ssgi_radius` | `160` | Gather radius, world units |
| `pp_ssgi_maxradius` | `0.12` | Radius cap as a fraction of trace height |
| `pp_ssgi_minradius` | `4` | Radius floor in pixels — keeps distant surfaces from losing the effect |
| `pp_ssgi_thickness` | `40` | Assumed occluder thickness, world units |
| `pp_ssgi_gi` | `1.0` | Indirect light intensity |
| `pp_ssgi_ao` | `1.0` | Occlusion intensity |
| `pp_ssgi_albedo` | `0.5` | How much the bounce is tinted by the receiving surface |
| `pp_ssgi_linear` | `2` | 0 gamma, 1 linear, 2 auto (gamma under HDR, where the framebuffer is already linear) |
| `pp_ssgi_temporal` | `1` | Temporal accumulation |
| `pp_ssgi_temporal_alpha` | `0.08` | New frame weight — lower is smoother and ghosts more |
| `pp_ssgi_temporal_clamp` | `2.0` | History clamp width, in neighbourhood std devs |
| `pp_ssgi_temporal_tol` | `0.05` | Disocclusion depth tolerance, relative |
| `pp_ssgi_denoise` | `2` | À-trous iterations (0–4) |
| `pp_ssgi_denoise_wide` | `0` | 5×5 kernel instead of 3×3 |
| `pp_ssgi_denoise_z` / `_n` / `_l` | `2` / `32` / `4` | Denoise depth / normal / luminance tolerance |
| `pp_ssgi_upsample_z` / `_n` | `1` / `32` | Upsample depth / normal tolerance |
| `pp_ssgi_ao_lightbias` | `0.6` | Fade occlusion out on bright pixels. `0` occludes direct light too |
| `pp_ssgi_debug` | `0` | 1 GI, 2 AO, 3 GI+AO, 4 normals, 5 depth, 6 A/B split, 7 difference, 8 coverage |
| `pp_ssgi_split` / `pp_ssgi_diffgain` | `0.5` / `12` | Divider position for view 6, amplification for view 7 |

Console commands:

| Command | Notes |
|---|---|
| `ssgi_diagnose` | Dump the whole pipeline state — branch, G-buffer, hooks, materials, render targets |
| `ssgi_preset [name]` | Apply a validation preset; no argument lists them |
| `ssgi_ab` | Toggle the A/B split view |

`ShouldDrawSSGI` is a client hook — return `false` to suppress the effect for a
frame.

## Judging whether it is correct

Being *on* and being *right* are different questions, and the second one is not
answerable by looking at the composited frame. See **[VALIDATION.md](VALIDATION.md)**
for the protocol: amplify the difference, split the screen, or converge a
reference and compare against it.

---

## Building

Shader sources live in `shadersrc/`; the compiled `.vcs` in `shaders/fxc/` are
what ship. `bin/ShaderCompile.exe` is ficool2's compiler.

```powershell
.\build.ps1                              # everything that changed
.\build.ps1 -Force                       # ignore the crc cache
.\build.ps1 ssgi_trace_high_ps30.hlsl    # one file
```

Regenerating the blue noise texture (void-and-cluster, writes a VTF 7.2 directly):

```
python bin/make_bluenoise_vtf.py materials/texture_samples/ssgi_bluenoise.vtf
```

### Register layout

Fixed by `screenspace_general`; see `shadersrc/ssgi_common.h`.

| Register | Bound to |
|---|---|
| `s0`–`s3` | `$basetexture`, `$texture1`–`$texture3` |
| `c0`–`c3` | `$c0`–`$c3` |
| `c4` | texel size of `$basetexture` (engine supplied) |
| `c11`–`c14` | `$viewprojmat` |
| `c15`–`c18` | `$invviewprojmat` |

`screenspace_general_8tex` exists in both the 32- and 64-bit `stdshader_dx9.dll`
and binds `$texture1`–`$texture7` if a pass ever needs more than four samplers.

### G-buffer layout (GShader Library)

| Target | Contents |
|---|---|
| `_rt_WPDepth` | `.rgb` = `1/worldPos`, `.a` = `1/linearDepth` (sky reads exactly `0.00025`, see below) |
| `_rt_NormalsTangents` | `.rg` octahedral normal, `.b` diamond tangent, `.a` handedness |
| `_rt_Bump` | `.rgb` bump, `.a` specular mask |
| `_rt_FullFrameFB` | the screen, via `render.UpdateScreenEffectTexture()` |

The sky test must be an **equality**, not `<=`. With `r_shaderlib_depthbuffer` on
the depth buffer is floating point and keeps counting past 1.0 — 0–4000 units map
to 0..1, 4000–8000 to 1..2, and so on — so real geometry beyond 4000 units stores
a value *smaller* than the sky constant. Testing `a <= 0.00025` silently discards
every distant surface in the map. See `SSGI_IS_SKY` in `shadersrc/ssgi_common.h`.

The 3D skybox is not in the G-buffer unless `r_shaderlib_3dskybox 1`.

---

## Special thanks

* **Evgeny Akabenko** (GShader Library) — the G-buffer everything here stands on, and most of the useful information
* **ficool2** (Source Shader SDK) — the compiler and bin files mixed into this repo
* **LVutner** — velocity encoding and the DX10/DX11 → DX9 upsampling work
* **Meetric** — WorldPos reconstruction
