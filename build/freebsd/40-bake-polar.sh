#!/bin/bash
# Bake the polar-cloud golden image: boot the base FreeBSD-VZ image with polar-vmd,
# install polar-agent (freebsd/arm64) + rc.d polar_agent/polar_seed over ssh, power
# off cleanly, and emit <OUT> (+ .sha256). Runs on the .89 box.
#
#   BASE=/Volumes/cross-buld/freebsd-vm/freebsd-vz.raw \
#   AGENT=/path/to/polar-agent.freebsd-arm64 \
#   OUT=/Volumes/cross-buld/freebsd-vm/freebsd-vz-polar.raw \
#   VMD=~/github/polar-cloud/cmd/polar-vmd/polar-vmd \
#   build/freebsd/40-bake-polar.sh
set -euo pipefail
BASE="${BASE:-/Volumes/cross-buld/freebsd-vm/freebsd-vz.raw}"
KEY="${KEY:-/Volumes/cross-buld/freebsd-vm/fbsd_key}"
AGENT="${AGENT:?path to polar-agent freebsd/arm64 binary}"
OUT="${OUT:-$(dirname "$BASE")/freebsd-vz-polar.raw}"
VMD="${VMD:-$HOME/github/polar-cloud/cmd/polar-vmd/polar-vmd}"
HERE="$(cd "$(dirname "$0")" && pwd)"
W="/Volumes/cross-buld/vms/bake-$$"
SSH="ssh -i $KEY -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCP="scp -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

st() { "$VMD" status --dir "$W"; }
guest_ip() { local mac; mac=$(python3 -c "import json;print(json.load(open('$W/config.json'))['mac'])" | sed 's/^0//;s/:0/:/g')
  grep -B1 -A2 ip_address /var/db/dhcpd_leases | grep -B1 "hw_address=1,$mac" | grep ip_address | head -1 | cut -d= -f2; }

echo "== create work VM from $BASE"
"$VMD" create --dir "$W" --image "$BASE" --disk-size 8G >/dev/null
"$VMD" run --dir "$W" --detach >/dev/null
for i in $(seq 1 60); do st | grep -q '"state":"running"' && break; sleep 2; done
sleep 6; IP=$(guest_ip); echo "guest IP=$IP"
[ -n "$IP" ] || { echo "no guest IP"; exit 1; }

echo "== install polar-agent + rc.d"
$SSH root@"$IP" 'mkdir -p /usr/local/bin /usr/local/sbin /usr/local/etc/rc.d'
$SCP "$AGENT" root@"$IP":/usr/local/bin/polar-agent
$SCP "$HERE/polar/polar_agent" "$HERE/polar/polar_seed" "$HERE/polar/polar_wg" root@"$IP":/usr/local/etc/rc.d/
$SCP "$HERE/polar/polar_wg_heartbeat" root@"$IP":/usr/local/sbin/polar-wg-heartbeat
echo "== pkg: wireguard-tools curl jq (overlay join; needs NAT internet in the bake VM)"
# pkg.FreeBSD.org (Fastly) is throttled to KB/s from here → go through the LAN
# HTTP proxy (zen). PKG_PROXY="" to go direct. Bake-time only; not baked in.
PKG_PROXY="${PKG_PROXY-http://192.168.11.57:10082}"
$SSH root@"$IP" "export HTTP_PROXY='$PKG_PROXY' HTTPS_PROXY='$PKG_PROXY' http_proxy='$PKG_PROXY' https_proxy='$PKG_PROXY' ASSUME_ALWAYS_YES=yes IGNORE_OSVERSION=yes; rm -f /usr/local/etc/pkg/repos/FreeBSD.conf; pkg bootstrap -f 2>&1 | tail -2; pkg install -y wireguard-tools curl jq 2>&1 | tail -3 && for b in wg wg-quick curl jq; do command -v \$b; done"
$SSH root@"$IP" '
set -e
chmod 0755 /usr/local/bin/polar-agent
chmod 0555 /usr/local/etc/rc.d/polar_agent /usr/local/etc/rc.d/polar_seed /usr/local/etc/rc.d/polar_wg /usr/local/sbin/polar-wg-heartbeat
sysrc -q polar_seed_enable=YES polar_agent_enable=YES polar_wg_enable=YES
# overlay heartbeat every minute (no-op until wg.json exists)
( crontab -l 2>/dev/null | grep -v polar-wg-heartbeat; echo "* * * * * /usr/local/sbin/polar-wg-heartbeat" ) | crontab -
rm -f /usr/local/etc/wireguard/wg0.conf /usr/local/etc/wireguard/wg0.key /root/.polar/wg.json 2>/dev/null
mkdir -p /root/.polar
/usr/local/bin/polar-agent --help >/dev/null 2>&1 || /usr/local/bin/polar-agent 2>&1 | head -3 || true
# growfs(rc) is KEYWORD: firstboot — it only runs when /firstboot exists. Repair the backup GPT
# header now and arm firstboot so every clone grows / to its disk size on first boot.
gpart recover vtbd0 || true
gpart show vtbd0 | head -5
touch /firstboot
# clear any stale identity so every clone registers fresh
rm -f /root/.polar/agent.toml /etc/ssh/ssh_host_*_key* 2>/dev/null; sysrc -q sshd_enable=YES
# /etc/hostid must be per-clone (polar-agent machine_uuid falls back to it) → regenerate at boot
rm -f /etc/hostid /etc/machine-id 2>/dev/null; sysrc -q hostid_enable=YES
: > /var/log/polar-seed.log
sync
# power off from inside this same session (ssh host keys are gone now, so no second login)
nohup sh -c "sleep 1; shutdown -p now" >/dev/null 2>&1 &
'
echo "== waiting for guest poweroff"
for i in $(seq 1 60); do st | grep -q '"alive":false' && break; sleep 2; done
grep -q '"stop_mode" : "guest"' "$W/state.json" || { echo "ERROR: not a clean guest poweroff — not emitting image"; cat "$W/state.json"; "$VMD" destroy --dir "$W" --force >/dev/null; exit 1; }

echo "== emit $OUT"
rm -f "$OUT"; cp -c "$W/disk.raw" "$OUT" 2>/dev/null || cp "$W/disk.raw" "$OUT"
shasum -a 256 "$OUT" | tee "$OUT.sha256"
"$VMD" destroy --dir "$W" >/dev/null
echo "BAKED $OUT"
