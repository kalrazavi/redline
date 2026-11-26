# Changelog

Every version of Redline and every bug I found and had fixed. Nothing here worked perfectly out of the box: I used each build, found what was wrong, worked out what it should do instead, and had it fixed. Each fix lists what I noticed, why it happened, and what changed.

Dates are when the change went live. Commit IDs link each entry to the code.

---

## v1.8 · 24 Nov 2026 · NOS: full power, nothing spent on looks, and a battery you can read at a glance
`9bd57d8`, `49faaf5`, `2862514`, `99b917e`, `74b4e34`, `00db9d6`

### Changed
- **NOS is now a real performance mode**, not just keep-awake with a light show. What I asked for: everything as fast as possible and never in a battery-saving state, but no energy wasted on making things pretty.
  - Low Power Mode off; screen and keyboard light at maximum.
  - **Never dims.** macOS's automatic brightness, dim-on-battery and the keyboard light's idle fade kept pulling the levels down, so NOS puts them back to maximum every couple of seconds. Tested: forced the screen to 30 %, back at 100 % within seconds.
  - App Nap off, so apps opened during NOS are never slowed down in the background.
  - Fans at maximum and the Mac kept awake, as before.
  - **No more light show.** The overdrive beams, strobe, sparks, heartbeat and flash cost 20-30 % CPU with the card open. NOS is now still: plain red card, red Touch Bar with no blinking or runner lights, no music listening.
  - **The whole Mac in NOS red:** red accent and highlight colour, and my own blue Sequoia wallpaper recoloured into NOS reds (same shapes and light rays, dark reds to hot red).
  - **Works with any wallpaper.** The red version is made by Redline itself from whatever wallpaper is on the Mac, and made again when the wallpaper changes. It photographs only macOS's wallpaper window, so desktop icons, open windows and the menu bar never end up in it. The first red picture had been made by hand from a screenshot, so on any other Mac (or after a new wallpaper) NOS would have had no red wallpaper or the wrong one; it also had a dark strip at the top where the menu bar had been.
  - **Tested with a second wallpaper (Sonoma):** Redline made a red Sonoma by itself within half a minute, NOS swapped to it and back, and switching back to Sequoia gave a red Sequoia again.
- **A wallpaper picked right after NOS could be overwritten.**
  Noticed: while testing with another wallpaper.
  Cause: after NOS, a still copy of the wallpaper stands in until the screen next sleeps, and then the saved live one is put back. A wallpaper picked in between would have been replaced by the old one.
  Fix: Redline now checks whether its own picture is still on the desktop. If you picked something else, your choice is kept and the old one is forgotten.
  - Everything is put back when NOS goes off, when Redline quits, or at the next start after a crash.
  - **Going in and out of NOS is animated**, on the card, the desktop and the Touch Bar at the same moment: in, a red-hot line sweeps up and the red fills in behind it, a shockwave leaves the big dial and the needles slam to the redline; out, the line wipes back down to the normal colours.
- **The battery tile is ten cells.** Plugged in they are calm green; while charging the next cell breathes and a soft sheen glides across the charge. On battery they stand still, and at 15 % or less they turn red and the last cells blink. The preview pictures show the cells too.
- **With VIBE off nothing moves behind the dials.** The slow waves that rolled there are gone: plain dark card, and the light show only with VIBE on. (The open card still uses about 15 % CPU with the engine on; that is the needles and numbers being redrawn every second, not the waves.)
- The admin helper's Low Power Mode switch is used by NOS too (to switch it off).
- **Engine off now really is off.** What I asked for: while Redline is loaded but not pushed on, it should cost as good as nothing, and every dial should be off.
  Noticed: with the engine off Redline still sat at about 12 % CPU, and the gauges kept reading in the background.
  Cause: the breathing ring around the start button was a SwiftUI animation that redrew 60 times a second for as long as the button was on screen; and the readings, the wallpaper check and the 30-a-second light timer never stopped with the engine.
  Fix: the ring is now one layer animated by macOS itself; with the engine off nothing is read at all, no timer runs, the wallpaper pictures are dropped from memory, every dial, light and graph sits at rest and the menu bar needle is parked. Measured with the engine off: 0.0 % CPU with the card closed or open (was about 12 %), about 24 MB after a fresh start (was about 40). With the engine on, the light timer also stops during NOS and ECO, where nothing moves anyway.
