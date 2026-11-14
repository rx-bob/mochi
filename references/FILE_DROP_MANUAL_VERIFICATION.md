# Native file drop verification

Verified on 2026-11-13 with a real Finder drag into Mochi's browser file drop zone. The drag used macOS mouse events; it did not synthesize a browser `DataTransfer`.

- OS: macOS 26.6.2 (Build 25G83)
- Browser: Google Chrome 157.0.8103.51
- Input: `utf8_boundary.txt`, 8,195 bytes, dropped from Finder
- Metadata received by Ruby: `utf8_boundary.txt:8195:text/plain:1794570263198:mochi-file-1`
- Whole file read: `text:8195:€` (the euro sign straddles the 8 KiB read boundary)
- Stream state: `idle:0:0`

Screenshot: [native-file-drop-2026-11-13.png](evidence/native-file-drop-2026-11-13.png).
