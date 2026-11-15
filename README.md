# fix-audio-msm8916
## Restore audio on Samsung Galaxy J5 (2016) and other Qualcomm MSM8916 phones running postmarketOS / Nura (OpenRC or systemd)

##Created using AI##

## Symptom this fixes

- `aplay -l` prints "no soundcards found"
- The desktop / `pactl list sinks` offers only "Dummy Output"

## Cause

The kernel's sound card is `qcom,msm8916-qdsp6-sndcard`. It is only created after the Hexagon DSP remoteproc (`4080000.remoteproc`, which also hosts the ADSP audio services) has been booted. On MSM8916 that remoteproc is started by `rmtfs -s`.

Minimal / converted installs often have rmtfs installed but not enabled in any OpenRC runlevel. Without rmtfs the DSP never boots, APR/q6afe/q6asm never appear, no ALSA card is created and the audio server falls back to a null sink ("Dummy Output").

This script enables + starts rmtfs (which boots the DSP), waits for the sound card, and then selects the built-in speaker profile and default sink in the running PulseAudio/PipeWire session.

## Usage

| Command | Description |
|---|---|
| `sudo ./fix-audio-msm8916.sh` | Do everything |
| `sudo ./fix-audio-msm8916.sh --status` | Only report state |
| `./fix-audio-msm8916.sh --session` | Only (re)apply routing |
| `sudo ./fix-audio-msm8916.sh --dry-run` | Show what would be done |
| `sudo ./fix-audio-msm8916.sh --install` | `apk add rmtfs` if missing |
| `sudo ./fix-audio-msm8916.sh --test` | Play a short test tone |

Safe to run repeatedly.
