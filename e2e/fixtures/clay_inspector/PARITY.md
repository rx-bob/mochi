# Station inspector parity

On macOS, install the three Playwright browsers and run `task desktop:parity`.
Each run saves both hosts’ cropped PNGs, observations, browser accessibility
snapshots, highlighted diffs and comparison reports under
`build/desktop-parity/run.*`. The independent macOS CI job uploads that
directory even when a comparison fails. Ordinary browser regression tests run
on their own.

The Ruby scenario records the selected and reversed checkpoints. Both drivers
replay the same plan at 285, 315, 318, 320 and 640 logical points with 2×
captures. At 315 and 318 points they also capture at 1×. Both use a light
theme and the declared Noto Sans subsets. For captures, the web entry
uses zero outer margin and removes its 520px demo width cap. The crop starts at
the panel origin and ends at the panel bounds. The panel’s authored 16px
padding stays in the crop. AppKit captures the view content and converts the
bitmap to sRGB. Browser images are decoded to sRGB for pixel comparison.

The comparison checks every measured edge within one logical point. Control
order, focus, accessible roles and names, pressed state, and rendered line
breaks must agree exactly. Line positions, advance widths, and baselines
are checked within one logical point. The Café row crosses its first-line
wrap boundary between 315 and 318 points, and the bold title exercises the
Ω fallback face. Solid fills are checked independently by sampling
four pixels in each filled control’s padding. Clay’s vendored v0.14 fix
excludes the final space of a candidate line when testing whether it fits. It
preserves spaces between words. The inspector exercises this at 320 points.

## Paint baselines

[`parity.json`](parity.json) records the per-engine limits for pixels with a
channel difference above 32. The table lists measured maximum percentages across
the ten reviewed 2× capture pairs for each engine on arm64 macOS 26.6.2 with the
browsers from the Playwright lockfile. The limits allow some raster variation
around those measurements.

| Region | Chromium | Firefox | WebKit |
|---|---:|---:|---:|
| Panel including controls | 3.76% | 4.08% | 3.37% |
| Title | 3.87% | 3.97% | 0.00% |
| Actions container | 6.90% | 8.48% | 5.12% |
| Reverse button | 3.45% | 7.41% | 0.46% |
| Details button | 4.03% | 7.33% | 0.81% |
| Details button focused | 20.00% | 16.18% | 8.85% |
| Station 01 | 2.23% | 1.99% | 0.00% |
| Station 02 | 2.58% | 3.17% | 0.00% |
| Station 02 focused | 12.69% | 7.82% | 5.26% |
| Station 03 | 1.20% | 1.29% | 0.00% |
| Selection label | 2.77% | 2.59% | 0.00% |
| Details label | 2.52% | 2.69% | 0.00% |

The 1× policy records separate limits where the four additional captures
show more raster variation. Chromium peaks at 4.82% for the title and 28.50%
for focused Details. Firefox peaks at 12.24% for the actions, 12.94% for
Reverse, 15.59% for Details, and 28.50% for focused Details. WebKit peaks
at 7.45% for the focused Café row.

AppKit draws its focus ring inside the button. Browser focus outlines differ in
position and color, which accounts for the separate focused limits. Other
differences concentrate on glyph edges and the fractional edges of the compact
action buttons. Focus identity, wrapping, and geometry have independent checks.

The font files are SIL Open Font License subsets of the Noto Sans faces under
`devground/public/fonts/noto-sans/static/`. The bold subset retains U+0020
through U+007E and U+00E9. The symbol subset retains U+03A9 from the same
bold face. They were prepared with HarfBuzz `hb-subset` and `woff2_compress`.
