#!/bin/sh
# EarnApp maintenance: actual service identity, logs and recovery records retained.
# Version 2026.10.18.3. Auxiliary filenames are documented by the names command.
set -u
SDK_BIN=${SDK_BIN:-}
OLD_SVC=earnapp
OLD_COMMON=
BACKUP_ROOT=${BACKUP_ROOT:-/var/backups}
BACKUP_DIR=${BACKUP_DIR:-}
CMD=${1:-}
APPLY=0
if [ "$#" -gt 2 ]; then printf '%s\n' 'FAIL: too many arguments' >&2; exit 1; fi
if [ "$#" = 2 ]; then
  [ "$2" = --apply ] || { printf '%s\n' 'FAIL: second argument must be --apply' >&2; exit 1; }
  APPLY=1
fi


fail(){ printf 'FAIL: %s\n' "$*" >&2; return 1; }

exists(){ [ -e "$1" ] || [ -L "$1" ]; }

valid_name(){
  case "$1" in ''|.|..|-*|*[!A-Za-z0-9_.-]*) fail "invalid service/runlevel name: $1";; *) return 0;; esac
}

valid_path(){
  case "$1" in
    /|*'/../'*|*'/./'*|*/..|*/.|*'//'*) fail "non-canonical path: $1";;
    /*) case "$1" in *[!A-Za-z0-9_./+,@%:=~-]*) fail "path contains unsupported shell characters: $1";; *) return 0;; esac;;
    *) fail "absolute path required: $1";;
  esac
}

need(){ command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"; }

require_root(){ [ "$(id -u)" = 0 ] || fail 'run --apply as root'; }

service_state(){
  rc-service "$1" status >/dev/null 2>&1
  printf '%s\n' "$?"
}

hash_file(){
  HF_RESULT=$(sha256sum "$1" 2>/dev/null) || return 1
  printf '%s\n' "${HF_RESULT%% *}"
}

sdk_hash(){ hash_file "$SDK_BIN"; }

discover_sdk(){
  if [ -n "$SDK_BIN" ]; then
    [ -f "$SDK_BIN" ] && [ -x "$SDK_BIN" ] || { fail "SDK not executable: $SDK_BIN"; return 1; }
    valid_path "$SDK_BIN"
    return $?
  fi
  for DS_C in /usr/bin/earnapp /usr/local/bin/earnapp /opt/earnapp/earnapp; do
    if [ -f "$DS_C" ] && [ -x "$DS_C" ]; then SDK_BIN=$DS_C; return 0; fi
  done
  fail 'SDK not found; set SDK_BIN to its absolute path'
}

openrc_value() (
  for OV_HELPER in /lib/rc/bin/service_get_value /usr/lib/rc/bin/service_get_value; do
    if [ -x "$OV_HELPER" ]; then RC_SVCNAME=$1 "$OV_HELPER" "$2"; exit $?; fi
  done
  OV_HELPER=$(command -v service_get_value) || exit 1
  RC_SVCNAME=$1 "$OV_HELPER" "$2"
)

service_is_supervised(){
  for SI_FILE in "/etc/init.d/$1" "/etc/conf.d/$1" "$OLD_COMMON" "${NEW_COMMON:-}"; do
    [ -f "$SI_FILE" ] || continue
    if grep -Eq "^[[:space:]]*supervisor=['\"]?supervise-daemon['\"]?[[:space:]]*(#.*)?$" "$SI_FILE"; then return 0; fi
  done
  SI_CHILD=$(openrc_value "$1" child_pid 2>/dev/null) || return 1
  [ -n "$SI_CHILD" ]
}

process_stamp() (
  PS_PID=$1
  case "$PS_PID" in ''|*[!0-9]*) exit 1;; esac
  [ "$PS_PID" -gt 1 ] || exit 1
  PS_STAT=$(cat "/proc/$PS_PID/stat" 2>/dev/null) || exit 1
  PS_FIELDS=${PS_STAT##*) }
  [ "$PS_FIELDS" != "$PS_STAT" ] || exit 1
  set -f
  set -- $PS_FIELDS
  [ "$#" -ge 20 ] || exit 1
  case "$1" in Z|X|x) exit 1;; esac
  PS_PARENT=$2
  shift 19
  case "$PS_PARENT:$1" in *[!0-9:]*) exit 1;; esac
  printf '%s:%s\n' "$PS_PARENT" "$1"
)

mapped_program_matches() (
  MP_PROC=$1; MP_TARGET=$2
  MP_ID=$(stat -Lc '%d %i' "$MP_TARGET" 2>/dev/null) || exit 1
  set -- $MP_ID
  [ "$#" = 2 ] || exit 1
  MP_DEV=$1; MP_INO=$2
  case "$MP_DEV:$MP_INO" in *[!0-9:]*) exit 1;; esac
  MP_MAJOR=$(( ((MP_DEV >> 8) & 4095) | ((MP_DEV >> 32) & 4294963200) ))
  MP_MINOR=$(( (MP_DEV & 255) | ((MP_DEV >> 12) & 4294967040) ))
  MP_DEVICE=$(printf '%x:%x' "$MP_MAJOR" "$MP_MINOR") || exit 1
  awk -v device="$MP_DEVICE" -v inode="$MP_INO" -v target="$MP_TARGET" '
    function hexnorm(s) {s=tolower(s); sub(/^0+/,"",s); return s=="" ? "0" : s}
    BEGIN {split(device,want,":")}
    $2 ~ /x/ && ("i:" $5)==("i:" inode) && $6==target && NF==6 {
      split($4,got,":")
      if (hexnorm(got[1])==hexnorm(want[1]) && hexnorm(got[2])==hexnorm(want[2])) found=1
    }
    END {exit !found}' "$MP_PROC/maps" 2>/dev/null
)

service_worker_pids() (
  SW_SERVICE=$1; SW_TARGET=$2
  SW_HASH=$(hash_file "$SW_TARGET") || exit 1
  SW_CANON=$(readlink -f "$SW_TARGET") || exit 1
  if service_is_supervised "$SW_SERVICE"; then
    SW_CHILD=$(openrc_value "$SW_SERVICE" child_pid 2>/dev/null) &&
    SW_PIDFILE=$(openrc_value "$SW_SERVICE" pidfile 2>/dev/null) || {
      fail "cannot read OpenRC child_pid/pidfile for $SW_SERVICE"; exit 1;
    }
    valid_path "$SW_PIDFILE" || exit 1
    SW_PARENT=$(cat "$SW_PIDFILE" 2>/dev/null) || {
      fail "cannot read supervisor PID for $SW_SERVICE: $SW_PIDFILE"; exit 1;
    }
    case "$SW_CHILD:$SW_PARENT" in *[!0-9:]*|:*|*:) fail "invalid OpenRC process IDs for $SW_SERVICE"; exit 1;; esac
    SW_CHILD_STAMP=$(process_stamp "$SW_CHILD") && SW_PARENT_STAMP=$(process_stamp "$SW_PARENT") || {
      fail "OpenRC worker/supervisor is not live for $SW_SERVICE"; exit 1;
    }
    [ "${SW_CHILD_STAMP%%:*}" = "$SW_PARENT" ] || {
      fail "OpenRC child $SW_CHILD does not belong to supervisor $SW_PARENT"; exit 1;
    }
    SW_SUPERVISOR=$(command -v supervise-daemon) && SW_SUPERVISOR=$(readlink -f "$SW_SUPERVISOR") || {
      fail 'cannot locate supervise-daemon'; exit 1;
    }
    SW_PARENT_EXE=$(readlink "/proc/$SW_PARENT/exe" 2>/dev/null) || exit 1
    [ "${SW_PARENT_EXE% (deleted)}" = "$SW_SUPERVISOR" ] || {
      fail "recorded supervisor $SW_PARENT is not supervise-daemon"; exit 1;
    }
    SW_PROC="/proc/$SW_CHILD"
    SW_EXE=$(readlink "$SW_PROC/exe" 2>/dev/null) || {
      fail "cannot read executable of $SW_SERVICE worker $SW_CHILD"; exit 1;
    }
    SW_MATCH=0
    if [ "${SW_EXE% (deleted)}" = "$SW_CANON" ]; then
      SW_ACTUAL=$(hash_file "$SW_PROC/exe") || exit 1
      [ "$SW_ACTUAL" = "$SW_HASH" ] && SW_MATCH=1
    fi
    if [ "$SW_MATCH" = 0 ] && mapped_program_matches "$SW_PROC" "$SW_CANON"; then SW_MATCH=1; fi
    if [ "$SW_MATCH" != 1 ]; then
      fail "$SW_SERVICE child $SW_CHILD does not execute or map $SW_CANON (kernel executable: $SW_EXE)"
      awk '$2 ~ /x/ && NF>=6 {print "  executable mapping: " $4 " " $5 " " $6; if (++n==12) exit}' "$SW_PROC/maps" >&2 2>/dev/null || true
      exit 1
    fi
    [ "$(openrc_value "$SW_SERVICE" child_pid 2>/dev/null)" = "$SW_CHILD" ] &&
    [ "$(openrc_value "$SW_SERVICE" pidfile 2>/dev/null)" = "$SW_PIDFILE" ] &&
    [ "$(cat "$SW_PIDFILE" 2>/dev/null)" = "$SW_PARENT" ] &&
    [ "$(process_stamp "$SW_CHILD")" = "$SW_CHILD_STAMP" ] &&
    [ "$(process_stamp "$SW_PARENT")" = "$SW_PARENT_STAMP" ] || {
      fail "service process changed during verification: $SW_SERVICE"; exit 1;
    }
    [ "$(hash_file "$SW_TARGET")" = "$SW_HASH" ] || {
      fail "program changed during verification: $SW_TARGET"; exit 1;
    }
    printf '%s\n' "$SW_CHILD"
    exit 0
  fi
  for SW_PROC in /proc/[0-9]*; do
    SW_EXE=$(readlink "$SW_PROC/exe" 2>/dev/null) || continue
    [ "${SW_EXE% (deleted)}" = "$SW_CANON" ] || continue
    SW_ACTUAL=$(hash_file "$SW_PROC/exe") || continue
    [ "$SW_ACTUAL" = "$SW_HASH" ] && printf '%s\n' "${SW_PROC##*/}"
  done
  exit 0
)

runlevels_for(){
  for RF_LEVEL in /etc/runlevels/*; do
    [ -d "$RF_LEVEL" ] || continue
    if exists "$RF_LEVEL/$1"; then printf '%s\n' "${RF_LEVEL##*/}"; fi
  done
  return 0
}

