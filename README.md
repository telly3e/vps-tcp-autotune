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

## 自动判断逻辑
```
RTT <= 80ms：
  亚太优质线路倾向，使用 32MB buffer

RTT 81-180ms：
  中等跨境 RTT，使用 64MB buffer

RTT > 180ms：
  欧美或绕路线路
  如果内存 >= 2GB 且端口 >= 1Gbps，使用 128MB
  否则使用 64MB

内存 < 768MB：
  降到 16MB

端口 <= 100Mbps：
  通常不使用超大 buffer

OpenVZ / LXC / Docker：
  更保守，避免 sysctl 报错或浪费资源
```
