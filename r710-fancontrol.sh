#!/bin/bash
# R710 Fan Control - Proxmox
# - CPU temps via lm-sensors
# - Ambient + Fan RPM via local IPMI
# - Hysteresis to prevent flapping
# - Logs only on state changes + HOURLY (on the clock hour) status + rolling 24h stats (min/max/avg)

set -u

# -------------------
# CONFIG (override via systemd Environment= if you want)
# -------------------
CPU_ON="${CPU_ON:-55}"           # Enter AUTO if CPU >= this
CPU_OFF="${CPU_OFF:-50}"         # Return to MANUAL if CPU <= this
AMBIENT_ON="${AMBIENT_ON:-33}"   # Enter AUTO if Ambient >= this
AMBIENT_OFF="${AMBIENT_OFF:-30}" # Return to MANUAL if Ambient <= this
FAN_HEX="${FAN_HEX:-0x10}"       # 0x00..0x64 (0..100%)
LOGTAG="r710-fancontrol"
STATE_FILE="/run/r710-fancontrol.state"

# Hourly logging + stats
HOURLY_FILE="/run/r710-fancontrol.last_logged_hour"   # stores YYYYMMDDHH of last hourly log
STATS_DIR="/var/lib/r710-fancontrol"
STATS_CSV="${STATS_DIR}/stats.csv"   # epoch,cpu,ambient

# -------------------
# HELPERS
# -------------------
log() { logger -t "$LOGTAG" "$*"; }

to_int() {
  local v="${1:-}"
  v="${v//[^0-9]/}"
  [ -z "$v" ] && v="0"
  echo "$v"
}

hex_to_percent() {
  # FAN_HEX like 0x10 -> 16
  printf "%d" "$(( $1 ))"
}

read_cpu_max() {
  local raw max
  raw="$(sensors 2>/dev/null \
    | grep -oP 'Core.*?\+\K[0-9]+(\.[0-9]+)?' \
    | sort -nr | head -1 || true)"
  max="$(to_int "${raw%%.*}")"
  echo "$max"
}

read_ambient() {
  local raw amb
  raw="$(ipmitool sdr type temperature 2>/dev/null \
    | awk '/Ambient Temp/ {for (i=1;i<=NF;i++) if ($i=="degrees") {print $(i-1); exit}}' || true)"
  amb="$(to_int "$raw")"
  echo "$amb"
}

read_fan_rpms() {
  local line fan last_field rpm out=""
  while IFS= read -r line; do
    # Example: FAN 1 RPM | 30h | ok | 7.1 | 3000 RPM
    fan="$(echo "$line" | awk '{print $2}')"
    last_field="$(echo "$line" | awk -F'|' '{print $NF}')"
    rpm="$(echo "$last_field" | grep -oE '[0-9]+' | head -n 1)"
    if [ -n "$fan" ] && [ -n "$rpm" ]; then
      out="${out}FAN${fan}=${rpm}RPM "
    fi
  done < <(ipmitool sdr elist 2>/dev/null | grep -E '^FAN[[:space:]]+[0-9]+[[:space:]]+RPM')
  echo "$out"
}

apply_auto() {
  ipmitool raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1 || true
}

apply_manual() {
  ipmitool raw 0x30 0x30 0x01 0x00 >/dev/null 2>&1 || true
  ipmitool raw 0x30 0x30 0x02 0xff "$FAN_HEX" >/dev/null 2>&1 || true
}

append_sample() {
  mkdir -p "$STATS_DIR" 2>/dev/null || true
  local now cutoff tmp

  now="$(date +%s)"
  cutoff="$(( now - 86400 ))"
  tmp="${STATS_CSV}.tmp"

  # Append current sample if sane
  if [ "${CPU_MAX:-0}" -gt 0 ] && [ "${AMBIENT:-0}" -gt 0 ]; then
    echo "${now},${CPU_MAX},${AMBIENT}" >> "$STATS_CSV"
  fi

  # Prune entries older than 24h (time-based, safe)
  awk -F',' -v cut="$cutoff" '$1 >= cut' "$STATS_CSV" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$STATS_CSV"
}

