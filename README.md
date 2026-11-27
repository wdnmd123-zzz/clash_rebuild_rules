# clash_rebuild_rules

一键重做 **Clash Verge (Rev)** 所有远程订阅的分流规则：自动屏蔽机场自带的老旧/杂乱规则，统一换成每日自动更新的开源规则集（支持 [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) 与 [MetaCubeX](https://github.com/MetaCubeX/meta-rules-dat)）。

> Windows 用户**无需安装 Python**，直接双击 `clash_rebuild_rules.bat` 按数字即可完成配置；macOS / Linux 用户可使用跨平台 Python 版。

## 功能介绍

- **一键统一所有订阅的分流规则**：自动扫描 Clash Verge 里的全部远程订阅并识别各自的主代理组，批量换上每日自动更新的在线规则集，不用再逐个手动调整订阅。
- **国内直连、海外代理，少踩误伤坑**：国内网站、Apple / iCloud、微软更新与驱动下载走直连不绕路；被墙网站与常见海外服务（Google、GitHub、OpenAI、Claude 等）稳定走代理；自带广告拦截，同时放行 Chrome 组件更新与 Claude 功能开关，防止误杀。
- **Bing 搜索、Steam 与 AI 工具大流量域名直连**：必应默认走国内直连，不再频繁跳国际版；Steam 游戏下载/更新、Qoder API（`qoder.sh`）及 Trae 安装包 CDN（`traecdn.us`）走直连、不消耗机场流量，Steam 商店/社区与 Trae 国际版主服务仍走代理。
- **改完还能在界面里直接编辑**：全部生效规则都能在 Clash Verge **「右键订阅 → 编辑规则」** 中直接查看和增删；自动补齐 `find-process-mode: always` 以便连接页和流量监控识别进程名，不覆盖你原有的 DNS 覆盖和 `tun` / `sniffer` 等自定义配置，之后重跑脚本也会自动保留你在界面里手工加过的规则。
- **自动预下载规则集，两种规则源可选**：写入配置时自动把全部 10 份规则集提前拉取到本地缓存（带终端进度条），避免首次启动拉取失败；默认使用方便直接查看排查的 YAML 文本源，也可一键切换为体积仅约 820 KB、启动更快、更省内存的 MetaCubeX 二进制 `.mrs` 源。
- **首次修改自动备份，随时一键还原**：运行前会自动保存 `.bak` 备份，用着不习惯随时一键还原回原来的配置。

## 运行预览

Windows 双击运行 `clash_rebuild_rules.bat` 后会自动识别配置目录与订阅，按数字回车即可（首次使用直接选 `1`；想更省内存可选 `2`）：

![clash_rebuild_rules.bat 运行预览](docs/bat-preview.png)

## 使用方法

### 方式一：Windows 双击交互菜单（推荐，免装 Python）

依赖 Windows 10/11 自带 PowerShell，**无需安装 Python 或任何第三方库**。直接双击运行 `clash_rebuild_rules.bat`，输入数字 `1`–`9` 回车即可（需要订阅名、代理组或目录等参数时会在选中后提示输入）：

- `[1]` 正式写入并预拉取规则集（默认应用）
- `[2]` 使用 MetaCubeX 二进制 `.mrs` 源（`--source metacubex`，选中后可选是否配合 jsDelivr）
- `[3]` 仅写入配置，不预拉取规则集（`--skip-download`）
- `[4]` 指定订阅 / 指定主代理组（`--profile` / `--group`）
- `[5]` 重置规则为默认模板（`--reset-rules`）
- `[6]` 使用 jsDelivr CDN 镜像拉取（`--cdn jsdelivr`）
- `[7]` 下载规则集不走代理（直连，`--no-proxy-download`）
- `[8]` 手动指定配置目录（`--dir`）
- `[9]` 还原 `.bak` 备份（`--restore`）

同样支持在命令行直接带参数运行（如 `clash_rebuild_rules.bat --source metacubex`、`clash_rebuild_rules.bat --restore`）。

### 方式二：Python 命令行版（Windows / macOS / Linux）

需要 Python 3.7+ 与 `PyYAML`，会自动识别 Windows（`%APPDATA%`）、macOS（`~/Library/Application Support`）与 Linux（`~/.local/share` / `~/.config`）下的 Clash Verge (Rev) 配置目录：

```bash
pip install pyyaml
```

常用命令：

```bash
# 1. 正式写入所有远程订阅的 Merge 与 Rules 增强配置（默认带进度条预拉取全部规则集到本地缓存）
python clash_rebuild_rules.py

# 2. 切换为 MetaCubeX 二进制 .mrs 规则集（体积更小、低内存，需 Mihomo 内核；可与 --cdn jsdelivr 组合）
python clash_rebuild_rules.py --source metacubex

# 可选：只写入配置文件，不预先拉取规则集（交由 Clash Verge 后台自行拉取）
python clash_rebuild_rules.py --skip-download

# 可选：仅处理指定订阅（按名称/uid 匹配，可重复指定）或手动指定目标主代理组
python clash_rebuild_rules.py --profile "订阅名称" --group "节点选择"

# 可选：重置 Rules 增强为模板默认规则（不保留界面中手工新增的自定义规则）
python clash_rebuild_rules.py --reset-rules

# 可选：使用 jsDelivr CDN 镜像拉取规则集
python clash_rebuild_rules.py --cdn jsdelivr

# 可选：下载规则集时不经过代理组（境外网络或 CDN 可直连时使用）
python clash_rebuild_rules.py --no-proxy-download

# 可选：手动指定 Clash Verge 配置目录（也可设置环境变量 CLASH_VERGE_DIR）
python clash_rebuild_rules.py --dir "D:\path\to\clash-verge-config"

# 还原：用首次生成的 .bak 备份恢复所有订阅
python clash_rebuild_rules.py --restore
```

## 生效与注意事项

1. 运行完成后，打开 **Clash Verge** → 进入 **「订阅（Profiles）」**，点击当前激活的订阅卡片重新加载（或点击右上角重启内核）即可生效。
2. 在「订阅」页 **右键订阅 →「编辑规则」**：
   - 顶部无删除线的 **27 条规则** 即为当前生效的完整分流规则；
   - 下方带**红色删除线**的条目是已被屏蔽的机场自带旧规则，运行时不会加载、也不会生效。
3. **Bing 国内版提示**：
   - 若浏览器此前挂代理访问过必应并缓存了国际版 Cookie，首次切回直连时访问一次 `https://cn.bing.com`（或清除浏览器中 `bing.com` 的 Cookie），后续地址栏默认搜索即可稳定使用国内版必应。
   - 若需要为 Bing 指定上游 DNS（如开启了「DNS 覆盖」且主 `nameserver` 含海外 DNS 时），请在 Clash Verge 的 **「设置 → DNS 覆盖」** 面板内配置 `nameserver-policy`，不要写在 Merge 中（否则会被 `AuthoritativeFields` 丢弃）。
4. **Steam 下载提示**：
   - 规则生效后，请同时在 Steam **「设置 → 下载 → 下载地区」** 确认选择国内城市并重启 Steam，避免因客户端此前锁定海外下载地区而直连海外节点导致速度变慢。

## 分流规则说明

Clash 按从上到下顺序匹配，**命中第一条即停止**（`{group}` 自动替换为各订阅自身的主代理组）：

| 顺序 | 规则 | 策略 | 说明 |
| :--- | :--- | :--- | :--- |
| 1 | `RULE-SET,private` | `DIRECT` | 局域网 / 私有域名直连 |
| 2 | `DOMAIN-SUFFIX,gvt2.com` | `{group}` | 放行 Google / Chrome 更新组件（防 `reject` 误杀） |
| 3 | `DOMAIN,statsig.anthropic.com` | `{group}` | 放行 Claude 特性开关（防 `reject` 误杀） |
| 4 | `RULE-SET,reject` | `REJECT` | 广告与追踪域名拦截 |
| 5–8 | `DOMAIN-SUFFIX,bing.com / bing.net / bingapis.com / bingj.com` | `DIRECT` | Bing 国内搜索、联想 API、静态资源与快照直连 |
| 9–13 | `DOMAIN-SUFFIX,steamcontent.com / steamserver.net / steamchina.com / st.dl.pinyuncloud.com`、`DOMAIN,steampipe.akamaized.net` | `DIRECT` | Steam 游戏下载/更新 CDN 与 CM 连接直连（商店/社区仍走代理） |
| 14–15 | `DOMAIN-SUFFIX,qoder.sh / traecdn.us` | `DIRECT` | Qoder API/OpenAPI 与 Trae 国际版安装包/静态资源 CDN 直连（防大流量落入兜底代理） |
| 16–17 | `RULE-SET,icloud` / `RULE-SET,apple` | `DIRECT` | iCloud 与 Apple 国内 CDN 直连 |
| 18–19 | `RULE-SET,google` / `DOMAIN-SUFFIX,gstatic.cn` | `{group}` | Google 大陆可直连域名与 `gstatic.cn` 强制走代理 |
| 20 | `RULE-SET,gfw` | `{group}` | GFW 被墙域名走代理 |
| 21 | `RULE-SET,direct` | `DIRECT` | 国内网站与微软 / 游戏 / 驱动下载 CDN 直连 |
| 22 | `RULE-SET,proxy` | `{group}` | 海外常见服务走代理（Claude / OpenAI / GitHub / Cursor 等） |
| 23–24 | `RULE-SET,lancidr` / `RULE-SET,cncidr` (`no-resolve`) | `DIRECT` | 局域网与中国大陆 IP 段直连（免 DNS 解析） |
| 25–26 | `GEOIP,LAN` / `GEOIP,CN` | `DIRECT` | 解析为私网或国内 IP 的域名直连兜底 |
| 27 | `MATCH` | `{group}` | 其余未命中流量默认走主代理组兜底 |

### 实现细节

- **Merge + Rules 分离写入**：Merge 增强仅负责提供 `rule-providers`（`interval: 86400`，预拉取到 Clash Verge 的 `ruleset/` 目录）并在未设置时补齐 `find-process-mode: always`，不触碰 `rules` 和 `dns`，从而避免覆盖「编辑规则」面板或与 DNS 覆盖冲突；Rules 增强将以上规则写入 `prepend`，并用 `delete` 屏蔽机场原规则。
- **为什么采用 `gfw → direct → proxy` 顺序**：先匹配 `gfw` 保证被墙域名走代理，再匹配 `direct` 避免 `proxy.txt` 抢走微软更新、驱动下载、Steam/主机下载 CDN、阿里云等数百条国内直连域名，最后再由 `proxy` 接管其余海外服务。
- **兼容多分组订阅**：支持 ACL4SSR 等多分组订阅自动识别主代理组，也可通过 `--profile` / `--group` 手动指定。

## 仓库文件说明

- `clash_rebuild_rules.bat`：Windows 免 Python 独立版（内置 YAML 解析与交互式功能菜单，双击即用，也兼容命令行参数）。
- `clash_rebuild_rules.py`：跨平台 Python 主脚本，基于规则集整套重建分流规则并配置 Merge + Rules 增强。