# Source module: maintenance-bootstrap-module.sh
# EARNAPP-MAINTENANCE-2026.10.18.2 bootstrap for the original EarnApp SDK.
# Source this module; the caller owns U_D and installs Alpine dependencies.
# Return 20 means the SDK remains installed and needs browser registration.
# Vendor installation has side effects outside this module's rollback control.
suite_bootstrap(){
  SDK_BIN=${SDK_BIN:-/usr/bin/earnapp}
  if [ -f "$SDK_BIN" ] && [ -x "$SDK_BIN" ]; then return 0; fi
  (
    sb_fail(){ printf '%s\n' "$*" >&2; return 1; }
    [ "$(id -u)" = 0 ] || { sb_fail BOOTSTRAP_ROOT_REQUIRED; exit 1; }
    [ -f /etc/alpine-release ] || { sb_fail BOOTSTRAP_ALPINE_REQUIRED; exit 1; }
    [ "$SDK_BIN" = /usr/bin/earnapp ] || { sb_fail BOOTSTRAP_STANDARD_SDK_PATH_REQUIRED; exit 1; }
    [ ! -e "$SDK_BIN" ] && [ ! -L "$SDK_BIN" ] || { sb_fail BOOTSTRAP_SDK_PATH_OCCUPIED; exit 1; }
    case "${U_D:-}" in /*) :;; *) sb_fail BOOTSTRAP_TEMP_DIRECTORY_REQUIRED; exit 1;; esac
    [ -d "$U_D" ] && [ ! -L "$U_D" ] || { sb_fail BOOTSTRAP_TEMP_DIRECTORY_REQUIRED; exit 1; }
    for SB_TOOL in bash curl sha256sum timeout mktemp install stat cmp readlink; do
      command -v "$SB_TOOL" >/dev/null 2>&1 || { sb_fail "BOOTSTRAP_DEPENDENCY_MISSING $SB_TOOL"; exit 1; }
    done
    umask 077
    SB_DIR=$(mktemp -d "$U_D/bootstrap-XXXXXXXX") || exit 1
    mkdir "$SB_DIR/bin" "$SB_DIR/identity" || exit 1
    cat > "$SB_DIR/fetch" <<'BOOTSTRAP_FETCH'
#!/bin/sh
# EarnApp maintenance download helper; errors never echo URLs or credentials.
fetch_bad_argument(){ printf '%s\n' "$*" >&2; exit 64; }
[ "$#" -eq 2 ] || fetch_bad_argument "FETCH_ARGUMENT_COUNT expected=2 received=$#"
url=$1; file=$2
[ -n "$url" ] || fetch_bad_argument FETCH_URL_REQUIRED
case "$url" in https://?*) :;; *) fetch_bad_argument FETCH_URL_HTTPS_REQUIRED;; esac
case "$url" in *[[:space:][:cntrl:]]*) fetch_bad_argument FETCH_URL_INVALID_CHARACTERS;; esac
authority=${url#https://}; authority=${authority%%[/?#]*}
[ -n "$authority" ] || fetch_bad_argument FETCH_URL_HOST_REQUIRED
[ -n "$file" ] || fetch_bad_argument FETCH_OUTPUT_REQUIRED
case "$file" in
  /|*/|*'/../'*|*'/./'*|*/..|*/.|*'//'*) fetch_bad_argument FETCH_OUTPUT_INVALID_PATH;;
  /*) case "$file" in *[!A-Za-z0-9_./+,@%:=~-]*) fetch_bad_argument FETCH_OUTPUT_INVALID_PATH;; esac;;
  *) fetch_bad_argument FETCH_OUTPUT_ABSOLUTE_PATH_REQUIRED;;
esac
parent=${file%/*}; [ -n "$parent" ] || parent=/
[ -d "$parent" ] && [ -w "$parent" ] && [ -x "$parent" ] || fetch_bad_argument FETCH_OUTPUT_PARENT_UNAVAILABLE
if [ -e "$file" ] || [ -L "$file" ]; then
  [ -f "$file" ] && [ ! -L "$file" ] || fetch_bad_argument FETCH_OUTPUT_UNSAFE
fi
command -v curl >/dev/null 2>&1 || { printf '%s\n' FETCH_CURL_MISSING >&2; exit 69; }
umask 077
attempts=0
for mode in auto ipv6 tls12; do
  case "$mode" in auto) set --;; ipv6) set -- -6;; tls12) set -- -4 --http1.1 --tlsv1.2 --tls-max 1.2;; esac
  attempts=$((attempts+1)); result=0; reason=empty_response
  if curl -q "$@" --silent -fL --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 30 --url "$url" --output "$file" 2>/dev/null; then
    [ ! -s "$file" ] || exit 0
  else
    result=$?
    case "$result" in
      5|6) reason=dns;; 7) reason=connect;; 22) reason=http_error;; 23) reason=output_write;;
      28) reason=timeout;; 35) reason=tls_handshake;; 60) reason=certificate_verification;;
      77) reason=ca_certificate;; *) reason=transport;;
    esac
  fi
  printf 'FETCH_ATTEMPT_FAILED mode=%s curl_rc=%s reason=%s\n' "$mode" "$result" "$reason" >&2
  rm -f -- "$file" 2>/dev/null || { printf '%s\n' FETCH_OUTPUT_RESET_FAILED >&2; exit 1; }
  case "$result" in 60|77) break;; esac
done
printf 'FETCH_DOWNLOAD_FAILED attempts=%s\n' "$attempts" >&2
exit 1
BOOTSTRAP_FETCH
    chmod 755 "$SB_DIR/fetch" || exit 1
    "$SB_DIR/fetch" https://cdn.earnapp.com/static/earnapp-install-1.665.73.sh "$SB_DIR/vendor.sh" || {
      sb_fail BOOTSTRAP_DOWNLOAD_FAILED; exit 1;
    }
    SB_HASH=$(sha256sum "$SB_DIR/vendor.sh") || exit 1
    [ "${SB_HASH%% *}" = c2bfb8f3fc8e0535ad7590c971eb223870ac4a09e6163a70be9a3e24e394c26a ] || {
      sb_fail BOOTSTRAP_HASH_MISMATCH; exit 1;
    }
    bash -n "$SB_DIR/vendor.sh" || { sb_fail BOOTSTRAP_SYNTAX_INVALID; exit 1; }

    # Existing IDs are validated and read, never normalized or chmodded.
    sb_id_read(){
      SB_ID=$(cat "$1") || return 1
      printf '%s\n' "$SB_ID" | grep -Eq '^[0-9a-f]{32}$' || return 1
      [ "$(printf '%s\n' "$SB_ID" | wc -l)" = 1 ] || return 1
    }
    if [ -e /etc/machine-id ] || [ -L /etc/machine-id ]; then
      sb_id_read /etc/machine-id || { sb_fail BOOTSTRAP_MACHINE_ID_INVALID; exit 1; }
    else
      if [ -s /var/lib/dbus/machine-id ]; then
        sb_id_read /var/lib/dbus/machine-id || { sb_fail BOOTSTRAP_DBUS_ID_INVALID; exit 1; }
      else
        SB_ID=$(tr -d '-' < /proc/sys/kernel/random/uuid) || exit 1
        printf '%s\n' "$SB_ID" | grep -Eq '^[0-9a-f]{32}$' || exit 1
      fi
      printf '%s\n' "$SB_ID" > "$SB_DIR/new-machine-id" || exit 1
      install -m 444 "$SB_DIR/new-machine-id" /etc/machine-id || exit 1
    fi
    SB_MACHINE=$(cat /etc/machine-id) || exit 1
    if [ -e /var/lib/dbus/machine-id ] || [ -L /var/lib/dbus/machine-id ]; then
      sb_id_read /var/lib/dbus/machine-id && [ "$SB_ID" = "$SB_MACHINE" ] || {
        sb_fail BOOTSTRAP_DBUS_ID_CONFLICT; exit 1;
      }
    else
      mkdir -p /var/lib/dbus && ln -s /etc/machine-id /var/lib/dbus/machine-id || exit 1
    fi
    sb_save_identity(){
      if [ -e "$1" ] || [ -L "$1" ]; then
        [ -f "$1" ] || return 1
        cp -pL "$1" "$SB_DIR/identity/$2.bytes" || return 1
        stat -c '%a:%u:%g' "$1" > "$SB_DIR/identity/$2.meta" || return 1
        stat -Lc '%a:%u:%g' "$1" > "$SB_DIR/identity/$2.target-meta" || return 1
        if [ -L "$1" ]; then readlink "$1" > "$SB_DIR/identity/$2.link" || return 1; fi
      fi
    }
    sb_check_identity(){
      [ -f "$SB_DIR/identity/$2.bytes" ] || return 0
      [ -f "$1" ] && cmp -s "$SB_DIR/identity/$2.bytes" "$1" || return 1
      [ "$(stat -c '%a:%u:%g' "$1")" = "$(cat "$SB_DIR/identity/$2.meta")" ] || return 1
      [ "$(stat -Lc '%a:%u:%g' "$1")" = "$(cat "$SB_DIR/identity/$2.target-meta")" ] || return 1
      if [ -f "$SB_DIR/identity/$2.link" ]; then
        [ -L "$1" ] && [ "$(readlink "$1")" = "$(cat "$SB_DIR/identity/$2.link")" ] || return 1
      else [ ! -L "$1" ] || return 1; fi
    }
    sb_save_identity /etc/machine-id machine && sb_save_identity /var/lib/dbus/machine-id dbus &&
    sb_save_identity /etc/earnapp/uuid uuid || { sb_fail BOOTSTRAP_IDENTITY_SNAPSHOT_FAILED; exit 1; }

    cat > "$SB_DIR/bin/lsb_release" <<'BOOTSTRAP_LSB'
#!/bin/sh
case "$1" in -rs) cat /etc/alpine-release;; -ds) printf 'Alpine Linux %s\n' "$(cat /etc/alpine-release)";; *) printf 'Alpine\n';; esac
BOOTSTRAP_LSB
    printf '%s\n' '#!/bin/sh' 'printf "Alpine Linux\n"' > "$SB_DIR/bin/hostnamectl" || exit 1
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$SB_DIR/bin/systemctl" || exit 1
    cat > "$SB_DIR/bin/wget" <<'BOOTSTRAP_WGET'
#!/bin/sh
if [ "$#" = 3 ] && [ "$2" = -O ]; then exec "$EARNAPP_FETCH" "$1" "$3"; fi
exec /usr/bin/wget -T 30 "$@"
BOOTSTRAP_WGET
    chmod 755 "$SB_DIR/bin/lsb_release" "$SB_DIR/bin/hostnamectl" "$SB_DIR/bin/systemctl" "$SB_DIR/bin/wget" || exit 1
    SB_VENDOR_RC=0
    printf 'yes\n' | env -u BASE_URL -u PRODUCT -u FORCE_SSL_BUILD -u FORCE_NO_SSL_BUILD \
      -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS EARNAPP_FETCH="$SB_DIR/fetch" PATH="$SB_DIR/bin:$PATH" \
      timeout -k 5 300 bash --noprofile --norc "$SB_DIR/vendor.sh" || SB_VENDOR_RC=$?
    if ! sb_check_identity /etc/machine-id machine || ! sb_check_identity /var/lib/dbus/machine-id dbus ||
       ! sb_check_identity /etc/earnapp/uuid uuid; then
      sb_fail "BOOTSTRAP_IDENTITY_CHANGED identity_snapshot=$SB_DIR/identity vendor_side_effects_not_rolled_back"
      exit 1
    fi
    [ "$SB_VENDOR_RC" = 0 ] || { sb_fail "BOOTSTRAP_VENDOR_FAILED rc=$SB_VENDOR_RC vendor_side_effects_not_rolled_back"; exit 1; }
    [ -x "$SDK_BIN" ] || { sb_fail BOOTSTRAP_SDK_MISSING; exit 1; }
    SB_DEVICE=$(timeout -k 2 15 "$SDK_BIN" showid) || { sb_fail BOOTSTRAP_SHOWID_FAILED; exit 1; }
    printf '%s\n' "$SB_DEVICE" | grep -Eq '^sdk-node-[0-9a-f]{32}$' &&
    [ "$(printf '%s\n' "$SB_DEVICE" | wc -l)" = 1 ] || { sb_fail BOOTSTRAP_DEVICE_ID_INVALID; exit 1; }
    printf 'BOOTSTRAP_INSTALLED\nDEVICE_ID\n%s\nLINK_URL\nhttps://earnapp.com/r/%s\n' "$SB_DEVICE" "$SB_DEVICE"
    if [ ! -s /etc/earnapp/registered ]; then
      printf '%s\n' 'NEEDS_REGISTRATION' 'Open LINK_URL in your browser, link this device, then rerun setup. Installed SDK and identity are retained.'
      exit 20
    fi
    exit 0
  )
}

# Source module: node-updater-guard.sh
# NODE-SUITE-2026.10.18.1 readonly compatibility for inactive vendor updater files.
# No service hooks, signals or file mutations are permitted in this module.
suite_updater_stopped() (
  # Alpine's established OpenRC state tree; do not execute an init status hook.
  [ "${RC_SVCDIR:-/run/openrc}" = /run/openrc ] && [ -d /run/openrc ] && [ -r /run/openrc ] && [ -x /run/openrc ] || exit 1
  NUS_HELPER=
  for NUS_FILE in /lib/rc/bin/service_stopped /usr/lib/rc/bin/service_stopped; do
    [ ! -x "$NUS_FILE" ] || { NUS_HELPER=$NUS_FILE; break; }
  done
  [ -n "$NUS_HELPER" ] || NUS_HELPER=$(command -v service_stopped) || exit 1
  for NUS_SERVICE in earnapp_upgrader earnapp-upgrader; do
    RC_SVCNAME=$NUS_SERVICE "$NUS_HELPER" "$NUS_SERVICE" 6>&- 7>&- 8>&- 9>&- >/dev/null 2>&1 || exit 1
    # STOPPED can coexist with additional librc state flags; reject those too.
    for NUS_FLAG in started starting stopping inactive failed hotplugged coldplugged wasinactive scheduled; do
      NUS_DIR="/run/openrc/$NUS_FLAG"
      if exists "$NUS_DIR"; then [ -d "$NUS_DIR" ] && [ -r "$NUS_DIR" ] && [ -x "$NUS_DIR" ] || exit 1; fi
      exists "$NUS_DIR/$NUS_SERVICE" && exit 1
    done
    for NUS_FILE in /run/openrc/scheduled/*/"$NUS_SERVICE"; do exists "$NUS_FILE" && exit 1; done
  done
  exit 0
)
suite_updater_meta_value() (
  NUM_HELPER=
  for NUM_FILE in /lib/rc/bin/service_get_value /usr/lib/rc/bin/service_get_value; do
    [ ! -x "$NUM_FILE" ] || { NUM_HELPER=$NUM_FILE; break; }
  done
  [ -n "$NUM_HELPER" ] || NUM_HELPER=$(command -v service_get_value) || exit 1
  NUM_RC=0
  NUM_VALUE=$(RC_SVCNAME=$1 "$NUM_HELPER" "$2" 6>&- 7>&- 8>&- 9>&- 2>/dev/null) || NUM_RC=$?
  case "$NUM_RC" in 0) printf '%s\n' "$NUM_VALUE";; 1) [ -z "$NUM_VALUE" ] || exit 1;; *) exit 1;; esac
)
suite_updater_meta_snapshot() (
  for NUM_SERVICE in earnapp_upgrader earnapp-upgrader; do
    NUM_CHILD=$(suite_updater_meta_value "$NUM_SERVICE" child_pid) || exit 1
    NUM_PATH=$(suite_updater_meta_value "$NUM_SERVICE" pidfile) || exit 1
    case "$NUM_CHILD" in ''|0) :;;
      *[!0-9]*) exit 1;;
      *) [ "$NUM_CHILD" -gt 1 ] && [ ! -d "/proc/$NUM_CHILD" ] || exit 1;;
    esac
    NUM_PARENT=absent
    if [ -n "$NUM_PATH" ]; then
      valid_path "$NUM_PATH" || exit 1
      if exists "$NUM_PATH"; then
        [ -f "$NUM_PATH" ] && [ ! -L "$NUM_PATH" ] && [ -r "$NUM_PATH" ] || exit 1
        NUM_PARENT=$(cat "$NUM_PATH" 2>/dev/null) || exit 1
        case "$NUM_PARENT" in ''|*[!0-9]*) exit 1;; esac
        [ "$NUM_PARENT" -gt 1 ] && [ ! -d "/proc/$NUM_PARENT" ] || exit 1
      fi
    fi
    printf '%s|%s|%s|%s\n' "$NUM_SERVICE" "$NUM_CHILD" "$NUM_PATH" "$NUM_PARENT"
  done
)
suite_updater_entries() (
  for NUE_SERVICE in earnapp_upgrader earnapp-upgrader; do
    for NUE_FILE in /etc/runlevels/*/"$NUE_SERVICE" "/etc/systemd/system/$NUE_SERVICE.service" "/usr/lib/systemd/system/$NUE_SERVICE.service" "/lib/systemd/system/$NUE_SERVICE.service"; do
      exists "$NUE_FILE" && { fail "updater entry is still enabled/unsupported: $NUE_FILE"; exit 1; }
    done
    for NUE_FILE in "/etc/init.d/$NUE_SERVICE" "/etc/conf.d/$NUE_SERVICE"; do
      exists "$NUE_FILE" || continue
      [ -f "$NUE_FILE" ] && [ ! -L "$NUE_FILE" ] && [ -r "$NUE_FILE" ] && [ "$(stat -c %u "$NUE_FILE")" = 0 ] || exit 1
      NUE_MODE=$(stat -c %a "$NUE_FILE") || exit 1
      case "$NUE_MODE" in ''|*[!0-7]*) exit 1;; esac
      [ "$((0$NUE_MODE & 022))" = 0 ] || exit 1
      NUE_HASH=$(hash_file "$NUE_FILE") || exit 1
      printf '%s|%s|%s\n' "$NUE_FILE" "$NUE_MODE" "$NUE_HASH"
    done
  done
)
suite_updater_references() (
  for NUR_FILE in /etc/init.d/* /etc/conf.d/* /etc/crontabs/* /etc/crontab /etc/cron.d/* \
      /etc/cron.hourly/* /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/* \
      /etc/periodic/*/* /var/spool/cron/crontabs/* /etc/local.d/*.start; do
    exists "$NUR_FILE" || continue
    case "$NUR_FILE" in /etc/init.d/earnapp_upgrader|/etc/init.d/earnapp-upgrader|/etc/conf.d/earnapp_upgrader|/etc/conf.d/earnapp-upgrader) continue;; esac
    [ -f "$NUR_FILE" ] && [ -r "$NUR_FILE" ] || exit 1
    NUR_CANON=$(readlink -f "$NUR_FILE") || exit 1
    case "$NUR_CANON" in /etc/init.d/earnapp_upgrader|/etc/init.d/earnapp-upgrader|/etc/conf.d/earnapp_upgrader|/etc/conf.d/earnapp-upgrader)
      fail "another entry aliases a retained updater: $NUR_FILE"; exit 1;;
    esac
    NUR_RC=0
    awk '/^[[:space:]]*#/ {next}
      /(^|[^A-Za-z0-9_.-])earnapp[_-]upgrader([^A-Za-z0-9_.-]|$)/ {found=1}
      END{exit !found}' "$NUR_FILE" >/dev/null 2>&1 || NUR_RC=$?
    case "$NUR_RC" in 1) :;; 0) fail "another entry references the updater: $NUR_FILE"; exit 1;; *) exit 1;; esac
  done
)
suite_updater_run_argv() (
  NUA_PROC=$1; NUA_ARGS=$(tr '\000' '\n' <"$NUA_PROC/cmdline" 2>/dev/null) || exit 1
  NUA_FIRST=$(printf '%s\n' "$NUA_ARGS" | head -n 1); NUA_DIRECT=0
  if [ "$NUA_FIRST" = "$NUG_SDK" ] || [ "$NUA_FIRST" = "$NUG_CANON" ]; then NUA_DIRECT=1
  else
    valid_path "$NUA_FIRST" >/dev/null 2>&1 || exit 1
    NUA_EXE=$(readlink "$NUA_PROC/exe" 2>/dev/null) || exit 1
    [ "$(readlink -f "$NUA_FIRST")" = "${NUA_EXE% (deleted)}" ] || exit 1
  fi
  printf '%s\n' "$NUA_ARGS" | awk -v direct="$NUA_DIRECT" -v sdk="$NUG_SDK" -v canonical="$NUG_CANON" '
    NR==1{next}
    direct==1{if(NR==2 && $0=="run")ok=1;else bad=1;next}
    done{bad=1;next}
    need_run{if($0=="run"){ok=1;done=1}else bad=1;need_run=0;next}
    skip{skip=0;next}
    $0==sdk || $0==canonical{need_run=1;next}
    !ended && $0=="--"{ended=1;next}
    !ended && ($0=="--argv0" || $0=="--preload" || $0=="--library-path"){skip=1;next}
    {bad=1}
    END{exit !(ok && !bad && !skip && !need_run)}'
)
suite_updater_main_key() (
  # This only reads core metadata; it never asks an init script for its status.
  NUK_SERVICE=${UPDATER_MAIN_SVC:-earnapp}
  valid_name "$NUK_SERVICE" || exit 1
  NUK_PIDS=$(service_worker_pids "$NUK_SERVICE" "$NUG_SDK" 6>&- 7>&- 8>&- 9>&- 2>/dev/null) || exit 1
  set -- $NUK_PIDS; [ "$#" = 1 ] || exit 1
  NUK_PID=$1; NUK_STAMP=$(process_stamp "$NUK_PID") || exit 1
  NUK_PARENT=${NUK_STAMP%%:*}; NUK_PARENT_STAMP=$(process_stamp "$NUK_PARENT") || exit 1
  [ "$(suite_updater_meta_value "$NUK_SERVICE" child_pid)" = "$NUK_PID" ] || exit 1
  NUK_PATH=$(suite_updater_meta_value "$NUK_SERVICE" pidfile) || exit 1
  valid_path "$NUK_PATH" && [ -f "$NUK_PATH" ] && [ ! -L "$NUK_PATH" ] || exit 1
  [ "$(cat "$NUK_PATH")" = "$NUK_PARENT" ] || exit 1
  NUK_SUP=$(command -v supervise-daemon) && NUK_SUP=$(readlink -f "$NUK_SUP") || exit 1
  NUK_EXE=$(readlink "/proc/$NUK_PARENT/exe" 2>/dev/null) || exit 1
  [ "${NUK_EXE% (deleted)}" = "$NUK_SUP" ] || exit 1
  NUK_ARGS=$(tr '\000' '\n' <"/proc/$NUK_PARENT/cmdline" 2>/dev/null) || exit 1
  printf '%s\n' "$NUK_ARGS" | awk -v service="$NUK_SERVICE" 'NR==2{found=($0==service)} END{exit !found}' || exit 1
  for NUK_CHECK in "$NUK_PID" "$NUK_PARENT"; do
    awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)} END{exit !ok}' "/proc/$NUK_CHECK/status" || exit 1
  done
  [ "$(process_stamp "$NUK_PID")" = "$NUK_STAMP" ] && [ "$(process_stamp "$NUK_PARENT")" = "$NUK_PARENT_STAMP" ] || exit 1
  printf '%s:%s\n' "$NUK_PID" "$NUK_STAMP"
)
suite_updater_processes() (
  NUP_COUNT=0
  for NUP_PROC in /proc/[0-9]*; do
    [ -d "$NUP_PROC" ] || continue
    NUP_PID=${NUP_PROC##*/}
    NUP_ARGS=$(tr '\000' '\n' <"$NUP_PROC/cmdline" 2>/dev/null) || { [ ! -d "$NUP_PROC" ] && continue; exit 1; }
    if printf '%s\n' "$NUP_ARGS" | awk '/(^|[^A-Za-z0-9_.-])earnapp[_-]upgrader([^A-Za-z0-9_.-]|$)/{found=1} END{exit !found}'; then
      fail "a live process still references the updater: $NUP_PID"; exit 1
    fi
    NUP_EXE=$(readlink "$NUP_PROC/exe" 2>/dev/null) || NUP_EXE=
    NUP_MATCH=0
    if [ "${NUP_EXE% (deleted)}" = "$NUG_CANON" ]; then
      [ "$NUG_HASH" != absent ] && [ "$(hash_file "$NUP_PROC/exe")" = "$NUG_HASH" ] || exit 1
      NUP_MATCH=1
    elif [ "$NUG_HASH" != absent ] && mapped_program_matches "$NUP_PROC" "$NUG_CANON"; then NUP_MATCH=1
    elif [ -r "$NUP_PROC/maps" ]; then
      awk -v target="$NUG_CANON" '$6==target{found=1} END{exit found}' "$NUP_PROC/maps" 2>/dev/null || exit 1
    elif [ -d "$NUP_PROC" ]; then exit 1
    fi
    [ "$NUP_MATCH" = 1 ] || continue
    if printf '%s\n' "$NUP_ARGS" | awk '$0=="autoupgrade"{found=1} END{exit !found}'; then
      fail "SDK updater payload is still running: $NUP_PID"; exit 1
    fi
    NUP_STAMP=$(process_stamp "$NUP_PID") || exit 1
    awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)} END{exit !ok}' "$NUP_PROC/status" || exit 1
    if [ "$NUP_PID:$NUP_STAMP" != "$NUG_MAIN" ]; then
      suite_updater_run_argv "$NUP_PROC" || { fail "SDK payload is an updater or has unknown purpose: $NUP_PID"; exit 1; }
    fi
    [ "$(process_stamp "$NUP_PID")" = "$NUP_STAMP" ] || exit 1
    NUP_COUNT=$((NUP_COUNT+1)); [ "$NUP_COUNT" = 1 ] || { fail 'extra SDK payload prevents inactive-updater verification'; exit 1; }
  done
)
suite_updater_guard_check() (
  NUG_HAVE=0
  for NUG_SERVICE in earnapp_upgrader earnapp-upgrader; do
    for NUG_FILE in "/etc/init.d/$NUG_SERVICE" "/etc/conf.d/$NUG_SERVICE" /etc/runlevels/*/"$NUG_SERVICE" "/etc/systemd/system/$NUG_SERVICE.service" "/usr/lib/systemd/system/$NUG_SERVICE.service" "/lib/systemd/system/$NUG_SERVICE.service"; do
      exists "$NUG_FILE" && NUG_HAVE=1
    done
  done
  # With no retained entry, add no new constraints to established worker identity.
  [ "$NUG_HAVE" = 1 ] || exit 0
  NUG_SDK=$1; valid_path "$NUG_SDK" || exit 1
  NUG_CANON=$(readlink -f "$NUG_SDK") || exit 1
  valid_path "$NUG_CANON" || exit 1
  NUG_HASH=absent
  if exists "$NUG_SDK"; then
    [ -f "$NUG_SDK" ] && [ -x "$NUG_SDK" ] || exit 1
    NUG_HASH=$(hash_file "$NUG_SDK") || exit 1
  fi
  NUG_ENTRIES=$(suite_updater_entries) || { fail 'updater retained files are not safely readable/inactive'; exit 1; }
  suite_updater_references || exit 1
  suite_updater_stopped || { fail 'updater OpenRC state is active or unknown'; exit 1; }
  NUG_META=$(suite_updater_meta_snapshot) || { fail 'updater metadata is live or unknown'; exit 1; }
  NUG_MAIN=$(suite_updater_main_key 2>/dev/null) || NUG_MAIN=
  suite_updater_processes || { fail 'updater process inactivity could not be verified'; exit 1; }
  NUG_META_LAST=$(suite_updater_meta_snapshot) || exit 1
  [ "$NUG_META_LAST" = "$NUG_META" ] || { fail 'updater metadata changed during verification'; exit 1; }
  suite_updater_stopped || { fail 'updater OpenRC state changed during verification'; exit 1; }
  if [ -n "$NUG_MAIN" ]; then
    NUG_MAIN_LAST=$(suite_updater_main_key 2>/dev/null) || exit 1
    [ "$NUG_MAIN_LAST" = "$NUG_MAIN" ] || exit 1
  fi
  NUG_ENTRIES_LAST=$(suite_updater_entries) || exit 1
  [ "$NUG_ENTRIES_LAST" = "$NUG_ENTRIES" ] && suite_updater_references || exit 1
  if [ "$NUG_HASH" = absent ]; then ! exists "$NUG_SDK" || exit 1
  else [ "$(hash_file "$NUG_SDK")" = "$NUG_HASH" ] || exit 1; fi
)
suite_updater_guard(){
  UPDATERS_INACTIVE=0
  suite_updater_guard_check "${1:-${SDK_BIN:-/usr/bin/earnapp}}" || return 1
  UPDATERS_INACTIVE=1
}

# Source module: maintenance-helper-module.sh
# EARNAPP-MAINTENANCE-2026.10.18.2 EarnApp maintenance helpers; the original SDK and service are retained.
suite_stage_helpers() (
[ "$#" -ge 3 ] && [ "$#" -le 4 ] || return 1
NS_DIR=$1; NS_TARGET=$2; NS_SERVICE=$3
case "$NS_TARGET" in /|*'/../'*|*'/./'*|*/..|*/.|*'//'*) return 1;;
/*) case "$NS_TARGET" in *[!A-Za-z0-9_./+,@%:=~-]*) return 1;; esac;;
*) return 1;; esac
case "$NS_SERVICE" in ''|.|..|-*|*[!A-Za-z0-9_.-]*) return 1;; esac
[ "$NS_SERVICE" = earnapp ] || { printf '%s\n' 'EARNAPP_SERVICE_REQUIRED' >&2; return 1; }
if [ "$#" = 4 ]; then NS_HASH=$4; else NS_HASH=$(hash_file "$NS_TARGET") || return 1; fi
case "$NS_HASH" in ''|*[!0-9a-f]*) return 1;; esac
[ "${#NS_HASH}" = 64 ] || return 1
mkdir -p "$NS_DIR" || return 1
printf '%s\n' '#!/bin/sh' '# EARNAPP-MAINTENANCE-2026.10.18.2' "APP_BIN='$NS_TARGET'" "APP_SVC='$NS_SERVICE'" "APP_HASH=$NS_HASH" >"$NS_DIR/common" || return 1
cat >>"$NS_DIR/common" <<'EARNAPP_MAINTENANCE_COMMON_TEMPLATE' || return 1
S=/run/earnapp-maintenance
L=/run/earnapp-maintenance.worker.lockfile
LOG=/var/log/earnapp-maintenance.log
CONF=/etc/earnapp/maintenance.conf
GUARD_CMD=/usr/local/sbin/selnu
RECOVER_CMD=/usr/local/sbin/tavik
LIMIT_CMD=/usr/local/sbin/loren
mkdir -p "$S"
UDP_THRESHOLD=250; FD_THRESHOLD=512; RSS_THRESHOLD_KB=184320; ZERO_MAX_BAD=2; RESOURCE_MAX_BAD=3; MIN_UPTIME=300; RESTART_COOLDOWN=900
if [ -r "$CONF" ]; then
C=$(awk '/^(UDP_THRESHOLD|FD_THRESHOLD|RSS_THRESHOLD_KB|ZERO_MAX_BAD|RESOURCE_MAX_BAD|MIN_UPTIME|RESTART_COOLDOWN)=[1-9][0-9]*$/ {split($0,a,"="); if(a[2]<=2147483647)print}' "$CONF")
eval "$C"
fi
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }
lock() { if [ "${1:-}" = --locked ]; then [ "$(readlink /proc/self/fd/9)" = "$L" ] || return 1; else exec 9>"$L"; fi; flock -n 9; }
process_stamp() (
  PS_PID=$1
  case "$PS_PID" in ''|*[!0-9]*) exit 1;; esac
  [ "$PS_PID" -gt 1 ] || exit 1
  PS_STAT=$(cat "/proc/$PS_PID/stat" 2>/dev/null) || exit 1
  PS_FIELDS=${PS_STAT##*) }
  [ "$PS_FIELDS" != "$PS_STAT" ] || exit 1
  set -f
  set -- $PS_FIELDS
  [ "$#" -ge 20 ] || exit 1
  case "$1" in Z|X|x) exit 1;; esac
  PS_PARENT=$2
  shift 19
  case "$PS_PARENT:$1" in *[!0-9:]*) exit 1;; esac
  printf '%s:%s\n' "$PS_PARENT" "$1"
)
mapped_program_matches() (
  MP_PROC=$1; MP_TARGET=$2
  MP_ID=$(stat -Lc '%d %i' "$MP_TARGET" 2>/dev/null) || exit 1
  set -- $MP_ID
  [ "$#" = 2 ] || exit 1
  MP_DEV=$1; MP_INO=$2
  case "$MP_DEV:$MP_INO" in *[!0-9:]*) exit 1;; esac
  MP_MAJOR=$(( ((MP_DEV >> 8) & 4095) | ((MP_DEV >> 32) & 4294963200) ))
  MP_MINOR=$(( (MP_DEV & 255) | ((MP_DEV >> 12) & 4294967040) ))
  MP_DEVICE=$(printf '%x:%x' "$MP_MAJOR" "$MP_MINOR") || exit 1
  awk -v device="$MP_DEVICE" -v inode="$MP_INO" -v target="$MP_TARGET" '
    function hexnorm(s) {s=tolower(s); sub(/^0+/,"",s); return s=="" ? "0" : s}
    BEGIN {split(device,want,":")}
    $2 ~ /x/ && ("i:" $5)==("i:" inode) && $6==target && NF==6 {
      split($4,got,":")
      if (hexnorm(got[1])==hexnorm(want[1]) && hexnorm(got[2])==hexnorm(want[2])) found=1
    }
    END {exit !found}' "$MP_PROC/maps" 2>/dev/null
)
hash_file() {
HF_RESULT=$(sha256sum "$1" 2>/dev/null) || return 1
printf '%s\n' "${HF_RESULT%% *}"
}
openrc_value() (
for OV_HELPER in /lib/rc/bin/service_get_value /usr/lib/rc/bin/service_get_value; do
if [ -x "$OV_HELPER" ]; then RC_SVCNAME=$1 "$OV_HELPER" "$2" 6>&- 7>&- 8>&- 9>&-; exit $?; fi
done
OV_HELPER=$(command -v service_get_value) || exit 125
RC_SVCNAME=$1 "$OV_HELPER" "$2" 6>&- 7>&- 8>&- 9>&-
)
runtime_path() {
case "$1" in /|*'/../'*|*'/./'*|*/..|*/.|*'//'*) return 1;;
/*) case "$1" in *[!A-Za-z0-9_./+,@%:=~-]*) return 1;; *) return 0;; esac;;
*) return 1;; esac
}
runtime_service_state() {
rs_rc=0
timeout -k 2 10 rc-service "$APP_SVC" status 6>&- 7>&- 8>&- 9>&- >/dev/null 2>&1 || rs_rc=$?
printf '%s\n' "$rs_rc"
}
runtime_no_orphans() (
rn_skip=${1:-}
rn_supervisor=$(command -v supervise-daemon) && rn_supervisor=$(readlink -f "$rn_supervisor") || exit 1
for rn_proc in /proc/[0-9]*; do
[ -d "$rn_proc" ] || continue
[ "${rn_proc##*/}" != "$rn_skip" ] || continue
rn_exe=$(readlink "$rn_proc/exe" 2>/dev/null) || rn_exe=
[ "${rn_exe% (deleted)}" != "$WS_CANON" ] || exit 1
if [ "${rn_exe% (deleted)}" = "$rn_supervisor" ]; then
rn_argv=$(tr '\000' '\n' <"$rn_proc/cmdline" 2>/dev/null) || exit 1
[ -n "$rn_argv" ] || exit 1
if printf '%s\n' "$rn_argv" | awk -v service="$APP_SVC" 'NR==2{found=($0==service)} END{exit !found}'; then exit 1; fi
fi
if [ -r "$rn_proc/maps" ]; then
# A residual mapping of this path is unknown even if its inode was replaced.
awk -v target="$WS_CANON" '$6==target{found=1} END{exit found}' "$rn_proc/maps" 2>/dev/null || exit 1
elif [ -d "$rn_proc" ]; then
exit 1
fi
done
)
worker_snapshot() (
ws_unknown() { printf 'WORKER_IDENTITY_UNKNOWN %s\n' "$*" >&2; exit 1; }
ws_read_meta() {
WS_CHILD_RC=0; WS_CHILD=$(openrc_value "$APP_SVC" child_pid 2>/dev/null) || WS_CHILD_RC=$?
WS_PATH_RC=0; WS_PIDFILE=$(openrc_value "$APP_SVC" pidfile 2>/dev/null) || WS_PATH_RC=$?
case "$WS_CHILD_RC:$WS_PATH_RC" in 0:0|0:1|1:0|1:1) ;; *) return 1;; esac
[ "$WS_CHILD_RC" = 0 ] || [ -z "$WS_CHILD" ] || return 1
[ "$WS_PATH_RC" = 0 ] || [ -z "$WS_PIDFILE" ] || return 1
case "$WS_CHILD" in ''|0) ;; *[!0-9]*) return 1;; *) [ "$WS_CHILD" -gt 1 ] || return 1;; esac
WS_PARENT=; WS_FILE_STATE=absent
if [ -n "$WS_PIDFILE" ]; then
runtime_path "$WS_PIDFILE" || return 1
if [ -e "$WS_PIDFILE" ] || [ -L "$WS_PIDFILE" ]; then
WS_PARENT=$(cat "$WS_PIDFILE" 2>/dev/null) || return 1
case "$WS_PARENT" in ''|*[!0-9]*) return 1;; esac
[ "$WS_PARENT" -gt 1 ] || return 1
WS_FILE_STATE=present
fi
fi
WS_META="$WS_CHILD_RC:$WS_CHILD|$WS_PATH_RC:$WS_PIDFILE|$WS_FILE_STATE:$WS_PARENT"
}
[ "$(hash_file "$APP_BIN")" = "$APP_HASH" ] || ws_unknown program_hash
WS_CANON=$(readlink -f "$APP_BIN") || ws_unknown program_path
runtime_path "$WS_CANON" || ws_unknown program_path
WS_STATE=$(runtime_service_state) || ws_unknown service_status
case "$WS_STATE" in 0|3|32) ;; *) ws_unknown service_transition;; esac
ws_read_meta || ws_unknown service_metadata
WS_META_FIRST=$WS_META
WS_PARENT_FIRST=$WS_PARENT
WS_CHILD_FIRST=$WS_CHILD
WS_PARENT_STAMP=; WS_CHILD_STAMP=
WS_PARENT_LIVE=0; WS_CHILD_LIVE=0
if [ -n "$WS_PARENT" ] && [ -d "/proc/$WS_PARENT" ]; then
WS_PARENT_STAMP=$(process_stamp "$WS_PARENT") || ws_unknown supervisor_stat
WS_SUPERVISOR=$(command -v supervise-daemon) && WS_SUPERVISOR=$(readlink -f "$WS_SUPERVISOR") || ws_unknown supervisor_program
WS_PARENT_EXE=$(readlink "/proc/$WS_PARENT/exe" 2>/dev/null) || ws_unknown supervisor_exe
[ "${WS_PARENT_EXE% (deleted)}" = "$WS_SUPERVISOR" ] || ws_unknown foreign_supervisor
WS_PARENT_ARGV=$(tr '\000' '\n' <"/proc/$WS_PARENT/cmdline" 2>/dev/null) || ws_unknown supervisor_command
printf '%s\n' "$WS_PARENT_ARGV" | awk -v service="$APP_SVC" 'NR==2{found=($0==service)} END{exit !found}' || ws_unknown foreign_supervisor_service
awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)} END{exit !ok}' "/proc/$WS_PARENT/status" || ws_unknown supervisor_uid
WS_PARENT_LIVE=1
fi
if [ -n "$WS_CHILD" ] && [ "$WS_CHILD" != 0 ] && [ -d "/proc/$WS_CHILD" ]; then
WS_CHILD_STAMP=$(process_stamp "$WS_CHILD") || ws_unknown child_stat
[ "$WS_PARENT_LIVE" = 1 ] && [ "${WS_CHILD_STAMP%%:*}" = "$WS_PARENT" ] || ws_unknown foreign_child
[ "$WS_STATE" = 0 ] || ws_unknown worker_with_inactive_service
awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)} END{exit !ok}' "/proc/$WS_CHILD/status" || ws_unknown child_uid
WS_CHILD_EXE=$(readlink "/proc/$WS_CHILD/exe" 2>/dev/null) || ws_unknown child_exe
WS_MATCH=0
if [ "${WS_CHILD_EXE% (deleted)}" = "$WS_CANON" ]; then
[ "$(hash_file "/proc/$WS_CHILD/exe")" = "$APP_HASH" ] && WS_MATCH=1
fi
if [ "$WS_MATCH" = 0 ] && mapped_program_matches "/proc/$WS_CHILD" "$WS_CANON"; then WS_MATCH=1; fi
[ "$WS_MATCH" = 1 ] || ws_unknown child_program
WS_CHILD_LIVE=1
else
if [ "$WS_PARENT_LIVE" = 1 ]; then
[ "$WS_STATE" != 3 ] || ws_unknown supervisor_with_stopped_service
WS_CHILDREN=$(cat "/proc/$WS_PARENT/task/$WS_PARENT/children" 2>/dev/null) || ws_unknown supervisor_children
for WS_OTHER in $WS_CHILDREN; do
case "$WS_OTHER" in ''|*[!0-9]*) ws_unknown supervisor_children;; esac
[ ! -d "/proc/$WS_OTHER" ] || ws_unknown unrecorded_child
done
else
case "$WS_STATE" in 3|32) ;; *) ws_unknown missing_started_metadata;; esac
fi
runtime_no_orphans "$WS_PARENT" || ws_unknown residual_or_unreadable_process
fi
[ "$(runtime_service_state)" = "$WS_STATE" ] || ws_unknown service_changed
ws_read_meta || ws_unknown service_metadata_changed
[ "$WS_META" = "$WS_META_FIRST" ] || ws_unknown service_metadata_changed
if [ "$WS_PARENT_LIVE" = 1 ]; then
[ "$(process_stamp "$WS_PARENT_FIRST")" = "$WS_PARENT_STAMP" ] || ws_unknown supervisor_changed
elif [ -n "$WS_PARENT_FIRST" ]; then
[ ! -d "/proc/$WS_PARENT_FIRST" ] || ws_unknown supervisor_appeared
fi
if [ "$WS_CHILD_LIVE" = 1 ]; then
[ "$(process_stamp "$WS_CHILD_FIRST")" = "$WS_CHILD_STAMP" ] || ws_unknown child_changed
else
if [ -n "$WS_CHILD_FIRST" ] && [ "$WS_CHILD_FIRST" != 0 ]; then
[ ! -d "/proc/$WS_CHILD_FIRST" ] || ws_unknown child_appeared
fi
if [ "$WS_PARENT_LIVE" = 1 ]; then
WS_CHILDREN_AGAIN=$(cat "/proc/$WS_PARENT_FIRST/task/$WS_PARENT_FIRST/children" 2>/dev/null) || ws_unknown supervisor_children
[ "$WS_CHILDREN_AGAIN" = "$WS_CHILDREN" ] || ws_unknown child_appeared
fi
runtime_no_orphans "$WS_PARENT_FIRST" || ws_unknown residual_or_unreadable_process
fi
[ "$(hash_file "$APP_BIN")" = "$APP_HASH" ] || ws_unknown program_changed
if [ "$WS_CHILD_LIVE" = 1 ]; then printf '%s:%s\n' "$WS_CHILD_FIRST" "${WS_CHILD_STAMP#*:}"; fi
)
worker_pids() {
[ "${1:-run}" = run ] || return 1
wp_key=$(worker_snapshot) || return 1
[ -z "$wp_key" ] || printf '%s\n' "${wp_key%%:*}"
}
worker_pid() {
wp_key=$(worker_snapshot) || return 1
[ -n "$wp_key" ] || return 1
printf '%s\n' "${wp_key%%:*}"
}
start() {
start_stamp=$(process_stamp "$1") || return 1
printf '%s\n' "${start_stamp#*:}"
}
proc_age() { h=$(getconf CLK_TCK) || return 1; case "$h" in ''|*[!0-9]*|0) return 1;; esac; awk -v h="$h" '{sub(/^.*\) /,""); if($20!~/^[0-9]+$/)exit 1} NR==FNR{s=$20;next} {if($20<s)exit 1;printf "%.0f\n",int(($20-s)/h)}' "/proc/$1/stat" /proc/self/stat; }
stats() {
FD=$(ls "/proc/$1/fd") || return 1; FD=$(printf '%s\n' "$FD" | awk 'NF{n++}END{print n+0}')
RSS=$(awk '/^VmRSS:/{print $2;ok=1}END{if(!ok)exit 1}' "/proc/$1/status") || return 1
t=$(ss -tanp) || return 1; u=$(ss -uanp) || return 1
TCP=$(printf '%s\n' "$t" | awk -v p="$1" 'index($0,"pid="p","){n++}END{print n+0}')
ESTAB=$(printf '%s\n' "$t" | awk -v p="$1" 'index($0,"pid="p",")&&($1=="ESTAB"||$2=="ESTAB"){n++}END{print n+0}')
UDP=$(printf '%s\n' "$u" | awk -v p="$1" 'index($0,"pid="p","){n++}END{print n+0}')
}
now() { awk '{print int($1)}' /proc/uptime; }
cool() { n=$(now) || return 1; [ -s "$S/attempt" ] || return 0; x=$(cat "$S/attempt"); case "$x" in ''|*[!0-9]*) return 0;; esac; [ "$n" -lt "$x" ] || [ $((n-x)) -ge "$RESTART_COOLDOWN" ]; }
network_ok() { for family in -4 -6; do for host in https://example.com https://www.google.com; do curl "$family" -fsSI --connect-timeout 5 --max-time 8 "$host" >/dev/null 2>&1 && return 0; done; done; return 1; }
sdk_state() {
[ "$(hash_file "$APP_BIN")" = "$APP_HASH" ] || { printf 'unknown\n'; return 0; }
ss_text=$(timeout -k 2 15 "$APP_BIN" status 6>&- 7>&- 8>&- 9>&- 2>&1) || { printf 'unknown\n'; return 0; }
printf '%s\n' "$ss_text" | sed "s/$(printf '\033')\[[0-9;]*[[:alpha:]]//g;s/$(printf '\r')//g" | awk '
{sub(/^[[:space:]]+/, "");sub(/[[:space:]]+$/, "")}
$0~/^[^[:alnum:]]*Current status: enabled$/{n++;state="enabled";next}
$0~/^[^[:alnum:]]*Current status: disabled$/{n++;state="disabled";next}
END{if(n==1)print state;else print "unknown"}'
}
fault_matches() {
fm_trigger=$1; fm_reason=$2
fm_key=$(worker_snapshot) || return 1
[ -n "$fm_key" ] && [ "$fm_key" = "$fm_trigger" ] || return 1
fm_pid=${fm_key%%:*}
fm_age=$(proc_age "$fm_pid") || return 1
[ "$fm_age" -ge "$MIN_UPTIME" ] || return 1
stats "$fm_pid" || return 1
[ "$(worker_snapshot)" = "$fm_trigger" ] || return 1
case "$fm_reason" in
no_tcp) [ "$TCP" = 0 ];;
resource_high) [ "$UDP" -ge "$UDP_THRESHOLD" ] || [ "$FD" -ge "$FD_THRESHOLD" ] || [ "$RSS" -ge "$RSS_THRESHOLD_KB" ];;
*) return 1;;
esac
}
EARNAPP_MAINTENANCE_COMMON_TEMPLATE
cat >"$NS_DIR/watchdog" <<'EARNAPP_MAINTENANCE_WATCHDOG_TEMPLATE' || return 1
#!/bin/sh
# EARNAPP-MAINTENANCE-2026.10.18.2
set -u
. /usr/local/lib/mivora.sh
lock || exit 0
trap 'exit 130' INT
trap 'exit 143' TERM
SDK_STATE=$(sdk_state)
case "$SDK_STATE" in enabled) ;; disabled) log SDK_DISABLED; exit 0;; *) log SDK_STATE_UNKNOWN; exit 1;; esac
T=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
if [ -z "$T" ]; then
cool || { log RECOVERY_COOLDOWN; exit 0; }
MISSING_AGAIN=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
[ -z "$MISSING_AGAIN" ] || { log WORKER_CHANGED; exit 0; }
"$RECOVER_CMD" --locked --missing worker_missing
exit $?
fi
P=${T%%:*}; I=${T#*:}
A=$(proc_age "$P") || { log AGE_PROBE_FAILED; exit 1; }
[ "$A" -ge "$MIN_UPTIME" ] || exit 0
stats "$P" || { log STATS_FAILED; exit 1; }
[ "$(worker_snapshot)" = "$T" ] || { log WORKER_CHANGED; exit 0; }
R=; M=$RESOURCE_MAX_BAD
if [ "$UDP" -ge "$UDP_THRESHOLD" ] || [ "$FD" -ge "$FD_THRESHOLD" ] || [ "$RSS" -ge "$RSS_THRESHOLD_KB" ]; then R=resource_high
elif [ "$TCP" = 0 ]; then
fault_matches "$T" no_tcp || { log FAULT_CHANGED; exit 0; }
if network_ok; then
fault_matches "$T" no_tcp || { log FAULT_CHANGED; exit 0; }
R=no_tcp; M=$ZERO_MAX_BAD
else log NETWORK_BAD; exit 0; fi
fi
if [ -z "$R" ]; then
rm -f "$S/count"
[ "$(sdk_state)" = enabled ] && [ "$(worker_snapshot)" = "$T" ] || { log WORKER_OR_SDK_CHANGED; exit 0; }
"$LIMIT_CMD" --locked 20 || { log LIMIT_MAINTENANCE_FAILED; exit 2; }
exit 0
fi
K="$T:$R"; old=; count=0
if [ -s "$S/count" ]; then read -r old count <"$S/count" || count=0; fi
case "$count" in ''|*[!0-9]*) count=0;; esac
[ "$old" = "$K" ] || count=0
[ "$count" -ge "$M" ] || count=$((count+1))
echo "$K $count" >"$S/count"
log "BAD pid=$P reason=$R count=$count/$M udp=$UDP fd=$FD"
if [ "$count" -ge "$M" ] && cool; then
[ "$(sdk_state)" = enabled ] && fault_matches "$T" "$R" || { log WORKER_OR_FAULT_CHANGED; exit 0; }
"$RECOVER_CMD" --locked --trigger "$T" "$R"
fi
EARNAPP_MAINTENANCE_WATCHDOG_TEMPLATE
cat >"$NS_DIR/recover" <<'EARNAPP_MAINTENANCE_RECOVER_TEMPLATE' || return 1
#!/bin/sh
# EARNAPP-MAINTENANCE-2026.10.18.2
set -u
. /usr/local/lib/mivora.sh
lock "${1:-}" || { log LOCK_BUSY; exit 1; }
[ "${1:-}" != --locked ] || shift
TRIGGER=; REASON=${1:-manual}; EXPECT_MISSING=0
case "${1:-}" in
--trigger)
[ "$#" = 3 ] || { log BAD_TRIGGER; exit 1; }
TRIGGER=$2; REASON=$3
case "$TRIGGER" in *[!0-9:]*|:*|*:) log BAD_TRIGGER; exit 1;; esac
case "$TRIGGER" in *:*:*) log BAD_TRIGGER; exit 1;; *:*) ;; *) log BAD_TRIGGER; exit 1;; esac
case "$REASON" in no_tcp|resource_high) ;; *) log BAD_TRIGGER; exit 1;; esac;;
--missing) [ "$#" = 2 ] && [ "$2" = worker_missing ] || { log BAD_TRIGGER; exit 1; }; REASON=worker_missing; EXPECT_MISSING=1;;
*) [ "$#" -le 1 ] || { log BAD_ARGUMENTS; exit 1; };;
esac
SDK_STATE=$(sdk_state)
case "$SDK_STATE" in enabled) ;; disabled) log SDK_DISABLED; exit 1;; *) log SDK_STATE_UNKNOWN; exit 1;; esac
cool || { log RECOVERY_COOLDOWN; exit 1; }
ORIGINAL=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
if [ -n "$TRIGGER" ]; then
[ "$ORIGINAL" = "$TRIGGER" ] && fault_matches "$TRIGGER" "$REASON" || { log WORKER_OR_FAULT_CHANGED; exit 1; }
if [ "$REASON" = no_tcp ]; then
network_ok || { log NETWORK_BAD; exit 1; }
fault_matches "$TRIGGER" "$REASON" || { log WORKER_OR_FAULT_CHANGED; exit 1; }
fi
elif [ "$EXPECT_MISSING" = 1 ]; then
[ -z "$ORIGINAL" ] || { log WORKER_CHANGED; exit 1; }
fi
NEED_START=0
recover_exit() {
recover_rc=$?
trap - EXIT INT TERM HUP
if [ "$NEED_START" = 1 ]; then
fallback_workers=$(worker_snapshot) || fallback_workers=unknown
fallback_status=0
timeout -k 2 10 rc-service "$APP_SVC" status 6>&- 7>&- 8>&- 9>&- >/dev/null 2>&1 || fallback_status=$?
if [ -z "$fallback_workers" ] && [ "$fallback_status" = 3 ] && [ "$(sdk_state)" = enabled ]; then
timeout -k 5 30 rc-service "$APP_SVC" start 6>&- 7>&- 8>&- 9>&- || log FALLBACK_START_FAILED
else log FALLBACK_START_REFUSED; fi
[ "$recover_rc" != 0 ] || recover_rc=1
fi
exit "$recover_rc"
}
trap recover_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
[ "$(sdk_state)" = enabled ] && cool || { log SDK_CHANGED_OR_COOLDOWN; exit 1; }
if [ -n "$TRIGGER" ]; then
fault_matches "$TRIGGER" "$REASON" || { log WORKER_OR_FAULT_CHANGED; exit 1; }
else
LATEST=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
[ "$LATEST" = "$ORIGINAL" ] || { log WORKER_CHANGED; exit 1; }
fi
log "RECOVER reason=$REASON"
now >"$S/attempt" || exit 1
# Recheck after recording the attempt, immediately before the managed stop.
if [ -n "$TRIGGER" ]; then
fault_matches "$TRIGGER" "$REASON" || { log WORKER_OR_FAULT_CHANGED; exit 1; }
else
LATEST=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
[ "$LATEST" = "$ORIGINAL" ] || { log WORKER_CHANGED; exit 1; }
fi
stop_rc=0
[ "$(sdk_state)" = enabled ] || { log SDK_CHANGED_BEFORE_STOP; exit 1; }
if [ -n "$TRIGGER" ]; then
fault_matches "$TRIGGER" "$REASON" || { log WORKER_OR_FAULT_CHANGED_BEFORE_STOP; exit 1; }
else
FINAL_WORKER=$(worker_snapshot) || { log WORKER_OWNERSHIP_OR_COUNT_UNKNOWN; exit 1; }
[ "$FINAL_WORKER" = "$ORIGINAL" ] || { log WORKER_CHANGED_BEFORE_STOP; exit 1; }
fi
NEED_START=1
timeout -k 5 30 rc-service "$APP_SVC" stop 6>&- 7>&- 8>&- 9>&- || stop_rc=$?
STOP_WORKERS=$(worker_snapshot) || { log STOP_INCOMPLETE; exit 1; }
stop_status=0
timeout -k 2 10 rc-service "$APP_SVC" status 6>&- 7>&- 8>&- 9>&- >/dev/null 2>&1 || stop_status=$?
[ "$stop_status" = 3 ] || { log STOP_UNCONFIRMED; exit 1; }
[ -z "$STOP_WORKERS" ] || { log STOP_INCOMPLETE; exit 1; }
[ "$(sdk_state)" = enabled ] || { NEED_START=0; log SDK_CHANGED; exit 1; }
START_WORKERS=$(worker_snapshot) || { NEED_START=0; log START_REFUSED; exit 1; }
[ -z "$START_WORKERS" ] || { NEED_START=0; log START_REFUSED; exit 1; }
timeout -k 5 30 rc-service "$APP_SVC" start 6>&- 7>&- 8>&- 9>&- || { log START_FAILED; exit 1; }
NEED_START=0
recovery_sample() {
sample_sdk=$(sdk_state)
[ "$sample_sdk" = enabled ] || { failure_reason=SDK_NOT_ENABLED; return 1; }
timeout -k 2 10 rc-service "$APP_SVC" status 6>&- 7>&- 8>&- 9>&- >/dev/null 2>&1 || { failure_reason=SERVICE_NOT_RUNNING; return 1; }
P=$(worker_pid) || { failure_reason=WORKER_IDENTIFICATION_FAILED; return 1; }
I=$(start "$P") || { failure_reason=BIRTH_PROBE_FAILED; return 1; }
sample_key=$(worker_snapshot) || { failure_reason=WORKER_IDENTIFICATION_FAILED; return 1; }
[ "$sample_key" = "$P:$I" ] || { failure_reason=WORKER_CHANGED; return 1; }
stats "$P" || { failure_reason=STATS_FAILED; return 1; }
current_birth=$(start "$P") || { failure_reason=BIRTH_PROBE_FAILED; return 1; }
[ "$current_birth" = "$I" ] || { failure_reason=WORKER_CHANGED; return 1; }
}
n=0; stable=0; last_key=; health_key=; pending_ok=1; failure_reason=NO_SUSTAINED_TCP
while [ "$n" -lt 24 ]; do
if recovery_sample; then
key="$P:$I"
if [ -n "$health_key" ] && [ "$key" != "$health_key" ]; then pending_ok=0; failure_reason=WORKER_CHANGED; fi
health_key=$key
if [ "$ESTAB" -gt 0 ]; then
if [ "$key" = "$last_key" ]; then stable=$((stable+1)); else stable=1; last_key=$key; fi
if [ "$stable" -ge 7 ]; then
rm -f "$S/count"
"$LIMIT_CMD" --locked 20 || { log LIMIT_UNAVAILABLE; exit 2; }
recovery_sample && [ "$P:$I" = "$key" ] || { log "RECOVERY_FAILED reason=WORKER_CHANGED_AFTER_LIMIT"; exit 1; }
printf '%s\n' "$key" >"$S/connection-key" || exit 1
log "CONNECTION_CHECK_OK pid=$P samples=$stable span=30s udp=$UDP tcp=$TCP estab=$ESTAB fd=$FD rss=$RSS"
exit 0
fi
else stable=0; last_key=; fi
else pending_ok=0; stable=0; last_key=; fi
sleep 5; n=$((n+1))
done
if [ "$pending_ok" = 1 ] && [ -n "$health_key" ] && recovery_sample; then
if [ "$P:$I" != "$health_key" ]; then log "RECOVERY_FAILED reason=WORKER_CHANGED"; exit 1; fi
"$LIMIT_CMD" --locked 20 || { log LIMIT_UNAVAILABLE; exit 2; }
recovery_sample && [ "$P:$I" = "$health_key" ] || { log "RECOVERY_FAILED reason=WORKER_CHANGED_AFTER_LIMIT"; exit 1; }
printf '%s\n' "$health_key" >"$S/connection-key" || exit 1
log "CONNECTION_PENDING pid=$P samples=$n service=running stats=readable limit=20"
exit 10
fi
log "RECOVERY_FAILED reason=$failure_reason"
exit 1
EARNAPP_MAINTENANCE_RECOVER_TEMPLATE
cat >"$NS_DIR/limit" <<'EARNAPP_MAINTENANCE_LIMIT_TEMPLATE' || return 1
#!/bin/sh
# EARNAPP-MAINTENANCE-2026.10.18.2
set -eu
. /usr/local/lib/mivora.sh
lock "${1:-}" || exit 1
[ "${1:-}" != --locked ] || shift
N=${1:-20}
case "$N" in ''|*[!0-9]*|0*) exit 1;; esac
[ "$N" -le 100000 ]
fail() { log "LIMIT_UNAVAILABLE $*"; exit 1; }
LIMIT_KEY=$(worker_snapshot) || fail worker_identity
[ -n "$LIMIT_KEY" ] || fail worker_missing
P=${LIMIT_KEY%%:*}; I=${LIMIT_KEY#*:}
LIMIT_PARENT_STAMP=$(process_stamp "$P") || fail worker_stat
LIMIT_PARENT=${LIMIT_PARENT_STAMP%%:*}
LIMIT_SUPERVISOR_STAMP=$(process_stamp "$LIMIT_PARENT") || fail supervisor_stat
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || fail cgroup_v2
G=$(awk -F: '$1==0{print $3}' "/proc/$P/cgroup")
case "$G" in ''|/|*[!A-Za-z0-9_./-]*|*..*) fail cgroup_path;; esac
[ "${G##*/}" = openrc.$APP_SVC ] || fail dedicated_cgroup
[ "$G" != "$(awk -F: '$1==0{print $3}' /proc/1/cgroup)" ] || fail shared_pid1
[ "$(awk '$0~/ - cgroup2 /&&$5=="/sys/fs/cgroup"{print $4}' /proc/self/mountinfo)" = / ] || fail cgroup_mount
C=/sys/fs/cgroup$G
members() {
[ "$(worker_snapshot)" = "$LIMIT_KEY" ] || return 1
for f in "$C"/*; do [ ! -d "$f" ] || return 1; done
v=$(cat "$C/cgroup.procs") || return 1
printf '%s\n' "$v" | grep -Fx "$P" >/dev/null || return 1
for m in $v; do [ "$m" = "$P" ] || [ "$m" = "$LIMIT_PARENT" ] || return 1; done
[ "$(process_stamp "$LIMIT_PARENT")" = "$LIMIT_SUPERVISOR_STAMP" ] || return 1
[ "$(start "$P")" = "$I" ] && [ "$(awk -F: '$1==0{print $3}' "/proc/$P/cgroup")" = "$G" ]
}
members || fail unrelated_members
J=$(stat -Lc %i "$C")
d=$(mktemp -d); PROBE=0; T=earnapp_probe_$$
trap '[ "$PROBE" = 0 ] || nft delete table inet "$T" >/dev/null 2>&1; rm -rf "$d"' EXIT
trap 'exit 1' INT TERM HUP
nft list tables >"$d/tables" || fail nft_permission
rule_digest() { sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter/g' "$1" | sha256sum | awk '{print $1}'; }
CACHE_KEY="earnapp-maintenance-v5:$(uname -r):$J:$N:$G"
if grep -Fxq 'table inet earnapp_maintenance' "$d/tables"; then
nft list table inet earnapp_maintenance >"$d/old" || fail nft_read
if [ "$(cat "$S/limit-key" 2>/dev/null || true)" = "$CACHE_KEY" ] && [ "$(cat "$S/limit-digest" 2>/dev/null || true)" = "$(rule_digest "$d/old")" ]; then
members && [ "$(stat -Lc %i "$C")" = "$J" ] || fail cgroup_changed
exit 0
fi
fi
room_uint() {
case "${1:-}" in ''|*[!0-9]*) return 1;; esac
# Normalize decimal strings before any signed-64-bit shell arithmetic.
printf '%s\n' "$1" | LC_ALL=C awk '{
n=$0; sub(/^0+/,"",n); if(n=="")n="0"
if(length(n)>19 || (length(n)==19 && ("x" n)>"x9223372036854775807"))exit 1
print n
}'
}
room_file_uint() {
room_value=$(cat "$1" 2>/dev/null) || return 1
room_uint "$room_value"
}
room_clean_cache() {
[ "$(room_file_uint "$1/memory.min")" = 0 ] || return 1
[ "$(room_file_uint "$1/memory.low")" = 0 ] || return 1
room_values=$(LC_ALL=C awk '
function uint(n) {
if(n !~ /^[0-9]+$/)return ""
sub(/^0+/,"",n); if(n=="")n="0"
if(length(n)>19 || (length(n)==19 && ("x" n)>"x9223372036854775807"))return ""
return n
}
{
if(NF!=2 || $1 !~ /^[a-z_][a-z0-9_]*$/ || seen[$1]++){bad=1; exit}
n=uint($2); if(n==""){bad=1; exit}
value[$1]=n
}
END {
if(bad || !seen["file"] || !seen["inactive_file"] || !seen["file_dirty"] || !seen["file_writeback"])exit 1
print value["file"],value["inactive_file"],value["file_dirty"],value["file_writeback"]
}' "$1/memory.stat" 2>/dev/null) || return 1
set -- $room_values
[ "$#" -eq 4 ] || return 1
room_cache=$1
[ "$room_cache" -le "$2" ] || room_cache=$2
# Saturating deductions avoid overflow and give no credit to dirty/writeback pages.
for room_used in "$3" "$4"; do
if [ "$room_cache" -le "$room_used" ]; then room_cache=0; else room_cache=$((room_cache-room_used)); fi
done
printf '%s\n' "$room_cache"
}
room() {
for z in "$C" /sys/fs/cgroup; do
for x in memory pids; do
[ -f "$z/$x.max" ] || continue
m=$(cat "$z/$x.max" 2>/dev/null) || return 1
[ "$m" = max ] && continue
m=$(room_uint "$m") || return 1
v=$(room_file_uint "$z/$x.current") || return 1
[ "$m" -ge "$v" ] || return 1
r=33554432; [ "$x" != pids ] || r=8
room_free=$((m-v))
if [ "$room_free" -lt "$r" ]; then
[ "$x" = memory ] || return 1
# This is only a conservative estimate; no reclaim or cache-control writes occur.
room_credit=$(room_clean_cache "$z") || return 1
[ "$room_credit" -le "$v" ] || room_credit=$v
[ "$room_credit" -ge "$((r-room_free))" ] || return 1
fi
done
done
}
[ "$(awk -F: '$1==0{print $3}' /proc/self/cgroup)" != "$G" ] || fail probe_must_run_outside
room || fail probe_low_headroom
{
printf 'create table inet %s\nadd chain inet %s out { type filter hook output priority -20; policy accept; }\n' "$T" "$T"
for level in $(seq 1 32); do
printf 'add rule inet %s out ip daddr 127.0.0.1 udp dport 9 socket cgroupv2 level %s "%s" counter comment "earnapp-maintenance-probe-level-%s"\n' "$T" "$level" "${G#/}" "$level"
done
} >"$d/probe"
nft -c -f "$d/probe" && nft -f "$d/probe" || fail kernel_probe
PROBE=1
timeout -k 2 5 bash -c 'echo "$BASHPID" >"$1/cgroup.procs" || exit 1; echo x >/dev/udp/127.0.0.1/9' _ "$C" 6>&- 7>&- 8>&- 9>&- || fail probe_send
nft list chain inet "$T" out >"$d/result" || fail probe_read
V=$(awk '/socket cgroupv2/{l=0;p=0;for(i=1;i<NF;i++){if($i=="level")l=$(i+1);if($i=="packets")p=$(i+1)}if(p>0)print l}' "$d/result")
case "$V" in ''|*[!0-9]*) fail cgroup_match_ambiguous;; esac
bash -c 'echo x >/dev/udp/127.0.0.1/9' 6>&- 7>&- 8>&- 9>&- || fail outside_probe_send
nft list chain inet "$T" out >"$d/outside" || fail probe_read
cmp -s "$d/result" "$d/outside" || fail cgroup_match_not_exclusive
nft delete table inet "$T" || fail probe_cleanup
PROBE=0
members && [ "$(stat -Lc %i "$C")" = "$J" ] || fail cgroup_changed
H="earnapp-maintenance-v5:$J:$V:$N"
log "CGROUP_MATCH_VERIFIED level=$V"

: >"$d/rules"
if grep -Fx 'table inet earnapp_maintenance' "$d/tables" >/dev/null; then echo 'delete table inet earnapp_maintenance' >"$d/rules"; fi
printf 'table inet earnapp_maintenance { chain output { type filter hook output priority -10; policy accept; socket cgroupv2 level %s "%s" meta l4proto { tcp, udp } ct state new ct count over %s counter reject comment "%s"; }; }\n' "$V" "${G#/}" "$N" "$H" >>"$d/rules"
nft -c -f "$d/rules" || fail nft_check
members && [ "$(stat -Lc %i "$C")" = "$J" ] || fail cgroup_changed
nft -f "$d/rules" || fail nft_apply
nft list table inet earnapp_maintenance >"$d/live" || fail nft_read
rule_digest "$d/live" >"$S/limit-digest" || fail cache_write
printf '%s\n' "$CACHE_KEY" >"$S/limit-key" || fail cache_write
log "LIMIT_OK flows=$N group=$G"
EARNAPP_MAINTENANCE_LIMIT_TEMPLATE
cat >"$NS_DIR/boot" <<'EARNAPP_MAINTENANCE_BOOT_TEMPLATE' || return 1
#!/bin/sh
# EARNAPP-MAINTENANCE-2026.10.18.2
n=0; while [ "$n" -lt 15 ]; do /usr/local/sbin/loren 20 && exit 0; n=$((n+1)); sleep 2; done; exit 1
EARNAPP_MAINTENANCE_BOOT_TEMPLATE
for NS_FILE in common watchdog recover limit boot; do sh -n "$NS_DIR/$NS_FILE" || return 1; done
chmod 644 "$NS_DIR/common" || return 1
chmod 755 "$NS_DIR/watchdog" "$NS_DIR/recover" "$NS_DIR/limit" "$NS_DIR/boot"
)

# Source module: node-source-module.sh
# EARNAPP-MAINTENANCE-2026.10.18.2 source foundation; never runs an unvalidated source hook.
suite_source_plain_file(){
  valid_path "$1" || return 1
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] && [ "$(stat -c %u "$1")" = 0 ] || return 1
  NSP_MODE=$(stat -c %a "$1") || return 1
  case "$NSP_MODE" in ''|*[!0-7]*) return 1;; esac
  [ "$((0$NSP_MODE & 022))" = 0 ]
}
suite_source_init_valid(){
  suite_source_plain_file "$1" && [ -x "$1" ] || return 1
  awk -v sdk="$SDK_BIN" -v service="$OLD_SVC" '
    function trim(s){sub(/^[[:space:]]+/,"",s);sub(/[[:space:]]+$/,"",s);return s}
    function literal(s, q){
      s=trim(s);q=substr(s,1,1)
      if(q=="\"" || q==sprintf("%c",39)){
        if(length(s)<2 || substr(s,length(s),1)!=q)return "!invalid"
        s=substr(s,2,length(s)-2)
      } else if(s ~ /[[:space:]]/)return "!invalid"
      if(s ~ /[^A-Za-z0-9 _.,:\/+=@%~-]/)return "!invalid"
      return s
    }
    NR==1{if($0!="#!/sbin/openrc-run")bad=1;next}
    {
      s=trim($0)
      if(s=="" || s ~ /^#/)next
      if(dep){
        if(s=="}"){dep=0;next}
        if(s ~ /^(need net|after networking);?$/)next
        bad=1;next
      }
      if(s ~ /^depend[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*(need net|after networking);?[[:space:]]*\}$/){if(seen_dep++)bad=1;next}
      if(s ~ /^depend[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*$/){if(seen_dep++)bad=1;dep=1;next}
      k=s;sub(/=.*/,"",k)
      if(k==s || k !~ /^[a-z_]+$/ || seen[k]++){bad=1;next}
      v=s;sub(/^[^=]*=/,"",v);v=literal(v)
      if(v=="!invalid"){bad=1;next}
      if(k=="command"){if(v!=sdk)bad=1;next}
      if(k=="command_args"){if(v!="run")bad=1;next}
      if(k=="command_user"){if(v!="root")bad=1;next}
      if(k=="supervisor"){if(v!="supervise-daemon")bad=1;next}
      if(k=="name"){if(v!=service)bad=1;next}
      if(k=="description")next
      if(k=="respawn_delay" || k=="respawn_max" || k=="respawn_period"){
        if(v !~ /^[0-9]+$/ || v+0>2147483647)bad=1;next
      }
      bad=1
    }
    END{exit bad || dep || !seen["command"] || !seen["command_args"] || !seen["command_user"] || !seen["supervisor"]}' "$1" && sh -n "$1"
}
suite_source_config_valid(){
  for NSC_FILE in "/etc/conf.d/$OLD_SVC".*; do
    exists "$NSC_FILE" && { fail "source runlevel-specific configuration retained: $NSC_FILE"; return 1; }
  done
  [ ! -e "/etc/conf.d/$OLD_SVC" ] && [ ! -L "/etc/conf.d/$OLD_SVC" ] && return 0
  suite_source_plain_file "/etc/conf.d/$OLD_SVC" &&
    awk '/^[[:space:]]*$/ || /^[[:space:]]*#/ {next} {bad=1} END{exit bad}' "/etc/conf.d/$OLD_SVC"
}
suite_source_references(){
  if command -v suite_updater_guard >/dev/null 2>&1; then
    UPDATER_MAIN_SVC=$OLD_SVC
    suite_updater_guard "$SDK_BIN" || return 1
  else
    for NSR_SVC in earnapp_upgrader earnapp-upgrader; do
      for NSR_FILE in "/etc/init.d/$NSR_SVC" "/etc/conf.d/$NSR_SVC" /etc/runlevels/*/"$NSR_SVC" \
        "/etc/systemd/system/$NSR_SVC.service" "/usr/lib/systemd/system/$NSR_SVC.service" "/lib/systemd/system/$NSR_SVC.service"; do
        exists "$NSR_FILE" && { fail "vendor updater retained for review: $NSR_FILE"; return 1; }
      done
    done
  fi
  for NSR_FILE in /etc/init.d/* /etc/conf.d/* /etc/crontabs/*; do
    exists "$NSR_FILE" || continue
    [ "$NSR_FILE" != "/etc/init.d/$OLD_SVC" ] && [ "$NSR_FILE" != "/etc/conf.d/$OLD_SVC" ] || continue
    if [ "${UPDATERS_INACTIVE:-0}" = 1 ]; then
      case "$NSR_FILE" in
        /etc/init.d/earnapp_upgrader|/etc/init.d/earnapp-upgrader|/etc/conf.d/earnapp_upgrader|/etc/conf.d/earnapp-upgrader) continue;;
      esac
    fi
    [ -f "$NSR_FILE" ] && [ -r "$NSR_FILE" ] || { fail "cannot inspect possible SDK hook: $NSR_FILE"; return 1; }
    NSR_RC=0; grep -F -e "$SDK_BIN" -e "$NSP_CANON" "$NSR_FILE" >/dev/null 2>&1 || NSR_RC=$?
    case "$NSR_RC" in
      0) fail "another service/cron references the SDK; retained: $NSR_FILE"; return 1;;
      1) :;; *) fail "cannot inspect possible SDK hook: $NSR_FILE"; return 1;;
    esac
  done
}
suite_source_program() (
  NSP_PROC=$1
  NSP_EXE=$(readlink "$NSP_PROC/exe" 2>/dev/null) || NSP_EXE=
  if [ "${NSP_EXE% (deleted)}" = "$NSP_CANON" ]; then
    [ "$(hash_file "$NSP_PROC/exe")" = "$NSP_HASH" ] && exit 0
    exit 2
  fi
  if mapped_program_matches "$NSP_PROC" "$NSP_CANON"; then exit 0; fi
  if [ -r "$NSP_PROC/maps" ]; then
    # A changed/deleted/non-executable mapping is uncertainty, not absence.
    awk -v target="$NSP_CANON" '$6==target{found=1} END{exit found}' "$NSP_PROC/maps" 2>/dev/null || exit 2
    exit 1
  fi
  [ ! -d "$NSP_PROC" ] && exit 1
  exit 2
)
suite_source_run_argv() (
  NSA_PROC=$1
  NSA_ARGS=$(tr '\000' '\n' <"$NSA_PROC/cmdline" 2>/dev/null) || exit 1
  NSA_FIRST=$(printf '%s\n' "$NSA_ARGS" | head -n 1)
  NSA_DIRECT=0
  if [ "$NSA_FIRST" = "$SDK_BIN" ] || [ "$NSA_FIRST" = "$NSP_CANON" ]; then NSA_DIRECT=1
  else
    valid_path "$NSA_FIRST" >/dev/null 2>&1 || exit 1
    NSA_EXE=$(readlink "$NSA_PROC/exe" 2>/dev/null) || exit 1
    [ "$(readlink -f "$NSA_FIRST")" = "${NSA_EXE% (deleted)}" ] || exit 1
  fi
  printf '%s\n' "$NSA_ARGS" | awk -v direct="$NSA_DIRECT" -v sdk="$SDK_BIN" -v canonical="$NSP_CANON" '
    NR==1{next}
    direct==1{if(NR==2 && $0=="run")ok=1;else bad=1;next}
    done{bad=1;next}
    need_run{if($0=="run"){ok=1;done=1}else bad=1;need_run=0;next}
    skip{skip=0;next}
    $0==sdk || $0==canonical{need_run=1;next}
    !ended && $0=="--"{ended=1;next}
    !ended && ($0=="--argv0" || $0=="--preload" || $0=="--library-path"){skip=1;next}
    {bad=1}
    END{exit !(ok && !bad && !skip && !need_run)}'
)
suite_source_scan() (
  NSS_ALLOWED_PARENT=${1:-}
  NSS_SUP=$(command -v supervise-daemon) && NSS_SUP=$(readlink -f "$NSS_SUP") || exit 1
  NSS_COUNT=0; NSS_RESULT=
  for NSS_PROC in /proc/[0-9]*; do
    [ -d "$NSS_PROC" ] || continue
    NSS_PID=${NSS_PROC##*/}
    NSS_EXE=$(readlink "$NSS_PROC/exe" 2>/dev/null) || NSS_EXE=
    if [ "${NSS_EXE% (deleted)}" = "$NSS_SUP" ] && [ "$NSS_PID" != "$NSS_ALLOWED_PARENT" ]; then
      NSS_ARGS=$(tr '\000' '\n' <"$NSS_PROC/cmdline" 2>/dev/null) || exit 1
      [ -n "$NSS_ARGS" ] || exit 1
      if printf '%s\n' "$NSS_ARGS" | awk -v sdk="$SDK_BIN" -v canonical="$NSP_CANON" -v service="$OLD_SVC" '
        NR==2 && ($0==service || $0=="earnapp_upgrader" || $0=="earnapp-upgrader"){found=1}
        $0==sdk || $0==canonical{found=1} END{exit !found}'; then
        fail "a live supervisor still owns/references the source SDK: $NSS_PID"; exit 1
      fi
    fi
    NSS_MATCH=0; suite_source_program "$NSS_PROC" || NSS_MATCH=$?
    case "$NSS_MATCH" in 1) continue;; 0) :;; *) fail "source process identity is unreadable/changed: $NSS_PID"; exit 1;; esac
    NSS_STAMP=$(process_stamp "$NSS_PID") || exit 1
    awk '/^Uid:/{ok=(NF==5&&$2==0&&$3==0&&$4==0&&$5==0)} END{exit !ok}' "$NSS_PROC/status" || exit 1
    suite_source_run_argv "$NSS_PROC" || { fail "SDK process does not have a verified run invocation: $NSS_PID"; exit 1; }
    [ "$(process_stamp "$NSS_PID")" = "$NSS_STAMP" ] || exit 1
    NSS_COUNT=$((NSS_COUNT+1)); [ "$NSS_COUNT" = 1 ] || { fail 'multiple SDK workers; source preparation refused'; exit 1; }
    NSS_RESULT="$NSS_PID:${NSS_STAMP#*:}:${NSS_STAMP%%:*}"
  done
  [ "$(hash_file "$SDK_BIN")" = "$NSP_HASH" ] || exit 1
  [ -z "$NSS_RESULT" ] || printf '%s\n' "$NSS_RESULT"
)
suite_source_meta_value() (
  NSG_HELPER=
  for NSG_FILE in /lib/rc/bin/service_get_value /usr/lib/rc/bin/service_get_value; do
    [ ! -x "$NSG_FILE" ] || { NSG_HELPER=$NSG_FILE; break; }
  done
  [ -n "$NSG_HELPER" ] || NSG_HELPER=$(command -v service_get_value) || exit 1
  NSG_RC=0
  NSG_VALUE=$(RC_SVCNAME=$OLD_SVC "$NSG_HELPER" "$1" 6>&- 7>&- 8>&- 9>&- 2>/dev/null) || NSG_RC=$?
  case "$NSG_RC" in
    0) printf '%s\n' "$NSG_VALUE";;
    1) [ -z "$NSG_VALUE" ] || exit 1;;
    *) exit 1;;
  esac
)
suite_source_meta_guard() (
  NSM_EXPECTED=${1:-}
  NSM_CHILD=$(suite_source_meta_value child_pid) || exit 1
  if [ -n "$NSM_CHILD" ]; then
    case "$NSM_CHILD" in *[!0-9]*) exit 1;; esac
    [ "$NSM_CHILD" -gt 1 ] || exit 1
    if [ -d "/proc/$NSM_CHILD" ]; then [ "$NSM_CHILD" = "$NSM_EXPECTED" ] || exit 1; fi
  fi
  NSM_PATH=$(suite_source_meta_value pidfile) || exit 1
  [ -n "$NSM_PATH" ] || exit 0
  valid_path "$NSM_PATH" || exit 1
  [ -e "$NSM_PATH" ] || [ -L "$NSM_PATH" ] || exit 0
  NSM_PARENT=$(cat "$NSM_PATH" 2>/dev/null) || exit 1
  case "$NSM_PARENT" in ''|*[!0-9]*) exit 1;; esac
  [ "$NSM_PARENT" -gt 1 ] || exit 1
  [ ! -d "/proc/$NSM_PARENT" ]
)
suite_source_static_guard(){
  [ "$(hash_file "$NSP_INIT")" = "$NSP_INIT_HASH" ] || { fail 'source init changed before execution'; return 1; }
  if [ "$NSP_CONF_HASH" = absent ]; then
    [ ! -e "/etc/conf.d/$OLD_SVC" ] && [ ! -L "/etc/conf.d/$OLD_SVC" ] || return 1
  else [ "$(hash_file "/etc/conf.d/$OLD_SVC")" = "$NSP_CONF_HASH" ] || return 1; fi
  suite_source_config_valid
}
suite_source_status(){
  suite_source_static_guard || return 1
  service_state "$OLD_SVC" 6>&- 7>&- 8>&- 9>&-
}
suite_source_live_key() (
  [ "$(suite_source_status)" = 0 ] || exit 1
  NSV_PIDS=$(service_worker_pids "$OLD_SVC" "$SDK_BIN" 6>&- 7>&- 8>&- 9>&-) || exit 1
  set -- $NSV_PIDS
  [ "$#" = 1 ] || exit 1
  NSV_PID=$1; NSV_STAMP=$(process_stamp "$NSV_PID") || exit 1
  NSV_PARENT=${NSV_STAMP%%:*}
  NSV_ARGS=$(tr '\000' '\n' <"/proc/$NSV_PARENT/cmdline" 2>/dev/null) || exit 1
  printf '%s\n' "$NSV_ARGS" | awk -v service="$OLD_SVC" 'NR==2{found=($0==service)} END{exit !found}' || exit 1
  NSV_SCAN=$(suite_source_scan "$NSV_PARENT") || exit 1
  [ "$NSV_SCAN" = "$NSV_PID:${NSV_STAMP#*:}:$NSV_PARENT" ] || exit 1
  [ "$(process_stamp "$NSV_PID")" = "$NSV_STAMP" ] && [ "$(suite_source_status)" = 0 ] || exit 1
  printf '%s:%s\n' "$NSV_PID" "${NSV_STAMP#*:}"
)
suite_source_poll(){
  NSP_POLL=0
  while [ "$NSP_POLL" -lt 10 ]; do
    NSP_READY=$(suite_source_live_key 2>>"$U_B/source-preparation.log") && return 0
    NSP_POLL=$((NSP_POLL+1)); [ "$NSP_POLL" = 10 ] || sleep 1
  done
  return 1
}
suite_prepare_source(){
  SOURCE_PREPARED=0; SOURCE_ACTION=; NSP_READY=
  [ -n "${U_D:-}" ] && [ -d "$U_D" ] && [ -n "${U_B:-}" ] && [ -d "$U_B" ] || { fail 'source foundation directories are missing'; return 1; }
  [ "${OLD_SVC:-}" = earnapp ] || { fail 'source foundation only supports the vendor source service'; return 1; }
  valid_path "$SDK_BIN" && [ -f "$SDK_BIN" ] && [ -x "$SDK_BIN" ] || return 1
  [ "$(od -An -tx1 -N4 "$SDK_BIN" | tr -d ' \n')" = 7f454c46 ] || { fail 'source SDK must be an ELF executable'; return 1; }
  NSP_HASH=$(hash_file "$SDK_BIN") && NSP_CANON=$(readlink -f "$SDK_BIN") || return 1
  valid_path "$NSP_CANON" || return 1
  NSP_INIT="/etc/init.d/$OLD_SVC"; NSP_INIT_HASH=; NSP_NEW_INIT=1
  NSP_CONF_HASH=absent
  suite_source_config_valid || { fail 'source configuration contains unsupported hooks/settings'; return 1; }
  [ ! -f "/etc/conf.d/$OLD_SVC" ] || NSP_CONF_HASH=$(hash_file "/etc/conf.d/$OLD_SVC") || return 1
  if exists "$NSP_INIT"; then
    suite_source_init_valid "$NSP_INIT" || { fail "unknown source init retained without execution: $NSP_INIT"; return 1; }
    NSP_INIT_HASH=$(hash_file "$NSP_INIT") || return 1
    NSP_NEW_INIT=0
  fi
  suite_source_references || return 1
  if [ "$NSP_NEW_INIT" = 0 ]; then
    NSP_STATE=$(suite_source_status) || return 1
    case "$NSP_STATE" in
      0)
        NSP_READY=$(suite_source_live_key) || { fail 'existing source supervision is not verifiable; retained'; return 1; }
        SOURCE_PREPARED=1; SOURCE_ACTION=kept
        printf 'SOURCE_PREPARED\nkept %s worker=%s\n' "$OLD_SVC" "$NSP_READY"
        return 0;;
      3) :;; *) fail "source service is transitional/crashed (status $NSP_STATE); retained"; return 1;;
    esac
  fi
  NSP_ORIGINAL=$(suite_source_scan) || return 1
  NSP_ORPHAN=
  if [ -n "$NSP_ORIGINAL" ]; then
    NSP_ORPHAN=${NSP_ORIGINAL%%:*}; NSP_REST=${NSP_ORIGINAL#*:}; NSP_BIRTH=${NSP_REST%%:*}; NSP_PARENT=${NSP_REST##*:}
    [ "$NSP_PARENT" = 1 ] || { fail 'only a verified parent-1 run orphan can be normalized'; return 1; }
  fi
  suite_source_meta_guard "$NSP_ORPHAN" || { fail 'live/unknown OpenRC ownership prevents source preparation'; return 1; }
  [ ! -e "$U_B/source-preparation.record" ] || { fail 'source foundation record already exists; use a separate foundation directory'; return 1; }
  printf '%s\n' 'FORMAT=1' "SDK=$SDK_BIN" "CANONICAL=$NSP_CANON" "HASH=$NSP_HASH" "SERVICE=$OLD_SVC" \
    "ORIGINAL_INIT_HASH=${NSP_INIT_HASH:-absent}" "ORIGINAL_CONFIG_HASH=$NSP_CONF_HASH" "ORIGINAL_WORKER=${NSP_ORIGINAL:-absent}" >"$U_B/source-preparation.record" || return 1
  chmod 600 "$U_B/source-preparation.record" || return 1
  printf '%s\n' prepared >"$U_B/source-preparation.state" || return 1
  if [ -n "$NSP_ORPHAN" ]; then
    NSP_RECHECK=$(suite_source_scan) || return 1
    [ "$NSP_RECHECK" = "$NSP_ORIGINAL" ] && suite_source_meta_guard "$NSP_ORPHAN" && suite_source_references || return 1
    [ "$(process_stamp "$NSP_ORPHAN")" = "1:$NSP_BIRTH" ] || { fail 'orphan PID/start time changed before TERM'; return 1; }
    printf '%s\n' term-attempted >"$U_B/source-preparation.state" || return 1
    kill -TERM "$NSP_ORPHAN" || { fail 'verified orphan did not accept TERM'; return 1; }
    NSP_WAIT=0
    while [ -d "/proc/$NSP_ORPHAN" ] && [ "$NSP_WAIT" -lt 5 ]; do
      [ "$(process_stamp "$NSP_ORPHAN")" = "1:$NSP_BIRTH" ] || { fail 'orphan PID changed/exited without a clean process disappearance; retained for review'; return 1; }
      sleep 1; NSP_WAIT=$((NSP_WAIT+1))
    done
    [ ! -d "/proc/$NSP_ORPHAN" ] || { fail 'verified orphan remains after bounded TERM; no stronger signal was sent'; return 1; }
    NSP_RECHECK=$(suite_source_scan) || { fail 'SDK identity is unknown after TERM; no further signals sent'; return 1; }
    [ -z "$NSP_RECHECK" ] && suite_source_meta_guard || { fail 'SDK worker/supervisor appeared after TERM; no further signals sent'; return 1; }
    printf '%s\n' orphan-stopped >"$U_B/source-preparation.state" || return 1
    SOURCE_ACTION=adopted
  else SOURCE_ACTION=started; fi
  suite_source_references || return 1
  if [ "$NSP_NEW_INIT" = 1 ]; then
    cat >"$U_D/source-init" <<EOF
#!/sbin/openrc-run
name="$OLD_SVC"
description="EarnApp service"
command="$SDK_BIN"
command_args="run"
command_user="root"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
respawn_period=1800
depend() { need net; }
EOF
    chmod 755 "$U_D/source-init" && suite_source_init_valid "$U_D/source-init" || return 1
    suite_atomic source-init "$U_D/source-init" 755 || return 1
    NSP_INIT_HASH=$(hash_file "$NSP_INIT") || return 1
    printf '%s\n' init-installed >"$U_B/source-preparation.state" || return 1
    rc-update add "$OLD_SVC" default 6>&- 7>&- 8>&- 9>&- || return 1
  fi
  NSP_STATE=$(suite_source_status) || return 1
  if [ "$NSP_STATE" != 3 ]; then
    case "$NSP_STATE" in 0|32) :;; *) fail 'source state changed before canonical start'; return 1;; esac
    # Only the statically verified init is used to clear a stale service flag.
    NSP_RECHECK=$(suite_source_scan) || return 1
    [ -z "$NSP_RECHECK" ] && suite_source_meta_guard && suite_source_static_guard || return 1
    timeout -k 2 10 rc-service "$OLD_SVC" zap 6>&- 7>&- 8>&- 9>&- || return 1
    [ "$(suite_source_status)" = 3 ] || return 1
  fi
  NSP_ATTEMPT=0
  while [ "$NSP_ATTEMPT" -lt 2 ]; do
    NSP_ATTEMPT=$((NSP_ATTEMPT+1))
    suite_source_static_guard && [ "$(hash_file "$SDK_BIN")" = "$NSP_HASH" ] || return 1
    printf '%s\n' start-attempted >"$U_B/source-preparation.state" || return 1
    NSP_START_RC=0
    timeout -k 5 30 rc-service "$OLD_SVC" start 6>&- 7>&- 8>&- 9>&- >>"$U_B/source-preparation.log" 2>&1 || NSP_START_RC=$?
    printf 'START_ATTEMPT=%s RC=%s\n' "$NSP_ATTEMPT" "$NSP_START_RC" >>"$U_B/source-preparation.log"
    if suite_source_poll; then
      SOURCE_PREPARED=1
      printf '%s\n' "READY_WORKER=$NSP_READY" >>"$U_B/source-preparation.record"
      printf '%s\n' ready >"$U_B/source-preparation.state"
      printf 'SOURCE_PREPARED\n%s %s worker=%s\nFOUNDATION\n%s\n' "$SOURCE_ACTION" "$OLD_SVC" "$NSP_READY" "$U_B"
      return 0
    fi
    [ "$(suite_source_status)" = 3 ] || break
    NSP_REMAINDER=$(suite_source_scan) || break
    [ -z "$NSP_REMAINDER" ] && suite_source_meta_guard || break
  done
  printf '%s\n' start-failed >"$U_B/source-preparation.state"
  fail "canonical source start could not be verified; known init and foundation diagnostics retained: $U_B"
  return 1
}

