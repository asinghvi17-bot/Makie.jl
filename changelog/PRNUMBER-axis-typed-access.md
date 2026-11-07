## Changed

- `Axis` limit code now reads its attributes with their documented types, so the limit pipeline is inferable for ahead-of-time compilation (`juliac --trim`). `autolimitaspect` is now typed `Union{Nothing, Float64}`, so `autolimitaspect = 1` reads back as `1.0`.
