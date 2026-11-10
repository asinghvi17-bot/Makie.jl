## Added

- Added the opt-in `ComputePipeline.StaticDispatch.install!(graphs...; inputs, outputs)`, which makes the update/resolve path of already built compute graphs statically dispatchable for ahead-of-time compilation (`juliac --trim`, WebAssembly). `StaticDispatch.track_graphs!()` records the graphs built afterwards so `install!` can find graphs connected only through `get_observable!` Observables. Native behaviour is unchanged unless these are called.
