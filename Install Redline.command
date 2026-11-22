#!/bin/zsh
# Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
# Builds and installs Redline. If this Mac has a Touch Bar and the Glowstrip folder sits next to this one,
# it installs the Touch Bar companion too. On a Mac without a Touch Bar that part is simply skipped.
set -e
cd "$(dirname "$0")"
./build.sh
if [ "$(./build/Redline --hasbar)" = "yes" ] && [ -x "../Glowstrip/build.sh" ]; then
  echo "Touch Bar found: installing Glowstrip as well."
  ../Glowstrip/build.sh
else
  echo "No Touch Bar on this Mac (or no Glowstrip folder): installing Redline only."
fi
open "/Applications/Redline.app"
echo "Done. Look for the small needle in the menu bar."
