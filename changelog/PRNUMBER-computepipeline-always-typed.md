## Changed

- ComputePipeline's invalid-result errors are now `InvalidResultTypesError`, `ResultLengthMismatchError` and `InvalidResultError` (formatted when shown), and its deprecation warnings format the callback location only when printed. This keeps reflection out of the resolve path for ahead-of-time compilation (`juliac --trim`).
