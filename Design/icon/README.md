# Icon artwork

Import-ready layers for Icon Composer. See `../icon-brief.md` for the design
rationale and the construction rules.

Drag all four folders onto the Icon Composer sidebar at once: folders become
groups, the SVGs inside become that group's layers, and the numeric prefixes
give the back-to-front z-order. Four groups is Icon Composer's documented
maximum.

| Group | Layer | Colour | Band height |
|-------|-------|--------|-------------|
| `1-outer` | `1-white` | `#FFFFFF` | 290px |
| `1-outer` | `2-gold` | `#F9B25C` | 245px |
| `2-mid` | `3-orange` | `#EE6B3B` | 199px |
| `2-mid` | `4-crimson` | `#C0374B` | 154px |
| `3-inner` | `5-plum` | `#7C1D5C` | 109px |
| `3-inner` | `6-deep-purple` | `#3E1150` | 63px |
| `4-core` | `7-night` | `#16061F` | 18px |

`wave-flat.svg` is all seven bands in one file. It is a reference for checking
the composite, not something to import - importing it would collapse the
per-band control that the split buys.

The background is deliberately absent. Icon Composer owns it; it is currently
set there to a warm linear gradient, `#FF8D28` to `#FF383C`. Note that
`1-white.svg` is consequently not imported into `Hushaboom.icon` - against a
coloured background it would read as a hard light edge rather than
disappearing.

Geometry: band-limited pink-noise curve (seed 3, 14 harmonics, slope 1.0),
amplitude 230, band 290, baseline y = 487, on a 1024 square. Each band is the
region between the curve translated up and down by a constant, trimmed to the
artboard.

**These files are generated.** The curve is seeded pseudo-random, so
`../generate-icon.py` is the source of truth - edit the parameters at the top
of it and rerun `python3 Design/generate-icon.py` rather than hand-editing the
SVGs. The script overwrites the SVGs in place and leaves this README alone.
