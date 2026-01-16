# Dell PowerEdge R710 Fan Control (Proxmox / Linux)

Quiet, safe, **local IPMI–based fan control** for the **Dell PowerEdge R710 (iDRAC6)** running **Proxmox VE** or other Debian-based Linux systems.

The Dell R710 is extremely loud in a homelab. Dell’s default fan profile is very conservative and ramps fans aggressively even at low load. This project provides a controlled, transparent, and safe way to reduce noise **without disabling Dell’s built-in hardware protections**.

This solution:
- Runs directly on the Proxmox host (no Docker, no remote IPMI)
- Uses CPU temperatures from `lm-sensors`
- Uses ambient temperature and fan RPMs from iDRAC via local IPMI
- Automatically falls back to Dell AUTO fan control when needed

---

## Features

- Manual fan speed when temperatures are safe (quiet mode)
- Automatic fallback to Dell AUTO fan mode when temperatures rise
- Hysteresis to prevent fan flapping
- Logs only meaningful events:
  - Fan mode changes (AUTO ↔ MANUAL)
  - Hourly status logs (exactly on the clock hour)
  - Rolling 24-hour min / max / average temperature statistics
- Keeps only the last 24 hours of stats (automatic cleanup)
- Runs via systemd timer (no cron)

---

## Supported Hardware

- Dell PowerEdge R710
- iDRAC6 Enterprise
- Proxmox VE / Debian-based Linux
- Local IPMI access (`/dev/ipmi0`)

May work on other Dell 11G servers, but raw IPMI fan commands may differ.

WARNING: This script sends raw IPMI commands. Use at your own risk and test carefully.

---

## How It Works

The script operates in two fan control modes.

MANUAL mode:
- Enables manual fan control
- Sets fans to a fixed speed (`FAN_HEX`)
- Used when temperatures are safely below thresholds

AUTO mode:
- Restores Dell BIOS/iDRAC automatic fan control
- Used when temperatures exceed safe limits

---

## Hysteresis Logic

To avoid rapid switching between modes:

MANUAL → AUTO when:
- CPU temperature >= CPU_ON OR
- Ambient temperature >= AMBIENT_ON

AUTO → MANUAL when:
- CPU temperature <= CPU_OFF AND
- Ambient temperature <= AMBIENT_OFF

This prevents oscillation when temperatures hover near thresholds.

---

## Temperature Sources (Important)

CPU temperature:
- NOT available via iDRAC on R710
- Read using lm-sensors (`coretemp`)
- Script uses the maximum core temperature across all CPUs

Ambient temperature:
- Read from iDRAC via IPMI (`Ambient Temp`)
- Used as an additional safety signal

Fan RPM:
- Read from iDRAC fan sensors
- Logged for visibility and diagnostics

---

## Requirements

Packages:
- ipmitool
- lm-sensors

Kernel modules:
- ipmi_si
- ipmi_devintf

You must have `/dev/ipmi0` available.

---

## Installation

1. Install required packages:
   apt update
   apt install -y ipmitool lm-sensors
   sensors-detect

2. Ensure IPMI device exists:
   ls -l /dev/ipmi0

   If missing:
   modprobe ipmi_si
   modprobe ipmi_devintf

   Persist modules:
   echo ipmi_si > /etc/modules-load.d/ipmi.conf
   echo ipmi_devintf >> /etc/modules-load.d/ipmi.conf

3. Copy script to:
   /usr/local/sbin/r710-fancontrol.sh

4. Make executable:
   chmod +x /usr/local/sbin/r710-fancontrol.sh

---

## systemd Integration (Recommended)

Service file: /etc/systemd/system/r710-fancontrol.service

[Unit]
Description=R710 Fan Control
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/r710-fancontrol.sh

Timer file: /etc/systemd/system/r710-fancontrol.timer

[Unit]
Description=Run R710 fan control every 30 seconds

[Timer]
OnBootSec=30
OnUnitActiveSec=30
AccuracySec=1s

[Install]
WantedBy=timers.target

Enable:
systemctl daemon-reload
systemctl enable --now r710-fancontrol.timer

---

## Configuration

All configuration is done via environment variables.

Defaults:
CPU_ON=55
CPU_OFF=50
AMBIENT_ON=33
AMBIENT_OFF=30
FAN_HEX=0x10 (~16%)

Recommended home lab value:
FAN_HEX=0x0C (~12%)

Override via systemd:
systemctl edit r710-fancontrol.service

Example:
[Service]
Environment=FAN_HEX=0x0C
Environment=CPU_ON=55
Environment=CPU_OFF=50
Environment=AMBIENT_ON=33
Environment=AMBIENT_OFF=30

Apply:
systemctl daemon-reload
systemctl start r710-fancontrol.service

---

## Fan Speed Reference (Typical R710)

0x0A ≈ 10% ≈ 2200 RPM (very quiet)
0x0C ≈ 12% ≈ 2500 RPM (recommended)
0x0E ≈ 14% ≈ 2700 RPM
0x10 ≈ 16% ≈ 3000 RPM
AUTO ≈ 5000–7000+ RPM (very loud)

RPM varies by fan model and airflow.

---

## Logging

Follow logs live:
journalctl -t r710-fancontrol -f

Log types:
- STATE CHANGE → AUTO / MANUAL
- HOURLY STATUS (exactly on HH:00)
- STATS24H (rolling 24h min/max/avg)

---

## Statistics Storage

Stats stored in:
 /var/lib/r710-fancontrol/stats.csv

Format:
 epoch,cpu_temp,ambient_temp

Data is automatically pruned to keep only the last 24 hours.

Inspect:
 wc -l /var/lib/r710-fancontrol/stats.csv
 tail -n 5 /var/lib/r710-fancontrol/stats.csv

---

## Troubleshooting

No logs:
- Normal if mode did not change and it is not on the hour
- Force a log:
  rm -f /run/r710-fancontrol.state
  systemctl start r710-fancontrol.service

Fans ramp often:
- Increase FAN_HEX
- Lower CPU_ON / AMBIENT_ON
- Check airflow, dust, and thermal paste

No temperatures:
- Run sensors
- Run ipmitool sdr type temperature

---

## Safety Notes

- Dell hardware protections remain active
- AUTO mode always overrides manual when needed
- Validate temperatures under real load
- Increase fan speed during hot summer months

---

## License

MIT License recommended.

---

Because a homelab server should not sound like a jet engine.
