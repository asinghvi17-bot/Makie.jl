#!/bin/bash
# FIG=text|axis run_hosted.sh : native screenshot; then the B' screenshot (looping: Julia lists the host jobs it lacks, Chromium answers them with the WasmHost adapter, repeat)
# env: TJ = tooling/text-js-sdf, plus jenv.sh's (JULIA_DEPOT_PATH, PW_MODULE, PLAYWRIGHT_BROWSERS_PATH, WASMHOST_DIR, FONT_DIR), ENVDIR = the Julia project
set -e
cd "${WORK:-.}"
export HOST_TABLE=${HOST_TABLE:-table_$FIG.tsv} HOST_MISSING=missing_$FIG.txt
VARIANT=native julia --project=$ENVDIR $TJ/hosted/render_hosted.jl 2>&1 | grep -v "^ *\[" | tail -3
: > $HOST_TABLE
for i in 1 2 3 4; do
  VARIANT=bsdf julia --project=$ENVDIR $TJ/hosted/render_hosted.jl > pass_${FIG}_$i.log 2>&1 || { tail -20 pass_${FIG}_$i.log; exit 1; }
  grep "still missing" pass_${FIG}_$i.log
  grep -q "still missing: 0 " pass_${FIG}_$i.log && break
  node $TJ/browser/run_answer.mjs $HOST_MISSING $HOST_TABLE
done
