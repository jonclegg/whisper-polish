#!/bin/bash
# Copies the keyboard lab's results off the phone and prints a summary of each step.
cd "$(dirname "$0")"
xcrun devicectl device copy from --device 00008150-001A54642284401C --domain-type appDataContainer \
  --domain-identifier com.jonclegg.WhisperPolish --source Documents/lab-results.jsonl \
  --destination data/phone/${1:-survey}-results.jsonl > /dev/null 2>&1 || { echo "no results yet"; exit 0; }
python3 -c "
import json, sys
for line in open('data/phone/${1:-survey}-results.jsonl'):
    d = json.loads(line); d.pop('trace', None)
    outputs = d.pop('outputs', None)
    print(json.dumps(d)[:700])
    for o in outputs or []: print('    ', json.dumps({k: v for k, v in o.items() if k != 'output'})[:300], '|', str(o.get('output', o.get('error','')))[:120].replace(chr(10), ' '))
"
