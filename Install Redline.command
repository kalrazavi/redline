#!/bin/zsh
# Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
# Builds and installs Redline. The Touch Bar part is inside Redline.app; on a Mac without a Touch Bar it simply never starts.
set -e
cd "$(dirname "$0")"
./build.sh
open "/Applications/Redline.app"
echo "Done. Look for the small needle in the menu bar."
