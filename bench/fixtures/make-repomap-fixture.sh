#!/usr/bin/env bash
#
# Build a synthetic multi-file JS repo for the quiet-repomap live A/B: one file
# (core/logger.js) is imported by 9 others and is unambiguously the most
# central module; everything else is a shallow leaf. Ground truth is fixed by
# construction, so the benchmark can grade exactly.
#
#   make-repomap-fixture.sh <target-dir>

set -euo pipefail
DIR="${1:?usage: make-repomap-fixture.sh <target-dir>}"
mkdir -p "$DIR/core" "$DIR/services" "$DIR/components" "$DIR/utils"
cd "$DIR"
git init -q

cat > core/logger.js <<'JS'
export function log(msg) { console.log('[log]', msg); }
export function warn(msg) { console.warn('[warn]', msg); }
JS

cat > core/config.js <<'JS'
export const CONFIG = { env: 'prod', region: 'us-east-1' };
JS

for name in auth billing notifications inventory shipping search reporting analytics; do
  cat > "services/${name}.js" <<JS
import { log } from '../core/logger';
export function ${name}Handler() { log('${name} handled'); return true; }
JS
done

cat > utils/format.js <<'JS'
import { log } from '../core/logger';
export function format(x) { log('formatting'); return String(x); }
JS

cat > components/Dashboard.js <<'JS'
import { authHandler } from '../services/auth';
import { billingHandler } from '../services/billing';
import { format } from '../utils/format';
export function Dashboard() { authHandler(); billingHandler(); return format('ok'); }
JS

cat > components/Settings.js <<'JS'
import { CONFIG } from '../core/config';
export function Settings() { return CONFIG.env; }
JS

git add -A && git commit -qm "fixture: synthetic app" >/dev/null
echo "fixture built at $DIR (ground truth: core/logger.js, in-degree 9)"
