#!/usr/bin/env bash
# Regressionstests fuer das evcc-Projekt.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project="$(dirname "$here")"

echo "== Python-Syntax =="
python3 -m py_compile "$project/update-trial-token.py"
echo "ok"

echo
echo "== Hilfetext =="
python3 "$project/update-trial-token.py" --help >/dev/null
echo "ok"

echo
echo "== Funktionstests =="
python3 "$here/test_update_trial_token.py"
