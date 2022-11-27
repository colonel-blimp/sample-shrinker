#!/bin/bash
# ------------------------------------------------------------------------------
# Bash wrapper for sox to down-convert M8 samples (requires sox)
# ------------------------------------------------------------------------------
# shellcheck disable=SC2155,SC2166

set -euo pipefail

script_name="$(basename "$0")"
usage_oneliner="Usage:  $script_name [options] DIRECTORY|FILE ..."

usage() {
  cat >&2 <<EOM
$usage_oneliner

Conditionally batch-convert audio samples into minimal .wav files

Each DIRECTORY is recursively searched for audio files to process, based
on their extension (.$src_extension by default, configure with -x).  Any FILE
specified directly will be processed (regardless of its extension).

If a sample does not already meet the target BIT_DEPTH or CHANNELS, it will be
converted in place and the original will be backed up to a parallel directory
structure (default: $backup_dir).

Upon conversion, spectrogram .png files are generated alongside the backed-up
original file to compare the original vs new audio files (disable with -S)

You can review the characteristics of *all* sample files, and see if/why they
would be converted by running with -l.  Preview only samples that would change
with -n.

Caveats:

- Samples are CONVERTED IN PLACE
  - The original file is backed up under '$backup_dir/' (change with -d)
  - Backups include spectrogram .pngs for old & new files (disable with -S)
- Only samples that DONT meet the target critera will be changed
- Samples are only converted to SMALLER target bit-depth (-b) or channels (-c)
  - ...unless a minimum bit-depth is specified (-B, disabled by default)
- Stereo samples can be conditionally converted to mono using auto-mono (-a)
  - the threshold for automatic conversion is configurable (-A)

Examples:

  Recursively convert samples under 'sample_dir/' using the default settings
  (max bit-depth: $target_bitdepth, stereo unchanged, original files backed up
  to the same relative location under '$backup_dir', with spectrogram .pngs
  generated alongside the backups):

        $script_name sample_dir/

  Also print the location to the new spectrogram file:

        $script_name -v sample_dir/

  Convert samples down to 8-bit, mono:

        $script_name -c1 -b8 sample_dir/

  Auto-convert "effectively mono" stereo samples to mono (see -a and -A):

        $script_name -a sample_dir/

  Auto-convert + auto-mono, with "efectively mono" = < -80 dB difference:

        $script_name -A-80 sample_dir/

  Print the location of spectrograms as they are generated:

        $script_name -v sample_dir/


Originally created to reduce the stress of streaming multiple simultaneous
.wav files from SD cards on devices like the Dirtywave M8 tracker

-x FILE_EXT
    Original sample file extension, used when searching under a DIRECTORY
    Default: $src_extension

-b BIT_DEPTH
    Target bit-depth for audio (only decreases)
    Downsamples only; does not affect audio files at or below this bit depth
    Valid values are '8' and '16'
    Default: $target_bitdepth

-B MINIMUM_BIT_DEPTH
    Minimum bit-depth of files (only increases)
    Upsamples only; does not affect audio files at or above this bit depth
    Valid values are '8' and '16'
    Default: ${minimum_bit_depth:-(none)}

-s SAMPLERATE
    Sets the samplerate of the output files
    Default: $target_samplerate

-c CHANNELS
    Target number of output channels (only decreases)
    Valid values are: 1 (mono) or 2 (stereo)
    Invalid values will be ignored, resulting in channels remaining unchanged
    Default: leave file channels unchanged

-a
    Auto-mono
    Automatically converts "effectively mono" stereo samples to actual mono

    "Effectively mono" = if the difference in Peak dB between its first two
    channels (one of which is phase-inverted) is below a threshold
    ($automono_threshold dB, configurable with -A)

-A DB_THRESHOLD
    Auto-mono threshold (implies -a)
    The (negative) Peak dB used to determine if a stereo sample is already
    "effectively mono" (See -a for details on auto-mono)
    Default: ${automono_threshold}

-p
   Pre-normalize sample before down-converting bit-depth.

   This preserves as much dynamic range as possible - but if the sample is part
   of a level-balanced collection it will change its volume relative to the
   other samples

-S
   Skip generating spectrogram .png files
   -d)

