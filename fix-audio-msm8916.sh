#!/bin/sh
# ============================================================================
# fix-audio-msm8916.sh
#
# Restore audio on Samsung Galaxy J5 (2016) and other Qualcomm MSM8916
# phones running postmarketOS / Nura (OpenRC or systemd).
#
# Symptom this fixes
# ------------------
#   - `aplay -l` prints "no soundcards found"
#   - the desktop / `pactl list sinks` offers only "Dummy Output"
#
# Cause
# -----
#   The kernel's sound card is "qcom,msm8916-qdsp6-sndcard".  It is only
#   created after the Hexagon DSP remoteproc (4080000.remoteproc, which
#   also hosts the ADSP audio services) has been booted.  On MSM8916 that
#   remoteproc is started by `rmtfs -s`.
#
#   Minimal / converted installs often have rmtfs installed but not
#   enabled in any OpenRC runlevel.  Without rmtfs the DSP never boots,
#   APR/q6afe/q6asm never appear, no ALSA card is created and the audio
#   server falls back to a null sink ("Dummy Output").
#
#   This script enables + starts rmtfs (which boots the DSP), waits for
#   the sound card, and then selects the built-in speaker profile and
#   default sink in the running PulseAudio/PipeWire session.
#
# Usage
# -----
#   sudo ./fix-audio-msm8916.sh            # do everything
#   sudo ./fix-audio-msm8916.sh --status   # only report state
#   ./fix-audio-msm8916.sh --session       # only (re)apply routing
#   sudo ./fix-audio-msm8916.sh --dry-run  # show what would be done
#   sudo ./fix-audio-msm8916.sh --install  # apk add rmtfs if missing
#   sudo ./fix-audio-msm8916.sh --test     # play a short test tone
#
# Safe to run repeatedly.
# ============================================================================

set -u

MODE=full
DRY_RUN=0
DO_INSTALL=0
DO_TEST=0

usage() {
	cat <<'EOF'
Usage: fix-audio-msm8916.sh [options]

Options:
  --session    only (re)apply the PulseAudio/PipeWire card profile,
               default sink and unmute; does not need root
  --status     print current DSP/card/audio-server state and exit
  --dry-run    print the privileged commands instead of running them
  --install    install rmtfs with apk if it is missing
  --test       play a short 440 Hz test tone when done
  -h, --help   show this help
EOF
}

for arg in "$@"; do
	case "$arg" in
		--session) MODE=session ;;
		--status)  MODE=status ;;
		--dry-run) DRY_RUN=1 ;;
		--install) DO_INSTALL=1 ;;
		--test)    DO_TEST=1 ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'Unknown option: %s\n\n' "$arg" >&2; usage; exit 2 ;;
	esac
done

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Run a command, or only print it in dry-run mode.
run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '    + %s\n' "$*"
		return 0
	fi
	"$@"
}

# ---------------------------------------------------------------------------
# Some small helpers
# ---------------------------------------------------------------------------

detect_init() {
	if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
		INIT=systemd
	elif command -v rc-service >/dev/null 2>&1; then
		INIT=openrc
	else
		INIT=unknown
	fi
}

card_present() {
	[ -r /proc/asound/cards ] || return 1
	grep -q 'no soundcards' /proc/asound/cards 2>/dev/null && return 1
	grep -q '^[[:blank:]]*[0-9]' /proc/asound/cards 2>/dev/null
}

