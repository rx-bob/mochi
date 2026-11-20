import type { Page } from "@playwright/test";
import fs from "node:fs";

type Rect = [number, number, number, number];
type RGB = [number, number, number];
export type Control = {
  id: string;
  rect: Rect;
  role: string | null;
  name: string | null;
  lines: string[];
  pressed: boolean | null;
  fill: RGB | null;
  lineFrames: [number, number, number, number, number][];
  lineFaces?: string[][];
};
export type Capture = {
  width: number;
  height: number;
  scale: number;
  focus: string | null;
  controls: Control[];
};
type Policy = { edgeTolerance: number; channelDelta: number; solidChannelDelta: number };
type Mismatch = { control: string; check: string; dom: unknown; native: unknown };

export async function captureDOM(page: Page, stem: string): Promise<Capture> {
  const root = page.locator("record-inspector");
  const selectors = "[data-view], [data-action], [data-id]";
  await root.locator(selectors).evaluateAll(async elements => {
    await Promise.all(elements.filter(el => !["panel", "actions"].includes((el as HTMLElement).dataset.view || "")).map(async el => {
      const style = getComputedStyle(el);
      const faces = await document.fonts.load(`${style.fontWeight} ${style.fontSize} ${style.fontFamily}`, el.textContent || "");
      if (!faces.length || faces.some(face => face.status !== "loaded")) throw new Error("inspector font unavailable");
      if ((el as HTMLElement).dataset.view === "title" &&
          (faces.length !== 2 || !faces.some(face => face.unicodeRange.toLowerCase() === "u+3a9"))) {
        throw new Error("inspector title did not load its bold Latin and Omega faces");
      }
    }));
    await document.fonts.ready;
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });
  const capture = await root.locator(selectors).evaluateAll((elements): Capture => {
    const panel = elements[0].getBoundingClientRect();
    const focused = elements[0].getRootNode() as ShadowRoot;
    let focus: string | null = null;
    const controls = elements.map((el): Control => {
      const { view, action, id } = (el as HTMLElement).dataset;
      const key = view || (action ? `action-${action}` : `station-${id}`);
      if (focused.activeElement === el) focus = key;
      const bounds = el.getBoundingClientRect();
      const container = view === "panel" || view === "actions";
      const lines: string[] = [];
      const lineFrames: Control["lineFrames"] = [];
      const style = getComputedStyle(el);
      if (!container) {
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        const range = document.createRange();
        const metrics = document.createElement("canvas").getContext("2d")!;
        metrics.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
        const ascent = metrics.measureText("H").fontBoundingBoxAscent;
        const descent = metrics.measureText("H").fontBoundingBoxDescent;
        const leading = Number.parseFloat(style.lineHeight);
        let top = -Infinity;
        while (walker.nextNode()) {
          const node = walker.currentNode as Text;
          for (const word of node.data.matchAll(/\S+/g)) {
            range.setStart(node, word.index!);
            range.setEnd(node, word.index! + word[0].length);
            const rect = range.getBoundingClientRect();
            const current = rect.top;
            const left = rect.left - panel.left, right = rect.right - panel.left;
            if (Math.abs(current - top) < 0.5) {
              lines[lines.length - 1] += " " + word[0];
              lineFrames[lineFrames.length - 1][2] = right - lineFrames[lineFrames.length - 1][0];
            } else {
              lines.push(word[0]);
              top = current;
              const baseline = top - panel.top + ascent;
              lineFrames.push([left, baseline - (leading + ascent - descent) / 2, right - left, leading, baseline]);
            }
          }
        }
      }
      const rgba = style.backgroundColor.match(/[\d.]+/g)?.map(Number);
      if (!rgba || (rgba.length !== 3 && rgba[3] !== 0))
        throw new Error(`unexpected fixture background for ${key}: ${style.backgroundColor}`);
      const pressed = el.getAttribute("aria-pressed");
      return {
        id: key, name: null, lines, role: container ? null : el.tagName === "BUTTON" ? "button" : "text",
        rect: [bounds.x - panel.x, bounds.y - panel.y, bounds.width, bounds.height],
        pressed: pressed === null ? null : pressed === "true",
        fill: rgba.length === 3 ? [rgba[0], rgba[1], rgba[2]] : null, lineFrames,
      };
    });
    return { width: panel.width, height: panel.height, scale: devicePixelRatio, focus, controls };
  });
  const panel = root.locator(".panel");
  await panel.screenshot({ path: stem + ".png", scale: "device", animations: "disabled" });
  fs.writeFileSync(stem + ".aria.yml", await panel.ariaSnapshot());
  for (const [index, control] of capture.controls.entries()) {
    if (!control.role) continue;
    const snapshot = (await root.locator(selectors).nth(index).ariaSnapshot()).trim();
    // Each fixture leaf is one static text node or one named button.
    const text = /^- text: (.+)$/.exec(snapshot);
    const named = /^- ([\w-]+) ("(?:[^"\\]|\\.)*")(?: \[.*\])?$/.exec(snapshot);
    control.role = text ? "text" : named?.[1] ?? null;
    control.name = text?.[1] ?? (named ? JSON.parse(named[2]) : snapshot);
    if (control.pressed !== null) control.pressed = /\[pressed(?:=true)?\]/.test(snapshot);
  }
  fs.writeFileSync(stem + ".json", JSON.stringify(capture, null, 2));
  return capture;
}

