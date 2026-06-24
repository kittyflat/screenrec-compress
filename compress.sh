#!/usr/bin/env bash
#
# compress.sh — batch-compress MP4 screen recordings
#
# Usage:
#   compress.sh [OPTIONS] [DIR]
#
#   DIR defaults to the current directory if omitted.
#
# Options:
#   --dry-run    Show what would be compressed without doing anything.
#   --force      Reprocess files that already have a compressed version.
#   -h, --help   Show this message.
#
# Goals:
#   - Reduce storage size while keeping on-screen text readable and meeting audio clear.
#   - Output alongside the original with a " - compressed.mp4" suffix so you can
#     verify before deleting originals.
#   - Preserve the original file's modified timestamp on the compressed output.
#   - Process oldest -> newest (by mtime) to preserve chronological order.
#   - Ctrl-C stops the entire batch immediately.
#   - Idempotent: safe to re-run; skips already-compressed files (unless --force).
#
# Codec choices:
#   Video: H.264 / libx264 (fast, universally compatible).
#   Audio: AAC 96k mono (clear for voice, smaller files).
#
# NOTE — faster but larger alternative:
#   Replace: -c:v libx265
#   With:    -c:v libx264 -tune stillimage  (and set CRF to 20)
#   H.264 encodes faster but files are typically 20–40% larger at equivalent quality.
#
# Compatibility:
#   Written for macOS default Bash 3.2 (no mapfile/readarray). Works on Bash 5 too.

set -euo pipefail

trap 'echo "Interrupted. Exiting batch."; exit 130' INT

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
dry_run=false
force=false
target_dir="."

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --force)   force=true ;;
    -h|--help)
      sed -n '3,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p }; /^[^#]/q }' "$0"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      target_dir="$1"
      ;;
  esac
  shift
done

if [[ ! -d "$target_dir" ]]; then
  echo "Directory not found: $target_dir" >&2
  exit 1
fi

suffix=" - compressed.mp4"

# -----------------------------------------------------------------------------
# Build file list: oldest -> newest, skipping already-compressed files
# -----------------------------------------------------------------------------
files=()
while IFS= read -r f; do
  files+=("$f")
done < <(
  ls -tU "$target_dir"/*.mp4 2>/dev/null \
    | tail -r \
    | grep -vF "$suffix" \
    || true
)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No .mp4 files found (or only already-compressed files)."
  exit 0
fi

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------
count=0
skipped=0

for f in "${files[@]}"; do
  out="${f%.mp4}$suffix"

  if [[ -f "$out" ]] && ! $force; then
    (( skipped += 1 ))
    continue
  fi

  (( count += 1 ))

  if $dry_run; then
    echo "[dry-run] $f"
    echo "       -> $out"
    continue
  fi

  echo "$f"
  echo "  -> $out"

  # ffmpeg flags:
  # -nostdin          don't read stdin (important in batch loops)
  # -crf 24           good balance for readable text in UI/screen recordings;
  #                   lower = sharper text, larger file (26+ can blur fine text)
  # -tag:v hvc1       Apple devices require hvc1 (not the default hev1) for HEVC
  # -fps_mode vfr     variable frame rate; reduces size on static sections
  #                   (remove if you see A/V sync issues in a specific player)
  # -ac 1             mono audio — great for meetings, saves space
  # -movflags +faststart  better streaming / quick start from cloud drives
  ffmpeg -nostdin -hide_banner -loglevel error -i "$f" \
    -c:v libx265 -preset slow -crf 24 -pix_fmt yuv420p -tag:v hvc1 -threads 0 \
    -fps_mode vfr \
    -c:a aac -b:a 96k -ac 1 \
    -movflags +faststart \
    "$out"

  touch -r "$f" "$out"
done

if $dry_run; then
  echo "Dry run: $count file(s) would be compressed, $skipped already done."
else
  echo "Done: $count compressed, $skipped already done."
fi