- **FANS works with the engine off.** Pressing it there holds both fans at maximum until I press it again or start the engine; it does not change my saved fan setting, and starting the engine goes back to that setting. If the Mac sleeps, the fans are put back to maximum after it wakes. Tested: maximum (5946 and 5446 rpm) and back to automatic, both with the engine off.
- **The connected list is no longer looked up every 10 seconds.** That started two system tools each time. Now it is looked up when the engine starts, when the card opens, the moment something is plugged in or pulled out (macOS tells Redline), about once a minute while the card is open for wireless devices, and one last time when the engine stops.
- **The separate push-to-start window is gone.** Noticed: it sat in the middle of the screen while the card showed the same button, and I could not close it without quitting Redline. The start button on the card is the only one now; in PUSH mode Redline simply waits in the menu bar.
- VIBE cannot be pressed while the start button is up.
- **Low Power Mode could be left on after NOS.**
  Noticed: in a full test run, going ECO → NOS → off left Low Power Mode on although it had been off before.
  Cause: Low Power Mode is switched in the background. Going straight from one mode to the other, the second mode noted "how it was before" while the first mode's switch-back had not happened yet, and later put that wrong state back.
  Fix: the switches now run strictly one after the other, and a switch that is still on its way counts as the state. Tested in both directions, with Low Power Mode starting off and starting on.
- **Bluetooth could be left off after ECO.**
  Noticed: in a stress run of 150 rapid presses. Bluetooth takes a few seconds to really switch, so ECO off and straight on again noted "Bluetooth was off" and never switched it back on.
  Fix: what was last asked for counts for a few seconds. Tested with fast ECO presses: Bluetooth back on every time.
- **Two crashes at the ECO click (24 Nov, 01:23 and 01:31) explained and closed.** macOS stops a program on the spot when it touches Bluetooth while another program (a terminal, a script) is held responsible for it, which happens when Redline's program file is run directly instead of being opened as an app. ECO now leaves Bluetooth alone in that case instead of being stopped.
- **Much less memory with the engine on.** The two full-screen wallpaper pictures for the NOS wipe were kept decoded the whole time, and macOS kept its own copies after a wipe: 76 MB with the engine on, about 180 MB once NOS had been used. They are now only held while the card is open and let go straight after a wipe: 54-58 MB with the card closed, before and after NOS.
- **Other Macs:** a socket number outside 1-4 or a colour that cannot be mixed can no longer stop the app.
- **Tested end to end (24 Nov):** fans in every state, quitting with the fans held, NOS and ECO on and off, quitting during NOS, a hard kill during NOS and during ECO (both undone at the next start), 150 rapid random presses without a crash, VIBE with real sound, no memory leaks.
- Two fan presses in quick succession can no longer finish in the wrong order (they are now done one after the other).
- The battery tile no longer shows the red low-battery warning when there is no battery reading.

### Fixed
- **NOS could leave me with a blank desktop (26 Nov).**
  Noticed: after the Dock restarted during NOS, my wallpaper was gone and the desktop was one flat blue.
  Cause: Redline makes the red wallpaper by photographing macOS's wallpaper window. That morning the window had not been drawn yet when the photo was taken, so both saved pictures (the red one and the still copy used when leaving NOS) were completely see-through. Nothing checked them. NOS had set the empty red picture as the wallpaper, and the Dock restart made macOS load it.
  Fix: a photo that is see-through or one flat colour is thrown away and taken again at the next check; it is never saved and never shown.
