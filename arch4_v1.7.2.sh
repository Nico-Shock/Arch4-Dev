#!/usr/bin/env bash
# Arch4 — 4-step Arch Linux ISO installer
# GUIDE_REF=V2.1  https://nico-shock.github.io/Arch-Linux-on-Nvidia-V2.1/
#
# Guide map:
#   step 1  ≈ partitioning / format / mount
#   step 2  ≈ §9 pacstrap (ISO) + §12–15 locale/pacman/NM/bootctl (chroot)
#   step 3  ≈ desktop + GPU + user (chroot)
#   step 4  ≈ CachyOS repos → kernel → extras (chroot)
#
# From the official Arch ISO, as root:
#   curl -fsSL <url> | bash
# Safer:
#   curl -fsSL <url> -o /tmp/arch4.sh && sha256sum /tmp/arch4.sh && bash /tmp/arch4.sh
#
# Options:  --dry-run   menus only, no wipe/pacstrap/chroot
#           --help
#
# Secure Boot is NOT supported (unsigned kernels / systemd-boot).
#
# Wrapped so `curl | bash` fully parses, then stdin rebinds to the TTY.

{

set -u

ARCH4_VERSION="1.7.2"
GUIDE_REF="V2.1"
STATE_FILE="/tmp/arch4.state"
LOG_FILE="/root/arch4.log"
HOST_NAME="iusearchbtw"
LOCALE="de_DE.UTF-8"
TIMEZONE="Europe/Berlin"
KEYMAP="de"
EFI_SIZE="2048M"
PARALLEL_DL=20
DRY_RUN=0

ISO_PACMAN_BAK=""
_iso_pacman_backup() {
  ISO_PACMAN_BAK="$(mktemp /tmp/pacman.conf.bak.XXXXXX)"
  cp -a /etc/pacman.conf "$ISO_PACMAN_BAK"
}
_iso_pacman_restore() {
  if [[ -n "${ISO_PACMAN_BAK:-}" && -f "$ISO_PACMAN_BAK" ]]; then
    cp -a "$ISO_PACMAN_BAK" /etc/pacman.conf 2>/dev/null || true
    rm -f "$ISO_PACMAN_BAK"
    ISO_PACMAN_BAK=""
  fi
}

# --- args ------------------------------------------------------------------

for _a in "$@"; do
  case "$_a" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      cat <<'H'
Arch4 — 4-step Arch Linux ISO installer (UEFI, live ISO only)

  bash install.sh            run installer
  bash install.sh --dry-run  menus + summary only (no wipe / pacstrap / chroot)
  bash install.sh --help     this text

Safer than curl|bash:
  curl -fsSL URL -o /tmp/arch4.sh
  sha256sum /tmp/arch4.sh
  bash /tmp/arch4.sh

Secure Boot is not supported. Disable it in firmware.
H
      exit 0
      ;;
  esac
done

# --- tty -------------------------------------------------------------------

if [[ ! -t 0 ]]; then
  if [[ -e /dev/tty ]]; then
    exec </dev/tty
  else
    echo "Arch4 needs a TTY. Run: bash <(curl -fsSL URL)" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/arch4.log"
chmod 600 "$LOG_FILE" 2>/dev/null || true
# Do NOT use umask 077 globally — pacstrap/pacman inherit it and create
# /etc as 700 → "permission denied" on /etc/profile and broken services.
umask 022
touch "$STATE_FILE" 2>/dev/null || true
chmod 600 "$STATE_FILE" 2>/dev/null || true

if [[ -t 1 ]] && tput setaf 0 &>/dev/null; then
  BOLD="$(tput bold)"
  DIM="$(tput dim)"
  RED="$(tput setaf 1)"
  GRN="$(tput setaf 2)"
  YLW="$(tput setaf 3)"
  BLU="$(tput setaf 4)"
  CYN="$(tput setaf 6)"
  REV="$(tput rev)"
  RST="$(tput sgr0)"
  HIDE="$(tput civis 2>/dev/null || true)"
  SHOW="$(tput cnorm 2>/dev/null || true)"
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; CYN=""; REV=""; RST=""
  HIDE=""; SHOW=""
fi

cleanup_tty() { printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true; }
cleanup_on_exit() { cleanup_tty; _iso_pacman_restore; }
trap cleanup_on_exit EXIT

log()  { printf '%s\n' "$*" | tee -a "$LOG_FILE" >/dev/null; printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$GRN$BOLD" "$RST" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s!!%s  %s\n' "$YLW$BOLD" "$RST" "$*" | tee -a "$LOG_FILE"; }
err()  { printf '%sxx%s  %s\n' "$RED$BOLD" "$RST" "$*" | tee -a "$LOG_FILE"; }
die()  { err "$*"; exit 1; }

ask() {
  local prompt="$1" default="${2-}" reply
  printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true
  if [[ -n "$default" ]]; then
    printf '%s?%s  %s [%s]: ' "$CYN$BOLD" "$RST" "$prompt" "$default" >/dev/tty
  else
    printf '%s?%s  %s: ' "$CYN$BOLD" "$RST" "$prompt" >/dev/tty
  fi
  IFS= read -r reply </dev/tty || true
  if [[ -z "$reply" && -n "$default" ]]; then reply="$default"; fi
  printf '%s' "$reply"
}

ask_secret() {
  local prompt="$1" reply
  printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true
  printf '%s?%s  %s: ' "$CYN$BOLD" "$RST" "$prompt" >/dev/tty
  IFS= read -r -s reply </dev/tty || true
  printf '\n' >/dev/tty
  printf '%s' "$reply"
}

pause_err() {
  printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true
  err "$1"
  printf 'Press Enter to continue... ' >/dev/tty
  IFS= read -r _ </dev/tty || true
}

compute_self_sha() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -r "$src" ]]; then
    sha256sum "$src" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  printf 'unknown'
}

# --- keyboard picker -------------------------------------------------------

read_key() {
  local k rest
  IFS= read -rsn1 k </dev/tty || true
  if [[ "$k" == $'\x1b' ]]; then
    IFS= read -rsn2 -t 0.05 rest </dev/tty || true
    case "$rest" in
      '[A') printf 'up'; return ;;
      '[B') printf 'down'; return ;;
      '[C') printf 'right'; return ;;
      '[D') printf 'left'; return ;;
    esac
    printf 'esc'; return
  fi
  if [[ -z "$k" ]]; then printf 'enter'; return; fi
  printf '%s' "$k"
}

pick() {
  local title="$1" hint="$2"
  shift 2
  local items=("$@")
  local n=${#items[@]}
  local cur=0
  local key i
  [[ "$n" -gt 0 ]] || return 1
  printf '%s' "$HIDE" >/dev/tty 2>/dev/null || true
  while true; do
    clear >/dev/tty 2>/dev/null || true
    printf '\n' >/dev/tty
    printf '  %s┌──────────────────────────────────────────────────┐%s\n' "$BLU" "$RST" >/dev/tty
    printf '  %s│%s  %sArch4%s  %sv%s%s%*s%s│%s\n' \
      "$BLU" "$RST" "$BOLD" "$RST" "$DIM" "$ARCH4_VERSION" "$RST" \
      $((38 - ${#ARCH4_VERSION})) "" "$BLU" "$RST" >/dev/tty
    printf '  %s└──────────────────────────────────────────────────┘%s\n' "$BLU" "$RST" >/dev/tty
    printf '\n  %s%s%s\n' "$BOLD" "$title" "$RST" >/dev/tty
    if [[ -n "$hint" ]]; then
      printf '  %s%s%s\n' "$DIM" "$hint" "$RST" >/dev/tty
    fi
    printf '\n' >/dev/tty
    for ((i=0; i<n; i++)); do
      if [[ "$i" -eq "$cur" ]]; then
        printf '  %s  ▸ %s  %s\n' "$REV$BOLD" "${items[$i]}" "$RST" >/dev/tty
      else
        printf '    %s  %s%s\n' "$DIM" "${items[$i]}" "$RST" >/dev/tty
      fi
    done
    printf '\n  %s↑↓  j/k  1–9  Enter  q%s\n' "$DIM" "$RST" >/dev/tty
    key="$(read_key)"
    case "$key" in
      up|k|K|left)
        cur=$(( (cur - 1 + n) % n ))
        ;;
      down|j|J|right)
        cur=$(( (cur + 1) % n ))
        ;;
      enter)
        PICK_IDX="$cur"
        PICK_VAL="${items[$cur]}"
        printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true
        return 0
        ;;
      esc|q|Q)
        printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true
        return 1
        ;;
      [1-9])
        if [[ "$key" -ge 1 && "$key" -le "$n" ]]; then
          cur=$((key - 1))
          PICK_IDX="$cur"
          PICK_VAL="${items[$cur]}"
          printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true
          return 0
        fi
        ;;
    esac
  done
}

pick_yesno() {
  local title="$1" def="${2:-Y}"
  if [[ "$def" == "Y" || "$def" == "y" ]]; then
    pick "$title" "Enter confirms the highlighted row." "Yes" "No" || return 1
  else
    pick "$title" "Enter confirms the highlighted row." "No" "Yes" || return 1
  fi
  [[ "$PICK_VAL" == "Yes" ]]
}

