#!/bin/sh
# Regenerates the embedded screenshots (src/shots/*.webp) from the real UI
# captures in ai-core-program/screenshots (fixture mode, sample data).
# Each is resized to 960 px wide, cropped to at most 1300 px tall and saved as
# WebP quality 55. build.sh inlines them as data: URIs. Needs ImageMagick + cwebp.
set -e
cd "$(dirname "$0")"
SRC=${AI_CORE_SCREENSHOTS:-../../../../../ai-core-program/screenshots}
mk() { # name source max-height
  magick "$SRC/$2" -resize 960x -crop "960x$3+0+0" +repage /tmp/aicore-shot-$$.png
  cwebp -quiet -q 55 /tmp/aicore-shot-$$.png -o "shots/$1.webp"
  rm -f /tmp/aicore-shot-$$.png
}
mk studio-setup     studio-a/mock-desktop-02-setup.png 1300
mk studio-overview  studio-a/mock-desktop-01-overview.png 1250
mk studio-usage     studio-a/mock-desktop-20-usage-overview.png 1100
mk studio-fr        studio-a/mock-desktop-42-fr-incident.png 1150
mk studio-recs      studio-b/mock-desktop-01-rec-list.png 900
mk studio-service   studio-b/mock-desktop-71-svc-finding-playbook-network.png 1250
mk studio-conv      studio-b/mock-desktop-47-conv-progress-final-answer.png 1250
mk portal-learned   portal/fx-1280-30-learned.png 1300
mk portal-approvals portal/fx-1280-22-lock-approved-second-step.png 1300
mk portal-final     portal/fx-1280-05-final-confirmation.png 700
mk portal-simconfirmed portal/fx-1280-07-simulated-confirmed-scene-offer.png 1300
ls -l shots
