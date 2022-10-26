#!/bin/bash
# ------------------------------------------------------------------------------
# Bash wrapper for sox to down-convert M8 samples (requires sox)
# ------------------------------------------------------------------------------
# shellcheck disable=SC2155,SC2166

set -euo pipefail

usage_oneliner="Usage:  $0 [options] FILE|DIRECTORY ..."

usage() {
  cat >&2 <<EOM
$usage_oneliner

Conditionally batch-convert audio samples into minimal .wav files

If a sample does not already meet the target BITDEPTH or CHANNELS, it will be
converted in place and the original will be backed up to a parallel directory
structure (default: $backup_dir).

Each DIRECTORY is recursively searched for audio files to process, based
on their extension (.$src_extension by default, configure with -x EXT).

Each FILE will be processed, regardless of its extension.

- Only samples that don't already meet the target critera will be changed
- Samples are only converted to a smaller target bitdepth/chanels (never higher)
- Stereo samples can be conditionally converted to mono using -a (auto-mono)

Examples:

  Recursively convert samples under 'sample_dir/' using the default settings
  (max bitdepth: $target_bitdepth, stereo unchanged, original files backed up
  to the same relative location under '$backup_dir'):

        $0 sample_dir/


  Convert samples to 8-bit, mono:

        $0 -c1 -b8 sample_dir/


  Auto-convert effectively mono stereo samples to mono (see -a and -A)

        $0 -a sample_dir/


Originally created to reduce the stress of streaming multiple simultaneous
.wav files from SD cards on devices like the Dirtywave M8 tracker

-x FILE_EXT
    Original sample file extension, used when searching under a DIRECTORY
    Default: $src_extension

-b BITDEPTH
    Target bitdepth of files (only decreases)
    Will not force bitdepths to be higher than they already are
    Valid values are '8' and '16'
    Default: $target_bitdepth

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

-A DB
    Auto-mono threshold (implies -a)
    The (negative) Peak dB used to determine if a stereo sample is already
    "effectively mono" (See -a for details on auto-mono)
    Default: ${automono_threshold}

-p
   Pre-normalize sample before down-converting bitdepth.

   This preserves as much dynamic range as possible - but if the sample is part
   of a level-balanced collection it will change its volume relative to the
   other samples

-s
   Generate spectrogram .png files for the original and converted file at the
   same relative location under the backup directory (see -d)

-d BACKUP_DIR
   Directory to stoe backed up original sample files
   Default: '$backup_dir'

-l
   List
   Dry run that identifies all files based on how they would meet criteria

-n
   Dry run
   Log any actions that would be taken, but don't actually do anything

-v
   Increase verbosity (stacks)
   Print actions that are taken and relavent diagnostic information
   Default verbosity level: ${log_level} (${log_levels[$log_level]})

-h
    Display this help message and exit

EOM
}

function .log () {
  local level="$1"
  shift
  if [[ $log_level -ge $level ]]; then
    printf "%-8s %s\n" "[${log_levels[$level]}]" "$@" |& tee -a out.log
  fi
}
function .fatal() { >&2 .log 0 "$@"; }
function .error() { >&2 .log 1 "$@"; }
function .warn () { >&2 .log 2 "$@"; }
function .info() { .log 3 "$@"; }
function .notice() { .log 4 "$@"; }
function .debug() { >&2 .log 5 "$@"; }
function .trace() { >&2 .log 6 "$@"; }


is_stereo_effectively_mono()
{
  local input="$1"
  if [[ "$(soxi -c "$input")" -lt 2 ]]; then
    return 1
  fi

  local stereo_diff="$(sox "$input" -n remix 1,2i stats |& grep '^Pk lev dB' | awk '{print $NF}')"

  .debug "[is_stereo_effectively_mono] $stereo_diff dB diff (threshold: $automono_threshold dB)"
  if [[ $stereo_diff == '-inf' ]] || [ "$(echo "$stereo_diff < $automono_threshold" | bc)" -eq 1 ]  ; then
    .notice "Stereo sample is effectively mono: ($stereo_diff dB): '$input'"
    return 0
  fi
  return 1
}

