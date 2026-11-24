# Redline

**Your whole Mac on one tuner-style dashboard.** A small needle in the menu bar: click it and a gauge cluster shows what the whole machine is doing. Two drive modes like a hybrid car: **NOS** puts the Mac at full power, **ECO** saves every bit of battery.

<p><img src="preview/look_vapor.png" width="460" alt="The Redline card with the engine running in the Vapor look: three dials, a column per CPU core, tiles for power, battery, thermals, network, disk and connected devices"></p>

**Push to start.** When the Mac starts, it starts exactly as Apple made it. Redline opens the moment you log in, and a start button appears. Press it and the engine turns over: the needles and the Touch Bar rev together, two blips and then the redline, and your look, lights, fans and custom Touch Bar take over. Switch the engine off and the Mac is back to its own defaults.

<p><img src="preview/start_gate.png" width="230" alt="The push-to-start window: a metal ENGINE START STOP button inside a ring of tick marks"> <img src="preview/panel_off.png" width="230" alt="The card with the engine off: gauges dimmed behind the start button"></p>
<p><img src="preview/touchbar/rev.png" width="700" alt="Four photos of the Touch Bar during an engine start: a first blip, a higher rev, everything at the redline, then running normally"></p>

## Why I built it

To know what my Mac is doing I had to open Activity Monitor and click through five tabs of tables. Power from the charger, what each USB device asks for, temperatures and fan speed are not in there at all.

I wanted one click instead of a hunt. And I wanted it to be fun: a dashboard like the gauge cluster of a tuned import car, calm and satisfying to look at.

I decide what it should do and test it; an AI coding assistant (Claude Code) writes the code.

Copyright (c) 2026 Ali Razavi. All rights reserved. See `LICENSE`.

## What it shows

- **CPU Last** (big tachometer), **GPU Last** and **Memory** dials, each with an amber dot marking the peak since you opened the card
- Shift lights and a gear indicator that follow CPU load; one LED column per CPU core; the busiest app right now
- **Power in**, **System draw** (whole Mac, plus CPU and GPU watts), **Thermals** (temperatures and fan speed)
- **Battery** as ten cells: plugged in they are calm green, and while charging the next cell breathes and a soft sheen glides across the charge; on battery they stand still, and at 15 % or less they turn red and the last cells blink. The label says CHARGING, PLUGGED IN (with the drain if the charger cannot keep up) or the watts on battery; battery health is in the tooltip.
- **Network** down and up with Wi-Fi signal and link rate; **Disk** read and write
- **Records**: all-time highs for CPU temperature, power draw and download speed (click to reset)
- **Connected**: every external USB device with its speed and requested current, Bluetooth devices such as AirPods with their battery levels, the charger, and a small top view of the laptop where the sockets in use glow (green = device, amber = charger).
- A red THROTTLED badge when macOS slows the CPU down because of heat

## Using it

