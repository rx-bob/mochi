# Station inspector parity

On macOS, install the three Playwright browsers and run `task desktop:parity`.
Each run saves both hosts’ cropped PNGs, observations, browser accessibility
snapshots, highlighted diffs and comparison reports under
`build/desktop-parity/run.*`. The independent macOS CI job uploads that
directory even when a comparison fails. Ordinary browser regression tests run
on their own.

The Ruby scenario records the selected and reversed checkpoints. Both drivers
replay the same plan at 285, 320 and 640 logical points, with 2× captures, a
light theme and the fixture’s Noto Sans subset. For captures, the web entry
uses zero outer margin and removes its 520px demo width cap. The crop starts at
the panel origin and ends at the panel bounds. The panel’s authored 16px
padding stays in the crop. AppKit captures the view content and converts the
bitmap to sRGB. Browser images are decoded to sRGB for pixel comparison.

The comparison checks every measured edge within one logical point. Control
order, focus, accessible roles and names, pressed state, and rendered line
breaks must agree exactly. Solid fills are checked independently by sampling
four pixels in each filled control’s padding. Clay’s vendored v0.14 fix
excludes the final space of a candidate line when testing whether it fits. It
preserves spaces between words. The inspector exercises this at 320 points.

## Paint baselines

[`parity.json`](parity.json) records the per-engine limits for pixels with a
channel difference above 32. The table lists measured maximum percentages across
the six reviewed capture pairs for each engine on arm64 macOS 26.6.2 with the
browsers from the Playwright lockfile. The limits allow some raster variation
around those measurements.

| Region | Chromium | Firefox | WebKit |
|---|---:|---:|---:|
| Panel including controls | 3.88% | 5.93% | 3.75% |
| Title | 3.00% | 6.80% | 0.00% |
| Actions container | 9.20% | 8.09% | 9.03% |
| Reverse button | 6.78% | 6.76% | 6.54% |
| Details button | 7.66% | 6.85% | 6.22% |
| Details button focused | 23.62% | 15.71% | 14.26% |
| Station 01 | 2.04% | 4.85% | 0.00% |
| Station 02 | 2.56% | 6.97% | 0.00% |
| Station 02 focused | 12.69% | 10.70% | 5.26% |
| Station 03 | 1.15% | 4.06% | 0.00% |
| Selection label | 2.77% | 7.07% | 0.00% |
| Details label | 2.52% | 6.27% | 0.00% |

AppKit draws its focus ring inside the button. Browser focus outlines differ in
position and color, which accounts for the separate focused limits. Other
differences concentrate on glyph edges and the fractional edges of the compact
action buttons. Focus identity, wrapping, and geometry have independent checks.
