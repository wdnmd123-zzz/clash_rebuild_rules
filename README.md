# clash_rebuild_rules

用 [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) 在线规则集整套重建 **Clash Verge (Rev)** 所有远程订阅的分流规则，同时支持在界面 **「右键订阅 → 编辑规则」** 中直接查看与微调。

## 功能特点

- **原生可视化编辑**：将配置拆分为 **Merge 增强**（仅提供 `rule-providers`，不触碰 `rules` 和 `dns`，避免覆盖面板或与 Clash Verge 的 DNS 覆盖冲突）与 **Rules 增强**（写入 `prepend` 前置规则并用 `delete` 屏蔽机场原规则），右键订阅点击「编辑规则」即可直接看到全部生效规则并随时增删改。
- **规则集每日自动更新**：基于 Mihomo / Clash 原生 `rule-providers`（`interval: 86400`），机场订阅更新不会覆盖自定义分流逻辑。
- **Bing 国内直连**：精确放行 `bing.com` / `bing.net` / `bingapis.com` / `bingj.com` 直连（置于 `reject` 之后保留广告拦截，置于 `gfw`/`proxy` 之前防止走代理）。
- **修正黑白名单交叉误伤**：
  - 采用 `gfw → direct → proxy` 顺序：既保证被墙域名走代理，又避免 `proxy.txt` 抢走微软更新、驱动下载、Steam/主机下载 CDN、阿里云等数百条国内直连域名。
  - 在 `reject` 广告拦截前精确放行 `gvt2.com`（Chrome/Google 组件更新）与 `statsig.anthropic.com`（Claude 功能开关），补齐 `gstatic.cn` 走代理与 `GEOIP,LAN,DIRECT` 内网域名兜底。
- **安全可逆**：保留 Merge 文件中用户原有的自定义字段（如 `tun`、`sniffer`、`profile` 等）；首次修改自动生成 `.bak` 备份，支持 `--dry-run` 预览与 `--restore` 一键还原。

## 环境依赖

- Python 3.7+
- `PyYAML`：

```bash
pip install pyyaml
```

支持自动识别 Windows（`%APPDATA%`）、macOS（`~/Library/Application Support`）与 Linux（`~/.local/share` / `~/.config`）下的 Clash Verge Rev / Clash Verge 配置目录。

## 使用方法

```bash
# 1. 预览将要写入的配置（推荐先跑，不修改任何文件）
python clash_rebuild_rules.py --dry-run

# 2. 正式写入所有远程订阅的 Merge 与 Rules 增强配置
python clash_rebuild_rules.py

# 可选：使用 jsDelivr CDN 镜像拉取规则集
python clash_rebuild_rules.py --cdn jsdelivr

# 可选：下载规则集时不经过代理组（境外网络或 CDN 可直连时使用）
python clash_rebuild_rules.py --no-proxy-download

# 可选：手动指定 Clash Verge 配置目录（也可设置环境变量 CLASH_VERGE_DIR）
python clash_rebuild_rules.py --dir "D:\path\to\clash-verge-config"

# 还原：用首次生成的 .bak 备份恢复所有订阅（同样支持配合 --dry-run 预览）
python clash_rebuild_rules.py --restore
```

### 生效与注意事项

1. 脚本运行完成后，打开 **Clash Verge** → 进入 **「订阅（Profiles）」**，点击当前激活的订阅卡片重新加载（或点击右上角重启内核）即可生效。
2. 在「订阅」页 **右键订阅 →「编辑规则」**：
   - 顶部无删除线的 **20 条规则** 即为当前生效的完整分流规则；
   - 下方带**红色删除线**的条目是已被屏蔽的机场自带旧规则，运行时不会加载、也不会生效。
3. **Bing 国内版提示**：
   - 若浏览器此前挂代理访问过必应并缓存了国际版 Cookie，首次切回直连时访问一次 `https://cn.bing.com`（或清除浏览器中 `bing.com` 的 Cookie），后续地址栏默认搜索即可稳定使用国内版必应。
   - 若需要为 Bing 指定上游 DNS（如在开启了「DNS 覆盖」且主 `nameserver` 含海外 DNS 时），请在 Clash Verge 的 **「设置 → DNS 覆盖」** 面板内配置 `nameserver-policy`，不要写在 Merge 中（否则会被 `AuthoritativeFields` 丢弃）。

## 分流规则匹配顺序

Clash 按从上到下顺序匹配，**命中第一条即停止**（`{group}` 自动替换为各订阅自身的主代理组）：

| 顺序 | 规则 | 策略 | 说明 |
| :--- | :--- | :--- | :--- |
| 1 | `RULE-SET,private` | `DIRECT` | 局域网 / 私有域名直连 |
| 2 | `DOMAIN-SUFFIX,gvt2.com` | `{group}` | 放行 Google / Chrome 更新组件（防 `reject` 误杀） |
| 3 | `DOMAIN,statsig.anthropic.com` | `{group}` | 放行 Claude 特性开关（防 `reject` 误杀） |
| 4 | `RULE-SET,reject` | `REJECT` | 广告与追踪域名拦截 |
| 5–8 | `DOMAIN-SUFFIX,bing.com / bing.net / bingapis.com / bingj.com` | `DIRECT` | Bing 国内搜索、联想 API、静态资源与快照直连 |
| 9–10 | `RULE-SET,icloud` / `RULE-SET,apple` | `DIRECT` | iCloud 与 Apple 国内 CDN 直连 |
| 11–12 | `RULE-SET,google` / `DOMAIN-SUFFIX,gstatic.cn` | `{group}` | Google 大陆可直连域名与 `gstatic.cn` 强制走代理 |
| 13 | `RULE-SET,gfw` | `{group}` | GFW 被墙域名走代理 |
| 14 | `RULE-SET,direct` | `DIRECT` | 国内网站与微软 / 游戏 / 驱动下载 CDN 直连 |
| 15 | `RULE-SET,proxy` | `{group}` | 海外常见服务走代理（Claude / OpenAI / GitHub / Cursor 等） |
| 16–17 | `RULE-SET,lancidr` / `RULE-SET,cncidr` (`no-resolve`) | `DIRECT` | 局域网与中国大陆 IP 段直连（免 DNS 解析） |
| 18–19 | `GEOIP,LAN` / `GEOIP,CN` | `DIRECT` | 解析为私网或国内 IP 的域名直连兜底 |
| 20 | `MATCH` | `{group}` | 其余未命中流量默认走主代理组兜底 |

## 仓库文件说明

- `clash_rebuild_rules.py`：主脚本，基于规则集整套重建分流规则并配置 Merge + Rules 增强。
