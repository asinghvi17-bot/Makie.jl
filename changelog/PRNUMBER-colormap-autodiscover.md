## Added

- Added `Makie.record_colormaps(f)`, which runs `f()` and returns the sorted names of the colormaps that were looked up while it ran, including those of the plots it made (whose colors are computed lazily). `Makie.set_static_colormaps!(Makie.record_colormaps(build_figures))` chooses the `static_colormaps` of a program compiled ahead of time without listing them by hand. With the preference set, missing colormaps are recorded too.