- **The wallpaper rules, written down and enforced.** What I asked for:
  - Redline never removes my wallpaper.
  - NOS on shows my current wallpaper in red. NOS off, engine off, or quitting Redline during NOS puts back exactly what was there before.
  - If I pick another wallpaper during NOS, my pick wins: leaving NOS or quitting does nothing to it. Before, leaving NOS put the still copy over it and later the old wallpaper.
  - With two screens, each screen is handled by itself: a screen where I picked something keeps it, a screen still showing the red picture goes back to its wallpaper from before NOS.
  - The red wallpaper is only used if it was already made, from the wallpaper that is showing, before NOS was clicked. A missing, empty or outdated picture means NOS leaves the wallpaper alone, and it is never switched later while NOS is already on.
  Also: the red picture is now always made from the screen with the menu bar. Before, it depended on which screen was in use at that moment.
  Tested on both screens: no picture ready (wallpaper untouched), NOS on and off twice in a row, quitting during NOS (wallpaper settings identical to before), another wallpaper picked on one screen and on both, then NOS off, NOS on again and quit. Not tested: a real empty photo, and the live wallpaper coming back after the screen sleeps.
- **Switching NOS off replaced my wallpaper with a different picture.**
  Noticed: after the first NOS test my blue wallpaper had become a forest photo.
  Cause: my wallpaper is Apple's live Sequoia wallpaper, which macOS draws in 3D. Asked which picture is on the desktop, macOS answers with a placeholder file (the forest), and Redline put that back.
  Fix: Redline now saves macOS's own wallpaper settings before NOS changes anything and restores exactly those afterwards. Tested: NOS on shows the red wallpaper, NOS off brings the live blue one back.
- **The first red wallpaper looked bad.** It was a flat red gradient I had not asked for. It is now made from my own wallpaper, recoloured.
- **Leaving NOS turned the desktop grey for a moment.**
  Cause: two things. The fade mixed cyan over red, which comes out grey, and restarting macOS's wallpaper process blanks the desktop for a frame.
  Fix: the new colours now lie under the old ones instead of being mixed, and the desktop wipes to a still copy of my wallpaper; the live one is quietly put back the next time the screen sleeps or Redline starts.
- **Leaving NOS stuck for a few seconds, the menu bar most of all.**
  Cause: the card was photographed the slow way before the animation, the wallpaper pictures were loaded at that moment, and the card redrew itself before the animation was handed over.
  Fix: macOS takes the snapshot, the pictures are loaded once at start-up, and the animation is handed over first. It now starts within a twentieth of a second.
- **The card, desktop and Touch Bar animated one after another.** They now share one start time.
- **The battery tile looked alarming while charging.** It was red because the level was low, even though the charger was in. Red and blinking now only happen on battery. A Mac that is plugged in but losing charge (my 60 W charger at full fans) shows PLUGGED IN with the drain, not HELD.
- **With VIBE off, the old light show stayed behind the dials.** Changing the underglow kept showing the previous look's frozen lights until VIBE came back on. A first fix made the whole card see-through, which I did not want; that was reversed. The card keeps its dark base and only the light-show layers stop.

### Not possible
- Overclocking: the i7-9750H is locked. Turbo Boost is on by default, and maximum fans keep it boosting longer.
- macOS "Reduce transparency": macOS does not let apps switch it.
- Browser Energy Saver / Memory Saver: Chrome and Brave do not let other apps change them.

## v1.7.1 · 24 Nov 2026 · ECO gives the Touch Bar back
`7fd82d4`

### Changed
- **In ECO the Touch Bar goes back to Apple's own bar**, as if Redline were switched off, instead of a dimmed Redline strip. Leaving ECO brings Redline's strip back (no rev). Tested: strip gone in ECO, back after.

## v1.7 · 24 Nov 2026 · ECO mode
`3a32b93`

