#!/bin/bash
# Copies the keyboard's prediction code and tests from a worktree into this
# package, so the prediction benchmarks run on a Linux box instead of a laptop:
#   scripts/keyboard-bench-linux/sync.sh .        (then copy this folder to the box)
#   docker run -it -v $PWD:/work -w /work swift:6.2-noble bash
#     apt-get update && apt-get install -y wamerican    (stands in for Apple's spell checker)
#     swift build -c release --build-tests
#     /work/run.sh LABEL [VAR=value ...]                (bench files go in data/)
set -euo pipefail
W=$1; P=$(cd "$(dirname "$0")" && pwd)
mkdir -p $P/Tests/Bench $P/Tests/WhisperPolishKeyboard && rm -f $P/Tests/Bench/*.swift
for f in Lexicon Predictor PersonalModel TypingContext TouchDecoder KeyLayout WordModel HostTextTracker; do
  sed '/^import UIKit$/d' $W/WhisperPolishKeyboard/$f.swift > $P/Tests/Bench/$f.swift
done
for f in $W/WhisperPolishKeyboard/ContextMemory.swift; do [ -f $f ] && cp $f $P/Tests/Bench/; done
for t in KeyboardTestSupport KeyboardCasingTests PredictionBenchmarkTests TypingSimulationTests KeyboardPerformanceTests KeyboardPredictorTests KeyboardTouchDecoderTests KeyboardLearnedWordsTests HostTextTrackerTests ContextMemoryTests; do
  [ -f $W/Tests/$t.swift ] && cp $W/Tests/$t.swift $P/Tests/Bench/
done
cp $P/UIKitShim.swift $P/Tests/Bench/
rsync -a --delete $W/WhisperPolishKeyboard/Lexicon/ $P/Tests/WhisperPolishKeyboard/Lexicon/
# Linux XCTest can't discover @MainActor test classes, and nothing here needs the main actor.
sed -i.bak '/^@MainActor$/d' $P/Tests/Bench/*.swift && rm $P/Tests/Bench/*.bak
