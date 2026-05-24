# VPS TCP Autotune

Auto TCP tuning script for overseas VPS accessed from mainland China.

## Usage

Make sure you check the script before executing!!!
```bash
curl -fsSL URL | sudo bash
```


Preview only:

```bash
curl -fsSL https://raw.githubusercontent.com/yourname/vps-tcp-autotune/main/vps-tcp-autotune.sh -o /tmp/vps-tcp-autotune.sh
chmod +x /tmp/vps-tcp-autotune.sh
sudo /tmp/vps-tcp-autotune.sh --dry-run
```

For normal website / SSH / Docker server:
```bash
sudo /tmp/vps-tcp-autotune.sh --no-forward
```

For proxy / VPN / forwarding node:
```bash
sudo /tmp/vps-tcp-autotune.sh --forward
```

For transparent proxy / TProxy gateway:
```bash
sudo /tmp/vps-tcp-autotune.sh --tproxy --forward
```