### Added
- **ECO**, the opposite of NOS, like the eco mode in a hybrid car. Made for being in bed on battery: as little power as possible while everything still works.
  - macOS Low Power Mode on, the same switch my battery app (AlDente) flips. Already on? It stays on afterwards too.
  - Bluetooth off.
  - Screen down to 15 %, still readable. Keyboard light off.
  - Fans handed back to macOS, whatever FANS was set to.
  - Redline's lights, music listening and animations off; readings every 3 to 6 seconds instead of every 1 to 2.
  - The Touch Bar very dim and still: no moving glow, no runner lights, no shine (replaced in v1.7.1 by Apple's own bar).
  - Switching ECO off puts every one of these back exactly as it was. Quitting Redline in ECO does the same, and if Redline ever stops during ECO, the next start undoes it.
  - NOS and ECO switch each other off.
- The fan helper (v3) can now also switch Low Power Mode. It needs one more run of the set-up with my Mac password (the FANS pill says FANS UPDATE until then).

### Tested
- With the updated helper: ECO on turned Bluetooth off, Low Power Mode on, fans to auto and the screen down; ECO off put all four back.

### Not done
- **Putting browser tabs to sleep.** Chrome and Brave do not let another app send their tabs to sleep, so ECO leaves browsers alone. Their own setting does it: Settings > Performance > Energy Saver, "turn on when unplugged".

## v1.6.1 · 24 Nov 2026 · Starts at log-in again
`79adcac`

### Fixed
- **Redline did not show up after a restart.**
  Noticed: I restarted the Mac and Redline never appeared in the menu bar.
  Cause: Redline did start at log-in, but on purpose it then waited for the Mac to "calm down" (system load below half the cores, up to 2.5 minutes) before showing anything. Right after a restart macOS is busy loading everything, so it sat there invisible, and from the outside it looked like it never started.
  Fix: the waiting rule is gone. Redline now starts the moment macOS opens it at log-in. Tested by relaunching: menu bar icon and Touch Bar up within 4 seconds.

## v1.6 · 23 Nov 2026 · Permissions that stick
`dd857d4`, `34f8b78`, `5e9234d`

### Fixed
- **The Touch Bar part asked for Accessibility on every engine start.**
  Noticed: each time I turned the engine off and on, macOS asked for the permission again.
  Cause: Redline starts a fresh Touch Bar process on every start, and it asked whenever it was not trusted yet.
  Fix: it now asks at most once per installed copy. The installer keeps file dates, so a rebuild of Redline alone no longer counts as a new copy.
- **Every rebuild lost the macOS permissions.**
  Cause: the app was signed with a throwaway signature, so macOS treated each build as a new app.
  Fix: the build now signs with my own local certificate when it is present, so Accessibility and audio permissions survive rebuilds.
- **Engine off did not always stop the Touch Bar.** If the Touch Bar part started late, it could stay running after engine off. Engine off now stops it in every case.

## v1.5 · 23 Nov 2026 · Push to start
`052f840`, `c9bab17`, `ebcc553`

### Added
- Engine on/off. Engine off gives the Mac back its defaults: Apple's Touch Bar, fans on auto, no keep-awake, no lights.
- Push-to-start window with a rev that runs in sync on the card and the Touch Bar. AUTO or PUSH start. A delayed start at log-in that waits until the Mac has settled (removed again in v1.6.1).

### Fixed
- **The push-to-start button did nothing.**
  Noticed: pressing the start button on the card did not start the engine, and the start window ignored the first click.
  Cause: the card's button had no action wired to it, and the start window was not the active window, so the first click only focused it.
  Fix: both buttons now run the same start action, and the window accepts the first click. Tested with real clicks: start window starts, header power button stops, card button starts.

## v1.4 · 22 Nov 2026 · Fans, NOS and the Touch Bar inside Redline
`e8c55fd`, `ea0cb89`, `cb6678e`, `77cbbb3`, `256004e`

### Added
- FANS switch (AUTO / MAX) with a small administrator helper, so I could uninstall Macs Fan Control. NOS forces MAX, and leaving NOS returns to my own setting.
- Both fans shown in the thermals tile with their speed against each fan's own maximum.
- NOS keeps the Mac awake by itself. Coffee Mode became optional and is kept in step when both are installed.
- The Touch Bar app (Glowstrip) now lives inside Redline: one app, one installer, one README.

### Fixed
- **MAX fans failed: "could not set maximum, returned to automatic".**
  Cause: the helper read the fan target back instantly, before the Mac's T2 chip had taken it, judged it a failure and went back to auto.
  Fix: helper v2 waits up to 2 seconds before judging, reports the chip's answer codes, logs failures, and the app shows UPDATE when an older helper is installed. Verified: both fans reached their rated maximum (5926 / 5468 rpm) and returned to about 2200 / 2000 rpm on auto.
- **Fans stayed at max after Redline was stopped from outside.** Quitting released them, but a system stop (SIGTERM) did not. Both now release the fans.
- **A new fan helper needed a Redline restart.** It is now picked up without one.
- **In NOS, the VIBE and FANS switches could still be clicked** and fight the override. They now show as on but dimmed and locked, like the colour dots.

## v1.3 · 22 Nov 2026 · Every look its own style
`bcb5b48`, `311b542`, `c244357`, `4c637df`, `8bed53b`, `c2e7f1c`, `5daad4c`

### Added
- Five club-style lighting looks, then four more (nine in total, plus NOS), each with its own light show and its own bodywork: tile shapes, glass, edges, light shapes and dial rims.
- Bluetooth devices with battery levels in the device bay; a hub's two halves merged into one row.
- Optional Touch Bar link and a one-step installer.

### Fixed
- **Themes only changed colour.** I wanted each look to be truly different, buttons included. Each look now has its own shapes and parts, not just a new colour.
- **The device bay cut off my third wireless device.** Rows were too tall, so only six fit. Rows are now compact and eight fit, and the card still fits above the Dock on my screen.
- **The colour choice could change during NOS.** NOS now locks the underglow: the dots are greyed out, the last pick is faintly ringed, and it comes back when NOS ends.
- **USB socket positions were wrong.** The socket map did not match my MacBook. A first fix only changed the README, because the code edit had not applied; I caught that and the positions are now fixed in the code itself. Badges are plain labels instead of looking clickable.
- **The Touch Bar link assumed every Mac has a Touch Bar.** It is now optional: Redline checks for one first and the installer skips the Touch Bar part on Macs without it.

## v1.2 · 22 Nov 2026 · Cleaner card and better lights
`127c122`, `7d2e42b`, `9a374e4`

### Fixed
- **Drag-to-resize broke and used too much CPU.** The resize grip and the wide two-column layout were removed. The card is one fixed size.
- **The sound effects sounded cheap.** All sound effects removed.
- **The bar equaliser looked like an old music player** and some text was squeezed. The card is wider and roomier, and the backdrop became smooth mirrored waves, glows behind the dials and rings on each beat.
- **Text spilled outside the small dials.** Dial text is now smaller, placed higher, with shorter captions and a width limit, checked against the circle in the preview picture.
- **The waves still looked basic.** Added colour drift, a slow aurora, sparks on high notes and double rings.

## v1.1 · 22 Nov 2026 · First add-ons
`6b7ceb1`, `470fa2c`, `bee6243`

### Added
- Drag-to-resize, charger socket shown in amber, records row, NOS switch, sounds, beat-synced lights. (Resize and sounds were later removed, see v1.2.)

## v1.0 · 22 Nov 2026 · First release
`f6b992c`, `d45d710`

- Tuner-style gauge card in the menu bar: CPU, GPU and memory dials, per-core LEDs, power, thermals, network, disk, and a USB bay with a map of my sockets. Colour themes and an optional music-reactive backdrop.

### Fixed before release
- **The card used 50 to 80 percent CPU.** Animating many small pieces every frame was too heavy. LEDs now snap instead of fading, dial faces are drawn once and reused, only the needles move, and the backdrop uses lightweight layers. Result: 0 percent with the card closed, about 20 percent with it open.

---

## Touch Bar part (Glowstrip), before it moved into Redline

Glowstrip started as its own app on 22 Nov 2026 and went through twelve versions before becoming part of Redline. The fixes that came from using it:

- **Slide-to-set volume was risky.** One wrong swipe could blast the volume to max. Replaced with step buttons (one small step per tap, hold to repeat); the bar only moves relative to where it is.
- **Not bright enough, and the look was not premium.** Raised to full brightness at rest, added neon halos, glass tiles and a pulsing backdrop.
- **Blurred shadows on moving parts cost too much** (18 percent of a core). Replaced with a second wide stroke for the halo.
- **The Touch Bar did not follow Redline's look**, and later followed it in the wrong way: switching VIBE off also changed the colour. Corrected so the Touch Bar always wears the colour picked in Redline, and VIBE only turns movement on or off.
- **Icons and lettering looked the same in every look.** Each look now has its own icon set, icon style, font, weight and labels.
- **It could start on a Mac without a Touch Bar.** It now checks first and exits cleanly.
