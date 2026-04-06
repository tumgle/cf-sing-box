# Vmess/Vless-WS CDN 优选部署

基于 `sing-box`、Cloudflare Tunnel 和 `Caddy` 的一键部署脚本，用来生成 `Vmess/Vless + WebSocket` 节点及多客户端订阅。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/tumgle/cf-sing-box/master/install.sh -o install.sh && chmod +x install.sh && bash install.sh
```

## 功能概览

- 安装 `sing-box`
- 配置 `Vmess + WS` 节点
- 配置 `Vless + WS` 节点
- 支持 `Vmess + WS` 与 `Vless + WS` 双节点共存
- 可选接入并复用同一个 `CF Tunnel`
- 每个节点独立保存自己的 `优选域名/IP` 与 `Host`
- 设置节点时 `Host` 为必填，不使用回车默认值
- 启用 `CF Tunnel` 时：
  - `Host` 仍按每个节点单独保存
  - `SNI/servername` 与输入的 `Host` 保持一致
- 生成 `Base64`、`Clash/Mihomo`、`Sing-box` 订阅文件
- 可选使用 `Caddy` 提供 HTTPS 在线订阅
- 端口输入自动校验 `1-65535`

## 运行环境

- Linux 服务器
- `systemd`
- `root` 权限
- 系统中建议具备 `curl`、`jq`、`ss`、`shuf`

## 仓库文件

| 文件 | 说明 |
|---|---|
| `install.sh` | 主部署脚本 |
| `Caddyfile` | Caddy 配置示例模板 |
| `auto-sync.service` | 预留的 systemd 服务样例，当前脚本不会自动安装它 |

## 菜单说明

| 选项 | 功能 |
|---|---|
| `1` | 安装 `sing-box` |
| `2` | 设置 vmess 节点 |
| `3` | 设置 vless 节点 |
| `4` | 修改节点配置（会先选择 vmess 或 vless） |
| `5` | 查看节点信息 |
| `6` | 查看订阅链接 |
| `7` | 查看服务状态 |
| `8` | 重启服务 |
| `9` | 卸载 |
| `10` | 配置 HTTPS 订阅（Caddy） |
| `0` | 退出 |

## 推荐执行顺序

`1 安装` → `2 设置 vmess 节点` → `3 设置 vless 节点`（可选，共存）→ `10 配置 Caddy HTTPS 在线订阅`

## CF Tunnel 使用说明

### 两个节点都走同一个 CF Tunnel

推荐操作：

1. 第一次设置节点时，选择：
   - `是否安装 CF Tunnel？` → `y`
   - 按提示完成 Tunnel 配置
2. 后续再新增第二个节点时，仍然选择：
   - `是否安装 CF Tunnel？` → `y`
   - 如果脚本检测到已有 Tunnel，再选择：
     - `是否重新配置？` → `n`

这样脚本会：
- 复用已有 Tunnel
- 不重复创建 Tunnel
- 让两个节点都按 CF Tunnel 模式正常下发订阅
- 在这种模式下：
  - 节点自己的 `Host` 可以各自不同
  - `SNI/servername` 与各自节点的 `Host` 一致

### 如果后续节点不想走 CF Tunnel

那就在设置节点时选择：

- `是否安装 CF Tunnel？` → `n`

脚本会按非 Tunnel 模式生成节点。

## 订阅输出

脚本会将订阅文件生成到 `/etc/s-box/sub/`：

- `base64.txt`：Base64 编码后的通用订阅
- `links.txt`：原始分享链接明文列表
- `clash.yaml`
- `mihomo.yaml`
- `singbox.json`
- `outbounds.json`

如果同时配置了 `vmess` 和 `vless`，这些订阅文件会同时包含两个节点。

## 在线订阅地址

- 通用：`https://你的订阅域名`
- Base64：`https://你的订阅域名?type=base64`
- Clash/Mihomo：`https://你的订阅域名?type=clash`
- Sing-box：`https://你的订阅域名?type=singbox`

## 说明

- 单脚本部署方案，核心逻辑集中在 `install.sh`
- 在线订阅由 `Caddy` 静态分发，不依赖 Python
- `4 节点修改` 会先让你选择要操作 `vmess` 还是 `vless`
- `5 查看节点` 会同时显示当前已配置的所有节点
- 删除最后一个节点时，会自动清理本地节点配置、订阅文件与相关残留状态
- 删除节点前会显示当前节点的协议、端口与 Host 供确认
- 脚本会自动重建 `/etc/s-box/nodes` 等运行目录，避免卸载后再次设置时报错
