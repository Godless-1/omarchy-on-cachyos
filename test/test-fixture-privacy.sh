#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
python - <<'PY'
from pathlib import Path
import re
bad = []
for p in Path('test').glob('*.sh'):
    for line in p.read_text().splitlines():
        if re.match(r'^(LIVE|DEAD|MID|MIDF)=', line):
            value = line.split('=', 1)[1]
            if not re.fullmatch(r'([a-f0-9])\1{31}', value):
                bad.append(str(p))
if bad:
    raise SystemExit('Use visibly synthetic repeated-character identifiers in: ' + ', '.join(bad))
print('PASS machine-identifier fixtures are visibly synthetic')
PY
