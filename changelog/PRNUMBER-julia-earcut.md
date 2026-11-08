## Changed

- `poly` (and so `barplot`, `hist`, `pie`) triangulates polygons with `Makie.earcut_triangulate`, a pure Julia port of mapbox's earcut, instead of calling `libearcut` through `GeometryBasics.earcut_triangulate`, so that these plots compile ahead of time (`juliac --trim`, Wasm). It returns the same triangles in the same order as `libearcut`.