export function compareObservations(dom: Capture, native: Capture, edgeTolerance: number): Mismatch[] {
  const mismatches: Mismatch[] = [];
  function compare(control: string, check: string, a: unknown, b: unknown) {
    if (JSON.stringify(a) !== JSON.stringify(b)) mismatches.push({ control, check, dom: a, native: b });
  }
  compare("panel", "width and scale", [dom.width, dom.scale], [native.width, native.scale]);
  compare(dom.focus || native.focus || "panel", "focus", dom.focus, native.focus);
  const webOrder = dom.controls.map(c => c.id), macOrder = native.controls.map(c => c.id);
  const longerOrder = webOrder.length > macOrder.length ? webOrder : macOrder;
  const orderIndex = longerOrder.findIndex((_, index) => webOrder[index] !== macOrder[index]);
  if (orderIndex >= 0)
    compare(webOrder[orderIndex] ?? macOrder[orderIndex], "control order", webOrder, macOrder);
  for (const web of dom.controls) {
    const mac = native.controls.find(c => c.id === web.id);
    if (!mac) continue;
    for (const field of ["role", "name", "pressed", "lines", "fill"] as const) {
      compare(web.id, field, web[field], mac[field]);
    }
    for (const [index, line] of web.lineFrames.entries()) {
      const other = mac.lineFrames[index];
      if (!other || line.some((value, coordinate) => Math.abs(value - other[coordinate]) > edgeTolerance)) {
        mismatches.push({ control: web.id, check: `line ${index + 1} frame and baseline`, dom: line, native: other });
      }
    }
    const edges = ([x, y, width, height]: Rect) => [x, y, x + width, y + height];
    const webEdges = edges(web.rect), macEdges = edges(mac.rect);
    for (const [index, edge] of ["left", "top", "right", "bottom"].entries()) {
      if (Math.abs(webEdges[index] - macEdges[index]) > edgeTolerance)
        mismatches.push({ control: web.id, check: edge, dom: webEdges[index], native: macEdges[index] });
    }
  }
  return mismatches;
}

export async function comparePaint(page: Page, dom: Capture, native: Capture, domPNG: string, nativePNG: string,
                                   diffPNG: string, policy: Policy) {
  const result = await page.evaluate(async ({ dom, native, files, policy }) => {
    const images = await Promise.all(files.map(async file => {
      const image = new Image();
      image.src = "data:image/png;base64," + file;
      await image.decode();
      return image;
    }));
    const width = Math.max(...images.map(img => img.width));
    const height = Math.max(...images.map(img => img.height));
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d", { colorSpace: "srgb", willReadFrequently: true })!;
    const [web, mac] = images.map(img => {
      context.clearRect(0, 0, width, height);
      context.drawImage(img, 0, 0);
      return context.getImageData(0, 0, width, height).data;
    });
    const highlight = context.createImageData(width, height);
    const changed = new Uint8Array(width * height);
    for (let pixel = 0; pixel < changed.length; pixel++) {
      const i = pixel * 4;
      changed[pixel] = Number([0, 1, 2, 3].some(k => Math.abs(web[i + k] - mac[i + k]) > policy.channelDelta));
      const pale = (channel: number) => Math.round((web[i + channel] + 255) / 2);
      highlight.data.set(changed[pixel] ? [255, 40, 40, 255] : [pale(0), pale(1), pale(2), 255], i);
    }
    context.putImageData(highlight, 0, 0);
    const solids: { control: string; host: string; expected: RGB; observed: number[] }[] = [];
    const fractions: Record<string, number> = {};
    for (const control of dom.controls) {
      const [x, y, w, h] = control.rect;
      const left = Math.floor(x * dom.scale), right = Math.min(width, Math.ceil((x + w) * dom.scale));
      const top = Math.floor(y * dom.scale), bottom = Math.min(height, Math.ceil((y + h) * dom.scale));
      let count = 0;
      for (let row = top; row < bottom; row++)
        for (let column = left; column < right; column++) count += changed[row * width + column];
      fractions[control.id] = count / ((right - left) * (bottom - top));
    }
    for (const [host, capture, pixels] of [["dom", dom, web], ["native", native, mac]] as const) {
      for (const control of capture.controls) {
        if (!control.fill) continue;
        const [x, y, w, h] = control.rect;
        // Bottom-right padding avoids text and focus outlines. Sample 4 device pixels.
        const right = Math.floor((x + w - 5) * capture.scale);
        const bottom = Math.floor((y + h - 5) * capture.scale);
        for (const [dx, dy] of [[0, 0], [1, 0], [0, 1], [1, 1]]) {
          const offset = ((bottom + dy) * width + right + dx) * 4;
          const observed = Array.from(pixels.slice(offset, offset + 4));
          if (observed[3] !== 255 || !control.fill.every((value, k) => Math.abs(value - observed[k]) <= policy.solidChannelDelta)) {
            solids.push({ control: control.id, host, expected: control.fill, observed });
            break;
          }
        }
      }
    }
    return { fractions, solids, sizes: images.map(img => [img.width, img.height]), diff: canvas.toDataURL("image/png") };
  }, {
    dom, native, policy, files: [domPNG, nativePNG].map(file => fs.readFileSync(file).toString("base64")),
  });
  fs.writeFileSync(diffPNG, Buffer.from(result.diff.split(",")[1], "base64"));
  const { diff, ...report } = result;
  return report;
}
