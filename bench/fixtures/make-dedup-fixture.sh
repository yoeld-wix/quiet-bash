#!/usr/bin/env bash
# Creates a large (~400-line) config file that an agent will read twice
set -euo pipefail
DIR="${1:-$(mktemp -d)}"
mkdir -p "$DIR"

# Generate a large config.sh with 400 lines of KEY=value pairs
{
  echo "#!/usr/bin/env bash"
  echo "# App configuration — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for i in $(seq 1 100); do
    echo "APP_CONFIG_${i}=\"value_${i}_$(openssl rand -hex 4 2>/dev/null || echo deadbeef)\""
  done
  echo ""
  echo "# Database settings"
  for i in $(seq 1 100); do
    echo "DB_SETTING_${i}=\"db_value_${i}\""
  done
  echo ""
  echo "# Feature flags"
  for i in $(seq 1 100); do
    echo "FEATURE_FLAG_${i}=$(( i % 2 ))"
  done
  echo ""
  echo "# API endpoints"
  for i in $(seq 1 100); do
    echo "API_ENDPOINT_${i}=\"https://api.example.com/v${i}\""
  done
  echo "# TARGET_VERSION=42"
} > "$DIR/config.sh"

echo "$DIR"
