#!/bin/sh
# Native Linux smoke: add -> pause -> quit -> reopen -> resume -> complete -> delete.
# Both app launches share one throwaway XDG profile; nothing touches real user dirs.
set -eu
cd "$(dirname "$0")/.."
flutter=${FLUTTER:-flutter}
profile=$(mktemp -d)
trap 'rm -rf "$profile"' EXIT
export XDG_DATA_HOME="$profile/data" FLUX_SMOKE_DIR="$profile/downloads"
# Headless X server; keep GTK off the user's Wayland session.
export GDK_BACKEND=x11
unset WAYLAND_DISPLAY
for phase in pause resume; do
  xvfb-run -a -s '-screen 0 1600x1000x24' "$flutter" test \
    integration_test/linux_smoke_test.dart -d linux --dart-define=FLUX_PHASE=$phase
done
