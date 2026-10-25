#!/bin/bash
while pgrep -f 'hf download' >/dev/null; do
  printf "%s  %s  free=%sG\n" "$(date +%H:%M)" "$(du -sh ~/swift15-src 2>/dev/null | cut -f1)" "$(df -k /System/Volumes/Data | tail -1 | awk '{printf "%.0f", $4/1048576}')" >> ~/swift15-watch.log
  sleep 600
done
echo "$(date +%H:%M)  DONE $(du -sh ~/swift15-src | cut -f1)" >> ~/swift15-watch.log