pick_multi() {
  local title="$1" hint="$2"
  shift 2
  local labels=() ids=() on=()
  local i n cur=0 key mark
  for item in "$@"; do
    labels+=("${item%%|*}")
    ids+=("${item#*|}")
    on+=(1)
  done
  n=${#labels[@]}
  [[ "$n" -gt 0 ]] || return 1
  printf '%s' "$HIDE" >/dev/tty 2>/dev/null || true
  while true; do
    clear >/dev/tty 2>/dev/null || true
    printf '\n' >/dev/tty
    printf '  %s┌──────────────────────────────────────────────────┐%s\n' "$BLU" "$RST" >/dev/tty
    printf '  %s│%s  %sArch4%s  %sv%s%s%*s%s│%s\n' \
      "$BLU" "$RST" "$BOLD" "$RST" "$DIM" "$ARCH4_VERSION" "$RST" \
      $((38 - ${#ARCH4_VERSION})) "" "$BLU" "$RST" >/dev/tty
    printf '  %s└──────────────────────────────────────────────────┘%s\n' "$BLU" "$RST" >/dev/tty
    printf '\n  %s%s%s\n' "$BOLD" "$title" "$RST" >/dev/tty
    if [[ -n "$hint" ]]; then
      printf '  %s%s%s\n' "$DIM" "$hint" "$RST" >/dev/tty
    fi
    printf '\n' >/dev/tty
    for ((i=0; i<n; i++)); do
      if [[ "${on[$i]}" -eq 1 ]]; then mark="[x]"; else mark="[ ]"; fi
      if [[ "$i" -eq "$cur" ]]; then
        printf '  %s  ▸ %s %s  %s\n' "$REV$BOLD" "$mark" "${labels[$i]}" "$RST" >/dev/tty
      else
        printf '      %s %s%s\n' "$mark" "${labels[$i]}" "$RST" >/dev/tty
      fi
    done
    printf '\n  %s↑↓  Space toggle  a all  n none  Enter confirm  q%s\n' "$DIM" "$RST" >/dev/tty
    key="$(read_key)"
    case "$key" in
      up|k|K|left) cur=$(( (cur - 1 + n) % n )) ;;
      down|j|J|right) cur=$(( (cur + 1) % n )) ;;
      " "|t|T)
        if [[ "${on[$cur]}" -eq 1 ]]; then on[$cur]=0; else on[$cur]=1; fi
        ;;
      a|A) for ((i=0; i<n; i++)); do on[$i]=1; done ;;
      n|N) for ((i=0; i<n; i++)); do on[$i]=0; done ;;
      enter)
        MULTI_SEL=""
        for ((i=0; i<n; i++)); do
          [[ "${on[$i]}" -eq 1 ]] && MULTI_SEL+="${ids[$i]} "
        done
        printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true
        return 0
        ;;
      esc|q|Q)
        printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true
        return 1
        ;;
    esac
  done
}

multi_has() {
  [[ " ${MULTI_SEL} " == *" $1 "* ]]
}

confirm_plan() {
  # Show selection summary + Yes/No on one screen (pick() would clear the list away).
  local title="$1"
  shift
  local lines=("$@")
  local cur=0 key line
  printf '%s' "$HIDE" >/dev/tty 2>/dev/null || true
  log "---- plan: ${title} ----"
  for line in "${lines[@]}"; do
    log "  ${line}"
  done
  while true; do
    clear >/dev/tty 2>/dev/null || true
    printf '\n' >/dev/tty
    printf '  %s┌──────────────────────────────────────────────────┐%s\n' "$BLU" "$RST" >/dev/tty
    printf '  %s│%s  %sArch4%s  %sv%s%s%*s%s│%s\n' \
      "$BLU" "$RST" "$BOLD" "$RST" "$DIM" "$ARCH4_VERSION" "$RST" \
      $((38 - ${#ARCH4_VERSION})) "" "$BLU" "$RST" >/dev/tty
    printf '  %s└──────────────────────────────────────────────────┘%s\n' "$BLU" "$RST" >/dev/tty
    printf '\n  %s%s%s\n' "$BOLD" "$title" "$RST" >/dev/tty
    printf '\n' >/dev/tty
    for line in "${lines[@]}"; do
      printf '      %s%s%s\n' "$DIM" "$line" "$RST" >/dev/tty
    done
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '\n  %sDRY-RUN: nothing destructive will run.%s\n' "$YLW$BOLD" "$RST" >/dev/tty
    fi
    printf '\n  %sProceed with this plan?%s\n\n' "$BOLD" "$RST" >/dev/tty
    if [[ "$cur" -eq 0 ]]; then
      printf '  %s  ▸ Yes  %s\n' "$REV$BOLD" "$RST" >/dev/tty
      printf '      No\n' >/dev/tty
    else
      printf '      Yes\n' >/dev/tty
      printf '  %s  ▸ No  %s\n' "$REV$BOLD" "$RST" >/dev/tty
    fi
    printf '\n  %s↑↓  Enter  q%s\n' "$DIM" "$RST" >/dev/tty
    key="$(read_key)"
    case "$key" in
      up|k|K|left|down|j|J|right) cur=$((1 - cur)) ;;
      enter)
        printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true
        [[ "$cur" -eq 0 ]]
        return $?
        ;;
      esc|q|Q)
        printf '%s' "$SHOW" >/dev/tty 2>/dev/null || true
        return 1
        ;;
    esac
  done
}

# --- state (never stores passwords) ----------------------------------------

STEP1=0 STEP2=0 STEP3=0 STEP4=0
STEP4_SKIPPED=0
DISK="" PART_EFI="" PART_ROOT="" UCODE_PKG="" UCODE_IMG="" GPU="" USERNAME=""
SKIP_MENUS=0
STEP3_USER=""
STEP3_PW=""
STEP3_ROOT_PW=""
EDITOR_PKG="nano vim"
DESKTOP="kde"
DM="sddm"
EXTRA_SEL=""
STEP4_SEL=""
OPENCODE=0

save_state() {
  local old_umask
  old_umask="$(umask)"
  umask 077
  cat > "$STATE_FILE" <<EOF
STEP1=${STEP1}
STEP2=${STEP2}
STEP3=${STEP3}
STEP4=${STEP4}
STEP4_SKIPPED=${STEP4_SKIPPED}
DISK='${DISK}'
PART_EFI='${PART_EFI}'
PART_ROOT='${PART_ROOT}'
UCODE_PKG='${UCODE_PKG}'
UCODE_IMG='${UCODE_IMG}'
GPU='${GPU}'
USERNAME='${USERNAME}'
EDITOR_PKG='${EDITOR_PKG}'
DESKTOP='${DESKTOP}'
DM='${DM}'
EXTRA_SEL='${EXTRA_SEL}'
STEP4_SEL='${STEP4_SEL}'
OPENCODE=${OPENCODE}
HOST_NAME='${HOST_NAME}'
LOCALE='${LOCALE}'
TIMEZONE='${TIMEZONE}'
KEYMAP='${KEYMAP}'
EOF
  chmod 600 "$STATE_FILE" 2>/dev/null || true
  umask "$old_umask"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  chmod 600 "$STATE_FILE" 2>/dev/null || true
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  STEP3_PW=""
  STEP3_ROOT_PW=""
}

detect_ucode() {
  if grep -q 'AuthenticAMD' /proc/cpuinfo; then
    UCODE_PKG="amd-ucode"; UCODE_IMG="amd-ucode.img"
  elif grep -q 'GenuineIntel' /proc/cpuinfo; then
    UCODE_PKG="intel-ucode"; UCODE_IMG="intel-ucode.img"
  else
    UCODE_PKG=""; UCODE_IMG=""
  fi
}

part_path() {
  local disk="$1" n="$2"
  case "$disk" in
    *[0-9]) printf '%sp%s' "$disk" "$n" ;;
    *)      printf '%s%s'  "$disk" "$n" ;;
  esac
}

is_mounted_root() { findmnt -n /mnt >/dev/null 2>&1; }

require_iso() {
  local ok=0
  [[ -d /run/archiso ]] && ok=1
  [[ -f /etc/hostname && "$(tr -d '[:space:]' </etc/hostname)" == "archiso" ]] && ok=1
  grep -q 'archiso' /proc/cmdline 2>/dev/null && ok=1
  [[ "$ok" -eq 1 ]] || die "Arch4 only runs from the official Arch ISO live environment."
}

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root."; }

require_uefi() {
  [[ -d /sys/firmware/efi ]] || die "UEFI firmware not detected. Arch4 is UEFI-only."
  if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    warn "Secure Boot is ON. Arch4 does not sign kernels — disable Secure Boot or boot may fail."
  else
    info "Secure Boot is not supported (unsigned systemd-boot + kernels)."
  fi
}

require_net() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 && return 0
  ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && return 0
  die "No internet. Connect first (Ethernet or: iwctl), then re-run."
}

boot_medium_disk() {
  local src pk
  src="$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
  [[ -z "$src" ]] && src="$(findmnt -n -o SOURCE /run/archiso/copytoram 2>/dev/null || true)"
  [[ -z "$src" ]] && return 0
  pk="$(lsblk -no pkname "$src" 2>/dev/null | head -n1 || true)"
  if [[ -n "$pk" ]]; then printf '%s' "$pk"
  else lsblk -no name "$src" 2>/dev/null | head -n1 || true
  fi
}

set_parallel() {
  local conf="$1"
  if grep -q '^#ParallelDownloads' "$conf"; then
    sed -i "s/^#ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL}/" "$conf"
  elif grep -q '^ParallelDownloads' "$conf"; then
    sed -i "s/^ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL}/" "$conf"
  else
    sed -i "/^\[options\]/a ParallelDownloads = ${PARALLEL_DL}" "$conf"
  fi
}

# Guide §10 — same pacstrap, retries only (no extra packages, no custom downloader).
pacstrap_retry() {
  local n=1
  while true; do
    info "pacstrap (guide §10) attempt ${n}/5..."
    if pacstrap -K /mnt "$@"; then
      return 0
    fi
    if [[ $n -ge 5 ]]; then
      return 1
    fi
    warn "pacstrap failed — retrying in $((n*2))s."
    n=$((n+1))
    sleep $((n*2))
  done
}

editors_ok() {
  local p
  for p in ${EDITOR_PKG:-nano}; do
    chroot_has "$p" || return 1
  done
  return 0
}

# --- per-command checks ----------------------------------------------------

CHECK_FAIL=0
FAIL_NAMES=()

checks_begin() { CHECK_FAIL=0; FAIL_NAMES=(); }

must() {
  local name="$1"
  shift
  if "$@"; then
    printf '  %s[x]%s %s\n' "$GRN$BOLD" "$RST" "$name" | tee -a "$LOG_FILE"
    return 0
  fi
  printf '  %s[ ]%s %s\n' "$RED$BOLD" "$RST" "$name" | tee -a "$LOG_FILE"
  FAIL_NAMES+=("$name")
  CHECK_FAIL=1
  return 1
}

must_test() {
  local name="$1"
  shift
  if test "$@"; then
    printf '  %s[x]%s %s\n' "$GRN$BOLD" "$RST" "$name" | tee -a "$LOG_FILE"
    return 0
  fi
  printf '  %s[ ]%s %s\n' "$RED$BOLD" "$RST" "$name" | tee -a "$LOG_FILE"
  FAIL_NAMES+=("$name")
  CHECK_FAIL=1
  return 1
}

must_run() {
  local name="$1"
  shift
  if "$@"; then
    printf '  %s[x]%s %s\n' "$GRN$BOLD" "$RST" "$name" | tee -a "$LOG_FILE"
    return 0
  fi
  printf '  %s[ ]%s FAILED  %s\n' "$RED$BOLD" "$RST" "$name" | tee -a "$LOG_FILE"
  FAIL_NAMES+=("$name")
  CHECK_FAIL=1
  return 1
}

checks_ok() { [[ "${CHECK_FAIL}" -eq 0 ]]; }

