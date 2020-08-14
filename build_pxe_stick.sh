#!/bin/bash
set -e
shopt -s nullglob


function log() {
    echo -e "\e[32m$*\e[0m" >&2
}

function error() {
    echo -e "\e[31m$*\e[0m" >&2
}

function check_env_vars() {
    case "" in
        "$PAPERTRAIL_HOST")
            missing="PAPERTRAIL_HOST";;
        "$PAPERTRAIL_PORT")
            missing="PAPERTRAIL_PORT";;
        "$UPTIMEROBOT_HEARTBEAT_PATH")
            missing="UPTIMEROBOT_HEARTBEAT_PATH";;
    esac

    if [[ -n "$missing" ]]; then
        error "You must set $missing!"
        usage_and_die
    fi
}

function git_reference() {
    repo="$(
        git remote show -n origin \
        | grep "Fetch URL:" \
        | cut -d: -f2,3 \
        | tr -d " " \
        | sed "s/git@github/github/" \
        | sed "s|github.com:|github.com/|" \
        | sed "s|^github.com|https://github.com|" \
        | sed "s/.git$//"
        )"
    maybe_dirty=""
    if [[ -n "$(cd "$HERE"; git status --short)" ]]; then
        maybe_dirty=" (with uncommitted changes)"
    fi
    commit="$(cd "$HERE"; git rev-parse --short HEAD || echo "???")" 

    echo "$repo/tree/$commit$maybe_dirty"
}

function repro() {
    echo "#!/bin/bash"
    echo "# @ $(git_reference)"
    env_patterns=(-e "^K3S_" -e "^PAPERTRAIL_" -e "^UPTIMEROBOT_HEARTBEAT_")
    echo "env \\"
    for e in $(env | grep "${env_patterns[@]}" | cut -d= -f1); do
        printf "  %s=%q \\" "$e" "${!e}"
        echo # newline
    done
    echo "  $0"
}


function build_ipxe() {
    (
        cd "$OUT"
        git clone git://git.ipxe.org/ipxe.git
        cd ipxe/src
        make -j "$(nproc)" bin/ipxe.usb EMBED="$HERE/flatcar.ipxe"
        log "Built $PWD/bin/ipxe.usb"
    ) >&2
    echo "$OUT/ipxe/src/bin/ipxe.usb"
}

function unmount() {
    log "unmounting $DISK (and associated partitions)"
    umount -q "$DISK" "$DISK"? || :
}

function usage_and_die() {
    error 'Usage: '
    error ' PAPERTRAIL_HOST=logsX.papertrailapp.com PAPERTRAIL_PORT=XXXXX \\'
    error ' UPTIMEROBOT_HEARTBEAT_PATH=biglongopaquethingitgivesyou \\'
    error ' [K3S_ENV_VARS_YOU_WANT_TO_SET=blahblahblah...] \\'
    error ' ./build_pxe_stick.sh /dev/sdX'
    exit 1
}

HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
OUT="$(mktemp -d /tmp/pxe_build_ephemeros_XXXXXX)"
log "Using $OUT for temp storage"

DISK="$1"
if [[ -z "$DISK" ]]; then
    usage_and_die
fi
check_env_vars

if [[ ! -w "$DISK" ]]; then
    error "$DISK is not writeable. Check your privilege, and that it exists."
    exit 2
fi

log "$DISK presently looks like this:"
log "$(lsblk "$DISK")"
read -p "We're gonna zap <$DISK>! Type \"i don't want that data\" to continue. >>> "
if [[ "$REPLY" != "i don't want that data" ]]; then
    error "Aborting."
    exit 2
fi

unmount

IPXE_IMG="$(build_ipxe)"
dd if="$IPXE_IMG" of="$DISK"
log "dd'd image to $DISK" >&2

log "Adding a partition for secrets to $DISK"
parted "$DISK" mkpart primary ext4 512MB 1GB
partprobe
log "We don't know the name of the actual partition we just made is,"
log "so we're just gonna assume it's ${DISK}1."
log
log "If you're running this on a drive that was previously provisioned with"
log "this script, you may find a scary message regarding an existing fs. "
log "This is caused by our parted invocation lining things up just right such"
log "that the existing fs is still roughly in tact."
log
log "It's likely safe to proceed here."
log "Making an ext4 volume on ${DISK}1 called 'secrets'."
mkfs.ext4 -L secrets "${DISK}1"

sudo mkdir "$OUT/mountpoint"
log "mounting secrets volume @ $OUT/mountpoint"
mount "${DISK}1" "$OUT/mountpoint"
SECRETS="$OUT/mountpoint"

log "Writing environment files in $SECRETS..."
(
    umask 0077
    # NOTE: if you update these, also update the patterns in `repro`
    env | grep "^K3S_" > "$SECRETS/k3s_env"
    env | grep "^PAPERTRAIL_" > "$SECRETS/papertrail_env"
    env | grep "^UPTIMEROBOT_HEARTBEAT_" > "$SECRETS/uptimerobot_heartbeat_env"

    repro > "$SECRETS/reproduce.sh"
)

log "!! DONE !!"
