// A signed-distance-field tile for Makie's glyph atlas, computed in JS so that a module compiled by WasmCodegen does not
// run the distance transform (about 0.7 s per glyph in the unoptimized wasm module, 34 ms natively; here a few ms).
//
// `edt` and `edt1d` are the squared-distance transform of @mapbox/tiny-sdf 2.3.0 (index.js), vendored under its license:
//
//   Copyright (c) 2016-2024 Mapbox, Inc.
//   BSD-2-Clause. Redistribution and use in source and binary forms, with or without modification, are permitted provided
//   that the following conditions are met: 1. Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer. 2. Redistributions in binary form must reproduce the above copyright
//   notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with
//   the distribution. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
//   IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
//   PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
//   INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//   SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
//   OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
//   OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//   (the full text is in LICENSE-tiny-sdf.txt next to this file)
//
// The rest (`sdfTile`) is this repository's: it reproduces Makie's `sdistancefield(img, downsample, pad)`
// (Makie/src/utilities/texture_atlas.jl) with the binary in/out classification Makie uses (coverage > 127.5, no
// tiny-sdf alpha heuristics): the exact squared Euclidean distance from every pixel to the nearest inside pixel and
// to the nearest outside pixel, sd = sqrt(outside) - sqrt(inside), averaged over downsample x downsample blocks and
// divided by `downsample`.

const INF = 1e20;

// 2D Euclidean squared distance transform by Felzenszwalb & Huttenlocher https://cs.brown.edu/~pff/papers/dt-final.pdf
function edt(data, x0, y0, width, height, gridSize, f, v, z, skipCols = 0) {
  for (let x = x0 + skipCols; x < x0 + width - skipCols; x++) edt1d(data, y0 * gridSize + x, gridSize, height, f, v, z);
  for (let y = y0; y < y0 + height; y++) edt1d(data, y * gridSize + x0, 1, width, f, v, z);
}

// 1D squared distance transform
function edt1d(grid, offset, stride, length, f, v, z) {
  v[0] = 0;
  z[0] = -INF;
  z[1] = INF;
  f[0] = grid[offset];

  for (let q = 1, k = 0; q < length; q++) {
    const fq = f[q] = grid[offset + q * stride];
    const q2 = q * q;
    let s;
    do {
      const r = v[k];
      s = (fq - f[r] + q2 - r * r) / (q - r) / 2;
    } while (s <= z[k] && --k > -1);

    k++;
    v[k] = q;
    z[k] = s;
    z[k + 1] = INF;
  }

  for (let q = 0, k = 0; q < length; q++) {
    while (z[k + 1] < q) k++;
    const r = v[k];
    const qr = q - r;
    grid[offset + q * stride] = f[r] + qr * qr;
  }
}

// Scratch space, reused between calls (a glyph tile is at most a few hundred pixels a side).
let scratch = { n: 0, side: 0, outer: null, inner: null, f: null, v: null, z: null };
function scratchFor(W, H) {
  const n = W * H, side = Math.max(W, H);
  if (scratch.n < n || scratch.side < side) {
    scratch = { n, side, outer: new Float64Array(n), inner: new Float64Array(n), f: new Float64Array(side), v: new Uint16Array(side), z: new Float64Array(side + 1) };
  }
  return scratch;
}

/**
 * Makie's `sdistancefield(img, downsample, pad)` for a coverage bitmap `bitmap` (row-major, `w` wide, `h` rows, top row
 * first, 8-bit coverage). Returns `{tw, th, data}`: the tile is `tw` x `th` (x fastest: the memory order of a Julia
 * `Matrix{Float32}(tw, th)`), `data` a Float32Array.
 * `downsample` and `pad` are the atlas's (5 and 12): the padding is in tile pixels, `pad * downsample` bitmap pixels per side.
 */
export function sdfTile(bitmap, w, h, downsample, pad) {
  const p = pad * downsample;
  const W = Math.ceil((w + 2 * p) / downsample) * downsample;     // (Makie's `dividable_size`)
  const H = Math.ceil((h + 2 * p) / downsample) * downsample;
  const tw = W / downsample, th = H / downsample;
  const { outer, inner, f, v, z } = scratchFor(W, H);
  const n = W * H;

  // outer: distance to the nearest inside pixel (0 on inside pixels); inner: to the nearest outside pixel (0 outside)
  outer.fill(INF, 0, n);
  inner.fill(0, 0, n);
  let anyInside = false;
  for (let y = 0; y < h; y++) {
    let j = (y + p) * W + p;
    for (let x = 0; x < w; x++, j++) {
      if (bitmap[y * w + x] > 127.5) { outer[j] = 0; inner[j] = INF; anyInside = true; }
    }
  }

  const out = new Float32Array(tw * th);
  if (!anyInside) {
    // (SignedDistanceFields.jl fills an image without inside pixels with its "upper bound" prod(size): a space becomes a tile of that value / downsample)
    out.fill(n / downsample);
    return { tw, th, data: out };
  }
  edt(outer, 0, 0, W, H, W, f, v, z);
  edt(inner, 0, 0, W, H, W, f, v, z);

  const div = downsample * downsample * downsample;   // (the block mean is /downsample^2, Makie then divides by downsample)
  for (let ty = 0; ty < th; ty++) {
    for (let tx = 0; tx < tw; tx++) {
      let sum = 0;
      for (let dy = 0; dy < downsample; dy++) {
        let j = (ty * downsample + dy) * W + tx * downsample;
        for (let dx = 0; dx < downsample; dx++, j++) sum += Math.sqrt(outer[j]) - Math.sqrt(inner[j]);
      }
      out[ty * tw + tx] = sum / div;
    }
  }
  return { tw, th, data: out };
}