dump_fail_summary() {
  err "Failed checks (${#FAIL_NAMES[@]}). Log: ${LOG_FILE}"
  local n
  for n in "${FAIL_NAMES[@]}"; do
    err "  - $n"
  done
}

req_run() {
  must_run "$@" && return 0
  dump_fail_summary
  return 1
}

chroot_has() {
  [[ -f /mnt/etc/os-release ]] || return 1
  arch-chroot /mnt pacman -Q "$1" >/dev/null 2>&1
}

chroot_enabled() {
  [[ -f /mnt/etc/os-release ]] || return 1
  arch-chroot /mnt systemctl is-enabled "$1" >/dev/null 2>&1
}

chroot_user() {
  [[ -f /mnt/etc/passwd ]] || return 1
  grep -q "^${1}:" /mnt/etc/passwd
}

file_has() {
  local f="$1" pat="$2"
  [[ -f "$f" ]] && grep -qE "$pat" "$f"
}

verify_step1() {
  [[ -n "${DISK}" && -b "${DISK}" ]] || return 1
  [[ -n "${PART_EFI}" && -b "${PART_EFI}" ]] || return 1
  [[ -n "${PART_ROOT}" && -b "${PART_ROOT}" ]] || return 1
  [[ "$(blkid -s PTTYPE -o value "$DISK" 2>/dev/null || true)" == "gpt" ]] || return 1
  [[ "$(lsblk -no FSTYPE "$PART_EFI" 2>/dev/null || true)" == "vfat" ]] || return 1
  [[ "$(lsblk -no FSTYPE "$PART_ROOT" 2>/dev/null || true)" == "ext4" ]] || return 1
  findmnt -n /mnt >/dev/null 2>&1 || return 1
  findmnt -n /mnt/boot >/dev/null 2>&1 || return 1
  [[ "$(findmnt -n -o SOURCE /mnt 2>/dev/null || true)" == "$PART_ROOT" ]] || return 1
  [[ "$(findmnt -n -o SOURCE /mnt/boot 2>/dev/null || true)" == "$PART_EFI" ]] || return 1
  return 0
}

verify_step2() {
  verify_step1 || return 1
  [[ -f /mnt/etc/os-release ]] || return 1
  [[ -f /mnt/etc/fstab ]] || return 1
  chroot_has base || return 1
  chroot_has base-devel || return 1
  chroot_has linux || return 1
  chroot_has linux-firmware || return 1
  chroot_has networkmanager || return 1
  editors_ok || return 1
  [[ -z "$UCODE_PKG" ]] || chroot_has "$UCODE_PKG" || return 1
  [[ "$(tr -d '[:space:]' < /mnt/etc/hostname 2>/dev/null || true)" == "$HOST_NAME" ]] || return 1
  file_has /mnt/etc/locale.conf "^LANG=${LOCALE}" || return 1
  file_has /mnt/etc/pacman.conf '^\[multilib\]' || return 1
  file_has /mnt/boot/loader/loader.conf '^timeout 0' || return 1
  [[ -f /mnt/boot/loader/entries/arch.conf ]] || return 1
  file_has /mnt/boot/loader/entries/arch.conf '^linux /vmlinuz-linux' || return 1
  chroot_enabled NetworkManager || return 1
  chroot_enabled fstrim.timer || return 1
  chroot_enabled systemd-timesyncd || return 1
  return 0
}

verify_step3() {
  verify_step2 || return 1
  [[ -n "$USERNAME" ]] || return 1
  chroot_user "$USERNAME" || return 1
  chroot_has sudo || return 1
  if [[ "$DESKTOP" == "gnome" ]]; then
    chroot_has gnome-shell || return 1
    chroot_has gnome-terminal || return 1
    chroot_has gdm || return 1
    chroot_enabled gdm || return 1
  elif [[ "$DESKTOP" == "kde" ]]; then
    chroot_has plasma-desktop || chroot_has plasma-workspace || return 1
    chroot_has konsole || return 1
    chroot_has ark || return 1
    chroot_has dolphin || return 1
    chroot_has sddm || return 1
    chroot_enabled sddm || return 1
  elif [[ "$DESKTOP" == "none" ]]; then
    :
  elif [[ "$DESKTOP" == "end4" ]]; then
    chroot_has ark || return 1
    chroot_has kate || return 1
    [[ -f "/mnt/home/${USERNAME}/.config/arch4/end4.pending" ]] || return 1
    [[ -f "/mnt/home/${USERNAME}/.config/arch4/firstboot.sh" ]] || return 1
  else
    return 1
  fi
  case "${GPU}" in
    nvidia)
      chroot_has nvidia-open-dkms || return 1
      chroot_has nvidia-utils || return 1
      file_has /mnt/etc/mkinitcpio.conf 'nvidia_drm' || return 1
      ;;
    amd)
      chroot_has mesa || return 1
      chroot_has vulkan-radeon || return 1
      ;;
    intel)
      chroot_has mesa || return 1
      chroot_has vulkan-intel || return 1
      ;;
    vmware)
      chroot_has open-vm-tools || return 1
      chroot_enabled vmtoolsd || return 1
      ;;
    *) return 1 ;;
  esac
  local id
  for id in ${EXTRA_SEL}; do
    case "$id" in
      flatpak) chroot_has flatpak || return 1 ;;
      git) chroot_has git || return 1 ;;
      wget) chroot_has wget || return 1 ;;
      thermald) chroot_has thermald || return 1 ;;
      kate) chroot_has kate || return 1 ;;
      gedit) chroot_has gedit || return 1 ;;
      gnome-text-editor) chroot_has gnome-text-editor || return 1 ;;
      gnome-font-viewer) chroot_has gnome-font-viewer || return 1 ;;
      gnome-tweaks) chroot_has gnome-tweaks || return 1 ;;
      ufw) chroot_has ufw || return 1; chroot_enabled ufw || return 1 ;;
      fzf) chroot_has fzf || return 1 ;;
      python) chroot_has python || return 1 ;;
      bluetooth) chroot_has bluez || return 1; chroot_enabled bluetooth || return 1 ;;
      zram) chroot_has zram-generator || return 1 ;;
      fastfetch) chroot_has fastfetch || return 1 ;;
      gstreamer) chroot_has gst-plugins-good || return 1 ;;
      vulkan) chroot_has vulkan-icd-loader || return 1 ;;
      libva) chroot_has libva-utils || return 1 ;;
    esac
  done
  return 0
}

verify_step4() {
  verify_step2 || return 1
  if [[ "${STEP4_SKIPPED}" == "1" ]]; then
    return 0
  fi
  [[ -n "${STEP4_SEL// }" ]] || return 1
  local id
  for id in ${STEP4_SEL}; do
    case "$id" in
      skip) ;;
      repos)
        file_has /mnt/etc/pacman.conf 'cachyos' || return 1
        ;;
      helpers)
        chroot_has yay || return 1
        chroot_has paru || return 1
        ;;
      chaotic)
        file_has /mnt/etc/pacman.conf '^\[chaotic-aur\]' || return 1
        ;;
      kernel)
        chroot_has linux-cachyos || return 1
        [[ -f /mnt/boot/vmlinuz-linux-cachyos ]] || return 1
        file_has /mnt/boot/loader/entries/arch.conf 'vmlinuz-linux-cachyos' || return 1
        ;;
      gaming)
        chroot_has cachyos-gaming-meta || return 1
        ;;
      settings)
        chroot_has cachyos-settings || return 1
        ;;
      patch)
        [[ -f /mnt/root/.arch4/pacman-patched ]] || return 1
        ;;
      ilovecandy)
        if [[ " ${STEP4_SEL} " == *" repos "* ]]; then
          file_has /mnt/etc/pacman.conf '^ILoveCandy' || return 1
        fi
        ;;
    esac
  done
  return 0
}

refresh_status() {
  local s1=0 s2=0 s3=0 s4=0
  if verify_step1; then s1=1; fi
  if [[ "$s1" == "1" ]] && verify_step2; then s2=1; fi
  if [[ "$s2" == "1" ]] && verify_step3; then s3=1; fi
  if [[ "$s2" == "1" ]] && verify_step4; then s4=1; fi
  STEP1=$s1
  STEP2=$s2
  STEP3=$s3
  STEP4=$s4
  save_state
}

tag_done() {
  if [[ "$2" == "1" ]]; then
    printf '%s[skip]%s' "$YLW" "$RST"
  elif [[ "$1" == "1" ]]; then
    printf '%s[done]%s' "$GRN" "$RST"
  else
    printf '%s[    ]%s' "$DIM" "$RST"
  fi
}

# --- chroot bodies (dumped with declare -f; vars set at runtime) -----------

append_nvidia_kparams() {
  local f=/boot/loader/entries/arch.conf
  [[ -f "$f" ]] || return 0
  grep -q 'nvidia-drm.modeset=1' "$f" || sed -i '/^options / s/$/ nvidia-drm.modeset=1/' "$f"
  grep -q 'nvidia_drm.fbdev=1' "$f" || sed -i '/^options / s/$/ nvidia_drm.fbdev=1/' "$f"
}

