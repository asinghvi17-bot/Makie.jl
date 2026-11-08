#!/bin/bash
# FIG=extras|scene3d ./run_all.sh : metrics loop, then native and C screenshots
set -e
./run_pass.sh
export TB=/home/factory/.factory/runners/personal/clones/140d0fdd-d7b4-4f4d-8783-448174a8910d/tooling/text-browser PW_MODULE=$TMPDIR/pw/node_modules/playwright/index.mjs PLAYWRIGHT_BROWSERS_PATH=$TMPDIR/pwbrowsers FONT_DIR=$TMPDIR/depot/artifacts/ad4e594b35357bcfafa2ed97db3137382a3f09bb/fonts
export JULIA_DEPOT_PATH="$TMPDIR/depot:$JULIA_DEPOT_PATH"
for v in native c; do VARIANT=$v timeout 270 julia --project=$TMPDIR/env serve_and_shoot.jl 2>&1 | grep -v "^ *\[" | tail -4; done