-d BACKUP_DIR
   Directory to stoe backed up original sample files
   Default: '$backup_dir'

-l
   list
   Dry run to identify all files based on how they would meet criteria

-o LOG_FILE
   Path for output log file (default: $log_file)

-n
   Dry run
   Log any actions that would be taken, but dont actually do anything

-v
   Increase verbosity (stacks)
   Print actions that are taken and relavent diagnostic information
   Default verbosity level: ${log_level} (${log_levels[$log_level]})

-h
    Display this help message and exit

EOM
}

# Log-level functions
# --------------------------------------
function .log () {
  local level="$1"
  shift
  if [[ $log_level -ge $level ]]; then
    printf "%-8s %s\n" "[${log_levels[$level]}]" "$@" |& tee -a "$log_file"
  fi
}
function .fatal() { >&2 .log 0 "$@"; }
function .error() { >&2 .log 1 "$@"; }
function .warn () { >&2 .log 2 "$@"; }
function .info() { .log 3 "$@"; }
function .notice() { .log 4 "$@"; }
function .debug() { >&2 .log 5 "$@"; }
function .trace() { >&2 .log 6 "$@"; }
# --------------------------------------


is_stereo_effectively_mono()
{
  local input="$1"
  if [[ "$(soxi -c "$input")" -lt 2 ]]; then
    return 1
  fi

  local stereo_diff="$(sox -V1 "$input" -n remix 1,2i stats |& grep '^Pk lev dB' | awk '{print $NF}')"

  .debug "[is_stereo_effectively_mono] $stereo_diff dB diff (threshold: $automono_threshold dB)"
  if [[ $stereo_diff == '-inf' ]] || [ "$(echo "$stereo_diff < $automono_threshold" | bc)" -eq 1 ]  ; then
    .notice "Stereo sample is effectively mono: ($stereo_diff dB): '$input'"
    return 0
  fi
  return 1
}


# Summarize sample and any prospective changs in orderly columns
one_line_sample_summary()
{
  local src="$1"
  local change_summary="$2"
  local stereo_diff="$3"
  local sox_bit_depth="$4"
  if [[ -z $stereo_diff ]]; then
    printf "%s         %6s" "$change_summary" "$sox_bit_depth"
  else
    printf "%s   %7s   %6s" "$change_summary" "$stereo_diff" "$sox_bit_depth"
  fi
}


# Determine what do to about bitrate
# - updates $change_summary with a text summary
# - updates $*_args with sox args
prep_bitdepth_convert()
{
  # Prepare bit-depth conversion
  if [[ $bitdepth -ne $target_bitdepth ]]; then
    change_summary="${bitdepth}       "
    if [[ $bitdepth -gt $target_bitdepth ]]; then
      change_summary="${bitdepth}->${target_bitdepth}"
      if [[ ${pre_normalize:-no} == yes ]]; then
        src_args+=(--norm=-0.1)  # =-0.1 acts as a guard volume for normalize
        change_summary="$change_summary+p"
      else
        change_summary="$change_summary  "
      fi
      dst_args+=(--bits="$target_bitdepth")

      # sox's dither down to 8-bit always sounds terrible
      [[ $target_bitdepth -eq 8 ]] && dst_args+=(--no-dither)

      if [[ $bitdepth -eq 32 ]]; then
        # There's a common problem in 32-bit .wav samples, where the .wav is technically malformed
        # The error message is "play WARN wav: wave header missing extended part of fmt chunk"
        if [[ "$encoding" == 'Signed Integer PCM' ]]; then
          src_args+=(-e signed-integer)
        elif [[ "$encoding" == 'Floating Point PCM' ]]; then
          #src_args+=(-G)
          src_args+=(-e floating-point)
        else
          .error "SKIP (don't know how to handle 32-bit encoding '$encoding'): $src"
          return 0
        fi
      fi

    # Raise below-minimum bit-depth samples to minimum bit-depth (default: 8)
    elif (( bitdepth < target_bitdepth && bitdepth < 8 )); then
      if [[ -n $minimum_bit_depth ]]; then
        dst_args+=(--bits="$minimum_bit_depth")

        # sox's dither down to 8-bit always sounds terrible
        [[ $minimum_bit_depth -eq 8 ]] && dst_args+=(--no-dither)

        change_summary="${bitdepth}->$minimum_bit_depth+M"
      fi
    fi
  else
    change_summary="${bitdepth}      "
  fi
}


