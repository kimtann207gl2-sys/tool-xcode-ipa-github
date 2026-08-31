#!/usr/bin/env bash
# Export tool/build-config.json fields as shell env vars (used by GitHub Actions).
set -euo pipefail

CONFIG="${1:-tool/build-config.json}"
if [[ ! -f "$CONFIG" ]]; then
  echo "Missing $CONFIG — run run.ps1 locally first."
  exit 1
fi

read_config() {
  python3 - "$CONFIG" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8-sig") as f:
    cfg = json.load(f)
print(cfg[sys.argv[2]])
PY
}

read_config_optional() {
  python3 - "$CONFIG" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8-sig") as f:
    cfg = json.load(f)
print(cfg.get(sys.argv[2], ""))
PY
}

GITHUB_ENV="${GITHUB_ENV:-}"
write_env() {
  local key="$1" val="$2"
  export "$key=$val"
  if [[ -n "$GITHUB_ENV" ]]; then
    echo "$key=$val" >> "$GITHUB_ENV"
  fi
}

write_env XCODE_ZIP "$(read_config xcodeZip)"
write_env XCODE_SRC "$(read_config xcodeSrc)"
write_env XCODE_PROJECT "$(read_config xcodeProject)"
write_env SCHEME "$(read_config scheme)"
write_env APP_NAME "$(read_config appName)"
write_env OUTPUT_IPA "Xcode-Output/$(read_config outputIpa)"
write_env ARTIFACT_NAME "$(read_config artifactName)"
write_env XCODE_ZIP_URL "$(read_config_optional xcodeZipUrl)"
write_env XCODE_ZIP_RELEASE "$(read_config_optional xcodeZipRelease)"

echo "Loaded build config from $CONFIG"
echo "  XCODE_SRC=$XCODE_SRC"
echo "  APP_NAME=$APP_NAME"