stats_24h() {
  # Prints: cpu_min cpu_max cpu_avg ambient_min ambient_max ambient_avg samples
  [ -f "$STATS_CSV" ] || { echo ""; return; }

  local cutoff
  cutoff="$(( $(date +%s) - 86400 ))"

  awk -F',' -v cut="$cutoff" '
    $1 >= cut && $2 > 0 && $3 > 0 {
      c=$2; a=$3;
      if (n==0) { cmin=cmax=c; amin=amax=a; }
      if (c < cmin) cmin=c;
      if (c > cmax) cmax=c;
      if (a < amin) amin=a;
      if (a > amax) amax=a;
      csum += c; asum += a; n++;
    }
    END {
      if (n>0) {
        printf "CPU(min=%dC max=%dC avg=%.1fC) Ambient(min=%dC max=%dC avg=%.1fC) samples=%d",
               cmin, cmax, csum/n, amin, amax, asum/n, n
      }
    }' "$STATS_CSV"
}

hourly_log_if_needed() {
  local minute hour_now last_hour

  minute="$(date +%M)"
  hour_now="$(date +%Y%m%d%H)"
  last_hour=""
  [ -f "$HOURLY_FILE" ] && last_hour="$(cat "$HOURLY_FILE" 2>/dev/null || true)"

  # Log only at the top of the hour (minute == 00) and only once per hour.
  if [ "$minute" = "00" ] && [ "$hour_now" != "$last_hour" ]; then
    echo "$hour_now" > "$HOURLY_FILE"

    local s24
    s24="$(stats_24h)"

    log "HOURLY STATUS | MODE=${MODE} Fan=${FAN_HEX} (~${FAN_PCT}%) | CPU=${CPU_MAX}C Ambient=${AMBIENT}C | ${FAN_RPMS}"
    [ -n "$s24" ] && log "STATS24H | ${s24}"
  fi
}

# -------------------
# READ INPUTS
# -------------------
CPU_MAX="$(read_cpu_max)"
AMBIENT="$(read_ambient)"
FAN_RPMS="$(read_fan_rpms)"
[ -z "$FAN_RPMS" ] && FAN_RPMS="RPMs=unknown"
FAN_PCT="$(hex_to_percent "$FAN_HEX")"

# -------------------
# LOAD PREV MODE
# -------------------
PREV_MODE="MANUAL"
[ -f "$STATE_FILE" ] && PREV_MODE="$(cat "$STATE_FILE" 2>/dev/null || echo MANUAL)"

# -------------------
# HYSTERESIS DECISION
# -------------------
MODE="$PREV_MODE"

if [ "$PREV_MODE" = "MANUAL" ]; then
  # Switch to AUTO only when crossing ON thresholds
  if [ "$CPU_MAX" -ge "$CPU_ON" ] || [ "$AMBIENT" -ge "$AMBIENT_ON" ]; then
    MODE="AUTO"
  fi
else
  # Switch back to MANUAL only when temps are safely below OFF thresholds
  if [ "$CPU_MAX" -le "$CPU_OFF" ] && [ "$AMBIENT" -le "$AMBIENT_OFF" ]; then
    MODE="MANUAL"
  fi
fi

# -------------------
# APPLY + LOG ON CHANGE
# -------------------
if [ "$MODE" != "$PREV_MODE" ]; then
  if [ "$MODE" = "AUTO" ]; then
    log "STATE CHANGE → AUTO | CPU=${CPU_MAX}C Ambient=${AMBIENT}C | $FAN_RPMS | thresholds: CPU_ON=${CPU_ON} AMBIENT_ON=${AMBIENT_ON}"
    apply_auto
  else
    log "STATE CHANGE → MANUAL | CPU=${CPU_MAX}C Ambient=${AMBIENT}C | $FAN_RPMS | Fan=${FAN_HEX} (~${FAN_PCT}%) | thresholds: CPU_OFF=${CPU_OFF} AMBIENT_OFF=${AMBIENT_OFF}"
    apply_manual
  fi
else
  # Silent enforcement
  if [ "$MODE" = "AUTO" ]; then
    apply_auto
  else
    apply_manual
  fi
fi

# -------------------
# SAVE STATE + STATS + HOURLY LOG
# -------------------
echo "$MODE" > "$STATE_FILE"
append_sample
hourly_log_if_needed
