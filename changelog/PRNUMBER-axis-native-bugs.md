## Fixed

- Fixed `autolimits(ax)` with its default arguments, `reset_limits!(ax; xauto = false)` / `yauto = false` and the `Axis` limit fallbacks for missing or failing inverse transforms, which errored after the 0.25 compute-graph refactor.