chroot_step2_main() {
  # Guide §13–15 order: packages first, then locale/host, then multilib + -Sy, then bootctl.
  local CONF=/etc/pacman.conf
  if grep -q '^#ParallelDownloads' "$CONF"; then
    sed -i "s/^#ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL}/" "$CONF"
  elif grep -q '^ParallelDownloads' "$CONF"; then
    sed -i "s/^ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL}/" "$CONF"
  else
    sed -i "/^\\[options\\]/a ParallelDownloads = ${PARALLEL_DL}" "$CONF"
  fi
  sed -i 's/^#Color$/Color/' "$CONF"
  sed -i 's/^[[:space:]]*DownloadUser[[:space:]]*=[[:space:]]*alpm/#&/' "$CONF"

  pac_cache_prep() {
    mkdir -p /var/cache/pacman/pkg
    chmod 755 /var/cache/pacman /var/cache/pacman/pkg 2>/dev/null || true
    rm -rf /var/cache/pacman/pkg/download-*
    rm -f /var/lib/pacman/db.lck
    rm -f /var/lib/pacman/sync/*.db.part
    rm -f /var/lib/pacman/sync/*.db.sig.part
  }
  # Up to 5 attempts; clean cache/locks; ParallelDownloads stays at PARALLEL_DL (20).
  pac_retry() {
    local n=1
    while true; do
      pac_cache_prep
      local cmd=("$@")
      if [[ "${cmd[0]}" == "pacman" ]]; then
        cmd=(pacman --disable-download-timeout "${cmd[@]:1}")
      fi
      if "${cmd[@]}"; then
        return 0
      fi
      if [[ $n -ge 5 ]]; then
        return 1
      fi
      echo "pacman retry ${n}/5 failed, cleaning and retrying..." >&2
      n=$((n + 1))
      sleep $((n * 2))
    done
  }

  # Sync first, then §13 packages in one transaction.
  pac_retry pacman -Sy --noconfirm
  local bootstrap_pkgs=(networkmanager)
  local _ed
  for _ed in ${EDITOR_PKG}; do
    [[ -n "$_ed" ]] || continue
    bootstrap_pkgs+=("$_ed")
  done
  pac_retry pacman -S --noconfirm --needed "${bootstrap_pkgs[@]}"
  systemctl enable NetworkManager fstrim.timer systemd-timesyncd

  # §14 — locale / hostname / timezone (offline)
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  hwclock --systohc --localtime
  sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
  sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  locale-gen
  printf 'LANG=%s\n' "${LOCALE}" > /etc/locale.conf
  printf 'KEYMAP=%s\n' "${KEYMAP}" > /etc/vconsole.conf
  printf '%s\n' "${HOST_NAME}" > /etc/hostname
  cat > /etc/hosts <<H
127.0.0.1        localhost
::1              localhost
127.0.1.1        ${HOST_NAME}.localdomain ${HOST_NAME}
H

  # §14 — enable multilib, then sync (guide: pacman -Sy after multilib)
  if grep -q '^#\[multilib\]' "$CONF"; then
    sed -i '/^#\[multilib\]/{s/^#//;n;s/^#Include/Include/}' "$CONF"
  fi
  pac_retry pacman -Sy --noconfirm

  # §15 — systemd-boot
  bootctl install
  mkdir -p /boot/loader/entries
  local ROOTSRC PARTUUID
  ROOTSRC=$(findmnt -n -o SOURCE /)
  PARTUUID=$(blkid -s PARTUUID -o value "$ROOTSRC")
  cat > /boot/loader/loader.conf <<'LC'
default arch.conf
timeout 0
console-mode keep
editor no
LC
  {
    echo "title Arch Linux"
    echo "linux /vmlinuz-linux"
    [[ -n "${UCODE_IMG}" ]] && echo "initrd /${UCODE_IMG}"
    echo "initrd /initramfs-linux.img"
    echo "options root=PARTUUID=${PARTUUID} rw"
  } > /boot/loader/entries/arch.conf
}

chroot_step3_main() {
  pac_cache_prep() {
    mkdir -p /var/cache/pacman/pkg
    chmod 755 /var/cache/pacman /var/cache/pacman/pkg 2>/dev/null || true
    rm -rf /var/cache/pacman/pkg/download-*
    rm -f /var/lib/pacman/db.lck
    rm -f /var/lib/pacman/sync/*.db.part
    rm -f /var/lib/pacman/sync/*.db.sig.part
  }
  pac_retry() {
    local n=1
    while true; do
      pac_cache_prep
      local cmd=("$@")
      if [[ "${cmd[0]}" == "pacman" ]]; then
        cmd=(pacman --disable-download-timeout "${cmd[@]:1}")
      fi
      if "${cmd[@]}"; then
        return 0
      fi
      if [[ $n -ge 5 ]]; then
        return 1
      fi
      echo "pacman retry ${n}/5 failed, cleaning and retrying..." >&2
      n=$((n + 1))
      sleep $((n * 2))
    done
  }

  pac_retry pacman -Sy --noconfirm
  pac_retry pacman -S --noconfirm --needed linux-headers
  if [[ -n "${DE_PKGS:-}" ]]; then
    # shellcheck disable=SC2206
    local de_arr=(${DE_PKGS})
    pac_retry pacman -S --noconfirm --needed "${de_arr[@]}"
  fi
  if [[ -n "${EXTRA_PKGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_arr=(${EXTRA_PKGS})
    pac_retry pacman -S --noconfirm --needed "${extra_arr[@]}"
  fi
  if [[ "${GPU}" == "nvidia" ]]; then
    pac_retry pacman -S --noconfirm --needed \
      nvidia-open-dkms libglvnd nvidia-utils opencl-nvidia \
      lib32-libglvnd lib32-nvidia-utils lib32-opencl-nvidia nvidia-settings \
      libva-nvidia-driver vdpauinfo
    if grep -q '^MODULES=()' /etc/mkinitcpio.conf; then
      sed -i 's/^MODULES=()/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    elif ! grep -q 'nvidia_drm' /etc/mkinitcpio.conf; then
      sed -i 's/^MODULES=(\s*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf
    fi
    mkdir -p /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/nvidia.hook <<'HOOK'
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia
Target=nvidia-open-dkms
Target=linux
Target=linux-headers
Target=linux-cachyos
Target=linux-cachyos-headers

[Action]
Description=Update NVIDIA module in initcpio
Depends=mkinitcpio
When=PostTransaction
Exec=/usr/bin/mkinitcpio -P
HOOK
    mkinitcpio -P
    append_nvidia_kparams
  elif [[ "${GPU}" == "amd" ]]; then
    pac_retry pacman -S --noconfirm --needed \
      mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu \
      libva-mesa-driver lib32-libva-mesa-driver mesa-vdpau lib32-mesa-vdpau vdpauinfo
  elif [[ "${GPU}" == "vmware" ]]; then
    pac_retry pacman -S --noconfirm --needed \
      open-vm-tools xf86-video-vmware xf86-input-vmmouse
    systemctl enable vmtoolsd
  else
    pac_retry pacman -S --noconfirm --needed \
      mesa lib32-mesa vulkan-intel lib32-vulkan-intel \
      intel-media-driver libva-intel-driver
  fi
  echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
  chmod 440 /etc/sudoers.d/wheel
  useradd -m -G wheel -s /bin/bash "${USERNAME}" || usermod -aG wheel -s /bin/bash "${USERNAME}"
  if [[ -n "${DM:-}" ]]; then
    systemctl enable "${DM}"
  fi
  local svc
  for svc in ${ENABLE_SVCS}; do
    [[ -n "$svc" ]] && systemctl enable "$svc"
  done
  if command -v ufw >/dev/null 2>&1; then
    ufw --force default deny incoming
    ufw --force default allow outgoing
    ufw --force enable || true
  fi
  # First login (TTY): always nmtui first, then optional end4/opencode — once only.
  local home="/home/${USERNAME}"
  mkdir -p "${home}/.config/arch4"
  printf '%s\n' "${KEYMAP}" > "${home}/.config/arch4/keymap"
  touch "${home}/.config/arch4/firstboot.pending"
  if [[ "${DESKTOP}" == "end4" ]]; then
    touch "${home}/.config/arch4/end4.pending"
    if [[ "${OPENCODE:-0}" == "1" ]]; then
      touch "${home}/.config/arch4/opencode.pending"
    fi
  fi
  cat > "${home}/.config/arch4/firstboot.sh" <<'FB'
#!/usr/bin/env bash
# Runs once on first interactive TTY login — not on the Arch ISO.
[[ -t 0 ]] || exit 0
FBDIR="$HOME/.config/arch4"
[[ -f "$FBDIR/firstboot.pending" ]] || exit 0

KM=de
[[ -f "$FBDIR/keymap" ]] && KM="$(tr -d '[:space:]' < "$FBDIR/keymap")"
[[ -z "$KM" ]] && KM=de
echo "==> Arch4: first boot — loadkeys ${KM}"
sudo loadkeys "$KM" || true

echo "==> Arch4: first boot — NetworkManager (nmtui)"
sudo nmtui || true

if [[ -f "$FBDIR/opencode.pending" ]]; then
  echo "==> Arch4: installing OpenCode"
  curl -fsSL https://opencode.ai/install | bash
  rm -f "$FBDIR/opencode.pending"
fi

if [[ -f "$FBDIR/end4.pending" ]]; then
  echo "==> Arch4: starting end-4 Hyprland installer."
  mv "$FBDIR/end4.pending" "$FBDIR/end4.started"
  bash <(curl -s https://ii.clsty.link/get)
fi

rm -f "$FBDIR/firstboot.pending"
FB
  chmod 755 "${home}/.config/arch4/firstboot.sh"
  local hook='[[ -t 0 && -f "$HOME/.config/arch4/firstboot.sh" ]] && bash "$HOME/.config/arch4/firstboot.sh"'
  local f
  for f in "${home}/.bash_profile" "${home}/.profile"; do
    touch "$f"
    grep -q 'arch4/firstboot.sh' "$f" 2>/dev/null || printf '\n%s\n' "$hook" >> "$f"
  done
  chown -R "${USERNAME}:${USERNAME}" "$home"
}

chroot_step4_main() {
  retry() {
    local n=1 max=5
    while true; do
      if "$@"; then return 0; fi
      if [[ $n -ge $max ]]; then
        echo "failed after ${max} tries: $*" >&2
        return 1
      fi
      echo "try ${n}/${max} failed, wait $((n*3))s: $*" >&2
      sleep $((n*3))
      n=$((n+1))
    done
  }
  pacman() { command pacman --noconfirm --needed "$@"; }
  retry command pacman --noconfirm -Sy
  retry pacman -S wget curl tar gawk gcc
  if [[ "${DO_REPOS}" -eq 1 ]]; then
    install_cachy_repos() {
      sed -i '/^\[cachyos/,/^$/d' /etc/pacman.conf
      sed -i '/^\[cachyos\]/,/^$/d' /etc/pacman.conf
      rm -f /var/lib/pacman/sync/cachyos*.db* /var/lib/pacman/sync/cachyos*.files*
      rm -f /var/lib/pacman/db.lck
      cd /tmp
      rm -rf cachyos-repo cachyos-repo.tar.xz
      curl -fL --retry 2 --retry-delay 2 https://mirror.cachyos.org/cachyos-repo.tar.xz -o cachyos-repo.tar.xz
      tar xf cachyos-repo.tar.xz
      cd cachyos-repo
      local rc=1
      local _pipes=()
      set +e
      set +o pipefail
      if ./cachyos-repo.sh --help 2>/dev/null | grep -q -- '--install'; then
        yes | ./cachyos-repo.sh --install
        _pipes=("${PIPESTATUS[@]}")
      else
        yes | ./cachyos-repo.sh
        _pipes=("${PIPESTATUS[@]}")
      fi
      rc="${_pipes[1]:-1}"
      [[ "$rc" -eq 0 ]] || rc=1
      set -o pipefail
      set -e
      cd /tmp
      rm -rf cachyos-repo cachyos-repo.tar.xz
      return "$rc"
    }
    retry install_cachy_repos
  fi
  if [[ "${DO_HELPERS}" -eq 1 ]]; then
    retry pacman -S yay paru
  fi
  if [[ "${DO_CHAOTIC}" -eq 1 ]]; then
    retry pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
    retry pacman-key --lsign-key 3056513887B78AEB
    retry pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
    retry pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
    if ! grep -q '^\[chaotic-aur\]' /etc/pacman.conf; then
      printf '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n' >> /etc/pacman.conf
    fi
    retry command pacman --noconfirm -Sy
  fi
  if [[ "${DO_KERNEL}" -eq 1 ]]; then
    retry pacman -S linux-cachyos linux-cachyos-headers cachyos-kernel-manager
    if [[ -f /boot/loader/entries/arch.conf ]]; then
      if [[ ! -f /boot/loader/entries/arch-linux.conf ]]; then
        cp /boot/loader/entries/arch.conf /boot/loader/entries/arch-linux.conf
        sed -i 's/^title .*/title Arch Linux (stock)/' /boot/loader/entries/arch-linux.conf
      fi
      sed -i 's|^title .*|title Arch Linux (CachyOS)|' /boot/loader/entries/arch.conf
      sed -i 's|^linux .*|linux /vmlinuz-linux-cachyos|' /boot/loader/entries/arch.conf
      sed -i 's|^initrd /initramfs-linux.img|initrd /initramfs-linux-cachyos.img|' /boot/loader/entries/arch.conf
    fi
    mkinitcpio -P
  fi
  if [[ "${DO_GAMING}" -eq 1 ]]; then
    retry pacman -S cachyos-gaming-meta
  fi
  if [[ "${DO_SETTINGS}" -eq 1 ]]; then
    retry pacman -S cachyos-settings
  fi
  if [[ "${DO_PATCH}" -eq 1 ]]; then
    retry command pacman --noconfirm -S pacman
    retry command pacman --noconfirm -Syuu
    mkdir -p /root/.arch4
    date -Is > /root/.arch4/pacman-patched
  fi
  if [[ "${DO_ILOVECANDY:-0}" -eq 1 && "${DO_REPOS}" -eq 1 ]]; then
    local CONF=/etc/pacman.conf
    if ! grep -q '^ILoveCandy' "$CONF"; then
      if grep -q '^ParallelDownloads' "$CONF"; then
        # Full line match so " = 20" stays on ParallelDownloads, not on ILoveCandy.
        sed -i 's/^ParallelDownloads.*/&\nILoveCandy/' "$CONF"
      else
        sed -i '/^\[options\]/a ILoveCandy' "$CONF"
      fi
    fi
  fi
  cd / && rm -rf /tmp/cachyos-repo /tmp/cachyos-repo.tar.xz
}

run_chroot_fn() {
  local fn="$1"
  mkdir -p /mnt/root/.arch4
  local dest="/mnt/root/.arch4/${fn}.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'TIMEZONE=%q\n' "${TIMEZONE}"
    printf 'LOCALE=%q\n' "${LOCALE}"
    printf 'KEYMAP=%q\n' "${KEYMAP}"
    printf 'HOST_NAME=%q\n' "${HOST_NAME}"
    printf 'PARALLEL_DL=%q\n' "${PARALLEL_DL}"
    printf 'EDITOR_PKG=%q\n' "${EDITOR_PKG}"
    printf 'UCODE_IMG=%q\n' "${UCODE_IMG:-}"
    printf 'GPU=%q\n' "${GPU:-}"
    printf 'USERNAME=%q\n' "${USERNAME:-}"
    printf 'DESKTOP=%q\n' "${DESKTOP:-}"
    printf 'DM=%q\n' "${DM:-}"
    printf 'DE_PKGS=%q\n' "${DE_PKGS:-}"
    printf 'EXTRA_PKGS=%q\n' "${EXTRA_PKGS:-}"
    printf 'ENABLE_SVCS=%q\n' "${ENABLE_SVCS:-}"
    printf 'DO_REPOS=%q\n' "${DO_REPOS:-0}"
    printf 'DO_HELPERS=%q\n' "${DO_HELPERS:-0}"
    printf 'DO_CHAOTIC=%q\n' "${DO_CHAOTIC:-0}"
    printf 'DO_KERNEL=%q\n' "${DO_KERNEL:-0}"
    printf 'DO_GAMING=%q\n' "${DO_GAMING:-0}"
    printf 'DO_SETTINGS=%q\n' "${DO_SETTINGS:-0}"
    printf 'DO_PATCH=%q\n' "${DO_PATCH:-0}"
    printf 'DO_ILOVECANDY=%q\n' "${DO_ILOVECANDY:-0}"
    printf 'OPENCODE=%q\n' "${OPENCODE:-0}"
    declare -f append_nvidia_kparams
    declare -f "$fn"
    echo "$fn"
  } > "$dest"
  chmod 700 "$dest"
  if [[ "$DRY_RUN" == "1" ]]; then
    info "DRY-RUN: would arch-chroot /mnt → ${fn}"
    must "chroot ${fn} (dry-run)" true
    return 0
  fi
  req_run "chroot ${fn}" arch-chroot /mnt /bin/bash "${dest#/mnt}"
}

