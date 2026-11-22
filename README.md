# Redline

**Your whole Mac on one tuner-style dashboard.** A small needle in the menu bar: click it and a gauge cluster shows what the whole machine is doing.

<p><img src="preview/panel.png" width="460" alt="The Redline panel: three dials, a column per CPU core, and tiles for power, battery, thermals, network, disk and USB"></p>

## Why I built it

To know what my Mac is doing I had to open Activity Monitor and click through five tabs of tables. Power from the charger, what each USB device asks for, temperatures and fan speed are not in there at all.

I wanted one click instead of a hunt. And I wanted it to be fun: a dashboard like the gauge cluster of a tuned import car, calm and satisfying to look at.

I decide what it should do and test it; an AI coding assistant (Claude Code) writes the code.

Copyright (c) 2026 Ali Razavi. All rights reserved. See `LICENSE`.

## What it shows

- **CPU Last** (big tachometer), **GPU Last** and **Memory** dials, each with an amber dot marking the peak since you opened the panel
- One LED column per CPU core, and the busiest app right now
- **Power in** (watts from the charger), **System draw** (whole Mac, plus CPU and GPU watts), **Battery** (charge, charge/drain watts, health), **Thermals** (CPU and GPU temperature, fan speed)
- **Network** down and up with Wi-Fi signal, link rate and transmit power; **Disk** read and write
- **USB bay**: every external device, its speed and the current it asks for
- A red THROTTLED badge when macOS slows the CPU down because of heat
- Uptime since the last restart

When the panel opens, every needle sweeps to the top and settles, like a car's ignition check.

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

Needs only the Swift command line tools. It builds `src/main.swift`, writes preview pictures to `preview/`, and installs `/Applications/Redline.app`.

`./build/Redline --probe` prints the raw sensor readings.