- Click the needle in the menu bar to open the card.
- **Engine**: with the engine off the Mac is exactly as Apple made it (Apple's Touch Bar, macOS fans, normal sleep). Starting it brings back your last look, VIBE, NOS, fans and the Touch Bar. The power button in the card's header switches it off.
- **START · AUTO / PUSH** (footer): AUTO starts the engine by itself when Redline loads, with no rev. PUSH (default) shows a push-to-start window instead; pressing it revs the needles and the Touch Bar (two blips, then the redline) and switches everything on. The rev happens only then, never when the card is merely opened.
- At log-in Redline starts straight away, with no waiting.
- Drag the card by its background to move it. It has one fixed size.
- Click anywhere outside the card, or press Esc, to close it.
- **VIBE**: club lighting behind the dials, driven by whatever the Mac is playing: waves, a glow behind each dial, rings off the big dial on every kick, a strobe, and mirrored sparks that are released on the beat and rise higher when the music lifts. It listens only while the card is open and VIBE is on; the sound is not changed, stored or sent anywhere. With VIBE off the light show stops and only the waves keep rolling, low and slow, in the look's colours.
- **Underglow**: eight looks, each its own lighting rig. Ice · CDJ (waves, a jog-wheel ring turning at 33 1/3 rpm, a few beams), Nitrous · Laser (a sweeping fan of beams and a strobe), Toxic · Radar (a radar sweep and rings from all three dials), Sunset · Sunrise (a striped sun behind the big dial), Vapor · Grid (a neon floor grid rushing towards you under a horizon), Galaxy · Warp (stars streaking outwards and a tunnel of rings), Prism · Spectrum (a rainbow band turning round the big dial), Mono · Scope (the actual sound wave as one mirrored white line on a graticule).
- **NOS**: full power, nothing spent on looks. Low Power Mode off; screen and keyboard light at maximum and held there (automatic brightness, dim-on-battery and the keyboard light's idle fade can never pull them down); fans at maximum; the Mac and its screen kept awake (no display sleep, no idle or system sleep, no screensaver); App Nap off, so apps opened from then on are never slowed down in the background. The Mac is dressed in NOS red: red accent and highlight colour, and your own wallpaper recoloured into NOS reds. Going in, a red-hot line sweeps up the card, the desktop and the Touch Bar at the same moment, a shockwave leaves the big dial and the needles slam to the redline; going out, the line wipes back down to your colours. After that nothing moves: no lights, no music listening, a still red card and a still red Touch Bar. Redline notes how everything was first and puts it all back when NOS goes off or Redline quits (even after a crash, at the next start), including live wallpapers such as Apple's Sequoia. Closing the lid on battery still sleeps the Mac. If the separate Coffee Mode app is also installed, Redline keeps its switch and running cup in step and follows it when you flip the switch there; neither app needs the other. `kill -USR2 $(pgrep -x Redline)` flips NOS from a script. Redline makes no sounds.
  Not possible from an app: overclocking (this Intel CPU is locked; Turbo Boost is already on and maximum fans let it stay there longer), macOS "Reduce transparency" (protected by macOS), and the browsers' own Energy Saver and Memory Saver (switch those off in Chrome or Brave under Settings > Performance).
- **ECO**: the opposite of NOS, like a hybrid's eco mode, for reading in bed on battery: macOS Low Power Mode on, Bluetooth off, screen at 15 %, keyboard light off, fans back to macOS, Redline's lights and music listening off with slower readings, and Apple's own Touch Bar back, as if Redline were off. Redline notes how everything was first and puts it all back when ECO goes off or Redline quits (even after a crash, at the next start). Low Power Mode that was already on (for example from AlDente) stays on. NOS and ECO switch each other off. Low Power Mode uses the same small helper as the fans. macOS asks once for the Bluetooth permission. `kill -INFO $(pgrep -x Redline)` flips ECO from a script.
- **Touch Bar**: it follows these switches. It always wears the underglow you picked; VIBE off = standing still, VIBE on = moving with the music; NOS = still NOS red; ECO = Apple's own bar until ECO goes off. The two parts talk only on this Mac (a saved setting and a local notification).

## Fans

The **FANS** switch in the footer has two positions: **AUTO** (macOS decides) and **MAX** (both fans at their own rated maximum, the figure the Mac itself reports: 5,927 and 5,489 rpm on this MacBook Pro). NOS always holds the fans at MAX and greys the switch out; when NOS goes off, the fans return to whatever you had chosen.

Changing fan speed needs administrator rights, so that one job is done by a separate helper, `src/fan.c`, about a hundred lines, which understands only `status`, `max`, `auto` and `lowpower on|off` (Low Power Mode for NOS and ECO). It can never set a speed below what macOS would choose, checks that its setting took, and hands the fan back to macOS if it did not. It is installed once by clicking the switch (it reads SET UP until then), which opens a Terminal window that asks for your Mac password. `Remove fan control.command` inside the app's Resources folder removes it again.

Redline returns the fans to automatic when it quits, and re-applies your choice after the Mac wakes from sleep. Do not run another fan tool (such as Macs Fan Control) at the same time: the two would fight over the fans.

## Touch Bar

The Touch Bar part (it shows up as Glowstrip in Activity Monitor and in the Accessibility list) lives inside Redline.app; there is no second app to install. On a Mac with a Touch Bar, Redline starts it and stops it again when Redline quits, which brings Apple's own bar straight back. On a Mac without a Touch Bar it never starts and nothing else changes. While NOS is on, the underglow dots are greyed out and locked; the one you had picked stays faintly marked and returns when NOS goes off.

- Same controls as Apple's strip: `ESC` · sleep · lock · keyboard light · screen brightness · Night Shift · previous / play-pause / next · volume · mute · show desktop · app controls. Each gauge has a down and an up button (one tap is one notch, holding keeps stepping); a touch alone never jumps the level.
- The last tile (four squares) steps aside to Apple's bar with the controls of the app in front; the small speedometer in Apple's strip brings the Redline bar back.
- **Esc needs one switch**: only Apple's own bar can show the real Esc key, so this one presses Esc for you, which macOS allows only with System Settings > Privacy & Security > Accessibility > Glowstrip switched on. Until then, tapping ESC steps aside to Apple's bar. The build only recompiles this part when `src/touchbar.swift` changed, because a recompiled copy counts as a new app and the switch must then be turned off and on again.
- `defaults write local.redline touchBar -bool false` keeps Apple's bar for good. `touchbar-backup/original 2026-11-22/Restore original Touch Bar.command` does that and restores the button layout as it was before.
- Handy: `kill -USR1 $(pgrep -x Glowstrip)` flips between the two bars; `screencapture -b file.png` photographs the Touch Bar; pictures of every look are in `preview/touchbar/`.

## Limits

- USB current is what each device *requests*, not a live measurement. macOS does not measure it.
- There is no live GHz reading. On this Intel Mac that needs a kernel driver, which Redline does not install. CPU package watts and the speed limit are shown instead.
- Sensor names are those of an Intel MacBook Pro (2018/2019). On other Macs some tiles may show `--`.

## Privacy

Everything is read locally from macOS. Redline makes no network connections, has no update channel, no telemetry and no licence check.

## Build

```
./build.sh
```

Needs only the Swift command line tools. It builds `src/main.swift` and the Touch Bar part (`src/touchbar.swift`), writes preview pictures to `preview/`, and installs `/Applications/Redline.app`.

`./build/Redline --probe` prints the raw sensor readings.