# Determine what do to about sample rate
# - updates $change_summary with a text summary
# - updates $*_args with sox args
prep_samplerate_convert()
{
  # Prepare samplerate conversion
  if [[ $samplerate -ne $target_samplerate ]]; then
    change_summary=$change_summary"${samplerate}      "
    if [[ $samplerate -gt $target_samplerate ]]; then
      change_summary=$change_summary"${samplerate}->${target_samplerate}"
      dst_args+=(--rate="$target_samplerate")

    # Raise below-minimum samplerate samples to minimum samplerate (default: 11025)
    elif (( samplerate < target_samplerate && samplerate < 11025 )); then
      if [[ -n $minimum_samplerate ]]; then
        dst_args+=(--rate="$minimum_samplerate")

        change_summary=$change_summary"${samplerate}->$minimum_samplerate+M"
      fi
    fi
  else
    change_summary=$change_summary"${samplerate}      "
  fi
}


prep_mono_convert()
{
  # Prepare channel conversion
  #   Intended for stereo -> mono, but should handle any number of channels
  #   (Not sure that's useful)
  local stereo_diff=""
  local sox_bit_depth="$(sox -V1 "$src" -n stats |& grep '^Bit-depth' | awk '{print $NF}')"
  local ch_stat="${channels}ch"
  if [[ $channels -gt 1 ]]; then
    stereo_diff="$(sox -V1 "$src" -n remix 1,2i stats |& grep '^Pk lev dB' | awk '{print $NF}')"
    [[ $channels -eq 2 ]] && ch_stat="st"
    if [[ $auto_mono == 'yes' ]] && is_stereo_effectively_mono "$src"; then
      .notice "|auto-mono| Converting to mono: $src"
      post_args+=(remix "1-$channels")
      ch_stat="$ch_stat->m+A"
    elif [[ $channels > $target_channels  ]]; then
      .debug "|channels| Channels > target_channels"
      ch_stat="$ch_stat->m  "
      post_args+=(remix "1-$channels")
    else
      ch_stat="$ch_stat     "
    fi
  else
    ch_stat="mono       "
  fi
  change_summary="$(one_line_sample_summary "$src" "$change_summary  ${ch_stat}" "$stereo_diff" "$sox_bit_depth")"
}