# --- flow helpers ----------------------------------------------------------

all_done() {
  [[ "${STEP1}" == "1" && "${STEP2}" == "1" && "${STEP3}" == "1" && "${STEP4}" == "1" ]]
}

ask_reboot() {
  if [[ "$DRY_RUN" == "1" ]]; then
    info "DRY-RUN: not rebooting."
    return 0
  fi
  if pick_yesno "Reboot into the new system now?" "N"; then
    info "Unmounting /mnt and rebooting..."
    sync
    umount -R /mnt 2>/dev/null || true
    sleep 1
    reboot
  else
    info "Not rebooting."
  fi
}

after_step() {
  if all_done; then
    info "All 4 steps finished successfully."
    ask_reboot
    if pick_yesno "Return to menu?" "Y"; then return 0; fi
    exit 0
  fi
  if pick_yesno "Return to menu?" "Y"; then return 0; fi
  ask_reboot
  exit 0
}

exit_flow() {
  if all_done; then info "All 4 steps are complete."; fi
  ask_reboot
  exit 0
}

maybe_resume_banner() {
  if [[ "${STEP1}${STEP2}${STEP3}${STEP4}" == "0000" ]]; then
    return 0
  fi
  info "Previous progress detected (live checks):"
  [[ "$STEP1" == "1" ]] && info "  1 Disk      done  ${DISK}"
  [[ "$STEP1" != "1" ]] && info "  1 Disk      open"
  [[ "$STEP2" == "1" ]] && info "  2 Base      done  ${HOST_NAME} / ${LOCALE}"
  [[ "$STEP2" != "1" ]] && info "  2 Base      open"
  [[ "$STEP3" == "1" ]] && info "  3 Drivers   done  ${USERNAME} · ${DESKTOP} · ${GPU}"
  [[ "$STEP3" != "1" ]] && info "  3 Drivers   open"
  if [[ "$STEP4_SKIPPED" == "1" ]]; then
    info "  4 Minmaxed  skipped"
  elif [[ "$STEP4" == "1" ]]; then
    info "  4 Minmaxed  done"
  else
    info "  4 Minmaxed  open"
  fi
  if ! pick_yesno "Keep this progress and continue?" "Y"; then
    warn "Clearing installer state (disk is not wiped)."
    STEP1=0 STEP2=0 STEP3=0 STEP4=0 STEP4_SKIPPED=0
    DISK="" PART_EFI="" PART_ROOT="" GPU="" USERNAME="" EXTRA_SEL="" STEP4_SEL=""
    save_state
  fi
}

# --- step 1: ISO only (partition / format / mount) -------------------------