print_sample_summary()
{
  local src="$1"
  local change_summary="$2"
  local stereo_diff="$3"
  local sox_bit_depth="$4"
  if [[ -z $stereo_diff ]]; then
    printf "%s         %6s  %s\n" "$change_summary" "$sox_bit_depth" "$src"
  else
    printf "%s   %7s   %6s  %s\n" "$change_summary" "$stereo_diff" "$sox_bit_depth" "$src"
  fi
}

convert()
{
  local src="$1"
  .notice ''
  .notice " $src"
  .notice '-----------------------------------------------------------------------'

  local b_src_dir="$backup_dir/$(dirname "$src")"
  local b_src="$(basename "$src")"
  local orig_ext="${src##*.}"
  local b_dst="${b_src%.${orig_ext}}".wav
  local dst="${src%.${orig_ext}}".wav

  local channels="$(soxi -V1 -c "$src")"
  local bitdepth="$(soxi -V1 -b "$src")"

  local dst_args=()
  local src_args=()
  local post_args=()
  local change_summary=""

  # Prepare bitdepth conversion
  if [[ $bitdepth -ne $target_bitdepth ]]; then
    change_summary="${bitdepth}       "
    if [[ $bitdepth -gt $target_bitdepth ]]; then
      # =-0.1 acts as a guard volume for normalize
      change_summary="${bitdepth}->${target_bitdepth}"
      if [[ ${pre_normalize:-no} == yes ]]; then
        src_args+=(--norm=-0.1)
        change_summary="$change_summary+p"
      else
        change_summary="$change_summary  "
      fi
      dst_args+=(--bits="$target_bitdepth")

      # sox's dither down to 8bit always sounds terrible, so turn it off
      if [[ $target_bitdepth -eq 8 ]]; then
        dst_args+=(--no-dither)
      fi
      if [[ $bitdepth -eq 32 ]]; then
        src_args+=(-e floating-point)
      fi
    # Raise below-minimum bitdepth samples to minimum bitdepth (8)
    elif (( bitdepth < target_bitdepth && bitdepth < 8 )); then
      dst_args+=(--bits="$target_bitdepth")
      change_summary="${bitdepth}->${target_bitdepth}+M"
    fi
  else
    change_summary="${bitdepth}      "
  fi

  # Prepare channel conversion
  #   Intended for stereo -> mono, but should handle any number of channels
  #   (Not sure that's useful)
  local ch_stat="${channels}ch"
  local stereo_diff=""
  local sox_bit_depth="$(sox -V1 "$input" -n stats |& grep '^Bit-depth' | awk '{print $NF}')"
  if [[ $channels -gt 1 ]]; then
    stereo_diff="$(sox -V1 "$input" -n remix 1,2i stats |& grep '^Pk lev dB' | awk '{print $NF}')"
    [[ $channels -eq 2 ]] && ch_stat="st"
    if [[ $auto_mono == 'yes' ]] && is_stereo_effectively_mono "$input"; then
      .notice "|auto-mono| Converting to mono: $input"
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
    ch_stat="mono      "
  fi
  change_summary="$change_summary  ${ch_stat}"


  if [[ $action == list ]]; then
    print_sample_summary "$src" "$change_summary" "$stereo_diff" "$sox_bit_depth"
    return 0
  fi

  # Don't convert sample if changes aren't required
  if [[ ${src,,} =~ .wav$ ]] && [[ "${#dst_args[@]}" == 0 ]] && [[ "${#src_args[@]}" == 0 ]] && [[ "${#post_args[@]}" == 0 ]]; then
     .debug  '[convert] .............................................................'
     .debug  "[convert] bitdepth: $bitdepth  (target: $target_bitdepth)"
     .debug  "[convert] channels: $channels   (target: $target_channels)"
     .debug  '[convert] .............................................................'
     .notice "[convert] SKIP (nothing to change):  $src "
     return 0
  fi

   .debug  '[convert] .............................................................'
   .debug  "[convert] bitdepth: $bitdepth  (target: $target_bitdepth)"
   .debug  "[convert] channels: $channels   (target: $target_channels)"
   .debug  "[convert] dst_args (${#dst_args[@]}): '${dst_args[*]}'"
   .debug  "[convert] src_args: '${src_args[*]}'"
   .debug  "[convert] post_args: '${post_args[*]}'"
   .debug  '[convert] .............................................................'

  if [[ "$dry_run" == yes ]]; then
    echo -n '[DRY RUN] '
    print_sample_summary "$src" "$change_summary" "$stereo_diff" "$sox_bit_depth"
    .notice "[convert] DRY RUN: sox ${src_args[*]} '$src' ${dst_args[*]} '$dst' ${post_args[*]}"
    return 0
  fi

  # Convert sample
  print_sample_summary "$src" "$change_summary" "$stereo_diff" "$sox_bit_depth"
  .notice "[convert] sox ${src_args[*]} '$src' ${dst_args[*]} '$dst' ${post_args[*]}"

  mkdir -p "$b_src_dir"
  # SD card is case insensitive, so compare both paths as uppercase
  if [[ ${src^^} == "${dst^^}" ]]; then
    .debug '[convert] src == dst'
    cp "$src" "$b_src_dir/"
    sox "${src_args[@]}" "$src" "${dst_args[@]}" "$dst.$$.wav" "${post_args[@]}" |& tee -a out.log \
      && mv "$dst.$$.wav" "$dst"
  else
    .debug '[convert] src != dst'
    sox -V5 "${src_args[@]}" "$src" "${dst_args[@]}" "$dst" "${post_args[@]}" |& tee -a out.log \
      && mv "$src" "$b_src_dir/"
  fi

  .debug "[backup] b_src_dir = '$b_src_dir'"
  .debug "[backup] src = '$src'"
  .debug "[backup] dst = '$dst'"

  if [[ $generate_spectrograms == yes ]]; then
    local b_ext=''
    if [[ ${src^^} == "${dst^^}" ]]; then
      b_ext="new."
    fi
    sox "${b_src_dir}/$b_src" -n spectrogram -o "${b_src_dir}/$b_src.png"
    sox "$dst" -n spectrogram -o "${b_src_dir}/$b_dst.${b_ext}png"
    ls -lrth "${b_src_dir}/${b_src}" "$dst"
    soxi "${b_src_dir}/${b_src}" "$dst"
    printf 'xdg-open "%s"\n' "${b_src_dir}/$b_dst.${b_ext}png"
    printf 'xdg-open "%s"\n' "${b_src_dir}/$b_src.png"
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
dry_run=no
action=convert
auto_mono=no
pre_normalize=no
src_extension=wav
backup_dir=_backup
automono_threshold='-95.5'
generate_spectrograms=no

declare -A log_levels
log_levels=([0]="FATAL" [1]="ERROR" [2]="WARNING" [3]="INFO" [4]="NOTICE" [5]="DEBUG" [6]="TRACE")
log_level=3

while getopts 'b:c:x:paA:sd:lnvh' opt; do
  case "${opt}" in
    b)
      if [ "$OPTARG" -ne 8 -a "$OPTARG" -ne 16 -a "$OPTARG" -ne 24 ]; then
        .error "-b takes a bitdepth of either 8, 16, or 24; got invalid value: '$OPTARG'"
        exit 1
      fi
      target_bitdepth="${OPTARG}"
      ;;
    c) target_channels="${OPTARG}" ;;
    x) src_extension="${OPTARG}" ;;
    p) pre_normalize=yes ;;
    a) auto_mono=yes ;;
    A)
      if [[ ! $OPTARG =~ ^[-+]?[0-9]+\.?[0-9]*$ ]]; then
        .error "-A takes a floating point number (default: '$automono_threshold'); got invalid value: '$OPTARG'"
        exit 1
      fi
      auto_mono=yes
      automono_threshold="${OPTARG}"
      ;;
    s) generate_spectrograms=yes ;;
    d) backup_dir="${OPTARG}" ;;
    l) action=list ;;
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
.debug "auto_mono:           ${auto_mono}"
.debug "automono_threshold:  ${automono_threshold} dB"
.debug "pre_normalize:       ${pre_normalize}"
.debug "backup_dir:          ${backup_dir}"
.debug "log_level:           ${log_levels[$log_level]} ($log_level)"
.debug "dry_run:             ${dry_run}"
.debug "----------------------------------------------------------------------"

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

echo > out.log
for file_or_dir in "$@"; do
  .debug "main: '$file_or_dir'"
  select_and_process_files "$file_or_dir"
done