convert()
{
  local src="$1"

  .notice ''
  .notice " $src"
  .notice '-----------------------------------------------------------------------'

  local channels="$(soxi -V1 -c "$src")"
  local bitdepth="$(soxi -V1 -b "$src")"
  local samplerate="$(soxi -V1 -r "$src")"
  local encoding="$(soxi -V1 -e "$src")"

  local change_summary=""
  local dst_args=()
  local src_args=()
  local post_args=()

  # ----------------------
  # These functions access the (dynamically-scopped) variables above like globals
  # and build up the contents of $change_summary and $*_args
  # They used to live here, but it's already a sprawl
  prep_bitdepth_convert
  prep_samplerate_convert
  prep_mono_convert
  # ----------------------

  local change_status='[CHANGED]'
  { [[ $action == list ]] || [[ $dry_run == yes ]]; } && change_status='[CHANGE]'

  change_summary="$change_summary  ${src@Q}"
  [[ ! ${src,,} =~ .wav$ ]] && change_summary="${change_summary}->.wav"
  [[ $change_summary =~ '->' ]] && change_summary="$change_summary  $change_status"

  # list reports ALL files (but doesn't log them)
  if [[ $action == list ]]; then
    echo "$change_summary"
    return 0
  fi

  .debug  '[convert] .............................................................'
  .debug  "[convert] bit-depth: $bitdepth  (target: $target_bitdepth)"
  .debug  "[convert] samplerate: $samplerate  (target: $target_samplerate)"
  .debug  "[convert] channels: $channels   (target: $target_channels)"

  # Skip conversion if no changes are required
  if [[ ${src,,} =~ .wav$ ]] && [[ "${#dst_args[@]}" == 0 ]] && [[ "${#src_args[@]}" == 0 ]] && [[ "${#post_args[@]}" == 0 ]]; then
     .debug  '[convert] .............................................................'
     .notice "[convert] SKIP (nothing to change):  $src "
     return 0
  fi

  .debug  "[convert] dst_args:  '${#dst_args[@]}'"
  .debug  "[convert] src_args:  '${src_args[*]}'"
  .debug  "[convert] post_args: '${post_args[*]}'"
  .debug  '[convert] .............................................................'

  local dst="${src%.*}".wav
  local tmp_dst=
  local sox_args=("${src_args[@]}" "$src" "${dst_args[@]}" "$dst" "${post_args[@]}")

  # (SD card is case insensitive)
  [[ ${src^^} == "${dst^^}" ]] && tmp_dst="${src%.*}.$$".wav

  sox_args=("${src_args[@]}" "$src" "${dst_args[@]}" "${tmp_dst:-$dst}" "${post_args[@]}")

  local flat_parent_dir="$( cd -- "$(dirname "$src")" >/dev/null 2>&1 ; pwd -P )"
  local b_src_dir="$backup_dir/${flat_parent_dir#$PWD/}"

  if [[ "$dry_run" == yes ]]; then
    echo "[DRY RUN] $change_summary" |& tee -a "$log_file"
    .notice "[convert] DRY RUN: sox  $(printf "%q " "${sox_args[@]}")"
  else
    # Convert sample
    echo "$change_summary" |& tee -a "$log_file"
    .notice "[convert] sox $(printf "%q " "${sox_args[@]}")"

    mkdir -p "$b_src_dir"

    if [[ -n "$tmp_dst" ]]; then
      .notice "[convert] ( using tmp_dst: '$tmp_dst' )"
      cp "$src" "$b_src_dir/"
      sox "${sox_args[@]}" |& tee -a "$log_file" && mv "$tmp_dst" "$dst"
    else
      sox -V5 "${sox_args[@]}" |& tee -a "$log_file" && mv "$src" "$b_src_dir/"
    fi
  fi



  local b_src="$(basename "$src")"
  local sg_dst="${b_src%.*}".wav  # FIXME how did this work?
  local sg_old_png="${b_src_dir}/$b_src.old.png"
  local sg_new_png="${b_src_dir}/$sg_dst.new.png"

  .debug "[backup] b_src_dir = '$b_src_dir'"
  .debug "[backup] b_src = '$b_src'"
  .debug "[backup] src = '$src'"
  .debug "[backup] dst = '$dst'"
  .debug "[backup] sg_dst = '$sg_dst'"

  if [[ "$dry_run" == yes ]]; then
    .debug -- sox -V1 "${b_src_dir}/$b_src" -n spectrogram -o "$sg_old_png"
    .debug -- sox -V1 "$dst" -n spectrogram -o "$sg_new_png"
    return 0
  fi

  if [[ $generate_spectrograms == yes ]]; then

    sox -V1 "${b_src_dir}/$b_src" -n spectrogram -o "$sg_old_png"
    sox -V1 "$dst" -n spectrogram -o "$sg_new_png"

    .debug "$(ls -lrth "${b_src_dir}/${b_src}" "$dst")"
    .notice "$(soxi "${b_src_dir}/${b_src}" "$dst" 2>&1)"

    .info "$(printf 'xdg-open "%s"\n' "$sg_new_png")"
    #printf 'xdg-open "%s"\n' "${b_src_dir}/$b_src.png"
  fi
}


select_and_process_files()
{
  local src="$1"
  local input
  local inputs=()

  if [ -d "$src" ]; then
    while IFS= read -r -d $'\0' input; do
      .debug "  INPUT: $input"
      inputs+=("$input")
    done < <(find "$src" -type f -iname "*.${src_extension}" -print0 )
  elif [ -f "$src" ]; then
    inputs+=("$src")
  else
    .warn "SKIPPING: Not a file or directory: '$src'"
  fi

  .debug "\n%%%% INPUTS: %s\n" "${#inputs[@]}"

  for input in "${inputs[@]}"; do
    [ -f "$input" ] ||  { .warn "SKIPPING: no such file: '$input'"; continue ; }
    convert "$input"
 done
}