show_rprocs() {
	for r in /sys/class/remoteproc/*; do
		[ -e "$r" ] || continue
		printf '    %-24s %s\n' "$(cat "$r/name" 2>/dev/null)" \
			"$(cat "$r/state" 2>/dev/null)"
	done
}

diagnose() {
	printf '\n--- diagnostics ---\n' >&2
	printf 'remoteprocs:\n' >&2
	show_rprocs >&2
	printf 'service status:\n' >&2
	case "$INIT" in
		openrc)  rc-service rmtfs status >&2 2>&1 || true ;;
		systemd) systemctl status rmtfs.service --no-pager -n 5 >&2 2>&1 || true ;;
	esac
	if [ "$(id -u)" = 0 ] && command -v dmesg >/dev/null 2>&1; then
		printf 'recent kernel messages:\n' >&2
		dmesg 2>/dev/null | grep -iE \
			'remoteproc|smd|apr|q6|snd|sound|codec|mba|firmware' \
			| tail -n 25 >&2
	fi
}

# ---------------------------------------------------------------------------
# System part: enable/start rmtfs so the DSP boots and ALSA gets a card
# ---------------------------------------------------------------------------

system_setup() {
	detect_init
	log "init system: $INIT"

	compat=$(tr -d '\000' < /proc/device-tree/compatible 2>/dev/null || true)
	case "$compat" in
		*qcom,msm8916*) ;;
		*) warn "this does not look like an MSM8916 device; continuing anyway" ;;
	esac

	if ! command -v rmtfs >/dev/null 2>&1; then
		if [ "$DO_INSTALL" = 1 ]; then
			log "installing rmtfs"
			run apk add --no-cache rmtfs || die "apk add rmtfs failed"
		else
			die "rmtfs is not installed. Run: apk add rmtfs  (or use --install)"
		fi
	fi

	if [ "$INIT" = openrc ] && [ ! -x /etc/init.d/rmtfs ]; then
		if [ "$DO_INSTALL" = 1 ]; then
			run apk add --no-cache rmtfs-openrc || die "apk add rmtfs-openrc failed"
		else
			die "OpenRC service missing. Run: apk add rmtfs-openrc  (or use --install)"
		fi
	fi

	# The modem firmware blobs (mba.mbn/modem.mbn) are extracted by
	# msm-firmware-loader into a runtime directory.  Without this path
	# the DSP remoteproc cannot load its firmware.
	fwpath=$(cat /sys/module/firmware_class/parameters/path 2>/dev/null || true)
	if [ -z "$fwpath" ]; then
		warn "firmware_class path is empty; msm-firmware-loader has not run."
		warn "The DSP may fail with 'unable to load mba'."
		warn "A reboot normally fixes this (the loader is in the sysinit runlevel)."
	fi

	case "$INIT" in
		openrc)
			run rc-update add rmtfs default || true
			if rc-service rmtfs status >/dev/null 2>&1; then
				if card_present; then
					log "rmtfs is running and a sound card is present"
				else
					log "rmtfs is running but there is no sound card; restarting it"
					run rc-service rmtfs restart || true
				fi
			else
				log "enabling and starting rmtfs"
				run rc-service rmtfs start || true
			fi
			;;
		systemd)
			run systemctl enable rmtfs.service || true
			if systemctl is-active --quiet rmtfs.service 2>/dev/null; then
				if card_present; then
					log "rmtfs is active and a sound card is present"
				else
					log "rmtfs is active but there is no sound card; restarting it"
					run systemctl restart rmtfs.service || true
				fi
			else
				log "enabling and starting rmtfs"
				run systemctl start rmtfs.service || true
			fi
			;;
		*)
			die "unsupported init system (neither OpenRC nor systemd found)"
			;;
	esac

	# Wait for the card (DSP boot takes a couple of seconds).
	if [ "$DRY_RUN" = 0 ]; then
		i=0
		while [ "$i" -lt 30 ]; do
			card_present && break
			sleep 1
			i=$((i + 1))
		done
	fi

	if [ "$DRY_RUN" = 0 ] && ! card_present; then
		warn "no sound card appeared"
		diagnose
		return 1
	fi

	if [ "$DRY_RUN" = 0 ]; then
		log "sound card is available:"
		awk '/^[[:blank:]]*[0-9]+ \[/ {print "    " $0}' /proc/asound/cards
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Session part: pick the speaker profile and make it the default sink.
# Runs as the logged-in desktop user (PulseAudio rejects connections from
# other uids, so this matters).
# ---------------------------------------------------------------------------

TU=
TUID=
TUHOME=

detect_user() {
	if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
		TU=$SUDO_USER
	else
		for d in /run/user/[0-9]*; do
			[ -d "$d" ] || continue
			if [ -S "$d/pulse/native" ] || [ -S "$d/pipewire-0" ]; then
				TU=$(id -nu "${d##*/}" 2>/dev/null) || continue
				break
			fi
		done
	fi
	[ -n "${TU:-}" ] || return 1

	TUID=$(id -u "$TU")
	TUHOME=$(awk -F: -v u="$TU" '$1 == u {print $6}' /etc/passwd)
	[ -n "$TUHOME" ] || TUHOME="/home/$TU"
	return 0
}

