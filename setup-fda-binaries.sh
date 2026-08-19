#!/usr/bin/env bash
#
# setup-fda-binaries.sh — create dedicated, re-signed copies of the binaries
# compress.sh needs in directory mode, so Full Disk Access can be granted
# narrowly to those copies instead of to the shared system/Homebrew binaries.
#
# Why: a headless launchd process touching an external volume needs Full
# Disk Access (macOS TCC). Granting that to /opt/homebrew/bin/bash (or
# /usr/bin/touch, /bin/mv, /bin/ls) would apply to EVERY script or process
# that happens to run through those shared binaries -- not just this
# automation. Re-signing private copies with a unique identifier gives each
# one a distinct TCC identity, so only this automation's copies can ever use
# the grant.
#
# Safe to re-run (e.g. after `brew upgrade`) -- it refreshes the copies and
# re-signs them in place. Full Disk Access does not need to be re-granted
# after a re-run as long as the identifier stays the same, which it does.
#
# Usage: ./setup-fda-binaries.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin_dir="$script_dir/bin"
mkdir -p "$bin_dir"

# Derived from this project's own directory name, so copying this script
# into another project (e.g. av2notes, ja2en-subs) just works with no
# manual editing -- and, importantly, so the dedicated binaries' filenames
# are self-identifying. macOS's Full Disk Access list only shows the bare
# filename (no path column), so a plain "bash" from two different projects
# would be indistinguishable in that list; prefixing with the project name
# keeps each entry legible on its own.
project_name="$(basename "$script_dir")"

# name -> source path to copy from
pairs=(
  "bash:$(command -v bash)"
  "ffmpeg:$(command -v ffmpeg)"
  "touch:/usr/bin/touch"
  "mv:/bin/mv"
  "ls:/bin/ls"
)

echo "Creating dedicated re-signed binaries in $bin_dir"
echo

for pair in "${pairs[@]}"; do
  name="${pair%%:*}"
  src="${pair#*:}"
  dest="$bin_dir/${project_name}-${name}"

  if [[ ! -x "$src" ]]; then
    echo "  ✗ $name: source not found or not executable ($src)" >&2
    exit 1
  fi

  cp "$src" "$dest"
  chmod +x "$dest"
  codesign --force --sign - --identifier "com.jas.$project_name.$name" "$dest"
  echo "  ✓ $name  ($src -> $dest)"
done

echo
echo "Done. Now grant Full Disk Access to each of these 5 paths:"
echo
for pair in "${pairs[@]}"; do
  name="${pair%%:*}"
  echo "  $bin_dir/${project_name}-${name}"
done
echo
echo "System Settings -> Privacy & Security -> Full Disk Access -> '+', then"
echo "Cmd+Shift+G to paste each path above. Opening that pane now..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