step1() {
  local bootmed names=() labels=() line name size model tran typ raw
  bootmed="$(boot_medium_disk)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="$(awk '{print $1}' <<<"$line")"
    size="$(awk '{print $2}' <<<"$line")"
    typ="$(awk '{print $3}' <<<"$line")"
    tran="$(awk '{print $4}' <<<"$line")"
    model="$(awk '{for(i=5;i<=NF;i++) printf $i" "; print ""}' <<<"$line")"
    [[ "$typ" == "disk" ]] || continue
    if [[ -n "$bootmed" && "$name" == "$bootmed" ]]; then
      continue
    fi
    names+=("$name")
    labels+=("${name}   ${size}   ${tran}   ${model}")
  done < <(lsblk -dn -o NAME,SIZE,TYPE,TRAN,MODEL)

  if [[ ${#names[@]} -eq 0 ]]; then
    pause_err "No usable disks found (live USB is skipped)."
    return 1
  fi

  if ! pick "Step 1 — select the install disk" \
      "↑↓ to move, Enter to select. Live ISO disk is hidden. Secure Boot is not supported." \
      "${labels[@]}"; then
    return 1
  fi
  raw="${names[$PICK_IDX]}"
  local disk_path="/dev/${raw}"
  [[ -b "$disk_path" ]] || { pause_err "${disk_path} is not a block device."; return 1; }

  local efi rootp
  efi="$(part_path "$disk_path" 1)"
  rootp="$(part_path "$disk_path" 2)"

  if ! confirm_plan "Step 1 — wipe and partition" \
      "disk     ${disk_path}" \
      "table    GPT" \
      "EFI      ${EFI_SIZE}  ${efi}  FAT32" \
      "root     rest        ${rootp}  ext4" \
      "no swap, no extra /home, no LUKS, no Secure Boot"; then
    return 1
  fi

  local again yes
  again="$(ask "Type the disk name again to confirm (${raw})")"
  again="${again#/dev/}"
  [[ "$again" == "$raw" ]] || { pause_err "Names did not match. Aborted."; return 1; }
  yes="$(ask "Type YES in uppercase to wipe ${disk_path}")"
  [[ "$yes" == "YES" ]] || { pause_err "Did not receive YES. Aborted."; return 1; }

  STEP1=0 STEP2=0 STEP3=0 STEP4=0 STEP4_SKIPPED=0
  EXTRA_SEL=""
  STEP4_SEL=""
  USERNAME=""
  GPU=""
  save_state

  checks_begin
  if [[ "$DRY_RUN" == "1" ]]; then
    info "DRY-RUN: would wipe ${disk_path} and mount ${rootp} + ${efi}"
    must "dry-run step 1" true
    info "Step 1 dry-run complete — not marked done."
    return 0
  fi

  info "Wiping and partitioning ${disk_path}..."
  umount -R /mnt 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  req_run "wipefs" wipefs -af "$disk_path" || return 1
  req_run "sgdisk zap" sgdisk --zap-all "$disk_path" || return 1
  req_run "sgdisk clear" sgdisk --clear "$disk_path" || return 1
  req_run "create EFI 2048M" sgdisk -n 1:1MiB:+${EFI_SIZE} -t 1:ef00 -c 1:EFI "$disk_path" || return 1
  req_run "create root partition" sgdisk -n 2:0:0 -t 2:8300 -c 2:ROOT "$disk_path" || return 1
  partprobe "$disk_path" 2>/dev/null || true
  udevadm settle 2>/dev/null || sleep 2
  local i
  for i in 1 2 3 4 5 6 7 8; do
    [[ -b "$efi" && -b "$rootp" ]] && break
    sleep 0.5
  done
  must_test "EFI block device ${efi}" -b "$efi" || true
  must_test "root block device ${rootp}" -b "$rootp" || true
  [[ -b "$efi" && -b "$rootp" ]] || {
    dump_fail_summary
    pause_err "Partitions did not appear."
    return 1
  }
  req_run "mkfs.fat EFI" mkfs.fat -F32 -n EFI "$efi" || return 1
  must_test "EFI is vfat" "$(lsblk -no FSTYPE "$efi" 2>/dev/null || true)" = "vfat" || true
  req_run "mkfs.ext4 root" mkfs.ext4 -F -L ROOT "$rootp" || return 1
  must_test "root is ext4" "$(lsblk -no FSTYPE "$rootp" 2>/dev/null || true)" = "ext4" || true
  mkdir -p /mnt
  req_run "mount root /mnt" mount "$rootp" /mnt || return 1
  must_test "/mnt is root" "$(findmnt -n -o SOURCE /mnt 2>/dev/null || true)" = "$rootp" || true
  mkdir -p /mnt/boot
  req_run "mount EFI /mnt/boot" mount "$efi" /mnt/boot || return 1
  must_test "/mnt/boot is EFI" "$(findmnt -n -o SOURCE /mnt/boot 2>/dev/null || true)" = "$efi" || true
  must_test "partition table GPT" "$(blkid -s PTTYPE -o value "$disk_path" 2>/dev/null || true)" = "gpt" || true

  DISK="$disk_path"
  PART_EFI="$efi"
  PART_ROOT="$rootp"

  if ! checks_ok || ! verify_step1; then
    STEP1=0
    save_state
    dump_fail_summary
    pause_err "Step 1 checks failed — not marked done."
    return 1
  fi
  STEP1=1
  save_state
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$disk_path"
  info "Step 1 complete — all checks passed."
  return 0
}

# --- step 2: pacstrap from ISO, then ALL config in arch-chroot -------------

step2() {
  if ! verify_step1; then
    pause_err "Step 1 must finish first (root must be mounted at /mnt)."
    return 1
  fi
  [[ -n "$PART_ROOT" && -n "$PART_EFI" ]] || {
    pause_err "Missing partition info. Re-run step 1."
    return 1
  }

  detect_ucode

  if [[ "${SKIP_MENUS}" != "1" ]]; then
    HOST_NAME="$(ask "Hostname" "$HOST_NAME")"
    HOST_NAME="$(printf '%s' "$HOST_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' )"
    [[ -n "$HOST_NAME" ]] || HOST_NAME="iusearchbtw"

    if ! pick "Step 2 — locale" \
        "Default matches the guide (de_DE)." \
        "de_DE.UTF-8  (default)" \
        "en_US.UTF-8"; then
      return 1
    fi
    case "$PICK_IDX" in
      0) LOCALE="de_DE.UTF-8" ;;
      1) LOCALE="en_US.UTF-8" ;;
    esac

    if ! pick "Step 2 — timezone" \
        "Default Europe/Berlin." \
        "Europe/Berlin  (default)" \
        "UTC"; then
      return 1
    fi
    case "$PICK_IDX" in
      0) TIMEZONE="Europe/Berlin" ;;
      1) TIMEZONE="UTC" ;;
    esac

    if ! pick "Step 2 — console keymap" \
        "Default de." \
        "de  (default)" \
        "us"; then
      return 1
    fi
    case "$PICK_IDX" in
      0) KEYMAP="de" ;;
      1) KEYMAP="us" ;;
    esac

    if ! pick "Step 2 — editor" \
        "Kernel, NetworkManager, systemd-boot, multilib are fixed." \
        "nano and vim   (default)" \
        "nano" \
        "vim"; then
      return 1
    fi
    case "$PICK_IDX" in
      0) EDITOR_PKG="nano vim" ;;
      1) EDITOR_PKG="nano" ;;
      2) EDITOR_PKG="vim" ;;
    esac
  else
    EDITOR_PKG="${EDITOR_PKG:-nano}"
  fi

  if [[ "${SKIP_MENUS}" != "1" ]]; then
    if ! confirm_plan "Step 2 — base system (guide §9 ISO, §12–15 chroot)" \
        "hostname   ${HOST_NAME}" \
        "locale     ${LOCALE}" \
        "timezone   ${TIMEZONE}" \
        "keymap     ${KEYMAP}" \
        "editor     ${EDITOR_PKG}" \
        "microcode  ${UCODE_PKG:-none}" \
        "pacstrap   base base-devel linux linux-firmware ${UCODE_PKG}" \
        "boot       systemd-boot timeout 0 · ParallelDownloads=${PARALLEL_DL}"; then
      return 1
    fi
  fi

  STEP2=0 STEP3=0 STEP4=0 STEP4_SKIPPED=0
  STEP4_SEL=""
  save_state
  checks_begin

  if [[ "$DRY_RUN" == "1" ]]; then
    info "DRY-RUN: would pacstrap + chroot step2"
    must "dry-run step 2" true
    info "Step 2 dry-run complete — not marked done."
    return 0
  fi

  info "Selections locked — starting base install (guide §9–10)."
  _iso_pacman_backup
  req_run "ParallelDownloads=${PARALLEL_DL} on ISO" set_parallel /etc/pacman.conf || return 1
  sed -i 's/^[[:space:]]*DownloadUser[[:space:]]*=[[:space:]]*alpm/#&/' /etc/pacman.conf
  must "ISO ParallelDownloads set" grep -q "^ParallelDownloads = ${PARALLEL_DL}" /etc/pacman.conf || true

  # Guide §10 exactly: base base-devel linux linux-firmware + ucode. No linux-headers here.
  local pkgs=(base base-devel linux linux-firmware)
  [[ -n "$UCODE_PKG" ]] && pkgs+=("$UCODE_PKG")

  info "pacstrap -K /mnt ${pkgs[*]}"
  if ! pacstrap_retry "${pkgs[@]}"; then
    pause_err "pacstrap failed (guide §10)."
    return 1
  fi
  must "pacstrap base system" true
  must_test "os-release in /mnt" -f /mnt/etc/os-release || true
  must "package base" chroot_has base || true
  must "package base-devel" chroot_has base-devel || true
  must "package linux" chroot_has linux || true
  must "package linux-firmware" chroot_has linux-firmware || true
  if [[ -n "$UCODE_PKG" ]]; then
    must "package ${UCODE_PKG}" chroot_has "$UCODE_PKG" || true
  fi

  info "Generating fstab (guide §10)..."
  req_run "genfstab" bash -c ': > /mnt/etc/fstab; genfstab -U -p /mnt >> /mnt/etc/fstab' || return 1
  must_test "fstab exists" -s /mnt/etc/fstab || true
  must "fstab has UUID" grep -q UUID /mnt/etc/fstab || true

  info "arch-chroot /mnt — locale, pacman, NetworkManager, bootctl"
  run_chroot_fn chroot_step2_main || {
    pause_err "Base system configure (chroot) failed."
    STEP2=0
    save_state
    return 1
  }
  must_test "hostname ${HOST_NAME}" "$(tr -d '[:space:]' < /mnt/etc/hostname 2>/dev/null || true)" = "$HOST_NAME" || true
  must "locale ${LOCALE}" file_has /mnt/etc/locale.conf "^LANG=${LOCALE}" || true
  must "package networkmanager" chroot_has networkmanager || true
  local p
  for p in ${EDITOR_PKG}; do
    must "package ${p}" chroot_has "$p" || true
  done
  must "[multilib] enabled" file_has /mnt/etc/pacman.conf '^\[multilib\]' || true
  must "NetworkManager enabled" chroot_enabled NetworkManager || true
  must "fstrim.timer enabled" chroot_enabled fstrim.timer || true
  must "timesyncd enabled" chroot_enabled systemd-timesyncd || true
  must_test "systemd-boot loader.conf" -f /mnt/boot/loader/loader.conf || true
  must "boot timeout 0" file_has /mnt/boot/loader/loader.conf '^timeout 0' || true
  must_test "arch.conf exists" -f /mnt/boot/loader/entries/arch.conf || true
  must "arch.conf linux image" file_has /mnt/boot/loader/entries/arch.conf '^linux /vmlinuz-linux' || true

  if ! checks_ok || ! verify_step2; then
    STEP2=0
    save_state
    dump_fail_summary
    pause_err "Step 2 checks failed — not marked done."
    return 1
  fi
  STEP2=1
  save_state
  info "Step 2 complete — all checks passed."
  return 0
}

# --- step 3: all in arch-chroot --------------------------------------------

