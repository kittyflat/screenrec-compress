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
#   --until HH:MM           Stop starting new files at/after this time today. The file
#                            already encoding is not interrupted -- only the next file
#                            in the queue is held back. For nightly off-hours runs.
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
until_time=""

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  dry_run=true ;;
    --force)    force=true ;;
    --progress) progress=true ;;
    --encoder)  shift; encoder="$1" ;;
    --until)    shift; until_time="$1" ;;
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
# Dedicated binaries (setup-fda-binaries.sh) — under launchd, a headless
# process touching an external volume needs Full Disk Access, and that
# can't safely be granted to the shared system/Homebrew binaries (used by
# everything else). If dedicated re-signed copies exist alongside this
# script, prefer them; otherwise fall back to PATH (fine for interactive
# runs, which don't hit the TCC restriction at all).
# -----------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_name="$(basename "$script_dir")"
resolve_bin() {
  local name="$1" dedicated="$script_dir/bin/${project_name}-$1"
  if [[ -x "$dedicated" ]]; then
    printf '%s' "$dedicated"
  else
    printf '%s' "$name"
  fi
}
ffmpeg_bin="$(resolve_bin ffmpeg)"
touch_bin="$(resolve_bin touch)"
mv_bin="$(resolve_bin mv)"
ls_bin="$(resolve_bin ls)"

# -----------------------------------------------------------------------------
# Deadline (--until) — computed once as today's date at HH:MM:SS, so it's a
# fixed point in time to compare against as the batch runs.
# -----------------------------------------------------------------------------
deadline_epoch=""
if [[ -n "$until_time" ]]; then
  if ! deadline_epoch="$(date -j -f "%H:%M:%S" "${until_time}:00" "+%s" 2>/dev/null)"; then
    echo "Invalid --until time: $until_time (expected HH:MM)" >&2
    exit 1
  fi
fi

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
  if ! command -v flock >/dev/null 2>&1; then
    echo "flock is required for directory mode but is not installed (brew install flock)." >&2
    exit 1
  fi
  lockfile="/tmp/screenrec-compress-$(printf '%s' "$target_dir" | cksum | cut -d' ' -f1).lock"
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
      "$ls_bin" -tU "$target_dir"/*.mp4 2>/dev/null \
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

    if [[ -n "$deadline_epoch" ]] && (( $(date "+%s") >= deadline_epoch )); then
      echo "Reached --until $until_time — stopping before starting: $f"
      break 2
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
      "$ffmpeg_bin" -nostdin "${loglevel_flags[@]}" -i "$f" \
        -c:v hevc_videotoolbox -q:v 65 -tag:v hvc1 \
        -fps_mode vfr \
        -c:a aac -b:a 96k -ac 1 \
        -movflags +faststart \
        -f mp4 "$tmp"
    else
      "$ffmpeg_bin" -nostdin "${loglevel_flags[@]}" -i "$f" \
        -c:v libx265 -preset "$preset" -crf 24 -pix_fmt yuv420p -tag:v hvc1 -threads 0 \
        -fps_mode vfr \
        -c:a aac -b:a 96k -ac 1 \
        -movflags +faststart \
        -f mp4 "$tmp"
    fi

    "$touch_bin" -r "$f" "$tmp"
    "$mv_bin" "$tmp" "$out"
    current_tmp=""
  done

  # Single-file mode: always exit after one pass
  # Dry-run: always exit after one pass -- it never creates the output file
  #   that the "already done" check relies on, so a second pass would just
  #   find the same files "new" again and loop forever.
  # Directory mode (non-dry-run): exit only when a full pass found nothing
  #   new to process.
  if ! $dir_mode || $dry_run || [[ $new_this_pass -eq 0 ]]; then
    break
  fi
done

if $dry_run; then
  echo "Dry run: $count file(s) would be compressed."
else
  echo "Done: $count compressed."
fi
