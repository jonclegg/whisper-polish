#!/bin/bash
# On the instance: run.sh LABEL [VAR=value ...] — benches dev (day-one, one-year) and the typing simulation.
# SPLIT=test scores the test split instead. Prints one line per result.
cd /work
label=$1; shift
for set in day-one one-year; do
  file=data/swift-${SPLIT:-bench}-$set.json
  env "$@" KEYBOARD_BENCH=$file swift test -c release --skip-build --filter PredictionBenchmarkTests 2>&1 | grep -o 'BENCH.*' | sed "s/^/$label $set /"
done
if [ -n "$TYPING" ]; then
  env "$@" KEYBOARD_BENCH=data/swift-${SPLIT:-bench}-day-one.json KEYBOARD_TYPING_LIMIT=${TYPING_LIMIT:-300} swift test -c release --skip-build --filter TypingSimulationTests 2>&1 | grep -o 'TYPING.*' | sed "s/^/$label /"
fi