step3() {
  if ! verify_step2; then
    pause_err "Step 2 must finish first (base system in /mnt)."
    return 1
  fi

  local user pw1 pw2 r1 r2 extra_pkgs=() extra_enable=()
  if [[ "${SKIP_MENUS}" == "1" ]]; then
    GPU="nvidia"
    DESKTOP="kde"
    DM="sddm"
    user="${STEP3_USER}"
    pw1="${STEP3_PW}"
    r1="${STEP3_ROOT_PW}"
    MULTI_SEL="flatpak git wget thermald kate ufw fzf python bluetooth zram fastfetch gstreamer vulkan libva "
    info "Nico's plan: NVIDIA · KDE Plasma · SDDM · all extras on"
  else
    if ! pick "Step 3 — GPU drivers" \
        "↑↓ then Enter. NVIDIA open-dkms = Turing / GTX 16 / RTX 20+." \
        "NVIDIA  (nvidia-open-dkms)" \
        "AMD" \
        "Intel" \
        "VMware tools  (open-vm-tools)"; then
      return 1
    fi
    case "$PICK_IDX" in
      0) GPU="nvidia" ;;
      1) GPU="amd" ;;
      2) GPU="intel" ;;
      3) GPU="vmware" ;;
    esac

    if ! pick "Step 3 — desktop" \
        "Login manager is locked to the desktop. end4-hyprland installs after first login (not on the ISO)." \
        "KDE Plasma  + SDDM   (default)" \
        "GNOME       + GDM" \
        "end4-hyprland  (after first login)" \
        "None        (no desktop, no display manager)"; then
      return 1
    fi
    case "$PICK_IDX" in
      0) DESKTOP="kde"; DM="sddm"; OPENCODE=0 ;;
      1) DESKTOP="gnome"; DM="gdm"; OPENCODE=0 ;;
      2) DESKTOP="end4"; DM=""; OPENCODE=1 ;;
      3) DESKTOP="none"; DM=""; OPENCODE=0 ;;
    esac

    if [[ "$DESKTOP" == "end4" ]]; then
      if ! pick_multi "Step 3 — apps after first login" \
          "Runs on the installed system after you log in. Space toggles. Enter continues." \
          "opencode (curl https://opencode.ai/install)|opencode"; then
        return 1
      fi
      OPENCODE=0
      multi_has opencode && OPENCODE=1
    fi

    local extra_items=()
    extra_items+=(
      "flatpak|flatpak"
      "git|git"
      "wget|wget"
      "thermald|thermald"
    )
    if [[ "$DESKTOP" == "kde" ]]; then
      extra_items+=("kate (KDE editor)|kate")
    elif [[ "$DESKTOP" == "gnome" ]]; then
      extra_items+=(
        "gedit|gedit"
        "gnome-text-editor|gnome-text-editor"
        "gnome-font-viewer|gnome-font-viewer"
        "gnome-tweaks|gnome-tweaks"
      )
    fi
    extra_items+=(
      "ufw (firewall)|ufw"
      "fzf|fzf"
      "python + pip|python"
      "bluetooth (bluez, blueman)|bluetooth"
      "zram-generator|zram"
      "fastfetch|fastfetch"
      "gstreamer (good/bad/libav)|gstreamer"
      "vulkan (64-bit + 32-bit)|vulkan"
      "libva-utils|libva"
    )
    if ! pick_multi "Step 3 — extra packages" \
        "All on by default. Space toggles. Enter continues." \
        "${extra_items[@]}"; then
      return 1
    fi

    while true; do
      user="$(ask "Username")"
      user="$(printf '%s' "$user" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
      if [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ && "$user" != "root" && ${#user} -le 32 ]]; then
        break
      fi
      warn "Lowercase Linux username (letter first, then letters/digits/_/-)."
    done

    while true; do
      pw1="$(ask_secret "Password for ${user}")"
      pw2="$(ask_secret "Repeat user password")"
      [[ -n "$pw1" ]] || { warn "Password cannot be empty."; continue; }
      [[ "$pw1" == "$pw2" ]] || { warn "Passwords did not match."; continue; }
      break
    done
    while true; do
      r1="$(ask_secret "Password for root")"
      r2="$(ask_secret "Repeat root password")"
      [[ -n "$r1" ]] || { warn "Password cannot be empty."; continue; }
      [[ "$r1" == "$r2" ]] || { warn "Passwords did not match."; continue; }
      break
    done

    if ! confirm_plan "Step 3 — drivers & user" \
        "GPU       ${GPU}" \
        "desktop   ${DESKTOP}${DM:+ + ${DM}}" \
        "end4      $([ "$DESKTOP" = end4 ] && echo "first login · loadkeys ${KEYMAP} · curl ii.clsty.link/get" || echo "-")" \
        "opencode  $([ "$OPENCODE" = 1 ] && echo "yes (after login)" || echo "no")" \
        "user      ${user} (wheel)" \
        "extras    ${MULTI_SEL}"; then
      unset pw1 pw2 r1 r2
      return 1
    fi
  fi

  extra_pkgs+=(sudo)
  [[ "$DESKTOP" == "end4" ]] && extra_pkgs+=(git curl)
  multi_has flatpak && extra_pkgs+=(flatpak)
  multi_has git && extra_pkgs+=(git)
  multi_has wget && extra_pkgs+=(wget)
  multi_has thermald && extra_pkgs+=(thermald)
  multi_has kate && extra_pkgs+=(kate)
  multi_has gedit && extra_pkgs+=(gedit)
  multi_has gnome-text-editor && extra_pkgs+=(gnome-text-editor)
  multi_has gnome-font-viewer && extra_pkgs+=(gnome-font-viewer)
  multi_has gnome-tweaks && extra_pkgs+=(gnome-tweaks)
  multi_has ufw && extra_pkgs+=(ufw) && extra_enable+=(ufw)
  multi_has fzf && extra_pkgs+=(fzf)
  multi_has python && extra_pkgs+=(python python-pip)
  multi_has bluetooth && extra_pkgs+=(bluez blueman bluez-utils) && extra_enable+=(bluetooth)
  multi_has zram && extra_pkgs+=(zram-generator)
  multi_has fastfetch && extra_pkgs+=(fastfetch)
  multi_has gstreamer && extra_pkgs+=(gst-plugins-good gst-plugins-bad gst-libav)
  multi_has vulkan && extra_pkgs+=(vulkan-icd-loader lib32-vulkan-icd-loader)
  multi_has libva && extra_pkgs+=(libva-utils)

  local de_pkgs=()
  if [[ "$DESKTOP" == "gnome" ]]; then
    de_pkgs=(gnome-shell gnome-terminal gnome-control-center gnome-software gnome-menus gnome-shell-extensions gnome-system-monitor mutter gdm)
    DM="gdm"
  elif [[ "$DESKTOP" == "kde" ]]; then
    de_pkgs=(plasma konsole ark dolphin sddm)
    DM="sddm"
  elif [[ "$DESKTOP" == "end4" ]]; then
    # Only extra packages with end4 (no full Plasma).
    DM=""
    de_pkgs=(ark kate)
  else
    DESKTOP="none"
    DM=""
    de_pkgs=()
  fi

  DE_PKGS="${de_pkgs[*]}"
  EXTRA_PKGS="${extra_pkgs[*]}"
  ENABLE_SVCS="${extra_enable[*]}"
  EXTRA_SEL="$MULTI_SEL"
  USERNAME="$user"
  STEP3=0
  save_state
  checks_begin

  if [[ "$DRY_RUN" == "1" ]]; then
    info "DRY-RUN: would install ${DESKTOP}/${DM} + ${GPU} + user ${user}"
    unset pw1 pw2 r1 r2 STEP3_PW STEP3_ROOT_PW
    must "dry-run step 3" true
    info "Step 3 dry-run complete — not marked done."
    return 0
  fi

  info "Selections locked — starting desktop/driver install."
  info "arch-chroot /mnt — ${DESKTOP}, ${DM}, drivers, extras..."
  run_chroot_fn chroot_step3_main || {
    unset pw1 pw2 r1 r2 STEP3_PW STEP3_ROOT_PW
    pause_err "Driver / desktop install failed."
    STEP3=0
    save_state
    return 1
  }

  info "Setting passwords inside chroot (not written to state or log)..."
  if printf '%s:%s\n' "root" "$r1" | arch-chroot /mnt chpasswd; then
    must "root password set" true
  else
    must "root password set" false
    unset pw1 pw2 r1 r2 STEP3_PW STEP3_ROOT_PW
    pause_err "Failed to set root password."
    return 1
  fi
  if printf '%s:%s\n' "$user" "$pw1" | arch-chroot /mnt chpasswd; then
    must "user password set" true
  else
    must "user password set" false
    unset pw1 pw2 r1 r2 STEP3_PW STEP3_ROOT_PW
    pause_err "Failed to set user password."
    return 1
  fi
  unset pw1 pw2 r1 r2 STEP3_PW STEP3_ROOT_PW

  USERNAME="$user"
  must "user ${user} exists" chroot_user "$user" || true
  must "package sudo" chroot_has sudo || true
  must "package linux-headers" chroot_has linux-headers || true
  if [[ "$DESKTOP" == "gnome" ]]; then
    must "package gnome-shell" chroot_has gnome-shell || true
    must "package gnome-terminal" chroot_has gnome-terminal || true
    must "package gdm" chroot_has gdm || true
    must "gdm enabled" chroot_enabled gdm || true
  elif [[ "$DESKTOP" == "kde" ]]; then
    must "package plasma" chroot_has plasma-desktop || chroot_has plasma-workspace || true
    must "package konsole" chroot_has konsole || true
    must "package ark" chroot_has ark || true
    must "package dolphin" chroot_has dolphin || true
    must "package sddm" chroot_has sddm || true
    must "sddm enabled" chroot_enabled sddm || true
  elif [[ "$DESKTOP" == "end4" ]]; then
    must "package ark" chroot_has ark || true
    must "package kate" chroot_has kate || true
    must "end4 pending flag" test -f "/mnt/home/${user}/.config/arch4/end4.pending" || true
    must "end4 firstboot script" test -f "/mnt/home/${user}/.config/arch4/firstboot.sh" || true
    must "no display manager (end4 after login)" test -z "${DM}" || true
  else
    must "no display manager (TTY)" test -z "${DM}" || true
  fi
  case "$GPU" in
    nvidia)
      must "nvidia-open-dkms" chroot_has nvidia-open-dkms || true
      must "nvidia-utils" chroot_has nvidia-utils || true
      must "mkinitcpio nvidia modules" file_has /mnt/etc/mkinitcpio.conf 'nvidia_drm' || true
      must "nvidia kparams" file_has /mnt/boot/loader/entries/arch.conf 'nvidia-drm.modeset=1' || true
      ;;
    amd)
      must "mesa" chroot_has mesa || true
      must "vulkan-radeon" chroot_has vulkan-radeon || true
      ;;
    vmware)
      must "open-vm-tools" chroot_has open-vm-tools || true
      must "vmtoolsd enabled" chroot_enabled vmtoolsd || true
      ;;
    intel)
      must "mesa" chroot_has mesa || true
      must "vulkan-intel" chroot_has vulkan-intel || true
      ;;
  esac
  local id
  for id in ${EXTRA_SEL}; do
    case "$id" in
      flatpak) must "extra flatpak" chroot_has flatpak || true ;;
      git) must "extra git" chroot_has git || true ;;
      wget) must "extra wget" chroot_has wget || true ;;
      thermald) must "extra thermald" chroot_has thermald || true ;;
      kate) must "extra kate" chroot_has kate || true ;;
      gedit) must "extra gedit" chroot_has gedit || true ;;
      gnome-text-editor) must "extra gnome-text-editor" chroot_has gnome-text-editor || true ;;
      gnome-font-viewer) must "extra gnome-font-viewer" chroot_has gnome-font-viewer || true ;;
      gnome-tweaks) must "extra gnome-tweaks" chroot_has gnome-tweaks || true ;;
      ufw) must "extra ufw" chroot_has ufw || true; must "ufw enabled" chroot_enabled ufw || true ;;
      fzf) must "extra fzf" chroot_has fzf || true ;;
      python) must "extra python" chroot_has python || true ;;
      bluetooth) must "extra bluez" chroot_has bluez || true; must "bluetooth enabled" chroot_enabled bluetooth || true ;;
      zram) must "extra zram-generator" chroot_has zram-generator || true ;;
      fastfetch) must "extra fastfetch" chroot_has fastfetch || true ;;
      gstreamer) must "extra gst-plugins-good" chroot_has gst-plugins-good || true ;;
      vulkan) must "extra vulkan-icd-loader" chroot_has vulkan-icd-loader || true ;;
      libva) must "extra libva-utils" chroot_has libva-utils || true ;;
    esac
  done

  if ! checks_ok || ! verify_step3; then
    STEP3=0
    save_state
    dump_fail_summary
    pause_err "Step 3 checks failed — not marked done."
    return 1
  fi
  STEP3=1
  save_state
  info "Step 3 complete — all checks passed. User ${user} · ${DESKTOP} · ${DM} · GPU ${GPU}."
  return 0
}