# Source module: maintenance-suite-module.sh
# Transparent EarnApp helper maintenance transaction. Loaded after shared base/source/helper modules.
SUITE_VERSION=2026.10.18.3
SUITE_SERVICE=earnapp
SUITE_REGISTRY=/var/lib/earnapp-maintenance/current

suite_path(){
  case "$1" in
    old-common) printf '%s\n' /usr/local/lib/earnapp-original.sh;;
    old-watchdog) printf '%s\n' /usr/local/sbin/earnapp-watchdog;;
    old-recover) printf '%s\n' /usr/local/sbin/earnapp-recover;;
    old-limit) printf '%s\n' /usr/local/sbin/earnapp-limit;;
    old-boot) printf '%s\n' /etc/local.d/earnapp-limit.start;;
    old-config) printf '%s\n' /etc/earnapp/watchdog.conf;;
    common) printf '%s\n' /usr/local/lib/mivora.sh;;
    watchdog) printf '%s\n' /usr/local/sbin/selnu;;
    recover) printf '%s\n' /usr/local/sbin/tavik;;
    limit) printf '%s\n' /usr/local/sbin/loren;;
    boot) printf '%s\n' /etc/local.d/pavri.start;;
    config) printf '%s\n' /etc/earnapp/maintenance.conf;;
    cron) printf '%s\n' /etc/crontabs/root;;
    registry) printf '%s\n' "$SUITE_REGISTRY";;
    source-init) printf '%s\n' /etc/init.d/earnapp;;
    source-conf) printf '%s\n' /etc/conf.d/earnapp;;
    *) fail "unknown suite file: $1";;
  esac
}
suite_tags(){ printf '%s\n' old-common old-watchdog old-recover old-limit old-boot old-config common watchdog recover limit boot config cron registry source-init source-conf; }
suite_regular(){
  valid_path "$1" || return 1
  SP_PARENT=$1
  while [ "$SP_PARENT" != / ]; do
    [ ! -L "$SP_PARENT" ] || { fail "symlink is not an upgrade target: $SP_PARENT"; return 1; }
    SP_PARENT=${SP_PARENT%/*}; [ -n "$SP_PARENT" ] || SP_PARENT=/
  done
  exists "$1" || return 0
  [ -f "$1" ] && [ -r "$1" ] && [ "$(stat -c %u "$1")" = 0 ] || {
    fail "expected a readable root-owned regular file: $1"; return 1;
  }
}
suite_legacy_hash(){
  case "$1:$2" in
    old-common:7d0e354f186b180f8df2f97c5804ec5b4a516f4bb935f207918b83b9dda9fa46|old-common:6a80401689c0d2bb16f403f7845a326fafdd4a58fbc07b22eec8419fc69744cb|\
    old-watchdog:4e6eeafaa13f510c08451e883260d9541125a2cfbd900dd9edab6e432e1b5fff|old-watchdog:c6bb5c971fabe055e674f473c1e9565bb5c4de8e9c07e3f3574b50e496aa6257|old-watchdog:9d5f4cec8a674fdb33a0af28db64d86a813cbc8abbef3f14bd2f50f24b8e35a8|\
    old-recover:963d1976b6a2070a0b05f966987cdee89487daf9dcb1d73de91ab89159e359a1|old-recover:e4f8536786ceb6ef2abcb48c7984ded0b021fbfd7196789005002850391e8026|old-recover:046471e99f57ebe1a7bb7616aaf1692eb5faab20d6a9e6a3dc87e683b8441529|old-recover:715316864c15540ea5e1d88f8d753863731991cdf9ded153cf38a184f63e34d8|\
    old-limit:dd738eb46331a49230b7977fca80183e7858ef829ad844ac550faeb3a3e38485|old-limit:971f4288ed4bc4757ffb9ccba3b91e0bcfc7ad8b9b46f050fe99871efca9e3e6|old-limit:1582c02ebe633d0bf98a468a1ea5fa8b5bf6bc6d4adcc4cf1ebfb1b6cf4a75c5|\
    old-boot:eff856125ffadef714d4b7bf5188f09c7d60568dfd2cfe7b6cb0b2a041d7f806|old-boot:6c44ca2d867d72ae2c7b3285d2b5037057cfe6fc764f8714da408dd5576b4947) return 0;;
    *) return 1;;
  esac
}
suite_has_legacy(){
  for SH_TAG in old-common old-watchdog old-recover old-limit old-boot; do
    SH_PATH=$(suite_path "$SH_TAG") || return 1
    if exists "$SH_PATH"; then return 0; fi
  done
  return 1
}
suite_config_valid(){
  [ ! -e "$1" ] || awk '
    /^[[:space:]]*$/ || /^[[:space:]]*#/ {next}
    /^(UDP_THRESHOLD|FD_THRESHOLD|RSS_THRESHOLD_KB|ZERO_MAX_BAD|RESOURCE_MAX_BAD|MIN_UPTIME|RESTART_COOLDOWN)=[1-9][0-9]*$/ {
      split($0,a,"="); if(a[2]<=2147483647 && !seen[a[1]]++)next
    }
    {bad=1} END{exit bad}' "$1"
}
suite_emit_config(){
  # Numeric data only: never source any retired helper or configuration.
  set --
  for SC_FILE in /usr/local/lib/earnapp-original.sh /usr/local/sbin/earnapp-watchdog /etc/earnapp/watchdog.conf /etc/earnapp/maintenance.conf; do
    [ ! -f "$SC_FILE" ] || set -- "$@" "$SC_FILE"
  done
  [ "$#" -gt 0 ] || { printf '%s\n' '# Defaults are defined in mivora.sh.'; return 0; }
  awk '
    BEGIN{n=split("UDP_THRESHOLD FD_THRESHOLD RSS_THRESHOLD_KB ZERO_MAX_BAD RESOURCE_MAX_BAD MIN_UPTIME RESTART_COOLDOWN",keys," ");for(i=1;i<=n;i++)known[keys[i]]=1}
    /^[[:space:]]*#/ {next}
    {count=split($0,part,";");for(j=1;j<=count;j++){
      s=part[j];sub(/^[[:space:]]+/,"",s);sub(/[[:space:]]+$/, "",s)
      k=s;sub(/=.*/,"",k)
      if(known[k]){v=s;sub(/^[^=]*=/,"",v);if(v !~ /^[1-9][0-9]*$/ || v+0>2147483647)bad=1;else value[k]=v}
    }}
    END{if(bad)exit 1;for(i=1;i<=n;i++)if(keys[i] in value)print keys[i] "=" value[keys[i]]}' "$@"
}
suite_cron_filter(){
  # check preserves bytes; paused omits the exact recognized entries.
  awk -v mode="$1" '
    function managed(s) {
      return s=="*/2 * * * * /usr/local/sbin/earnapp-watchdog >/dev/null 2>&1 # EARNAPP-WATCHDOG" ||
        s=="0 */12 * * * /usr/local/sbin/earnapp-recover scheduled >/dev/null 2>&1 # EARNAPP-12H-STOPSTART" ||
        s=="*/2 * * * * /usr/local/sbin/selnu >/dev/null 2>&1 # EARNAPP-MAINT-WATCHDOG" ||
        s=="0 */12 * * * /usr/local/sbin/tavik scheduled >/dev/null 2>&1 # EARNAPP-MAINT-RECOVERY"
    }
    managed($0){if(mode=="check")print;next}
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {print;next}
    {s=tolower($0);if(index(s,"earnapp") || index(s,"/usr/local/sbin/selnu") || index(s,"/usr/local/sbin/tavik") || index(s,"/usr/local/sbin/loren") ||
      index(s,"/usr/local/sbin/node-guard") || index(s,"/usr/local/sbin/node-recover") || index(s,"/usr/local/sbin/node-limit") ||
      index(s,"/usr/local/lib/node-runtime.sh") || index(s,"/etc/local.d/node-limit.start"))bad=1;print}
    END{exit bad}' "$2"
}
suite_read_current(){
  suite_regular "$SUITE_REGISTRY" || return 1
  [ -s "$SUITE_REGISTRY" ] || return 1
  U_PREVIOUS=$(cat "$SUITE_REGISTRY") || return 1
  valid_path "$U_PREVIOUS" && [ -d "$U_PREVIOUS" ] && [ ! -L "$U_PREVIOUS" ] || return 1
  [ -f "$U_PREVIOUS/settings" ] && [ -f "$U_PREVIOUS/owned" ] && [ "$(cat "$U_PREVIOUS/state")" = active ] || return 1
  suite_regular "$U_PREVIOUS/settings" && suite_regular "$U_PREVIOUS/owned" || return 1
  U_CURRENT_VERSION=; U_TARGET=; U_SOURCE=; U_SERVICE=; U_APP_HASH=; SR_SEEN=' '; SR_COUNT=0
  while IFS='=' read -r SR_KEY SR_VAL; do
    case "$SR_SEEN" in *" $SR_KEY "*) return 1;; esac
    SR_SEEN="$SR_SEEN$SR_KEY "; SR_COUNT=$((SR_COUNT+1))
    case "$SR_KEY" in
      VERSION) U_CURRENT_VERSION=$SR_VAL;; TARGET) U_TARGET=$SR_VAL;; SERVICE) U_SERVICE=$SR_VAL;;
      HASH) U_APP_HASH=$SR_VAL;;
      SOURCE) U_SOURCE=$SR_VAL;;
      MODE) case "$SR_VAL" in legacy|managed|fresh|prepared) :;; *) return 1;; esac;; *) fail 'invalid suite settings'; return 1;;
    esac
  done < "$U_PREVIOUS/settings"
  [ "$SR_COUNT" = 6 ] && [ -n "$U_CURRENT_VERSION" ] && valid_path "$U_TARGET" && [ "$U_SERVICE" = "$SUITE_SERVICE" ] || return 1
  [ "$U_SOURCE" = "$U_TARGET" ] || return 1
  case "$U_APP_HASH" in ''|*[!0-9a-f]*) return 1;; esac
  [ "${#U_APP_HASH}" = 64 ] && [ "$(hash_file "$U_TARGET")" = "$U_APP_HASH" ] || { fail 'installed program changed'; return 1; }
  suite_check_owned "$U_PREVIOUS" || return 1
}
suite_check_owned(){
  SCO_SEEN=' '; SCO_COUNT=0
  while read -r SCO_TAG SCO_HASH SCO_EXTRA; do
    [ -z "$SCO_EXTRA" ] || return 1
    case "$SCO_TAG" in common|watchdog|recover|limit|boot) :;; *) return 1;; esac
    case "$SCO_SEEN" in *" $SCO_TAG "*) return 1;; esac
    SCO_SEEN="$SCO_SEEN$SCO_TAG "; SCO_COUNT=$((SCO_COUNT+1))
    SCO_PATH=$(suite_path "$SCO_TAG") || return 1
    suite_regular "$SCO_PATH" && [ -f "$SCO_PATH" ] || return 1
    SCO_MODE=755; [ "$SCO_TAG" != common ] || SCO_MODE=644
    [ "$(stat -c %a "$SCO_PATH")" = "$SCO_MODE" ] || { fail "managed file mode changed: $SCO_PATH"; return 1; }
    [ "$(hash_file "$SCO_PATH")" = "$SCO_HASH" ] || { fail "managed file changed: $SCO_PATH"; return 1; }
  done < "$1/owned"
  [ "$SCO_COUNT" = 5 ] || { fail 'incomplete helper ownership record'; return 1; }
}
suite_table_owned(){
  STO_TEXT=$(nft list table inet "$1") || { fail "cannot read nft table inet $1; rules retained"; return 2; }
  if printf '%s\n' "$STO_TEXT" | awk -v table="$1" -v service="$2" -v prefix="$3" '
    # This narrowly identifies the observed old marked-flow limiter. Numeric
    # cgroup IDs identify the saved rule format, not the current live worker.
    function uint64(s) {
      return (s=="0" || s ~ /^[1-9][0-9]*$/) &&
        (length(s)<20 || (length(s)==20 && ("u:" s)<=("u:18446744073709551615")))
    }
    function legacy(s, n,a) {
      if(s=="")return
      gsub(/[[:space:]]+/," ",s)
      if(ls==0 && s=="table inet earnapp_limit {"){ls=1;return}
      if(ls==1 && s=="chain output {"){ls=2;return}
      if(ls==2 && (s=="type filter hook output priority -10; policy accept;" ||
                   s=="type filter hook output priority filter - 10; policy accept;")){ls=3;return}
      n=split(s,a," ")
      if(ls==3 && n==12 && a[1]=="socket" && a[2]=="cgroupv2" && a[3]=="level" &&
         a[4] ~ /^[1-9][0-9]*$/ && a[4]+0<=255 && uint64(a[5]) && a[5]!="0" &&
         a[6]=="ct" && a[7]=="state" && a[8]=="new" && a[9]=="ct" &&
         a[10]=="mark" && a[11]=="set" && a[12]=="0x000eaa20"){
        ll=a[4];li=a[5];ls=4;return
      }
      if(ls==4 && n==21 && a[1]=="socket" && a[2]=="cgroupv2" && a[3]=="level" &&
         ("l:" a[4])==("l:" ll) && ("i:" a[5])==("i:" li) &&
         a[6]=="ct" && a[7]=="state" && a[8]=="new" && a[9]=="ct" &&
         a[10]=="mark" && a[11]=="0x000eaa20" && a[12]=="ct" && a[13]=="count" &&
         a[14]=="over" && a[15]=="20" && a[16]=="counter" && a[17]=="packets" &&
         uint64(a[18]) && a[19]=="bytes" && uint64(a[20]) && a[21]=="reject"){
        ls=5;return
      }
      if(ls==5 && s=="}"){ls=6;return}
      if(ls==6 && s=="}"){ls=7;return}
      lb=1
    }
    function numeric(s, n,a,tag) {
      if(s=="")return
      gsub(/[[:space:]]+/," ",s)
      if(ns==0 && s=="table inet " table " {"){ns=1;return}
      if(ns==1 && s=="chain output {"){ns=2;return}
      if(ns==2 && (s=="type filter hook output priority -10; policy accept;" ||
                   s=="type filter hook output priority filter - 10; policy accept;")){ns=3;return}
      if(table=="earnapp_maintenance" && service=="earnapp" && prefix=="earnapp-maintenance-")tag="earnapp-maintenance-v5"
      else if(table=="earnapp_limit" && service=="earnapp" && prefix=="earnapp-")tag="earnapp-v4"
      n=split(s,a," ")
      if(ns==3 && tag!="" && n==26 && a[1]=="socket" && a[2]=="cgroupv2" && a[3]=="level" &&
         a[4] ~ /^[1-9][0-9]*$/ && a[4]+0<=255 && uint64(a[5]) && a[5]!="0" &&
         a[6]=="meta" && a[7]=="l4proto" && a[8]=="{" && a[9]=="tcp," && a[10]=="udp" && a[11]=="}" &&
         a[12]=="ct" && a[13]=="state" && a[14]=="new" && a[15]=="ct" && a[16]=="count" &&
         a[17]=="over" && a[18] ~ /^[1-9][0-9]*$/ && a[18]+0<=100000 &&
         (tag!="earnapp-v4" || a[18]=="20") && a[19]=="counter" && a[20]=="packets" &&
         uint64(a[21]) && a[22]=="bytes" && uint64(a[23]) && a[24]=="reject" && a[25]=="comment" &&
         a[26]==("\"" tag ":" a[5] ":" a[4] ":" a[18] "\"")){
        ns=4;return
      }
      if(ns==4 && s=="}"){ns=5;return}
      if(ns==5 && s=="}"){ns=6;return}
      nb=1
    }
    {s=$0;sub(/^[[:space:]]+/,"",s);sub(/[[:space:]]+$/, "",s);legacy(s);numeric(s)}
    s=="" || s=="}" {next}
    s=="table inet " table " {" {t++;next}
    s=="chain output {" {c++;next}
    s ~ /^type filter hook output priority .*; policy accept;$/ {h++;next}
    index(s,"socket cgroupv2 level ")==1 && index(s,"openrc." service "\"") && index(s,"ct count over ") && index(s,"comment \"" prefix) {r++;next}
    {bad=1}
    END{
      modern_ok=(!bad && t==1 && c==1 && h==1 && r==1)
      legacy_ok=(table=="earnapp_limit" && service=="earnapp" && prefix=="earnapp-" && !lb && ls==7)
      numeric_ok=(!nb && ns==6)
      exit !(modern_ok || legacy_ok || numeric_ok)
    }'; then return 0; fi
  fail "unrecognized nft table format retained: inet $1"
  return 1
}
suite_reject_sdk_copies(){
  [ -f "$SDK_BIN" ] || return 0
  SRC_HASH=$(hash_file "$SDK_BIN") && SRC_CANON=$(readlink -f "$SDK_BIN") || return 1
  for SRC_FILE in /usr/local/bin/xray /usr/local/lib/xray /usr/local/lib/xrayrun /usr/bin/xray /usr/local/libexec/xray; do
    exists "$SRC_FILE" || continue
    [ -f "$SRC_FILE" ] && [ -r "$SRC_FILE" ] || { fail "cannot inspect an existing Xray path: $SRC_FILE"; return 1; }
    SRC_OTHER=$(readlink -f "$SRC_FILE") && SRC_DIGEST=$(hash_file "$SRC_FILE") || return 1
    if [ "$SRC_OTHER" = "$SRC_CANON" ] || [ "$SRC_DIGEST" = "$SRC_HASH" ]; then
      fail "an SDK copy occupies an old Xray deployment path; retained without modification: $SRC_FILE"; return 1
    fi
  done
}
suite_verify_source() (
  OLD_SVC=$SUITE_SERVICE
  suite_source_init_valid "/etc/init.d/$OLD_SVC" && suite_source_config_valid || { fail 'source init/config is not a recognized transparent EarnApp service'; exit 1; }
  SV_INIT_HASH=$(hash_file "/etc/init.d/$OLD_SVC") || exit 1
  SV_CONF_HASH=absent
  [ ! -f "/etc/conf.d/$OLD_SVC" ] || SV_CONF_HASH=$(hash_file "/etc/conf.d/$OLD_SVC") || exit 1
  SV_PIDS=$(service_worker_pids "$OLD_SVC" "$SDK_BIN" 6>&- 7>&- 8>&- 9>&-) || exit 1
  set -- $SV_PIDS; [ "$#" = 1 ] || { fail 'exactly one verified EarnApp worker is required'; exit 1; }
  SV_PID=$1; SV_STAMP=$(process_stamp "$SV_PID") || exit 1
  [ "$(service_state "$OLD_SVC" 6>&- 7>&- 8>&- 9>&-)" = 0 ] || exit 1
  [ "$(hash_file "/etc/init.d/$OLD_SVC")" = "$SV_INIT_HASH" ] || exit 1
  if [ "$SV_CONF_HASH" = absent ]; then ! exists "/etc/conf.d/$OLD_SVC" || exit 1
  else [ "$(hash_file "/etc/conf.d/$OLD_SVC")" = "$SV_CONF_HASH" ] || exit 1; fi
  suite_source_config_valid && [ "$(process_stamp "$SV_PID")" = "$SV_STAMP" ] || exit 1
  printf '%s:%s\n' "$SV_PID" "$SV_STAMP"
)
suite_preflight(){
  require_root && [ -f /etc/alpine-release ] || { fail 'ROOT_ALPINE_REQUIRED'; return 1; }
  # A previous service-renaming deployment requires its own explicit recovery.
  if exists /var/lib/node-suite/current; then
    fail 'old node-suite registry exists; restore/review that deployment before ordinary EarnApp maintenance'; return 1
  fi
  for SP_OLD_NODE in /usr/local/lib/node-runtime.sh /usr/local/sbin/node-guard /usr/local/sbin/node-recover /usr/local/sbin/node-limit /etc/local.d/node-limit.start /etc/node-guard.conf; do
    exists "$SP_OLD_NODE" && { fail "old node-suite auxiliary file exists; retained without modification: $SP_OLD_NODE"; return 1; }
  done
  for SP_TOOL in awk sha256sum stat readlink rc-service rc-update mktemp cmp; do need "$SP_TOOL" || return 1; done
  U_MODE=legacy; U_PREVIOUS=; U_TARGET=; U_SERVICE=$SUITE_SERVICE; U_PREPARE_SOURCE=0
  OLD_SVC=$SUITE_SERVICE
  valid_path "$BACKUP_ROOT" || return 1
  for SP_TAG in $(suite_tags); do
    SP_PATH=$(suite_path "$SP_TAG") || return 1
    suite_regular "$SP_PATH" || return 1
  done
  if exists "$SUITE_REGISTRY"; then
    suite_read_current || { fail 'existing maintenance registry or owned files need review'; return 1; }
    U_MODE=managed; SDK_BIN=$U_TARGET
  else
    for SP_TAG in common watchdog recover limit boot config; do
      SP_PATH=$(suite_path "$SP_TAG") || return 1
      exists "$SP_PATH" && { fail "unowned maintenance destination exists: $SP_PATH"; return 1; }
    done
  fi
  for SP_TAG in old-common old-watchdog old-recover old-limit old-boot; do
    SP_PATH=$(suite_path "$SP_TAG") || return 1
    if [ -f "$SP_PATH" ]; then
      SP_HASH=$(hash_file "$SP_PATH") || return 1
      suite_legacy_hash "$SP_TAG" "$SP_HASH" || { fail "unknown/custom legacy helper retained: $SP_PATH ($SP_HASH)"; return 1; }
      sh -n "$SP_PATH" || return 1
    fi
  done
  for SP_CONFIG in /etc/earnapp/watchdog.conf /etc/earnapp/maintenance.conf; do
    suite_config_valid "$SP_CONFIG" || { fail "unsupported or duplicate numeric configuration: $SP_CONFIG"; return 1; }
  done
  suite_emit_config >/dev/null || { fail 'legacy thresholds are not supported literal numbers'; return 1; }
  for SP_CRON in /etc/crontabs/*; do
    exists "$SP_CRON" || continue
    suite_regular "$SP_CRON" || return 1
    suite_cron_filter check "$SP_CRON" >/dev/null || { fail "custom EarnApp maintenance cron retained: $SP_CRON"; return 1; }
    if [ "$SP_CRON" != /etc/crontabs/root ] && grep -Eiq 'earnapp|/usr/local/sbin/(selnu|tavik|loren)' "$SP_CRON"; then
      fail "maintenance entries outside root crontab: $SP_CRON"; return 1
    fi
  done
  if command -v nft >/dev/null 2>&1; then
    SP_TABLES=$(nft list tables) || { fail 'cannot read nft tables'; return 1; }
    if printf '%s\n' "$SP_TABLES" | grep -Fxq 'table inet node_limit'; then
      fail 'old node-suite node_limit table exists; retained without modification'; return 1
    fi
    if printf '%s\n' "$SP_TABLES" | grep -Fxq 'table inet earnapp_maintenance'; then
      [ "$U_MODE" = managed ] || { fail 'unowned earnapp_maintenance table retained'; return 1; }
      suite_table_owned earnapp_maintenance earnapp earnapp-maintenance- || return 1
    fi
    if printf '%s\n' "$SP_TABLES" | grep -Fxq 'table inet earnapp_limit'; then
      suite_table_owned earnapp_limit earnapp earnapp- || return 1
    fi
  fi
  if ! discover_sdk >/dev/null 2>&1; then
    [ "$U_MODE" != managed ] || { fail 'managed SDK is missing'; return 1; }
    [ -z "$SDK_BIN" ] || ! exists "$SDK_BIN" || { fail 'SDK destination is occupied'; return 1; }
    SDK_BIN=${SDK_BIN:-/usr/bin/earnapp}; U_MODE=fresh; U_PREPARE_SOURCE=1
    exists /etc/init.d/earnapp && { fail 'source init exists without a usable SDK; retained'; return 1; }
  else
    valid_path "$SDK_BIN" || return 1
    suite_reject_sdk_copies || return 1
    if exists /etc/init.d/earnapp; then
      suite_verify_source >/dev/null || { fail 'existing EarnApp source must be statically recognized and have a verified running worker'; return 1; }
    else
      [ "$U_MODE" != managed ] || { fail 'managed source init is missing'; return 1; }
      U_MODE=prepared; U_PREPARE_SOURCE=1
    fi
  fi
  U_TARGET=$SDK_BIN
  UPDATER_MAIN_SVC=earnapp
  suite_updater_guard "$SDK_BIN" || return 1
  if [ "$U_PREPARE_SOURCE" = 1 ] && suite_has_legacy; then
    fail 'legacy helpers exist without a usable running source; retained for review'; return 1
  fi
  printf 'maintenance mode=%s program=%s service=%s\n' "$U_MODE" "$U_TARGET" "$SUITE_SERVICE"
}
suite_snapshot(){
  # Foundation may follow a vendor bootstrap. Validate before its status hook,
  # even when the source service has not yet been prepared by this suite.
  OLD_SVC=$SUITE_SERVICE
  suite_source_config_valid || return 1
  if exists "/etc/init.d/$OLD_SVC"; then
    suite_source_init_valid "/etc/init.d/$OLD_SVC" || { fail 'unknown source init retained without execution during snapshot'; return 1; }
  fi
  : > "$U_B/files.manifest"; : > "$U_B/allowed"
  mkdir "$U_B/files" || return 1
  for SS_TAG in $(suite_tags); do
    SS_PATH=$(suite_path "$SS_TAG") || return 1
    if [ -f "$SS_PATH" ]; then
      cp -p "$SS_PATH" "$U_B/files/$SS_TAG" || return 1
      SS_HASH=$(hash_file "$U_B/files/$SS_TAG") && SS_MODE=$(stat -c %a "$SS_PATH") || return 1
      printf '%s 1 %s %s\n' "$SS_TAG" "$SS_HASH" "$SS_MODE" >> "$U_B/files.manifest"
      printf '%s %s %s\n' "$SS_TAG" "$SS_HASH" "$SS_MODE" >> "$U_B/allowed"
    else
      printf '%s 0 - -\n' "$SS_TAG" >> "$U_B/files.manifest"
      printf '%s - -\n' "$SS_TAG" >> "$U_B/allowed"
    fi
  done
  for SS_SERVICE in earnapp crond local; do
    runlevels_for "$SS_SERVICE" > "$U_B/$SS_SERVICE.runlevels" || return 1
    if [ "$SS_SERVICE" = earnapp ] && ! exists /etc/init.d/earnapp; then
      printf '%s\n' 1 > "$U_B/$SS_SERVICE.status" || return 1
    else service_state "$SS_SERVICE" 6>&- 7>&- 8>&- 9>&- > "$U_B/$SS_SERVICE.status" || return 1; fi
  done
  SS_TABLES=$(nft list tables) || return 1
  for SS_TABLE in earnapp_limit earnapp_maintenance; do
    if printf '%s\n' "$SS_TABLES" | grep -Fxq "table inet $SS_TABLE"; then
      nft list table inet "$SS_TABLE" > "$U_B/$SS_TABLE.nft" || return 1
    fi
  done
  SS_PROGRAM_HASH=$(hash_file "$SDK_BIN") || return 1
  printf '%s\n' "VERSION=$SUITE_VERSION" "MODE=$U_MODE" "SOURCE=$SDK_BIN" "TARGET=$U_TARGET" "SERVICE=$SUITE_SERVICE" "HASH=$SS_PROGRAM_HASH" > "$U_B/settings" || return 1
  printf '%s\n' prepared > "$U_B/state" || return 1
  suite_seal_backup
}
suite_meta_names(){ printf '%s\n' settings files.manifest earnapp.runlevels earnapp.status crond.runlevels crond.status local.runlevels local.status earnapp_limit.nft earnapp_maintenance.nft; }
suite_seal_backup(){
  : > "$U_B/metadata"
  for SM_FILE in $(suite_meta_names); do
    if [ -f "$U_B/$SM_FILE" ]; then
      SM_HASH=$(hash_file "$U_B/$SM_FILE") || return 1
      printf '%s %s\n' "$SM_FILE" "$SM_HASH" >> "$U_B/metadata" || return 1
    else
      case "$SM_FILE" in earnapp_limit.nft|earnapp_maintenance.nft) printf '%s -\n' "$SM_FILE" >> "$U_B/metadata";; *) return 1;; esac
    fi
  done
}
suite_current_allowed(){
  SA_PATH=$(suite_path "$1") || return 1
  suite_regular "$SA_PATH" || return 1
  SA_HASH=-; SA_MODE=-
  if [ -f "$SA_PATH" ]; then SA_HASH=$(hash_file "$SA_PATH") && SA_MODE=$(stat -c %a "$SA_PATH") || return 1; fi
  grep -Fxq "$1 $SA_HASH $SA_MODE" "$U_B/allowed" || { fail "file changed during/after installation: $SA_PATH"; return 1; }
}
suite_atomic(){
  SA_DEST=$(suite_path "$1") || return 1
  suite_current_allowed "$1" || return 1
  SA_NEW_HASH=$(hash_file "$2") || return 1
  printf '%s %s %s\n' "$1" "$SA_NEW_HASH" "$3" >> "$U_B/allowed" || return 1
  mkdir -p "$(dirname "$SA_DEST")" || return 1
  SA_TEMP=$(mktemp "$(dirname "$SA_DEST")/.earnapp-maintenance-XXXXXXXX") || return 1
  if ! cp -p "$2" "$SA_TEMP" || ! chmod "$3" "$SA_TEMP" || ! mv -f "$SA_TEMP" "$SA_DEST"; then
    rm -f "$SA_TEMP"; return 1
  fi
}
suite_remove(){
  suite_current_allowed "$1" || return 1
  SD_PATH=$(suite_path "$1") || return 1
  printf '%s - -\n' "$1" >> "$U_B/allowed" || return 1
  rm -f "$SD_PATH"
}
suite_wait_helpers(){
  SW_N=0
  while :; do
    SW_BUSY=0
    for SW_PROC in /proc/[0-9]*; do
      [ -r "$SW_PROC/cmdline" ] || continue
      if tr '\000' '\n' < "$SW_PROC/cmdline" 2>/dev/null | awk '
        $0=="/usr/local/sbin/earnapp-watchdog" || $0=="/usr/local/sbin/earnapp-recover" || $0=="/usr/local/sbin/earnapp-limit" ||
        $0=="/usr/local/sbin/selnu" || $0=="/usr/local/sbin/tavik" || $0=="/usr/local/sbin/loren" {found=1}
        END{exit !found}'; then SW_BUSY=1; break; fi
    done
    [ "$SW_BUSY" = 1 ] || return 0
    [ "$SW_N" -lt 75 ] || { fail 'old helper is still running; the upgrade was cancelled'; return 1; }
    [ "$((SW_N % 15))" != 0 ] || printf '%s\n' 'Waiting for an existing helper to finish...'
    sleep 2; SW_N=$((SW_N+1))
  done
}
suite_pause(){
  printf '%s\n' '#!/bin/sh' '# Temporary EarnApp maintenance transaction pause.' 'exit 0' > "$U_D/paused"
  if [ -f "$U_B/files/cron" ]; then suite_cron_filter paused "$U_B/files/cron" > "$U_D/cron.paused" || return 1
  else : > "$U_D/cron.paused"; fi
  suite_atomic cron "$U_D/cron.paused" 600 || return 1
  # Atomic replacements also neutralize a cron command already cached before its reload.
  for SP_TAG in old-watchdog old-recover old-limit old-boot watchdog recover limit boot; do
    SP_PATH=$(suite_path "$SP_TAG") || return 1
    [ ! -f "$SP_PATH" ] || suite_atomic "$SP_TAG" "$U_D/paused" 755 || return 1
  done
  suite_wait_helpers || return 1
  exec 7>/run/earnapp-watchdog.lockfile
  flock -n 7 || { fail 'legacy helper lock is busy'; return 1; }
  exec 9>/run/earnapp-maintenance.worker.lockfile
  flock -n 9 || { fail 'new helper lock is busy'; return 1; }
}
suite_identity(){
  SI_VALUE=$(timeout -k 2 15 "$1" showid 6>&- 7>&- 8>&- 9>&- 2>/dev/null) || return 1
  printf '%s\n' "$SI_VALUE" | awk 'NR==1 && /^sdk-node-[0-9a-f]+$/ && length($0)==41{ok=1} END{exit !(ok && NR==1)}' || return 1
  printf '%s\n' "$SI_VALUE"
}
suite_verify_runtime() (
  exec 6>&-
  suite_verify_source >/dev/null || exit 1
  . /usr/local/lib/mivora.sh || exit 1
  SV_KEY=$(worker_snapshot) || { fail 'managed worker identity is not confirmed'; exit 1; }
  [ -n "$SV_KEY" ] || { fail 'managed worker is missing'; exit 1; }
  [ "$(sdk_state)" = enabled ] || { fail 'SDK is not enabled'; exit 1; }
  SV_PID=${SV_KEY%%:*}
  stats "$SV_PID" || { fail 'worker statistics could not be read'; exit 1; }
  [ "$(worker_snapshot)" = "$SV_KEY" ] || { fail 'worker changed during verification'; exit 1; }
  printf 'worker=%s tcp=%s established=%s udp=%s fd=%s rss_kb=%s\n' "$SV_KEY" "$TCP" "$ESTAB" "$UDP" "$FD" "$RSS"
  if [ "$ESTAB" -gt 0 ]; then printf '%s\n' 'CONNECTION_STATE=ESTABLISHED'
  else printf '%s\n' 'CONNECTION_STATE=PENDING'; fi
)

suite_validate_backup(){
  valid_path "$U_B" && [ -d "$U_B/files" ] && [ -f "$U_B/files.manifest" ] && [ -f "$U_B/allowed" ] && [ -f "$U_B/metadata" ] || return 1
  SV_META_SEEN=' '; SV_META_COUNT=0
  while read -r SV_META SV_DIGEST SV_EXTRA; do
    [ -z "$SV_EXTRA" ] || return 1
    suite_meta_names | grep -Fxq "$SV_META" || return 1
    case "$SV_META_SEEN" in *" $SV_META "*) return 1;; esac
    SV_META_SEEN="$SV_META_SEEN$SV_META "; SV_META_COUNT=$((SV_META_COUNT+1))
    if [ "$SV_DIGEST" = - ]; then
      case "$SV_META" in earnapp_limit.nft|earnapp_maintenance.nft) ! exists "$U_B/$SV_META" || return 1;; *) return 1;; esac
    else
      [ -f "$U_B/$SV_META" ] && [ ! -L "$U_B/$SV_META" ] && [ "$(hash_file "$U_B/$SV_META")" = "$SV_DIGEST" ] || { fail "backup metadata is missing or changed: $SV_META"; return 1; }
    fi
  done < "$U_B/metadata"
  [ "$SV_META_COUNT" = 10 ] || return 1
  for SV_SERVICE in earnapp crond local; do
    case "$(cat "$U_B/$SV_SERVICE.status")" in 0|1|3) :;; *) return 1;; esac
    while IFS= read -r SV_LEVEL; do valid_name "$SV_LEVEL" || return 1; done < "$U_B/$SV_SERVICE.runlevels" || return 1
  done
  SV_SEEN=' '; SV_COUNT=0
  while read -r SV_TAG SV_PRESENT SV_HASH SV_MODE SV_EXTRA; do
    [ -z "$SV_EXTRA" ] || return 1
    suite_path "$SV_TAG" >/dev/null || return 1
    case "$SV_SEEN" in *" $SV_TAG "*) return 1;; esac
    SV_SEEN="$SV_SEEN$SV_TAG "; SV_COUNT=$((SV_COUNT+1))
    case "$SV_PRESENT" in
      0) [ "$SV_HASH:$SV_MODE" = -:- ] || return 1;;
      1) [ -f "$U_B/files/$SV_TAG" ] && [ ! -L "$U_B/files/$SV_TAG" ] && [ "$(hash_file "$U_B/files/$SV_TAG")" = "$SV_HASH" ] || return 1
        case "$SV_MODE" in ''|*[!0-7]*) return 1;; esac;;
      *) return 1;;
    esac
  done < "$U_B/files.manifest"
  [ "$SV_COUNT" = 16 ] || return 1
  for SV_TAG in $(suite_tags); do
    # Source files are diagnostic snapshots, never maintenance rollback targets.
    case "$SV_TAG" in source-init|source-conf) continue;; esac
    suite_current_allowed "$SV_TAG" || return 1
  done
  return 0
}
suite_restore_tag(){
  SRT_ROW=$(awk -v tag="$1" '$1==tag {print}' "$U_B/files.manifest") || return 1
  set -- $SRT_ROW
  [ "$#" = 4 ] || return 1
  SRT_TAG=$1; SRT_PRESENT=$2; SRT_MODE=$4
  if [ "$SRT_PRESENT" = 1 ]; then suite_atomic "$SRT_TAG" "$U_B/files/$SRT_TAG" "$SRT_MODE"
  else suite_remove "$SRT_TAG"; fi
}
suite_validate_live_tables(){
  SRT_TABLES=$(nft list tables) || return 1
  SRT_SERVICE=$(awk -F= '$1=="SERVICE"{print $2}' "$U_B/settings") || return 1
  [ "$SRT_SERVICE" = "$SUITE_SERVICE" ] || return 1
  if printf '%s\n' "$SRT_TABLES" | grep -Fxq 'table inet earnapp_maintenance'; then
    suite_table_owned earnapp_maintenance "$SRT_SERVICE" earnapp-maintenance- || return 1
  fi
  if printf '%s\n' "$SRT_TABLES" | grep -Fxq 'table inet earnapp_limit'; then
    suite_table_owned earnapp_limit earnapp earnapp- || return 1
  fi
  return 0
}
suite_restore_transaction(){
  suite_validate_backup || { fail "suite backup/file ownership validation failed: $U_B"; return 1; }
  suite_validate_live_tables || return 1
  for SRT_TAG in $(suite_tags); do
    case "$SRT_TAG" in cron|registry|source-init|source-conf) continue;; esac
    suite_restore_tag "$SRT_TAG" || return 1
  done
  # Restore only the two owned EarnApp limiter tables; never touch Xray tables.
  : > "$U_D/restore.nft"
  SRT_TABLES=$(nft list tables) || return 1
  for SRT_TABLE in earnapp_limit earnapp_maintenance; do
    if printf '%s\n' "$SRT_TABLES" | grep -Fxq "table inet $SRT_TABLE"; then
      printf 'delete table inet %s\n' "$SRT_TABLE" >> "$U_D/restore.nft"
    fi
    [ ! -f "$U_B/$SRT_TABLE.nft" ] || cat "$U_B/$SRT_TABLE.nft" >> "$U_D/restore.nft" || return 1
  done
  if [ -s "$U_D/restore.nft" ]; then nft -c -f "$U_D/restore.nft" && nft -f "$U_D/restore.nft" || return 1; fi
  for SRT_SERVICE in crond local; do
    SRT_LEVELS=$(runlevels_for "$SRT_SERVICE") || return 1
    for SRT_LEVEL in $SRT_LEVELS; do
      grep -Fxq "$SRT_LEVEL" "$U_B/$SRT_SERVICE.runlevels" || rc-update del "$SRT_SERVICE" "$SRT_LEVEL" 6>&- 7>&- 8>&- 9>&- || return 1
    done
    while IFS= read -r SRT_LEVEL; do
      valid_name "$SRT_LEVEL" || return 1
      exists "/etc/runlevels/$SRT_LEVEL/$SRT_SERVICE" || rc-update add "$SRT_SERVICE" "$SRT_LEVEL" 6>&- 7>&- 8>&- 9>&- || return 1
    done < "$U_B/$SRT_SERVICE.runlevels"
  done
  if [ "$(cat "$U_B/crond.status")" = 3 ] && [ "$(service_state crond)" = 0 ]; then
    rc-service crond stop 6>&- 7>&- 8>&- 9>&- || return 1
  fi
  suite_restore_tag registry && suite_restore_tag cron || return 1
  printf '%s\n' rolled-back > "$U_B/state"
  printf 'SUITE_RESTORED\n%s\n' "$U_B"
}
suite_exit(){
  UE_RC=$?
  trap - 0 HUP INT TERM
  if [ "$UE_RC" -ne 0 ] && [ "$U_TX" = 1 ]; then
    printf '%s\n' 'EarnApp maintenance installation failed; restoring the recorded configuration.' >&2
    if ! suite_restore_transaction; then
      printf '%s\n' rollback-failed > "$U_B/state"
      printf 'FAIL: recovery needs review; backup retained: %s\n' "$U_B" >&2
    fi
  fi
  UE_KEEP=0
  if [ "$UE_RC" -ne 0 ]; then
    for UE_BOOT in "$U_D"/bootstrap-*; do [ ! -d "$UE_BOOT/identity" ] || UE_KEEP=1; done
    if [ -n "${U_FOUNDATION:-}" ]; then
      UE_KEEP=1
      printf 'Source preparation record retained: %s\n' "$U_FOUNDATION" >&2
    fi
  fi
  if [ "$UE_KEEP" = 1 ]; then
    printf 'Diagnostic/identity snapshot retained: %s\n' "$U_D" >&2
  else [ -z "$U_D" ] || rm -rf "$U_D"; fi
  [ "${U_DIR_LOCKED:-0}" = 0 ] || rmdir /run/earnapp-maintenance.setup.lock 2>/dev/null || true
  exit "$UE_RC"
}
cmd_suite_install() (
  suite_preflight || exit 1
  if [ "$APPLY" != 1 ]; then
    printf '%s\n' '[dry-run] install EarnApp if absent; upgrade recognized maintenance helpers, configuration, limiter and cron.'
    printf '%s\n' '[dry-run] the EarnApp program path and existing source service are retained; use install --apply.'
    exit 0
  fi
  if [ "$U_MODE" = managed ] && [ "$U_CURRENT_VERSION" = "$SUITE_VERSION" ] && cmd_suite_status >/dev/null 2>&1; then
    suite_verify_runtime || exit 1
    printf 'ALREADY_CURRENT\n%s\n' "$SUITE_VERSION"
    exit 0
  fi
  U_TX=0; U_B=; U_D=; U_DIR_LOCKED=0; U_FOUNDATION=
  umask 077
  U_D=$(mktemp -d /tmp/earnapp-maintenance-XXXXXXXX) || exit 1
  trap suite_exit 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir /run/earnapp-maintenance.setup.lock || { fail 'another maintenance operation or stale setup lock exists'; exit 1; }
  U_DIR_LOCKED=1
  for US_TOOL in bash curl timeout nft ss flock getconf; do
    if ! command -v "$US_TOOL" >/dev/null 2>&1; then
      apk add --no-cache bash wget curl ca-certificates gcompat libstdc++ libgcc coreutils openrc nftables iproute2 flock || exit 1
      break
    fi
  done
  exec 8>/run/earnapp-maintenance.lockfile
  flock -n 8 || { fail 'another EarnApp maintenance operation is running'; exit 1; }
  exec 6>/run/earnapp-setup.lockfile
  flock -n 6 || { fail 'the legacy installer is still running'; exit 1; }
  if [ "$U_MODE" = fresh ]; then
    apk add --no-cache bash wget curl ca-certificates gcompat libstdc++ libgcc coreutils openrc nftables iproute2 flock || exit 1
    suite_bootstrap 6>&- 7>&- 8>&- 9>&-; US_BOOT_RC=$?
    [ "$US_BOOT_RC" = 0 ] || exit "$US_BOOT_RC"
  fi
  U_TARGET=$SDK_BIN
  suite_reject_sdk_copies || exit 1
  UPDATER_MAIN_SVC=earnapp
  suite_updater_guard "$SDK_BIN" || exit 1
  US_TABLES=$(nft list tables) || exit 1
  if printf '%s\n' "$US_TABLES" | grep -Fxq 'table inet node_limit'; then
    fail 'old node-suite node_limit table appeared before installation; retained without modification'; exit 1
  fi
  if [ "$U_MODE" != managed ] && printf '%s\n' "$US_TABLES" | grep -Fxq 'table inet earnapp_maintenance'; then
    fail 'unowned earnapp_maintenance table appeared before installation'; exit 1
  fi
  US_ID_BEFORE=$(suite_identity "$SDK_BIN") || { fail 'cannot read the existing device identity'; exit 1; }
  if [ -s /etc/earnapp/uuid ]; then cp -p /etc/earnapp/uuid "$U_D/uuid" || exit 1; fi
  mkdir -p "$BACKUP_ROOT" || exit 1
  if [ "$U_PREPARE_SOURCE" = 1 ]; then
    U_B=$(mktemp -d "$BACKUP_ROOT/earnapp-maintenance-source-$(date -u +%Y%m%d-%H%M%S)-XXXXXXXX") || exit 1
    U_FOUNDATION=$U_B
    suite_snapshot && suite_validate_backup || exit 1
    OLD_SVC=earnapp
    suite_prepare_source 6>&- 7>&- 8>&- 9>&- || {
      fail "source preparation is incomplete; installed SDK and foundation records retained: $U_FOUNDATION"; exit 1;
    }
    [ "$SOURCE_PREPARED" = 1 ] || exit 1
    [ "$(suite_identity "$SDK_BIN")" = "$US_ID_BEFORE" ] || { fail 'device ID changed during source preparation'; exit 1; }
    [ ! -f "$U_D/uuid" ] || cmp -s "$U_D/uuid" /etc/earnapp/uuid || { fail 'device UUID changed during source preparation'; exit 1; }
    U_PREPARE_SOURCE=0
  fi
  suite_verify_source >/dev/null || exit 1
  U_B=$(mktemp -d "$BACKUP_ROOT/earnapp-maintenance-$(date -u +%Y%m%d-%H%M%S)-XXXXXXXX") || exit 1
  suite_snapshot || exit 1
  [ -z "$U_FOUNDATION" ] || printf '%s\n' "$U_FOUNDATION" > "$U_B/source-foundation.ref" || exit 1
  suite_emit_config > "$U_D/config" || exit 1
  mkdir "$U_D/staged" || exit 1
  US_PROGRAM_HASH=$(hash_file "$SDK_BIN") || exit 1
  suite_stage_helpers "$U_D/staged" "$SDK_BIN" "$SUITE_SERVICE" "$US_PROGRAM_HASH" || exit 1
  for US_FILE in common watchdog recover limit boot; do sh -n "$U_D/staged/$US_FILE" || exit 1; done
  suite_validate_backup || { fail 'maintenance backup validation failed before installation'; exit 1; }
  U_TX=1
  printf 'EarnApp maintenance backup: %s\n' "$U_B"
  suite_pause || exit 1
  : > "$U_B/owned"
  for US_TAG in common watchdog recover limit boot; do
    US_MODE=755; [ "$US_TAG" != common ] || US_MODE=644
    suite_atomic "$US_TAG" "$U_D/staged/$US_TAG" "$US_MODE" || exit 1
    US_HELPER_HASH=$(hash_file "$U_D/staged/$US_TAG") || exit 1
    printf '%s %s\n' "$US_TAG" "$US_HELPER_HASH" >> "$U_B/owned" || exit 1
  done
  suite_atomic config "$U_D/config" 600 || exit 1
  suite_verify_runtime || exit 1
  /usr/local/sbin/loren --locked 20 6>&- || { fail 'EarnApp limiter verification failed'; exit 1; }
  suite_verify_runtime || exit 1
  US_ID_AFTER=$(suite_identity "$SDK_BIN") || exit 1
  [ "$US_ID_AFTER" = "$US_ID_BEFORE" ] || { fail 'device ID changed'; exit 1; }
  [ ! -f "$U_D/uuid" ] || cmp -s "$U_D/uuid" /etc/earnapp/uuid || { fail 'device UUID changed'; exit 1; }
  if printf '%s\n' "$US_TABLES" | grep -Fxq 'table inet earnapp_limit'; then
    suite_table_owned earnapp_limit earnapp earnapp- || exit 1
    nft delete table inet earnapp_limit || exit 1
  fi
  for US_TAG in old-common old-watchdog old-recover old-limit old-boot old-config; do suite_remove "$US_TAG" || exit 1; done
  cp "$U_D/cron.paused" "$U_D/cron.final" || exit 1
  if [ -f "$U_B/files/cron" ] && grep -Eq '# (EARNAPP-12H-STOPSTART|EARNAPP-MAINT-RECOVERY)$' "$U_B/files/cron"; then
    printf '%s\n' '0 */12 * * * /usr/local/sbin/tavik scheduled >/dev/null 2>&1 # EARNAPP-MAINT-RECOVERY' >> "$U_D/cron.final"
  fi
  printf '%s\n' '*/2 * * * * /usr/local/sbin/selnu >/dev/null 2>&1 # EARNAPP-MAINT-WATCHDOG' >> "$U_D/cron.final"
  rc-update add crond default 6>&- 7>&- 8>&- 9>&- && rc-update add local default 6>&- 7>&- 8>&- 9>&- || exit 1
  [ "$(service_state crond)" = 0 ] || rc-service crond start 6>&- 7>&- 8>&- 9>&- || exit 1
  suite_atomic cron "$U_D/cron.final" 600 || exit 1
  printf '%s\n' "$U_B" > "$U_D/registry"
  suite_atomic registry "$U_D/registry" 600 || exit 1
  suite_check_owned "$U_B" && suite_verify_runtime || exit 1
  printf '%s\n' active > "$U_B/state" || exit 1
  U_TX=0
  printf 'INSTALL_STATE=COMPLETE\nVERSION=%s\nSERVICE=%s\nPROGRAM=%s\nDEVICE_ID=%s\nBACKUP=%s\n' "$SUITE_VERSION" "$SUITE_SERVICE" "$SDK_BIN" "$US_ID_AFTER" "$U_B"
  printf '%s\n' 'EarnApp watchdog: every 2 minutes. EarnApp connection limit: 20 flows.' 'Effective numeric overrides:'
  cat /etc/earnapp/maintenance.conf
)
cmd_suite_status() (
  suite_read_current || { fail 'no verified active EarnApp maintenance installation'; exit 1; }
  SDK_BIN=$U_TARGET
  printf 'VERSION=%s\nSERVICE=%s\nPROGRAM=%s\nBACKUP=%s\n' "$U_CURRENT_VERSION" "$U_SERVICE" "$U_TARGET" "$U_PREVIOUS"
  suite_verify_runtime || exit 1
  suite_table_owned earnapp_maintenance "$U_SERVICE" earnapp-maintenance- || exit 1
  [ -f /etc/crontabs/root ] && grep -Fxq '*/2 * * * * /usr/local/sbin/selnu >/dev/null 2>&1 # EARNAPP-MAINT-WATCHDOG' /etc/crontabs/root || { fail 'watchdog schedule is missing'; exit 1; }
  [ "$(service_state crond)" = 0 ] || { fail 'cron daemon is not running'; exit 1; }
  exists /etc/runlevels/default/crond && exists /etc/runlevels/default/local || { fail 'cron/limiter boot activation is missing'; exit 1; }
  printf '%s\n' 'PASS: helper files, worker, limiter and schedule are present.'
)
cmd_suite_restore() (
  require_root || exit 1
  if [ -n "$BACKUP_DIR" ]; then U_B=$BACKUP_DIR
  else U_B=$(cat "$SUITE_REGISTRY" 2>/dev/null) || { fail 'set BACKUP_DIR to an exact suite backup'; exit 1; }; fi
  suite_validate_backup || { fail 'backup validation failed'; exit 1; }
  [ "$(cat "$U_B/state")" != rolled-back ] || { printf '%s\n' 'Already restored.'; exit 0; }
  suite_validate_live_tables || exit 1
  if [ "$APPLY" != 1 ]; then printf '[dry-run] restore maintenance helpers, cron, owned rules and support-service activation using %s\n' "$U_B"; exit 0; fi
  U_D=$(mktemp -d /tmp/earnapp-maintenance-restore-XXXXXXXX) || exit 1
  U_RESTORE_PHASE=prepare
  trap 'SRC=$?; trap - 0; if [ "$SRC" -ne 0 ] && [ "$U_RESTORE_PHASE" = quiesce ]; then suite_resume_pause || printf "FAIL: paused entry restoration needs review: %s\n" "$U_D" >&2; fi; if [ "$SRC" = 0 ]; then rm -rf "$U_D"; else printf "Restore diagnostic files retained: %s\n" "$U_D" >&2; fi; exit "$SRC"' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  exec 8>/run/earnapp-maintenance.lockfile
  flock -n 8 || { fail 'another suite operation is running'; exit 1; }
  exec 6>/run/earnapp-setup.lockfile
  flock -n 6 || { fail 'the legacy installer is still running'; exit 1; }
  suite_save_pause || exit 1
  U_RESTORE_PHASE=quiesce
  suite_pause || exit 1
  U_RESTORE_PHASE=restore
  suite_restore_transaction || { printf '%s\n' rollback-failed > "$U_B/state"; exit 1; }
)
suite_save_pause(){
  mkdir "$U_D/resume" || return 1
  : > "$U_D/resume.manifest"
  for SRP_TAG in cron old-watchdog old-recover old-limit old-boot watchdog recover limit boot; do
    SRP_PATH=$(suite_path "$SRP_TAG") || return 1
    suite_current_allowed "$SRP_TAG" || return 1
    if [ -f "$SRP_PATH" ]; then
      cp -p "$SRP_PATH" "$U_D/resume/$SRP_TAG" || return 1
      printf '%s %s\n' "$SRP_TAG" "$(stat -c %a "$SRP_PATH")" >> "$U_D/resume.manifest"
    fi
  done
}
suite_resume_pause(){
  while read -r SRP_TAG SRP_MODE; do
    suite_atomic "$SRP_TAG" "$U_D/resume/$SRP_TAG" "$SRP_MODE" || return 1
  done < "$U_D/resume.manifest"
}

