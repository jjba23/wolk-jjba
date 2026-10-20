#!/bin/bash
# Rebuild the README screenshots and the demo GIF.
#
# The raw captures are not committed (they are 2.4 MB of 2407x1504
# screenshots).  Capture the four dashboards from Grafana at 1600x1000 in
# kiosk mode and save them here as:
#
#   raw-network.png   /d/network-http
#   raw-storage.png   /d/storage-retention
#   raw-logs.png      /d/herd-daemons-logs
#   raw-host.png      /d/host-cpu-memory
#
# Then run this script.  It trims the empty bottom band, paints over the
# desktop app's overlay chip in the top-left corner, downscales to 1280 px,
# adds a caption strip and assembles demo.gif.
set -euo pipefail

cd "$(dirname "$0")"

for f in raw-network.png raw-storage.png raw-logs.png raw-host.png; do
  [ -f "$f" ] || { echo "missing $f — see the header of this script" >&2; exit 1; }
done

clean() {          # $1 = raw, $2 = output, $3 = caption
  magick "$1" \
    -crop 2407x1250+0+0 +repage \
    -fill '#111217' -draw 'rectangle 0,0 150,72' \
    -resize 1280x \
    -gravity north -background '#0b0c0e' -splice 0x62 \
    -fill '#ececec' -font DejaVu-Sans -pointsize 24 -annotate +30+38 "$3" \
    -quality 92 "$2"
}

clean raw-network.png network-http.png \
  'Network & HTTP — request rate, latency percentiles, upstream timings and status codes'
clean raw-storage.png storage-retention.png \
  'Storage & retention — disk forecast, ingestion per signal, every cap in one place'
clean raw-logs.png herd-daemons-logs.png \
  'Daemon logs — every service routed to its own stream, searchable in Grafana'
clean raw-host.png host-cpu-memory.png \
  'Host — CPU, memory, load and network, scraped by node_exporter'

magick -delay 260 -dispose previous \
  network-http.png storage-retention.png herd-daemons-logs.png host-cpu-memory.png \
  -loop 0 -layers Optimize demo.gif

ls -lh demo.gif network-http.png storage-retention.png herd-daemons-logs.png host-cpu-memory.png