# --- step 4: all in arch-chroot --------------------------------------------

step4() {
  if ! verify_step2; then
    pause_err "Step 2 must finish first (need a chrootable system)."
    return 1
  fi

  if [[ "${SKIP_MENUS}" != "1" ]]; then
    if ! pick_multi "Step 4 — minmaxed (CachyOS)" \
        "All on by default. Space toggles. Enter continues. n = none (skip step)." \
        "CachyOS repos|repos" \
        "yay + paru|helpers" \
        "Chaotic-AUR|chaotic" \
        "linux-cachyos + headers + kernel manager|kernel" \
        "cachyos-gaming-meta|gaming" \
        "cachyos-settings|settings" \
        "pacman patch + full upgrade (-Syuu)|patch" \
        "enable ILoveCandy (c instead of # animation)|ilovecandy"; then
      return 1
    fi
  else
    MULTI_SEL="repos helpers chaotic kernel gaming settings patch ilovecandy "
  fi

  if [[ -z "${MULTI_SEL// }" ]]; then
    if ! pick_yesno "Nothing selected. Skip step 4 (CachyOS) entirely?" "Y"; then
      return 1
    fi
    STEP4_SEL=""
    STEP4_SKIPPED=1
    STEP4=1
    save_state
    info "Step 4 skipped."
    return 0
  fi

  if [[ "${SKIP_MENUS}" != "1" ]]; then
    if ! confirm_plan "Step 4 — CachyOS pieces" \
        "selected  ${MULTI_SEL}"; then
      return 1
    fi
  fi

  STEP4_SEL="$MULTI_SEL"
  STEP4_SKIPPED=0
  STEP4=0
  save_state
  checks_begin

  DO_REPOS=0 DO_HELPERS=0 DO_CHAOTIC=0 DO_KERNEL=0 DO_GAMING=0 DO_SETTINGS=0 DO_PATCH=0 DO_ILOVECANDY=0
  multi_has repos && DO_REPOS=1
  multi_has helpers && DO_HELPERS=1
  multi_has chaotic && DO_CHAOTIC=1
  multi_has kernel && DO_KERNEL=1
  multi_has gaming && DO_GAMING=1
  multi_has settings && DO_SETTINGS=1
  multi_has patch && DO_PATCH=1
  if multi_has ilovecandy && multi_has repos; then
    DO_ILOVECANDY=1
  elif multi_has ilovecandy; then
    warn "ILoveCandy is on, but CachyOS repos are off — skipping ILoveCandy (needs cachyos pacman)."
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    info "DRY-RUN: would install CachyOS selection: ${MULTI_SEL}"
    must "dry-run step 4" true
    info "Step 4 dry-run complete — not marked done."
    return 0
  fi

  info "Selections locked — starting CachyOS install."
  info "arch-chroot /mnt — selected CachyOS pieces (downloads can take a while)."
  run_chroot_fn chroot_step4_main || {
    pause_err "Step 4 hit an error. Check ${LOG_FILE} and /mnt/root/.arch4/chroot_step4_main.sh"
    STEP4=0
    save_state
    return 1
  }

  multi_has repos && must "CachyOS repos in pacman.conf" file_has /mnt/etc/pacman.conf 'cachyos' || true
  multi_has helpers && must "package yay" chroot_has yay || true
  multi_has helpers && must "package paru" chroot_has paru || true
  multi_has chaotic && must "[chaotic-aur] repo" file_has /mnt/etc/pacman.conf '^\[chaotic-aur\]' || true
  multi_has kernel && must "package linux-cachyos" chroot_has linux-cachyos || true
  multi_has kernel && must_test "vmlinuz-linux-cachyos" -f /mnt/boot/vmlinuz-linux-cachyos || true
  multi_has kernel && must "boot entry cachyos" file_has /mnt/boot/loader/entries/arch.conf 'vmlinuz-linux-cachyos' || true
  multi_has gaming && must "cachyos-gaming-meta" chroot_has cachyos-gaming-meta || true
  multi_has settings && must "cachyos-settings" chroot_has cachyos-settings || true
  multi_has patch && must_test "pacman patched stamp" -f /mnt/root/.arch4/pacman-patched || true
  if [[ "${DO_ILOVECANDY}" == "1" ]]; then
    must "ILoveCandy in pacman.conf" file_has /mnt/etc/pacman.conf '^ILoveCandy' || true
  fi

  if ! checks_ok || ! verify_step4; then
    STEP4=0
    save_state
    dump_fail_summary
    pause_err "Step 4 checks failed — not marked done."
    return 1
  fi
  STEP4=1
  save_state
  info "Step 4 complete — all checks passed."
  return 0
}

# --- Nico's plan: steps 2+3+4, NVIDIA, one user/password -------------------

nicos_plan() {
  if ! verify_step1; then
    pause_err "Run step 1 first (disk must be mounted at /mnt)."
    return 1
  fi

  GPU="nvidia"
  DESKTOP="kde"
  DM="sddm"
  EDITOR_PKG="nano"
  local user pw1 pw2
  while true; do
    user="$(ask "Username")"
    user="$(printf '%s' "$user" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    if [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ && "$user" != "root" && ${#user} -le 32 ]]; then
      break
    fi
    warn "Lowercase Linux username (letter first, then letters/digits/_/-)."
  done
  while true; do
    pw1="$(ask_secret "Password (user + root)")"
    pw2="$(ask_secret "Repeat password")"
    [[ -n "$pw1" ]] || { warn "Password cannot be empty."; continue; }
    [[ "$pw1" == "$pw2" ]] || { warn "Passwords did not match."; continue; }
    break
  done

  if ! confirm_plan "Nico's plan — automatic 2+3+4" \
      "hostname  ${HOST_NAME}" \
      "locale    ${LOCALE}  ${TIMEZONE}  ${KEYMAP}" \
      "editor    nano" \
      "GPU       NVIDIA open-dkms" \
      "desktop   KDE Plasma + SDDM" \
      "user      ${user} (same password as root)" \
      "extras    all on" \
      "CachyOS   all pieces on" \
      "passwords stay in RAM only"; then
    unset pw1 pw2
    return 1
  fi

  STEP3_USER="$user"
  STEP3_PW="$pw1"
  STEP3_ROOT_PW="$pw1"
  SKIP_MENUS=1
  unset pw1 pw2

  if [[ "${STEP2}" != "1" ]]; then
    if ! step2; then
      SKIP_MENUS=0
      unset STEP3_PW STEP3_ROOT_PW
      return 1
    fi
  else
    info "Step 2 already done — skipping."
  fi
  if [[ "${STEP3}" != "1" ]]; then
    if ! step3; then
      SKIP_MENUS=0
      unset STEP3_PW STEP3_ROOT_PW
      return 1
    fi
  else
    info "Step 3 already done — skipping."
  fi
  if [[ "${STEP4}" != "1" ]]; then
    if ! step4; then
      SKIP_MENUS=0
      unset STEP3_PW STEP3_ROOT_PW
      return 1
    fi
  else
    info "Step 4 already done — skipping."
  fi
  SKIP_MENUS=0
  unset STEP3_PW STEP3_ROOT_PW
  return 0
}

# --- main ------------------------------------------------------------------

main() {
  require_root
  require_iso
  require_uefi
  loadkeys "$KEYMAP" 2>/dev/null || warn "Could not loadkeys ${KEYMAP} (continuing)."
  require_net
  detect_ucode
  load_state
  detect_ucode

  local sha
  sha="$(compute_self_sha)"
  info "Arch4 v${ARCH4_VERSION}  guide ${GUIDE_REF}  sha256:${sha}"
  info "Safer: curl -fsSL URL -o /tmp/arch4.sh && sha256sum /tmp/arch4.sh && bash /tmp/arch4.sh"
  [[ "$DRY_RUN" == "1" ]] && warn "DRY-RUN mode — no wipe / pacstrap / chroot."
  log "---- Arch4 ${ARCH4_VERSION} sha256=${sha} $(date -Is) ----"

  if [[ -n "$PART_ROOT" && -b "$PART_ROOT" ]]; then
    if ! is_mounted_root; then
      mkdir -p /mnt /mnt/boot
      mount "$PART_ROOT" /mnt 2>/dev/null || true
      [[ -n "$PART_EFI" ]] && mount "$PART_EFI" /mnt/boot 2>/dev/null || true
    fi
  fi
  refresh_status
  maybe_resume_banner

  while true; do
    refresh_status
    if ! pick "Select a step" \
        "Arrow keys or 1–5 / q. [done] only if every check passed. Secure Boot unsupported." \
        "1  Disk & partitions     $(tag_done "$STEP1" 0)" \
        "2  Base system           $(tag_done "$STEP2" 0)" \
        "3  Drivers & user        $(tag_done "$STEP3" 0)" \
        "4  Minmaxed              $(tag_done "$STEP4" "$STEP4_SKIPPED")" \
        "5  Nico's plan           (2+3+4 · NVIDIA)" \
        "q  Exit"; then
      exit_flow
    fi
    case "$PICK_IDX" in
      0) if step1; then after_step; fi ;;
      1) if step2; then after_step; fi ;;
      2) if step3; then after_step; fi ;;
      3) if step4; then after_step; fi ;;
      4) if nicos_plan; then after_step; fi ;;
      5) exit_flow ;;
    esac
  done
}

main "$@"
exit 0
}
