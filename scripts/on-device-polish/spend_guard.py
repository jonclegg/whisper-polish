# Exits non-zero once OpenRouter usage passes a budget measured from a baseline.
#
# Usage: python spend_guard.py BASELINE_USD BUDGET_USD

import json
import sys
import urllib.request

import common

baseline, budget = float(sys.argv[1]), float(sys.argv[2])
request = urllib.request.Request("https://openrouter.ai/api/v1/key", headers={"Authorization": f"Bearer {common.openrouter_key()}"})
usage = json.load(urllib.request.urlopen(request))["data"]["usage"]
spent = usage - baseline
print(f"OpenRouter spent this round: ${spent:.2f} of ${budget:.2f}")
sys.exit(1 if spent > budget else 0)