# Run a shell command as the desktop user.
as_user() {
	if [ "$(id -u)" = "$TUID" ]; then
		XDG_RUNTIME_DIR="/run/user/$TUID" HOME="$TUHOME" \
			PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
			sh -c "$1"
	else
		su -s /bin/sh -c \
			"XDG_RUNTIME_DIR='/run/user/$TUID' HOME='$TUHOME' PATH='/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' $1" \
			"$TU"
	fi
}

# List card profiles (available ones only, then all).
list_available_profiles() {
	as_user "pactl list cards" 2>/dev/null | sed -n \
		's/^[[:blank:]]*\(.*\): .*(sinks: [0-9]*, sources: [0-9]*, priority: [0-9]*, available: yes)$/\1/p'
}
list_all_profiles() {
	as_user "pactl list cards" 2>/dev/null | sed -n \
		's/^[[:blank:]]*\(.*\): .*(sinks: [0-9]*, sources: [0-9]*, priority: [0-9]*, available: [a-z]*)$/\1/p'
}

session_setup() {
	if ! detect_user; then
		warn "no logged-in desktop session found"
		warn "log in and then run: $0 --session"
		return 1
	fi

	if [ ! -S "/run/user/$TUID/pulse/native" ] && \
	   [ ! -S "/run/user/$TUID/pipewire-0" ]; then
		warn "no sound server socket for user $TU (logged in?)"
		warn "log in and then run: $0 --session"
		return 1
	fi

	# Wait a little in case the server is still starting.
	i=0
	while [ "$i" -lt 15 ]; do
		as_user "pactl info" >/dev/null 2>&1 && break
		sleep 1
		i=$((i + 1))
	done
	if ! as_user "pactl info" >/dev/null 2>&1; then
		warn "cannot reach the sound server of user $TU"
		return 1
	fi

	card=$(as_user "pactl list short cards" 2>/dev/null \
		| awk '/7702000\.sound/ {print $2; exit}')
	[ -n "$card" ] || card=$(as_user "pactl list short cards" 2>/dev/null \
		| awk 'NR == 1 {print $2}')
	if [ -z "$card" ]; then
		warn "the sound server does not see any sound card yet"
		warn "try: $0 --session   after the DSP has finished booting"
		return 1
	fi

	available=$(list_available_profiles)
	all=$(list_all_profiles)

	# Prefer the internal microphone + speaker, then headset + speaker,
	# then any available profile that outputs to the speaker.
	chosen=
	for want in "HiFi (Mic1, Speaker)" "HiFi (Headset, Speaker)" "HiFi (Speaker)"; do
		if printf '%s\n' "$available" | grep -Fxq "$want"; then
			chosen=$want
			break
		fi
	done
	if [ -z "$chosen" ]; then
		chosen=$(printf '%s\n' "$available" | grep -i 'speaker' | head -n 1)
	fi
	if [ -z "$chosen" ]; then
		chosen=$(printf '%s\n' "$all" | grep -i 'speaker' | head -n 1)
	fi
	if [ -z "$chosen" ]; then
		warn "no 'Speaker' card profile found; leaving profile unchanged"
		warn "available profiles are:"
		printf '%s\n' "$all" | sed 's/^/    /' >&2
	fi

	if [ -n "$chosen" ]; then
		if [ "$DRY_RUN" = 1 ]; then
			printf '    + pactl set-card-profile %s "%s"\n' "$card" "$chosen"
		else
			log "selecting card profile: $chosen"
			as_user "pactl set-card-profile '$card' '$chosen'" >/dev/null 2>&1 || \
				warn "could not set card profile '$chosen'"
			sleep 1
		fi
	fi

	sink=$(as_user "pactl list short sinks" 2>/dev/null \
		| awk '/Speaker/ {print $2; exit}')
	[ -n "$sink" ] || sink=$(as_user "pactl list short sinks" 2>/dev/null \
		| awk 'NR == 1 {print $2}')

	if [ -n "$sink" ]; then
		if [ "$DRY_RUN" = 1 ]; then
			printf '    + pactl set-default-sink %s\n' "$sink"
			printf '    + pactl set-sink-mute %s 0\n' "$sink"
		else
			as_user "pactl set-default-sink '$sink'" >/dev/null 2>&1 || true
			as_user "pactl set-sink-mute '$sink' 0" >/dev/null 2>&1 || true
			log "default sink: $sink"
		fi
	fi

	if [ "$DRY_RUN" = 0 ]; then
		awk_profile=$(as_user "pactl list cards" 2>/dev/null \
			| sed -n 's/^[[:blank:]]*Active Profile: //p' | head -n 1)
		[ -n "$awk_profile" ] && log "active profile: $awk_profile"
	fi

	if [ "$DO_TEST" = 1 ] && [ "$DRY_RUN" = 0 ]; then
		log "playing a short test tone"
		as_user "timeout 8 speaker-test -D pulse -c 2 -t sine -f 440 -l 1" \
			>/dev/null 2>&1 || warn "test tone failed (speaker-test installed?)"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

show_status() {
	detect_init
	log "init system: $INIT"
	log "remoteprocs:"
	show_rprocs
	log "sound cards:"
	if [ -r /proc/asound/cards ]; then
		cat /proc/asound/cards
	else
		echo "    /proc/asound/cards not available"
	fi
	case "$INIT" in
		openrc)
			log "rmtfs service: $(rc-service rmtfs status 2>&1 | sed 's/^ \* status: //' | tail -n 1)"
			;;
		systemd)
			if systemctl is-active --quiet rmtfs.service 2>/dev/null; then
				log "rmtfs service: active"
			else
				log "rmtfs service: inactive"
			fi
			;;
	esac
	if detect_user && { [ -S "/run/user/$TUID/pulse/native" ] || \
	                    [ -S "/run/user/$TUID/pipewire-0" ]; }; then
		log "audio server (user $TU):"
		as_user "pactl info" 2>/dev/null \
			| sed -n 's/^\(Server Name\|Default Sink\|Default Source\): /\n    \1: /p' \
			| sed '/^$/d'
		as_user "pactl list cards" 2>/dev/null \
			| sed -n 's/^[[:blank:]]*Active Profile: /    Active Profile: /p' \
			| head -n 1
	else
		log "no active desktop audio session"
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Root is only needed for the system part.  --session is designed to be
# run as the normal user; --dry-run should not require root either.
need_root=1
[ "$MODE" = session ] && need_root=0
[ "$DRY_RUN" = 1 ] && need_root=0

if [ "$need_root" = 1 ] && [ "$(id -u)" -ne 0 ]; then
	command -v sudo >/dev/null 2>&1 || \
		die "please run as root: su -c 'sh $0 $*'"
	log "re-running as root"
	exec sudo -- /bin/sh "$0" "$@"
fi

case "$MODE" in
	status)
		show_status
		exit 0
		;;
	session)
		session_setup
		exit $?
		;;
	full)
		system_setup || exit 1
		printf '\n'
		session_setup || true
		printf '\n'
		log "done - if you still see 'Dummy Output', log out/in and run: $0 --session"
		;;
esac
