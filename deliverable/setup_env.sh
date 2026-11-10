#!/bin/bash
# Rebuilds the scratch environment under $TMPDIR (clone of the managed checkout merged with 37cb4114, WasmCodegen
# @316bbaf, WasmCompat @8df2164, capmap inputs). Usage: setup_env.sh CLONE
set -e
C=$1
UA="JuliaWASM-demos/0.1 (+https://github.com/JuliaWASM/demos)"
cd $TMPDIR
[ -d makie-merged ] || { git clone -q -s $C makie-merged; (cd makie-merged && git checkout -q e2f012445 && git fetch -q $C 37cb4114 2>/dev/null || true; git merge --no-edit -q 37cb4114); }
[ -d wc ] || { git -c http.userAgent="$UA" clone -q https://github.com/gbaraldi/WasmCodegen.jl wc; (cd wc && git checkout -q 316bbaf); }
[ -d capmap ] || { git -c http.userAgent="$UA" clone -q --depth 1 -b capmap-v1 https://github.com/asinghvi17-bot/makie-wasm-inputs capmap-inputs
  (cd capmap-inputs && [ "$(sha256sum capmap.tgz | cut -d' ' -f1)" = "$(cat capmap.tgz.sha256)" ] && mkdir -p ../capmap && tar xzf capmap.tgz -C ../capmap); }
mkdir -p env && cd env
cat > LocalPreferences.toml <<'P'
[Makie]
precompile_workload = false

[WGLMakie]
precompile_workload = false
P
