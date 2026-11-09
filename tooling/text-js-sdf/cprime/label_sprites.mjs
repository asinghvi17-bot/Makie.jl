// Route C': a label as a canvas-texture sprite inside WGLMakie's own WebGL scene, depth tested like any other 3D object.
// The label's pixels come from Canvas2D (`fillText`: the browser's fonts and shaping; no SDF, no glyph atlas, nothing for Julia to rasterize).
// The sprite is a quad drawn by a ShaderMaterial that uses the scene's own Makie camera uniforms (`scene.wgl_camera.projectionview`/`resolution`,
// the objects OrbitControls updates), so it follows the camera without a Julia round trip, is clipped by the same depth buffer
// as the meshes (one depth value per label: its anchor's, like Makie's own `markerspace = :pixel` text), and is part of the canvas,
// hence of `canvas.toDataURL` exports. One quad and one texture per label.
//   addCanvasLabel(WGL, { scene?, text, anchor: [x, y, z], fontsize (px), color, font, align: [-1..1, -1..1] })
export function addCanvasLabel(WGL, { scene = null, text, anchor, fontsize = 16, color = '#000', font = 'TeX Gyre Heros Makie', align = [0, 0], stroke = null, dpr = window.devicePixelRatio || 1 }) {
  const THREE = window.THREE;
  const three = scene ?? Object.values(WGL.scene_cache).find((s) => s.orbitcontrols && s.wgl_camera && s.screen)   // (the 3D scene: the one with a camera controller);
  const cv = document.createElement('canvas');
  const ctx = cv.getContext('2d');
  ctx.font = `${fontsize * dpr}px "${font}"`;
  const m = ctx.measureText(text);
  const padPx = 2 * dpr;
  const w = Math.ceil(m.width + 2 * padPx), asc = Math.ceil(m.fontBoundingBoxAscent), desc = Math.ceil(m.fontBoundingBoxDescent);
  cv.width = w; cv.height = asc + desc + 2 * Math.ceil(padPx);
  ctx.font = `${fontsize * dpr}px "${font}"`; ctx.textBaseline = 'alphabetic';
  if (stroke) { ctx.lineWidth = stroke.width * dpr; ctx.strokeStyle = stroke.color; ctx.lineJoin = 'round'; ctx.strokeText(text, padPx, asc + padPx); }
  ctx.fillStyle = color; ctx.fillText(text, padPx, asc + padPx);
  const tex = new THREE.CanvasTexture(cv);
  tex.minFilter = THREE.LinearFilter; tex.generateMipmaps = false;
  const material = new THREE.ShaderMaterial({
    uniforms: {
      projectionview: three.wgl_camera.projectionview,   // (shared with every other plot of the scene)
      resolution: three.wgl_camera.resolution,
      anchor: { value: new THREE.Vector3(...anchor) },
      size_px: { value: new THREE.Vector2(cv.width / dpr, cv.height / dpr) },
      offset_px: { value: new THREE.Vector2(-(align[0] + 1) / 2 * cv.width / dpr, -(align[1] + 1) / 2 * cv.height / dpr) },
      map: { value: tex },
    },
    vertexShader: `
      uniform mat4 projectionview; uniform vec2 resolution; uniform vec3 anchor; uniform vec2 size_px; uniform vec2 offset_px;
      varying vec2 vUv;
      void main() {
        vUv = uv;
        vec4 p = projectionview * vec4(anchor, 1.0);
        vec2 corner = position.xy + 0.5;                       // (the plane is -0.5..0.5)
        p.xy += (offset_px + corner * size_px) / resolution * 2.0 * p.w;
        gl_Position = p;
      }`,
    fragmentShader: `
      uniform sampler2D map; varying vec2 vUv;
      void main() { gl_FragColor = texture2D(map, vUv); if (gl_FragColor.a < 0.003) discard; }`,
    transparent: true, depthTest: true, depthWrite: false,
  });
  const mesh = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), material);
  mesh.frustumCulled = false;
  three.add(mesh);
  three.screen.request_render?.();
  return mesh;
}
