## Changed

- Converting meshes for `mesh`, `poly` (and so `barplot`, `hist`, `pie`) now gives meshes of concrete types, so these conversions are inferable for ahead-of-time compilation (`juliac --trim`). An empty vector of meshes of a concrete type converts to an empty mesh of the type that non-empty vectors of it convert to (was `Mesh{N, Float32}`). The dim conversion of an empty `Vector{<:VecTypes}` is now empty with the element type of the components of its points (was `Float64`).
