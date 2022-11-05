## sample-shrinker.sh

Conditionally batch-convert audio samples into minimal .wav files


<!-- vim-markdown-toc GFM -->

* [Description](#description)
* [Usage](#usage)
  * [Basic use cases](#basic-use-cases)
  * [List samples + preview changes, based on the given options](#list-samples--preview-changes-based-on-the-given-options)
  * [Automatically convert stereo to mono when the content is mono](#automatically-convert-stereo-to-mono-when-the-content-is-mono)
  * [Normalize before downsampling bit-depth](#normalize-before-downsampling-bit-depth)
* [Setup](#setup)
  * [Requirements](#requirements)

<!-- vim-markdown-toc -->


## Description

This script scans directories for audio samples and batch-converts them into
small `.wav` files, based on target criteria.  This is useful to save storage
space and reduce the I/O stress during simultaneous real-time streaming
of multiple `.wav` files on devices like the [Dirtywave M8 tracker][m8].

If you have directories full of 24/32-bit stereo `.wav` files, or stereo
samples with effectively mono content, this script can reclaim wasted storage
space and reduce I/O stress on your SD card.  It can even detect if the content
of a stereo sample is actually mono & convert it for you.

## Usage

```console
bash sample-shrinker.sh [options] FILE|DIRECTORY ...
```

Each DIRECTORY is recursively searched for audio files to process, based
on their extension (`.wav` by default, configure with `-x`).  Any FILE
specified directly will be processed (regardless of its extension).

The basics:

- Samples are **converted in place**
  - The original file is backed up under '_backup/' (change with `-d`)
  - Backups generate spectrogram `.png` files to compare old & new files
    (disable with `-S`)
- Only samples that **DON'T meet the target** criteria will ever be changed
- Samples are only converted to SMALLER target bit-depth (`-b`) or channels (`-c`)
  - ...unless a minimum bit-depth is specified (`-B`, disabled by default)
- Stereo samples can be conditionally converted to mono using auto-mono (`-a`)
  - the threshold for automatic conversion is configurable (`-A`)


If a sample does not already meet the target BIT_DEPTH or CHANNELS, it will be
converted in place and the original will be backed up to a parallel directory
structure (default: `_backup`).

Upon conversion, spectrogram `.png` files are generated alongside the backed-up
original file, to compare the original vs new audio files (disable with `-S`)

You can review the characteristics of *all* sample files, and see if/why they
would be converted by running with `-l`.  You can preview only samples that
would change with `-n`.

Run `sample-shrinker.sh -h` to see all the options.


### Basic use cases

```console
bash sample-shrinker.sh directory_of_samples/
```

This uses the default options, where:

* The target bit-depth is `16` (change with `-b BITRATE`)
* Stereo channels are always left unchanged (change with `-a`, `-A DB`, or `-c1`)
* The original files are backed up to a parallel directory structure under
  `_backup/` (change location with `-d`)
* Spectrogram `.png` graphics that compare the old and new files are generated
  alongside the backed-up file (Use `-v` to pr


Unless you use `-v` to increase verbosity, the script will output one line per
sample, summarizing its properties and any changes it makes:

```console
bash sample-shrinker.sh -a -A-80 inst/ vocals/

16        st->m+A    -inf      16/16  inst/drums/anvil.wav  [CHANGED]
16        st->m+A    -84.29    16/16  inst/drums/kalimba.wav  [CHANGED]
16        st         -60.21    16/16  inst/drums/closed_hh.wav
8         mono                 8/8    inst/waves/triangle.wav
16        mono                 16/16  inst/waves/monowave.wav
24->16    mono                 23/24  vocals/otr-snippet.wav  [CHANGED]
32->16    st         -22.48    31/32  vocals/accapella.wav  [CHANGED]

```

* Changed files are followed by `[CHANGED]`
* Specific changes are denoted with `->`
  * If the change has additional was automatically decided, it will be followed
    with `+` and a character to describe the reason:
    * `+A`: decided by auto-mono (`-a`/`-A`)
    * `+P`: pre-normalize before down-converting bit-depth (`-p`)
    * `+M`: auto-converted to meet the minimum bit-depth (`-B`, unset by default)
* The columns are: bit depth, stereo, stereo diff, effective bit-depth, file path


### List samples + preview changes, based on the given options

Use `-l` to scan and list each sample, and summarize what would be changed
based on the other options:

```console
bash sample-shrinker.sh -l -a -A-80 inst/ vocals/

16        st->m+A    -inf      16/16  inst/drums/anvil.wav  [CHANGE]
16        st->m+A    -84.29    16/16  inst/drums/kalimba.wav  [CHANGE]
16        st         -60.21    16/16  inst/drums/closed_hh.wav
8         mono                 8/8    inst/waves/triangle.wav
16        mono                 16/16  inst/waves/monowave.wav
24->16    mono                 23/24  vocals/otr-snippet.wav  [CHANGE]
32->16    st         -22.48    31/32  vocals/accapella.wav  [CHANGE]

```

The output will look identical to conversion, but it will not alter any files


### Automatically convert stereo to mono when the content is mono

This detects stereo samples that are effectively mono and converts them to mono:

```console
bash sample-shrinker.sh -a dir1/ dir2/
```

Stereo content is "effectively mono" if―after summing its first two
channels after inverting one of them—the resulting Peak dB level is below -95.5
dB.

To configure the auto-mono threshold to be -80 dB:

```console
# Note: `-A` implies `-a`
bash sample-shrinker.sh -A -80 dir1/ dir2/
```

### Normalize before downsampling bit-depth

```console
bash sample-shrinker.sh -p dir1 dir2
```

Pre-normalizing before downsampling will preserve as much dynamic range as
possible, but it is disabled by default: if the sample is part of a
level-balanced collection (like a single hit from a drum kit), normalizing the
sample would change its relative volume with the rest of the collection.


## Setup

### Requirements

* Bash
  * Tested with Bash 5.1.16
  * Requires at least Bash 4.4 to support `${parameter@Q}` substitution
* [SoX][sox]
  * Tested with 14.4.2
  * Requires sox >= 14.3 to support automatic `--no-dither` for 8-bit samples


[sox]: https://sox.sourceforge.net/
[m8]: https://dirtywave.com/products/m8-tracker