usage(){
  printf 'usage: sh %s <install|precheck|status|restore|names> [--apply]\n' "$0"
  printf '%s\n' 'EarnApp keeps its actual service name and program path.'
  printf '%s\n' 'install --apply installs if absent or upgrades recognized auxiliary scripts.'
  printf '%s\n' 'precheck is read-only; status verifies the active maintenance installation.'
  printf '%s\n' 'restore --apply restores the recorded auxiliary configuration.'
  printf '%s\n' 'Vendor installation/source preparation is retained as a separate foundation.'
  printf '%s\n' 'BACKUP_DIR selects an exact maintenance backup; BACKUP_ROOT sets its parent.'
  printf '%s\n' 'Configuration: /etc/earnapp/maintenance.conf; log: /var/log/earnapp-maintenance.log'
}
cmd_names(){
  printf 'APPLICATION=EarnApp\nSERVICE=earnapp\n'
  for MN_ROLE in common watchdog recover limit boot config registry; do
    printf '%s=%s\n' "$MN_ROLE" "$(suite_path "$MN_ROLE")" || return 1
  done
  printf '%s\n' 'log=/var/log/earnapp-maintenance.log'
}
case "$CMD" in
  install|upgrade|setup) cmd_suite_install;;
  precheck) suite_preflight;;
  status) cmd_suite_status;;
  restore) cmd_suite_restore;;
  names) cmd_names;;
  -h|--help|help) usage;;
  *) usage; exit 1;;
esac
MAINT_RC=$?
[ "$MAINT_RC" = 0 ] || exit "$MAINT_RC"
case "$CMD:$APPLY" in
  install:0|upgrade:0|setup:0|restore:0|precheck:*) printf '%s\n' '== SUCCESS (read-only) ==';;
  *) printf '%s\n' '== SUCCESS ==';;
esac
exit 0
