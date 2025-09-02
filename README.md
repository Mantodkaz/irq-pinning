# IRQ Pinning

Auto IRQ CPU pinning script for Linux NICs (Ethernet & Wi-Fi).  
Useful for reducing latency, CPU cache misses, and improving throughput

---

## Features
- Detects active NICs automatically (both LAN & Wi-Fi).
- Picks least-loaded CPU cores as IRQ affinity pool.
- Round-robin assignment across available cores.
- Supports manual overrides with environment variables.
- One-shot script, can be hooked into `systemd` for persistence.

---

## Usage

### Run manually
```
chmod +x irq-pinning.sh
sudo ./irq-pinning.sh
````

### Options

* `IFACE=wlo1 sudo ./irq-pinning.sh` -> pin specific interface only
* `PIN="3,11" sudo ./irq-pinning.sh` -> force fixed CPUs for all NIC IRQs
* `PER_NIC_CORES_WIFI=2 PER_NIC_CORES_ETH=4 sudo ./irq-pinning.sh` -> adjust pool size

---

## Systemd Setup (Persistent)

1. Install script to `/usr/local/bin`:
```
sudo install -m755 irq-pinning.sh /usr/local/bin/irq-pinning.sh
```

2. Create unit file:
```
sudo nano /etc/systemd/system/irq-pinning.service
```

Paste:

```ini
[Unit]
Description=IRQ CPU Pinning
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/irq-pinning.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

3. Reload & enable service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable irq-pinning.service
sudo systemctl start irq-pinning.service
```

4. Check status:

```
systemctl status irq-pinning.service
```

Now the script will automatically run at boot.

---

## Verify

Check IRQ affinity:
```bash
grep -H . /proc/irq/*/smp_affinity_list
```

And monitor distribution:
```
watch -n1 "grep -H . /proc/softirqs | sed -n '1p;/NET_[RT]X/p'"
```

---

## Notes
* Requires root (`sudo`).
* Disable irqbalance service for best results (`systemctl stop irqbalance`)
* For persistent setup, run via systemd service (see [irq-pinning.service](https://github.com/Mantodkaz/irq-pinning?tab=readme-ov-file#systemd-setup-persistent))
* Best for **bare metal servers** (`VPS hypervisors may block affinity changes`)
* Works well high throughput NICs, and gaming/streaming rigs
* Combine with `BBR` or custom sysctl tuning for maximum performance

---