target_channels=2
target_bitdepth=16
target_samplerate=44100
dry_run=no
action=convert
auto_mono=no
pre_normalize=no
src_extension=wav
backup_dir=_backup
automono_threshold='-95.5'
minimum_bit_depth=
minimum_samplerate=
generate_spectrograms=yes
log_file="_${script_name%%.*}.log"

declare -A log_levels
log_levels=([0]="FATAL" [1]="ERROR" [2]="WARNING" [3]="INFO" [4]="NOTICE" [5]="DEBUG" [6]="TRACE")
log_level=2

while getopts 'b:B:r:R:c:x:paA:Sd:lo:nvh' opt; do
  case "${opt}" in
    b)
      if [ "$OPTARG" -ne 8 -a "$OPTARG" -ne 16 -a "$OPTARG" -ne 24 ]; then
        .error "-b takes a bit-depth of either 8, 16, or 24; got invalid value: '$OPTARG'"
        exit 1
      fi
      target_bitdepth="${OPTARG}"
      ;;
    B)
      if [ "$OPTARG" -ne 8 -a "$OPTARG" -ne 16 -a "$OPTARG" -ne 24 ]; then
        .error "-B takes a bit-depth of either 8, 16, or 24; got invalid value: '$OPTARG'"
        exit 1
      fi
      minimum_bit_depth="${OPTARG}"
      ;;
    r)
      if ! [[ "$OPTARG" =~ ^[0-9]+$ ]]; then
        .error "-r must be an integer; got invalid value: '$OPTARG'"
        exit 1
      fi
      target_samplerate="${OPTARG}"
      ;;
    R)
      if ! [[ "$OPTARG" =~ ^[0-9]+$ ]]; then
        .error "-R must be an integer; got invalid value: '$OPTARG'"
        exit 1
      fi
      minimum_samplerate="${OPTARG}"
      ;;
    c) target_channels="${OPTARG}" ;;
    x) src_extension="${OPTARG}" ;;
    p) pre_normalize=yes ;;
    a) auto_mono=yes ;;
    A)
      if [[ ! $OPTARG =~ ^-[0-9]+\.?[0-9]*$ ]]; then
        .error "-A takes a negative floating point number (default: '$automono_threshold'); got invalid value: '$OPTARG'"
        exit 1
      fi
      auto_mono=yes
      automono_threshold="${OPTARG}"
      ;;
    S) generate_spectrograms=no ;;
    d) backup_dir="${OPTARG}" ;;
    l) action=list ;;
    o) log_file="${OPTARG}" ;;
    n) dry_run=yes ;;
    v)
      (( ++log_level ))
      [ "$log_level" -gt 5 ] && log_level=5
      ;;
    h | *)
      usage
      exit 0
      ;;
  esac
done
shift $((OPTIND-1))

.debug "----------------------------------------------------------------------"
.debug "                  Settings after parsing CLI options:"
.debug "----------------------------------------------------------------------"
.debug "action:              ${action}"
.debug "src_extension:       ${src_extension}"
.debug "target_channels:     ${target_channels}"
.debug "target_bitdepth:     ${target_bitdepth}"
.debug "target_samplerate:   ${target_samplerate}"
.debug "auto_mono:           ${auto_mono}"
.debug "automono_threshold:  ${automono_threshold} dB"
.debug "pre_normalize:       ${pre_normalize}"
.debug "backup_dir:          ${backup_dir}"
.debug "log_level:           ${log_levels[$log_level]} ($log_level)"
.debug "dry_run:             ${dry_run}"
.debug "----------------------------------------------------------------------"


if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

for arg in "$@"; do
  if [[ $arg =~ ^- ]] && [ ! -f "$arg" -a ! -d "$arg" ]; then
    cat >&2 <<EOM

ERROR: Argument '$arg' looks like an option, and is not a FILE or DIRECTORY
(Options must be provided before all files and directories)

$usage_oneliner
Try '$0 --help' for more details

EOM
    exit 1
  fi
done

[[ $action != list ]] && echo > "$log_file"
for file_or_dir in "$@"; do
  .debug "main: '$file_or_dir'"
  select_and_process_files "$file_or_dir"
done
