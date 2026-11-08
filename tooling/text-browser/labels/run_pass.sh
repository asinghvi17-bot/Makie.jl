#!/bin/bash
# two-pass metrics loop: native layout (browser metrics from metrics.tsv, FreeType for what is missing) -> missing.tsv -> the browser measures -> repeat until nothing is missing
set -e
export TB=/home/factory/.factory/runners/personal/clones/140d0fdd-d7b4-4f4d-8783-448174a8910d/tooling/text-browser
export PW_MODULE=$TMPDIR/pw/node_modules/playwright/index.mjs PLAYWRIGHT_BROWSERS_PATH=$TMPDIR/pwbrowsers FONT_DIR=$TMPDIR/depot/artifacts/ad4e594b35357bcfafa2ed97db3137382a3f09bb/fonts
export JULIA_DEPOT_PATH="$TMPDIR/depot:$JULIA_DEPOT_PATH"
for i in 1 2 3; do
  FALLBACK=1 julia --project=$TMPDIR/env labels_pass.jl > pass$i.log 2>&1
  n=$(grep "still missing" pass$i.log | awk '{print $3}')
  echo "pass $i: missing $n"
  [ "$n" = "0" ] && break
  node $TB/labels/measure.mjs missing.tsv metrics.tsv
done
