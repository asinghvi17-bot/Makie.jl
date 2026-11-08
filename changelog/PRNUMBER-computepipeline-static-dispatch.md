## Added

- Added the opt-in `ComputePipeline.StaticDispatch.install!(graphs...; inputs, outputs)`, which makes the update/resolve path of already built compute graphs statically dispatchable for ahead-of-time compilation (`juliac --trim`, WebAssembly). Native behaviour is unchanged unless it is called.
