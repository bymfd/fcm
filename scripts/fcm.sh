#!/bin/bash
# fcm.sh — control fan speed from the command line
#
# Usage:
#   ./fcm.sh status           — show current state (rpm, mode, min/max)
#   ./fcm.sh max              — run fan at maximum speed
#   ./fcm.sh min              — run fan at minimum speed
#   ./fcm.sh auto             — return control to the system (default)
#   ./fcm.sh set <rpm>        — lock fan to a specific speed (min..max)
#   ./fcm.sh hold <max|min|rpm> — keep asserting a speed until Ctrl+C
#
# Note: writing to the SMC requires root; sudo will prompt for a password.

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SMC="$ROOT/build-smc"
SRC="$ROOT/src/smc.c"

# Build the smc helper if it's missing
if [ ! -x "$SMC" ]; then
    echo "Compiling smc helper..."
    cc -O2 -o "$SMC" "$SRC" -framework IOKit -framework CoreFoundation || {
        echo "BUILD ERROR"; exit 1; }
fi

cmd="${1:-status}"

read_key() { "$SMC" read "$1" 2>/dev/null | sed 's/^[A-Za-z0-9]*=//' | tr -d '\r\n'; }
write_key() { sudo "$SMC" write "$1" "$2" >/dev/null 2>&1; }

# Detect number of fans (if FNum is 0, probe F0Ac/F1Ac/F2Ac)
fans=()
count="$(read_key FNum)"
if [ -z "$count" ] || [ "$count" = "0" ] || ! echo "$count" | grep -qE '^[0-9]+$'; then
    for i in 0 1 2; do
        v="$(read_key "F${i}Ac")"
        if [ -n "$v" ] && [ "$v" != "0" ]; then
            fans+=("$i")
        fi
    done
else
    for ((i = 0; i < count; i++)); do
        fans+=("$i")
    done
fi

if [ "${#fans[@]}" -eq 0 ]; then
    echo "ERROR: no fans found (SMC access may require root)."
    exit 1
fi

mode_of() { local m; m="$(read_key "F${1}Md")"; if [ "$m" = "1" ]; then echo "MANUAL"; else echo "AUTO"; fi; }

case "$cmd" in
    status)
        echo "Fans: ${#fans[@]}"
        for i in "${fans[@]}"; do
            ac="$(read_key "F${i}Ac")"
            mn="$(read_key "F${i}Mn")"
            mx="$(read_key "F${i}Mx")"
            tg="$(read_key "F${i}Tg")"
            md="$(mode_of "$i")"
            if [ "$md" = "MANUAL" ]; then
                st="target ${tg} rpm"
            else
                st="system managed"
            fi
            echo "  Fan $i : ${ac} rpm | min ${mn} | max ${mx} | $md ($st)"
        done
        ;;
    max)
        for i in "${fans[@]}"; do
            mx="$(read_key "F${i}Mx")"
            [ -n "$mx" ] || mx=6500
            write_key "F${i}Md" 1
            write_key "F${i}Mn" "$mx"
            write_key "F${i}Tg" "$mx"
            echo "Fan $i -> MAX ($mx rpm)"
        done
        ;;
    min)
        for i in "${fans[@]}"; do
            write_key "F${i}Md" 1
            write_key "F${i}Mn" 1800
            write_key "F${i}Tg" 1800
            echo "Fan $i -> MIN (1800 rpm)"
        done
        ;;
    auto)
        for i in "${fans[@]}"; do
            write_key "F${i}Md" 0
            echo "Fan $i -> AUTO (system managed)"
        done
        ;;
    set)
        rpm="${2:-}"
        if ! echo "$rpm" | grep -qE '^[0-9]+$'; then
            echo "Usage: ./fcm.sh set <rpm>"
            exit 1
        fi
        for i in "${fans[@]}"; do
            mx="$(read_key "F${i}Mx")"
            [ -n "$mx" ] || mx=6500
            if [ "$rpm" -gt "$mx" ]; then rpm="$mx"; fi
            write_key "F${i}Md" 1
            write_key "F${i}Mn" "$rpm"
            write_key "F${i}Tg" "$rpm"
            echo "Fan $i -> $rpm rpm (max $mx)"
        done
        ;;
    hold)
        target="${2:-}"
        if [ -z "$target" ]; then
            echo "Usage: ./fcm.sh hold max|min|<rpm>   (Ctrl+C to stop)"
            exit 1
        fi
        case "$target" in
            max)   v="$(read_key "F0Mx")"; [ -n "$v" ] || v=6500 ;;
            min)   v=1800 ;;
            *[!0-9]*) echo "target: max, min or an rpm value"; exit 1 ;;
            *)     v="$target" ;;
        esac
        echo "Fan 0 -> $v rpm (continuous, Ctrl+C to stop)"
        while true; do
            for i in "${fans[@]}"; do
                write_key "F${i}Md" 1
                write_key "F${i}Mn" "$v"
                write_key "F${i}Tg" "$v"
            done
            sleep 1
        done
        ;;
    *)
        echo "Usage: ./fcm.sh {status|max|min|auto|set <rpm>|hold <max|min|rpm>}"
        exit 1
        ;;
esac
