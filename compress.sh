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
#   --dry-run              Show what would be compressed without doing anything.
#   --force                Reprocess files that already have a compressed version.
#   --progress             Show live ffmpeg encoding progress (time, speed, bitrate).
#   -h, --help             Show this message.
#
# Encoder (default: libx265:slow):
#   --encoder libx265:slow      Software encoder, best quality, smallest files (default).
#   --encoder libx265:fast      Software encoder, faster, slightly larger files.
#   --encoder videotoolbox      Apple hardware encoder. Uses the M-series media engine
#                               (~5x faster, ~3x larger files, slightly lower quality).
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
#   Video: HEVC / libx265 (best quality and compression for screen recordings).
#   Audio: AAC 96k mono (clear for voice, smaller files).
#
# Compatibility:
#   Written for macOS default Bash 3.2 (no mapfile/readarray). Works on Bash 5 too.

set -euo pipefail

current_tmp=""
trap 'echo "Interrupted. Exiting batch."; [[ -n "$current_tmp" ]] && rm -f "$current_tmp"; exit 130' INT

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
dry_run=false
force=false
progress=false
encoder="libx265:slow"
target_dir="."

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  dry_run=true ;;
    --force)    force=true ;;
    --progress) progress=true ;;
    --encoder)  shift; encoder="$1" ;;
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

suffix=" - compressed.mp4"

# -----------------------------------------------------------------------------
# Validate input
# -----------------------------------------------------------------------------
if [[ -f "$target_dir" ]]; then
  f="$target_dir"
  if [[ "$f" != *.mp4 ]]; then
    echo "Not an .mp4 file: $f" >&2; exit 1
  fi
  case "$f" in
    *"$suffix") echo "Already a compressed file: $f" >&2; exit 1 ;;
  esac
  dir_mode=false
elif [[ -d "$target_dir" ]]; then
  dir_mode=true
else
  echo "Not a file or directory: $target_dir" >&2; exit 1
fi

# -----------------------------------------------------------------------------
# Lockfile (directory mode only) — prevents concurrent instances from
# processing the same files; the running instance drains the queue instead.
# -----------------------------------------------------------------------------
if $dir_mode; then
  lockfile="/tmp/screenrec-compress-$(printf '%s' "$target_dir" | md5).lock"
  exec 9>"$lockfile"
  if ! flock -n 9; then
    echo "Another instance is already running — it will process any new files."
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# Main loop — in directory mode, re-scans after each pass to drain new arrivals
# -----------------------------------------------------------------------------
count=0
skipped=0
enc="${encoder%%:*}"
preset="${encoder##*:}"
[[ "$enc" == "$preset" ]] && preset="slow"

loglevel_flags=(-hide_banner -loglevel error)
$progress && loglevel_flags=(-hide_banner)

while true; do
  # Build file list for this pass
  files=()
  if $dir_mode; then
    while IFS= read -r f; do
      files+=("$f")
    done < <(
      ls -tU "$target_dir"/*.mp4 2>/dev/null \
        | tail -r \
        | grep -vF "$suffix" \
        || true
    )
  else
    files+=("$target_dir")
  fi

  new_this_pass=0

  for f in ${files[@]+"${files[@]}"}; do
    out="${f%.mp4}$suffix"

    if [[ -f "$out" ]] && ! $force; then
      continue
    fi

    (( count += 1 ))
    (( new_this_pass += 1 ))

    if $dry_run; then
      echo "[dry-run] $f"
      echo "       -> $out"
      continue
    fi

    tmp="$(dirname "$out")/.$(basename "$out").tmp"
    current_tmp="$tmp"

    echo "$f"
    echo "  -> $out"

    if [[ "$enc" == "videotoolbox" ]]; then
      ffmpeg -nostdin "${loglevel_flags[@]}" -i "$f" \
        -c:v hevc_videotoolbox -q:v 65 -tag:v hvc1 \
        -fps_mode vfr \
        -c:a aac -b:a 96k -ac 1 \
        -movflags +faststart \
        "$tmp"
    else
      ffmpeg -nostdin "${loglevel_flags[@]}" -i "$f" \
        -c:v libx265 -preset "$preset" -crf 24 -pix_fmt yuv420p -tag:v hvc1 -threads 0 \
        -fps_mode vfr \
        -c:a aac -b:a 96k -ac 1 \
        -movflags +faststart \
        "$tmp"
    fi

    touch -r "$f" "$tmp"
    mv "$tmp" "$out"
    current_tmp=""
  done

  # Single-file mode: always exit after one pass
  # Directory mode: exit only when a full pass found nothing new to process
  if ! $dir_mode || [[ $new_this_pass -eq 0 ]]; then
    break
  fi
done

if $dry_run; then
  echo "Dry run: $count file(s) would be compressed."
else
  echo "Done: $count compressed."
fi
