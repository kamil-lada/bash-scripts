#!/bin/bash
set -e

NAS="stornator-svc.babum.ovh"

echo ""
echo "Select mount profile:"
echo "  1) personal  — multimedia, archive, vm-share"
echo "  2) server    — pbs, pve, iso, vm-share"
echo "  3) all       — everything"
echo ""
read -rp "Choice [1/2/3]: " PROFILE_INPUT

case "$PROFILE_INPUT" in
  1|personal)  PROFILE="personal" ;;
  2|server)    PROFILE="server"   ;;
  3|all)       PROFILE="all"      ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac

echo ""
echo "Profile selected: ${PROFILE}"
echo ""

# PBS: strictatime mandatory for GC, sync for integrity, no nofail intentional
PBS_OPTS="nfsvers=4.1,rw,hard,_netdev,timeo=150,retrans=3,rsize=1048576,wsize=1048576,sync,strictatime"

# PVE (LXC templates, CT volumes): large files, rw needed
PVE_OPTS="nfsvers=4.1,rw,hard,_netdev,timeo=150,retrans=3,rsize=1048576,wsize=1048576,async,noatime,nofail"

# ISO store: large sequential reads, mostly read-only workload
ISO_OPTS="nfsvers=4.1,rw,hard,_netdev,timeo=150,retrans=3,rsize=1048576,wsize=1048576,async,noatime,nofail"

# Multimedia: writes needed (metadata, subtitles etc), large sequential files
MEDIA_OPTS="nfsvers=4.1,rw,hard,_netdev,timeo=150,retrans=3,rsize=1048576,wsize=1048576,async,noatime,nofail"

# VM-share: scripts, ZIPs, general small files — always mounted
SHARE_OPTS="nfsvers=4.1,rw,hard,_netdev,timeo=150,retrans=3,noatime,nofail"

# Archive: mixed content, general use
ARCH_OPTS="nfsvers=4.1,rw,hard,_netdev,timeo=150,retrans=3,noatime,nofail"

add_fstab() {
  local entry="$1"
  if grep -qF "$entry" /etc/fstab; then
    echo "  [skip] already in fstab: $entry"
  else
    echo "$entry" >> /etc/fstab
    echo "  [added] $entry"
  fi
}

ensure_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    echo "  [mkdir] $dir"
  fi
}

MOUNTS_PERSONAL=(
  "${NAS}:/mnt/md0/multimedia|/mnt/nas01/multimedia|${MEDIA_OPTS}"
  "${NAS}:/mnt/md0/archive|/mnt/nas01/archive|${ARCH_OPTS}"
)

MOUNTS_SERVER=(
  "${NAS}:/mnt/md0/proxmox/pbs|/mnt/nas01/pbs|${PBS_OPTS}"
  "${NAS}:/mnt/md0/proxmox/pve|/mnt/nas01/pve|${PVE_OPTS}"
  "${NAS}:/mnt/md0/proxmox/iso|/mnt/nas01/iso|${ISO_OPTS}"
)

MOUNTS_ALWAYS=(
  "${NAS}:/mnt/md0/vm-share|/mnt/nas01/vm-share|${SHARE_OPTS}"
)

# Build final mount list based on profile
MOUNTS=()

case "$PROFILE" in
  personal)
    MOUNTS+=("${MOUNTS_PERSONAL[@]}")
    ;;
  server)
    MOUNTS+=("${MOUNTS_SERVER[@]}")
    ;;
  all)
    MOUNTS+=("${MOUNTS_SERVER[@]}")
    MOUNTS+=("${MOUNTS_PERSONAL[@]}")
    ;;
esac

# Always append vm-share
MOUNTS+=("${MOUNTS_ALWAYS[@]}")

echo "--- Creating mount points ---"
for entry in "${MOUNTS[@]}"; do
  IFS='|' read -r _src mountpoint _opts <<< "$entry"
  ensure_dir "$mountpoint"
done

echo ""
echo "--- Writing fstab entries ---"
for entry in "${MOUNTS[@]}"; do
  IFS='|' read -r src mountpoint opts <<< "$entry"
  add_fstab "${src}  ${mountpoint}  nfs  ${opts}  0 0"
done

echo ""
echo "--- Reloading systemd and mounting ---"
systemctl daemon-reload
mount -a

echo ""
echo "--- Verification ---"
for entry in "${MOUNTS[@]}"; do
  IFS='|' read -r _src mountpoint _opts <<< "$entry"
  if mountpoint -q "$mountpoint"; then
    echo "  ✓ $mountpoint"
    nfsstat -m "$mountpoint" 2>/dev/null | grep -E "vers|flags" | head -2 | sed 's/^/      /'
  else
    echo "  ✗ $mountpoint — NOT mounted"
  fi
done

echo ""
echo "Done."