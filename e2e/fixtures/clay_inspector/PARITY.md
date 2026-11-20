# Station inspector parity

On macOS, install the three Playwright browsers and run `task desktop:parity`.
Each run saves both hosts’ cropped PNGs, observations, browser accessibility
snapshots, highlighted diffs and comparison reports under
`build/desktop-parity/run.*`. The independent macOS CI job uploads that
directory even when a comparison fails. Ordinary browser regression tests run
on their own.

The Ruby scenario records the initial, selected and reversed states. Both
drivers replay it at viewport widths of 333, 363, 366, 368, 567, 568 and 640
logical points with 2× captures. They also capture at 363 and 366 points at
1×. The project's 24px inset and 520px width cap apply in both builds. The
last three widths test just below, exactly at and above the cap. The crop
includes the full viewport width and both vertical insets. It excludes window
chrome. AppKit converts the bitmap to sRGB and browser images are decoded to
sRGB for comparison.

The comparison checks every measured edge within one logical point. Control
order, focus, accessible roles and names, pressed state, inherited text color,
and rendered line breaks must agree exactly. The two action buttons reverse
their class order and both get the same local padding override. The Reverse
button uses a fixed size. Station rows use available width. The selection
change updates appearance on the two affected rows and preserves all measured
bounds.

Line positions, advance widths, and baselines are checked within one logical
point. The Café row crosses its first-line wrap boundary between panel widths
of 315 and 318 points, and the bold title exercises the Ω fallback face. Solid
fills are checked independently by sampling four pixels in each filled
control’s padding. Clay’s vendored v0.14 fix excludes the final space of a
candidate line when testing whether it fits. It preserves spaces between words.
The inspector exercises this at a panel width of 320 points.

## Paint baselines

[`parity.json`](parity.json) records the per-engine limits for pixels with a
channel difference above 32. The table lists measured maximum percentages across
the 21 reviewed 2× capture pairs for each engine on arm64 macOS 26.6.2 with the
browsers from the Playwright lockfile. The limits allow some raster variation
around those measurements.

| Region | Chromium | Firefox | WebKit |
|---|---:|---:|---:|
| Panel including controls | 3.71% | 4.05% | 3.31% |
| Title | 3.87% | 3.97% | 0.00% |
| Actions container | 7.04% | 8.97% | 4.95% |
| Reverse button | 2.83% | 6.59% | 0.00% |
| Details button | 2.68% | 6.45% | 0.00% |
| Details button focused | 19.66% | 14.56% | 8.11% |
| Station 01 | 2.23% | 1.99% | 0.00% |
| Station 02 | 2.62% | 3.19% | 0.00% |
| Station 02 focused | 13.61% | 8.83% | 5.33% |
| Station 03 | 1.20% | 1.29% | 0.00% |
| Selection label | 2.81% | 2.63% | 0.00% |
| Details label | 2.52% | 2.69% | 0.00% |

The 1× policy records separate limits where the six additional captures
show more raster variation. Chromium peaks at 4.82% for the title and 28.87%
for focused Details. Firefox peaks at 12.49% for the actions, 11.38% for
Reverse, 11.48% for Details, and 27.50% for focused Details. WebKit peaks
at 7.45% for the focused Café row.

AppKit draws its focus ring inside the button. Browser focus outlines differ in
position and color, which accounts for the separate focused limits. Other
differences concentrate on glyph edges and the fractional edges of the compact
action buttons. Focus identity, wrapping, and geometry have independent checks.

The font files are SIL Open Font License subsets of the Noto Sans faces under
`devground/public/fonts/noto-sans/static/`. The bold subset retains U+0020
through U+007E and U+00E9. The symbol subset retains U+03A9 from the same
bold face. They were prepared with HarfBuzz `hb-subset` and `woff2_compress`.
