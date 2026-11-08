// The two label renderers of option C, one label list (BrowserLabels.labels_json): a DOM overlay and a Canvas2D layer, both put
// over the WebGL canvas. Positions are window pixels (y down), the first baseline's left end; the angle is Makie's (counter-clockwise).
const css = (c) => `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${c[3]})`;
const fontOf = (l) => `${l.style ? l.style + ' ' : ''}${l.size}px "${l.family}"`;

/** DOM overlay: one absolutely positioned element per line, rotated about its baseline's left end. */
export function mountDomOverlay(host, data) {
  const root = document.createElement('div');
  root.style.cssText = 'position:absolute;inset:0;overflow:hidden;pointer-events:none;';
  for (const l of data.labels) {
    const el = document.createElement('div');
    const asc = l.ascender * l.size, content = (l.ascender - l.descender) * l.size;
    // line-height = the font's content area: no half-leading, so the baseline is `asc` below the top of the box
    el.style.cssText = `position:absolute;left:${l.x}px;top:${l.y - asc}px;white-space:pre;font:${fontOf(l)};line-height:${content}px;color:${css(l.color)};` +
      `transform-origin:0 ${asc}px;transform:rotate(${-l.angle}rad);`;
    el.textContent = l.text;
    root.appendChild(el);
  }
  host.appendChild(root);
  return root;
}

/** Canvas2D layer: `fillText` at the baseline, rotated. Device-pixel aware. */
export function mountCanvasLayer(host, data, dpr = window.devicePixelRatio || 1) {
  const cv = document.createElement('canvas');
  cv.width = Math.round(data.width * dpr); cv.height = Math.round(data.height * dpr);
  cv.style.cssText = `position:absolute;left:0;top:0;width:${data.width}px;height:${data.height}px;pointer-events:none;`;
  const ctx = cv.getContext('2d');
  ctx.scale(dpr, dpr);
  ctx.textBaseline = 'alphabetic'; ctx.textAlign = 'left';
  for (const l of data.labels) {
    ctx.save();
    ctx.translate(l.x, l.y); ctx.rotate(-l.angle);
    ctx.font = fontOf(l); ctx.fillStyle = css(l.color);
    ctx.fillText(l.text, 0, 0);
    ctx.restore();
  }
  host.appendChild(cv);
  return cv;
}
