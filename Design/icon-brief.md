# Hushaboom app icon - designer brief

Target pipeline: **Icon Composer** (ships inside Xcode 26, at
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`). It takes
flat vector layers and applies Apple's Liquid Glass material, lighting,
shadows, and the rounded-rect mask itself. Your job is the flat artwork only.

## The app

Hushaboom is a noise generator for iOS and macOS. White, pink, and brown
noise plus *synthesized* (never sampled, never looping) ocean waves, wind,
rain, and rustling trees. The pitch is a seamless, calm, continuous sound -
sleep, focus, masking. Existing in-app channel tints, if useful as a palette
anchor: gray, pink, brown, teal (ocean), light gray (wind), blue (rain),
green (trees).

Tone to aim for: calm and quiet, not "audio gear".

## The concept

A **noise waveform outlined in successive colors, inside a white container** -
a wandering line crossing the square edge to edge, banded in a sunset ramp
from night at the core out to white.

The curve is **band-limited noise**: a Fourier sum over the canvas width with
random phases and component amplitudes falling off as `k ** -slope`. Slope 0
is white noise, 1 is pink, 2 is brown - the same three colours the app itself
generates. It is periodic over the width, so the two clipped edges meet
instead of jumping.

`Design/generate-icon.py` is the source of truth, not the SVGs: the curve is
seeded pseudo-random and cannot be reconstructed by hand. Change a parameter
at the top of that file and rerun it. Shipped settings: seed 3, 14 harmonics,
slope 1.0 (pink), amplitude 230, band 290, baseline y = 487.

- **The ends are clipped by the artboard, not capped.** Sample the curve only
  across `x = 0 .. 1024` and close each band with vertical edges at the
  artboard boundary. Do not use round caps - they distort into a nub at the
  ends once the band geometry is built.
- **Centre it by bounding box, not by the baseline.** A noise curve is not
  symmetric about zero over any finite window, so centring the baseline leaves
  it visibly lopsided.
- The stacking is an **outline / enlargement**: each successive colour is the
  same contour enlarged around the one before it, so the bands nest.
- Colour ramp, **innermost -> outermost**:

  A **sunset**: a glowing warm edge deepening to night at the core.

  | # | Colour | Hex | Luminance |
  |---|--------|-----|-----------|
  | 1 | night | `#16061F` | 0.00 |
  | 2 | deep purple | `#3E1150` | 0.02 |
  | 3 | plum | `#7C1D5C` | 0.06 |
  | 4 | crimson | `#C0374B` | 0.14 |
  | 5 | orange | `#EE6B3B` | 0.29 |
  | 6 | gold | `#F9B25C` | 0.53 |
  | 7 | white | `#FFFFFF` | 1.00 |

  Hexes are a first pass - refine them, but keep the luminance monotonic (see
  below). A warm off-white background such as `#FFF6EA` suits this ramp better
  than pure white; that is an Icon Composer setting, not artwork.

### The spectral slope is the real design dial

The band stack behaves as a low-pass filter on the artwork. Any wiggle in the
curve finer than the stack is tall gets swallowed, and where that happens the
colour ramp collapses into a dark line with a thin warm fringe. So the two
things the concept is built on - "reads as noise" and "outlined in successive
colours" - pull against each other, and `slope` is the dial between them.

See `Design/concepts/slope-comparison.png` (and the 88px version beside it),
all three at matched height and the same seed:

| Slope | Reads as | Ramp legibility |
|-------|----------|-----------------|
| 0 (white) | unmistakably noise | poor - bands crush together |
| 1 (pink) | noise, calmer | usable at full size, marginal at 88px |
| 2 (brown) | a smooth swell, not noise | excellent at every size |

Shipped at slope 1 as the compromise. Worth knowing before committing: at
home-screen size **only brown holds the ramp**. Cutting the band count does
not rescue white - a shorter stack just makes the ramp a thin fringe instead
of a crushed one - so this is a choice between the two ideas, not a tuning
problem. `slope-0-white.svg` and `slope-2-brown.svg` are the two ends.

`alt-sinc-impulse.svg` is the earlier smoothed-impulse version, kept as an
alternative.

### Build the bands as vertical offsets, not perpendicular offsets

This is the one construction detail that has to be right, and it is not the
obvious approach.

The obvious approach is to stroke the curve seven times at decreasing widths,
or equivalently to offset the contour perpendicular to itself. That fails at
every sharp turn in the curve, and a noise waveform is nothing but sharp
turns. Offsetting a curve *inward* crowds as the offset approaches the curve's
radius of curvature. Past the limit you get an outright cusp - a sharp V.
Short of the limit you still get the artifact visible in
`Design/concepts/cusp-before-after.png`: on the concave side the bands bunch
together and their arch tips nest at uneven heights, so the ramp reads
compressed and lopsided against the clean outer side.

**Instead, define each band by translating the curve vertically.** Band `i` is
the filled region between the curve moved up by `h_i` and the curve moved down
by `h_i`, painted widest first so each narrower band covers the middle of the
one before it. A vertical translation is a rigid motion - it cannot crowd,
cusp, or self-intersect at any curvature - so every peak comes out clean by
construction at any amplitude, with no constraint linking band width to
amplitude at all. This matters far more for a noise curve than it did for a
smooth one: with perpendicular offsets, every sharp turn would need checking
individually.

Half-heights for the seven bands, outermost to innermost: 145, 122.3, 99.7,
77, 54.3, 31.7, 9.

Known side effect, and it is the honest trade: bands keep a constant
*vertical* thickness, so their *perpendicular* thickness thins on steep
stretches by `cos(angle)`. It reads as a deliberate taper rather than an
error, but it is why the steep runs look leaner than the turns.

`Design/concepts/V5-sine-tall.svg` is a plain two-period sine, kept as a
fallback if the noise reads too busy.

### How this ramp behaves

**The outermost white band is invisible against the white container** - by
design. It reads as nothing in the light appearance, and becomes a bright
halo separating the wave from the background in dark or coloured appearances.
So the icon adapts on its own; don't "fix" it.

**It survives the tinted appearance.** Tinted mode flattens the icon to a
single colour, which usually destroys multicolour banding. Because this ramp
is monotonic in luminance (night -> white), the bands stay distinguishable
when colour is removed. Keep that property when refining the hexes: each band
should be a clear luminance step from its neighbours, not just a hue step.
The sunset ramp is comfortably better here than the blue one it replaced - its
smallest luminance step is 0.016 against the blue ramp's 0.009 - and its
larger hue steps also make it hold up better at 88px.

An inverted arrangement - bright core, deep violet outermost - is in
`Design/concepts/alt-sunset-inverted.svg`. It gives the icon a much crisper
silhouette on a light background, at the cost of the adaptive behaviour above:
a dark outermost band disappears against a dark background instead of haloing
against it. Recoverable, since every band is its own layer and Icon Composer
can vary colour per appearance, but it is extra work rather than free.

## Layering

Icon Composer's documented limit is **four groups**, not four layers - and a
group holds as many layers as you like. Each of the seven bands can therefore
stay its own layer, which means every band can be retinted independently per
platform and per appearance.

Better still, Icon Composer turns **folders into groups**: drag a folder of
SVGs onto the sidebar and the folder becomes a group with its files as that
group's layers, named and ordered alphabetically. So the directory layout is
the group structure, and numeric prefixes fix the back-to-front z-order.

The artwork in `Design/icon/` is already arranged that way - drag all four
folders in at once:

```
Design/icon/
  1-outer/  1-white.svg    2-gold.svg
  2-mid/    3-orange.svg   4-crimson.svg
  3-inner/  5-plum.svg     6-deep-purple.svg
  4-core/   7-night.svg
  wave-flat.svg                 (all seven bands in one file, reference only)
```

Each part is a single filled path on a transparent canvas, trimmed
geometrically to the 1024 square rather than relying on a viewBox clip, so
nothing downstream has to crop it. Stacking the seven in order reproduces
`wave-flat.svg` exactly (verified: max channel difference of 1, which is
antialiasing).

Do not ship the white container as a layer: Icon Composer owns the
background. Hand over the background colour as a value and we set it in the
tool.

## Hard technical requirements

These come from Apple's
[Icon Composer documentation](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
Ideally start from the Icon Composer template in
[Apple Design Resources](https://developer.apple.com/design/resources/).

**Canvas**
- 1024 x 1024 px artboard (square, no rounding). 1088 x 1088 only if we ever
  add watchOS - not needed now.
- Do **not** draw or export the rounded-rect mask. The system crops
  automatically; a baked-in mask will double up and look wrong.
- Keep meaningful content inside the safe area of Apple's template grid -
  corners get clipped and the icon is also rendered at very small sizes.
  The wave is the deliberate exception: it bleeds off the left and right
  edges. That is safe because it meets those edges near the vertical midpoint,
  well clear of the rounded corners.

**Layers**
- Max **four groups**. A group may hold any number of layers, and groups are
  ordered back to front in the z-plane.
- Name each exported file with a leading number so ordering survives the
  handoff, and put the files in folders named the same way - Icon Composer
  turns folders into groups.
- Split anything we might want to retint per-platform or per-appearance
  (light / dark / clear / tinted) into its own layer. Merged artwork can't be
  re-separated later.
- One SVG file per layer. Not one SVG with internal groups.

**SVG specifics**
- Convert all text to outlines - SVG does not carry fonts.
- Prefer SVG for every layer. If a layer needs an effect SVG can't express
  cleanly, ship that one layer as a PNG at 1024x1024 (or larger) instead;
  mixing formats across layers is fine.
- No filters (`feGaussianBlur`, drop shadows, etc.), no clip paths or masks
  used as effects, no live text, no embedded raster inside the SVG.
- Strokes: expand/outline them rather than relying on `stroke-width`.

**Do NOT bake in** (Icon Composer applies all of this, and it will be
doubled if the artwork already has it):
- blurs and shadows
- specular highlights, opacity, and translucency
- the background color or background gradient (Icon Composer owns the
  background fill - hand the background over as its own layer/colour spec,
  or just tell us the colours and we'll set them in the tool)

## Deliverables

1. One SVG per layer, numbered back to front, in folders that map to the
   intended groups (max four folders).
2. A flattened 1024x1024 PNG preview so we can sanity-check the intended
   look against what Icon Composer renders.
3. Source file (Figma / Illustrator / Sketch) so we can iterate.
4. Note any layer that must stay a specific colour in dark or tinted mode.

A first cut meeting all of this is already in `Design/icon/` - see the README
there. Treat it as the starting point to refine rather than a blank page.

## Wiring (done)

`Hushaboom.icon` lives at the repo root and is wired into both targets.
`project.yml` gives each target an explicit `type: file` source entry for it
plus `ASSETCATALOG_COMPILER_APPICON_NAME: Hushaboom`; the Xcode project is
generated, so edit `project.yml` and rerun `xcodegen generate` rather than
touching `Hushaboom.xcodeproj`.

The Icon Composer file carries six of the seven layers - `1-white` was left
out, and the white container it was designed against is now a warm linear
gradient (`#FF8D28` to `#FF383C`) set as the Icon Composer background. That is
a reasonable call with a coloured background, since a white outer band would
read as a hard light edge rather than disappearing, but it is a deliberate
difference from the brief above rather than an oversight to rediscover later.

### Back-deployment: verified working

Deployment targets are iOS 15 / macOS 12, and both targets build clean. Xcode
generates the legacy icons from the `.icon` file automatically. Confirmed in
the built products:

- macOS: `Hushaboom.icns` in `Contents/Resources`, all sizes present.
- iOS: `Assets.car` carries the `IconImageStack` (the Liquid Glass version for
  26+) *alongside* pre-rendered flat 1024x1024 PNGs for the default, dark, and
  tintable appearances, in both phone and pad idioms, plus a `MultiSized
  Image` entry the system derives the smaller home-screen sizes from.
- `Info.plist` gets both `CFBundleIconName` (modern) and
  `CFBundlePrimaryIcon` / `CFBundleIconFiles` (legacy).

Those flat PNGs are the pre-26 fallback, so an older phone shows a normal flat
icon rather than nothing. If the generated fallback ever looks wrong on a
specific old release, the escape hatch is a conventional `AppIcon` asset
catalog set with a flat 1024 PNG plus
`--enable-icon-stack-fallback-generation=disabled` in
`ASSETCATALOG_COMPILER_OTHER_FLAGS`.
