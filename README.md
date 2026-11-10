# halvo-node — 代理节点应用（Halvo / Docker）

单容器节点，专为 Halvo（halvo.nubcoders.com）免费档 **FreeCore（0.25 vCPU / 256MB 内存）**
设计：镜像 = Alpine + busybox + 三个官方静态二进制（构建时下载好，运行时零下载），
总内存目标 < 200MB。

## 架构

```
客户端 → cf.877774.xyz:443 (优选域名, TLS, SNI/Host = 隧道域名)
       → Cloudflare 固定隧道 → 容器内 cloudflared
       → sing-box VLESS+WS  127.0.0.1:18001
平台子域名 appname.nubcoders.com → 容器 $PORT (默认 3000)
       → busybox httpd: /health 与 /<SUB_PATH> 订阅（平台探活/回源用，节点本身不走这里）
哪吒 agent → 旧面板 nezha2026.5785787.xyz:443
```

- `entrypoint.sh` 是 PID 1 守护脚本：httpd、sing-box、cloudflared、nezha-agent
  各自跑在独立的自动重启循环里，任一崩溃 5 秒后拉起，不拖垮其他服务。
- 所有密钥只从环境变量读；镜像和代码里没有任何 UUID、token、secret，
  也没有 TG token/chat id（TG 通知由平台外发送，不进应用）。

## 部署步骤

1. 把本目录推到一个 GitHub 仓库（根目录必须有 `Dockerfile`，已 EXPOSE 3000）。
2. Halvo 面板 → New App → Import from GitHub → 选该仓库。
3. 规格选 **FreeCore**（0.25 vCPU / 256MB；每账号同时只能跑 1 个免费应用）。
4. 在应用的 Environment 里设下表环境变量（必填的先设好再启动）。
5. 启动后验证：
   - `https://<appname>.nubcoders.com/health` → `ok`
   - `https://<appname>.nubcoders.com/<SUB_PATH>` → 一串 base64（解开是本节点链接）
   - 隧道侧：`https://<NODE_HOST>/<WS_PATH>` 带 WS 升级头应回 101。

## 环境变量清单

| 变量 | 必填 | 说明 |
|---|---|---|
| `VLESS_UUID` | 是 | 节点 UUID（新生成一个，勿与别的节点共用） |
| `WS_PATH` | 是 | WS 路径，如 `/halvo-xxxx`（自己定，链接与配置共用此值） |
| `NODE_HOST` | 是 | 固定隧道域名（SNI / WS Host），如 `halvo.fengco.tech` |
| `CF_TUNNEL_TOKEN` | 是 | Cloudflare 固定隧道 token（只存面板 env，勿写进仓库） |
| `NZ_CLIENT_SECRET` | 是 | 哪吒面板客户端密钥（只存面板 env） |
| `NZ_UUID` | 是 | 哪吒探针 UUID（新生成、固定不变） |
| `NODE_ADDR` | 否 | 连接地址，默认 `cf.877774.xyz`（优选域名） |
| `NODE_PORT` | 否 | 连接端口，默认 `443` |
| `NODE_NAME` | 否 | 链接备注名，默认 `halvo-node` |
| `SUB_PATH` | 否 | 订阅路径，默认 `sub`（服务在平台子域名 /<SUB_PATH>） |
| `NZ_SERVER` | 否 | 哪吒面板地址，默认 `nezha2026.5785787.xyz:443` |
| `NZ_TLS` | 否 | 默认 `true` |
| `PORT` | 否 | 平台注入，默认 `3000`，不要手动改 |

未设 `CF_TUNNEL_TOKEN` / `NZ_CLIENT_SECRET` 时对应组件自动跳过（打日志），
HTTP 服务与 sing-box 照常运行。

## 固定隧道（Cloudflare 侧，部署前备好）

- 隧道 ingress：`NODE_HOST` → `http://localhost:18001`；
  另给订阅单独子域名 → `http://localhost:3000` 的话，把 `SUB_PATH` 保持默认即可
  （订阅也可直接走平台子域名，二选一）。

## 本地自检（无 Docker 时的等效验证）

```sh
sh -n entrypoint.sh                                   # 语法
HALVO_CONFIG_ONLY=1 VLESS_UUID=<uuid> WS_PATH=/test \
  NZ_CLIENT_SECRET=dummy NZ_UUID=<uuid> sh entrypoint.sh   # 只生成配置
sing-box check -c run/sing-box.json                   # 官方校验（需本机有 sing-box）
base64 -d www/sub                                     # 应解出一条 vless:// 链接
```

## 内存预算（256MB 上限内的估算）

| 进程 | 约 RSS |
|---|---|
| busybox httpd | ~1–2 MB |
| sing-box（单 WS 入站） | ~55 MB（本机实测，1.14.4 空载启动） |
| cloudflared（4 条 http2 连接） | ~30–45 MB（舰队同版本经验值） |
| nezha-agent | ~17 MB（本机实测，v2.4.0） |
| 守护 shell + 系统开销 | ~5 MB |
| **合计** | **~110–150 MB**（< 200MB 目标，256MB 上限内） |
