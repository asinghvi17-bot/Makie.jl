## Changed

- ComputePipeline's invalid-result errors are now `InvalidResultTypesError`, `ResultLengthMismatchError` and `InvalidResultError` (same messages, formatted when shown), and its deprecation warnings format the callback location only when printed. This keeps reflection out of the resolve path for ahead-of-time compilation (`juliac --trim`).

## Fixed

- Fixed a `MethodError` instead of the intended error message when a ComputePipeline callback returns a tuple of the wrong length on a later update.
