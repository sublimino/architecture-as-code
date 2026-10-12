#!/usr/bin/env bash
# Throwaway: build a realistic appliance archive offline, with the helper
# actually staged, so the airgap suite has something to inspect. Not committed.
#
# cp -a, never cp -al: a hardlinked tree shares inodes and a build writing in
# place through a hardlink corrupts the source it came from.
set -Eeuo pipefail
# This file lives in test/helpers/, so the repository root is two levels up.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W=/tmp/airgap-fx
rm -rf "$W"; mkdir -p "$W"
cp -a "$REPO/bundle" "$W/bundle"

# Stage the helper for both arches into the copy (no network: it is built).
"$REPO/scripts/package-tenant-bundle.sh" --only ed25519-keygen --arch all \
  --bundle-dir "$W/bundle" > "$W/stage.log" 2>&1 || true
ls -l "$W/bundle/bin/amd64/" | sed 's/^/  /'

set +e
SLSI_CRANE_BIN="$REPO/test/helpers/slsi-bundle-fake-crane.bash" \
  SLSI_BUNDLE_OUT="$W/dist" \
  bash "$REPO/test/helpers/slsi-bundle-build-driver.bash" \
  "$REPO" "$W/bundle" stage_osd_1_first_party_images stage_p1_3_manifest \
  > "$W/build.log" 2>&1
rc=$?
set -e
echo "build rc=${rc}"
tail -n 3 "$W/build.log"
ls -l "$W/dist" | sed 's/^/  /'
echo "--- archive bin members ---"
tar -tzf "$W/dist/slsi-appliance-0.1.0.tar.gz" | grep '^bin/' | sed 's/^/  /'
echo "--- archive bin/checksums.txt ---"
tar -xzOf "$W/dist/slsi-appliance-0.1.0.tar.gz" bin/checksums.txt | sed 's/^/  /'
