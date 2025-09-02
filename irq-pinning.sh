#!/bin/bash
# Auto pick cool CPU pool per NIC, then round-robin per-IRQ within that pool.
# Usage:
#   sudo ./irq-pinning.sh
#   IFACES="wlo1 enp108s0" sudo ./irq-pinning.sh
#   PER_NIC_CORES_WIFI=2 PER_NIC_CORES_ETH=4 sudo ./irq-pinning.sh
#   PIN="14,15" sudo ./irq-pinning.sh   # force all NICs to fixed CPU (bypass auto)

set -euo pipefail

: "${IFACES:=}"                # empty = auto NIC active
: "${PER_NIC_CORES_WIFI:=2}"   # pool size Wi-Fi (1-2 recommended)
: "${PER_NIC_CORES_ETH:=4}"    # pool size Ethernet (2-4 recommended)
: "${START_CORE:=1}"           # fallback if scoring fails
PIN="${PIN-}"                  # if set, override all NIC

[[ $EUID -ne 0 ]] && { echo "run as root"; exit 1; }

expand() { awk -F, '
function add(a,b){for(i=a;i<=b;i++)print i}
{ for(j=1;j<=NF;j++){ if($j~/^[0-9]+-[0-9]+$/){split($j,r,"-"); add(r[1],r[2])} else print $j } }'; }

get_nics() {
  if [[ -n "$IFACES" ]]; then echo "$IFACES"; return; fi
  ip -br link | awk '$1!="lo" && ($2 ~ /UP|UNKNOWN/){print $1}'
}

get_kind() {  # WiFi / ETH / OTHER
  local ifc="$1"
  if [[ -e "/sys/class/net/$ifc/wireless" ]] || iw dev "$ifc" info >/dev/null 2>&1; then
    echo WIFI; return
  fi
  echo ETH
}

get_irqs_for_iface() {
  local ifc="$1"; local -a irqs=()
  mapfile -t irqs < <(grep -E "[[:space:]]${ifc}(:|[[:space:]]|$)" /proc/interrupts \
                      | awk -F: '{gsub(/^[ \t]+/,"",$1); print $1}')
  if [[ ${#irqs[@]} -eq 0 && -e "/sys/class/net/${ifc}/device/driver" ]]; then
    local drv; drv=$(basename "$(readlink -f /sys/class/net/${ifc}/device/driver)")
    mapfile -t irqs < <(grep -E "[[:space:]]${drv}(:|[[:space:]]|$)" /proc/interrupts \
                        | awk -F: '{gsub(/^[ \t]+/,"",$1); print $1}')
  fi
  printf "%s\n" "${irqs[@]}" | sort -n | uniq
}

pick_pool() { # arg: need_count -> print cpu list "a,b,c"
  local need="${1:-2}" total; total=$(nproc)
  declare -a score; for ((c=0;c<total;c++)); do score[$c]=0; done
  # add score from i915/nvidia/amdgpu + LOC (bigger = more avoidable)
  while read -r line; do
    vals=($line); off=0
    for ((i=0;i<${#vals[@]};i++)); do [[ ${vals[$i]} =~ ^[0-9]+$ ]] && { off=$i; break; }; done
    for ((i=0;i<total;i++)); do v=${vals[$((off+i))]:-0}; [[ $v =~ ^[0-9]+$ ]] || v=0; score[$i]=$((score[$i]+v)); done
  done < <(grep -E '^[[:space:]]*([0-9]+:.*( i915$| nvidia$| amdgpu$)|LOC:)' /proc/interrupts)
  # avoid hard CPU0
  score[0]=$((score[0]+10**9))
  # select lowest N cpu
  local sel
  sel=$(for ((i=0;i<total;i++)); do echo "${score[$i]} $i"; done | sort -n | awk -v N="$need" 'NR<=N{printf("%s%s",$2,(NR<N?",":""))}')
  [[ -z "$sel" ]] && sel="$START_CORE"
  echo "$sel"
}

apply_rr_in_pool() { # args: ifc, cpulist
  local ifc="$1" cpulist="$2"; local -a pool; local psize=0
  readarray -t pool < <(printf "%s\n" "$cpulist" | expand)
  psize=${#pool[@]}
  [[ $psize -eq 0 ]] && return 1
  local idx=0 ok=0

  while read -r irq; do
    [[ -z "$irq" ]] && continue
    local line ints
    line=$(grep -E "^[[:space:]]*$irq:" /proc/interrupts || true)
    [[ -z "$line" ]] && continue
    ints=$(echo "$line" | awk '{sum=0; for(i=2;i<=NF-1;i++) if($i~/^[0-9]+$/) sum+=$i; print sum+0}')
    [[ "$ints" -eq 0 ]] && continue

    local cpu=${pool[$((idx%psize))]}
    local list="/proc/irq/$irq/smp_affinity_list"
    local aff="/proc/irq/$irq/smp_affinity"

    if [[ -w "$list" ]]; then
      echo "$cpu" > "$list" && echo "  IRQ $irq -> CPU $cpu (list OK)" && ok=1
    elif [[ -w "$aff" ]]; then
      # to_hexmask
      local word=$((cpu/32)); local bit=$((cpu%32)); local -a words; for ((i=0;i<=word;i++)); do words[i]=0; done
      words[$word]=$((1<<bit)); local hex=""
      for ((i=${#words[@]}-1;i>=0;i--)); do hex+="${hex:+,}$(printf "%x" "${words[i]}")"; done
      echo "$hex" > "$aff" && echo "  IRQ $irq -> CPU $cpu (mask 0x$hex)" && ok=1
    else
      echo "  IRQ $irq -> no writable affinity"
    fi
    ((idx++))
  done < <(get_irqs_for_iface "$ifc")

  [[ $ok -eq 1 ]]
}

# --- main ---
mapfile -t nics < <(get_nics)
[[ ${#nics[@]} -eq 0 ]] && { echo "no active NICs"; exit 0; }

echo "[*] target NICs: ${nics[*]}"

# Fixed PIN? Apply all NICs to the PIN directly (no auto-setup)
if [[ -n "$PIN" ]]; then
  for ifc in "${nics[@]}"; do
    echo "[NIC $ifc] fixed PIN $PIN"
    apply_rr_in_pool "$ifc" "$PIN" || echo "  (no IRQs or not writable)"
  done
  echo "[*] done (manual PIN)"; exit 0
fi

# Auto per-NIC
for ifc in "${nics[@]}"; do
  kind=$(get_kind "$ifc")
  need=$PER_NIC_CORES_ETH
  [[ "$kind" == WIFI ]] && need=$PER_NIC_CORES_WIFI
  pool=$(pick_pool "$need")
  echo "[NIC $ifc] kind=$kind pool=$pool"
  apply_rr_in_pool "$ifc" "$pool" || echo "  (no IRQs or not writable)"
done

echo "[*] done (hybrid)"
