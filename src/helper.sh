#!/bin/bash
# fcm-helper.sh — root LaunchDaemon: reads commands from FIFO, writes to SMC
FIFO=/var/run/fcm.fifo
SMC=/Library/PrivilegedHelperTools/fcm-smc

rm -f "$FIFO"
mkfifo "$FIFO"
chmod 666 "$FIFO"

tail -f "$FIFO" | while read -r key val; do
    "$SMC" write "$key" "$val"
done
