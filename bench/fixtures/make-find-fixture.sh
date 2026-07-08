#!/usr/bin/env bash
# Creates a fixture dir with ~200 .sh files across 5 directories.
# Usage: bash bench/fixtures/make-find-fixture.sh /path/to/target
set -euo pipefail
TARGET="${1:?pass target dir}"
for d in alpha beta gamma delta epsilon; do
  mkdir -p "$TARGET/$d"
  for i in $(seq 1 40); do
    echo "#!/usr/bin/env bash" > "$TARGET/$d/script${i}.sh"
  done
done
echo "fixture: 200 .sh files in 5 dirs under $TARGET" >&2
