#!/bin/zsh
# Copyright (c) 2026 Ali Razavi. All rights reserved. Owned and controlled solely by Ali Razavi: no licence check, no remote control, no backdoor. Terms: see the LICENSE file.
# Puts the Touch Bar back exactly as it was on 22 Nov 2026: stops the Touch Bar part of Redline and restores Apple's saved button layout.
cd "$(dirname "$0")"
defaults write local.redline touchBar -bool false   # Redline no longer starts its Touch Bar part; delete this setting to get it back
pkill -x Glowstrip 2>/dev/null
defaults import com.apple.controlstrip com.apple.controlstrip.plist
defaults import com.apple.touchbar.agent com.apple.touchbar.agent.plist
killall ControlStrip 2>/dev/null
echo "Touch Bar restored to the original. You can close this window."
