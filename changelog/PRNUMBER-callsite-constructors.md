## Added

- Added `Makie.CallsiteConstructors` and the hooks `Makie.construction_types` and `Makie.validated_keys`, which let a build tool give plot construction the concrete types of the plot call sites of a program (found by compiler inference), for ahead-of-time compilation (`juliac --trim`, WebAssembly). Native behaviour is unchanged unless `generate!` is called.

## Changed

- `register_computation!` errors for outputs which already have a parent edge are formatted when shown (`ComputePipeline.SameComputationError`) instead of where they are raised. The messages are unchanged.
