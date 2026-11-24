#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 GitHub 规则集整套重建 Clash Verge (Rev) 所有订阅的分流规则，并支持在右键「编辑规则」中查看与微调。

做什么
------
对每个远程订阅同时写入两个增强文件（profiles/<uid>.yaml）：
  1. 合并(Merge)增强:
     - rule-providers: 指向 Loyalsoldier/clash-rules (YAML，默认) 或 MetaCubeX/meta-rules-dat (MRS 二进制，--source metacubex) 在线规则集（自动更新，interval=86400s）
     - 保留 Merge 文件中用户原有的其它配置项（如 tun/profile/sniffer 等），并移除旧版遗留的 rules 字段
  2. 规则(Rules)增强（即 Clash Verge 右键订阅 ->「编辑规则」所读写的配置）:
     - prepend: 完整的分流规则（含 Bing 国内直连、防误杀、RULE-SET、结尾 MATCH 兜底）；重跑时自动保留你在界面中手工新增的自定义规则（加 --reset-rules 可强制重置）
     - delete:  标记删除订阅自带的旧规则（界面上显示删除线，运行时不再冗余保留）

为什么拆成 Merge + Rules 增强
-----------------------------
- Merge 只负责提供 rule-providers；不在 Merge 里写 rules（避免覆盖「编辑规则」面板），也不写 dns（避免与 Clash Verge 的 DNS 覆盖 / AuthoritativeFields 冲突而被丢弃弹窗警告）。
- Rules 增强的 prepend 在订阅规则之前生效，且 Clash Verge 的「右键 -> 编辑规则」直接读取该文件（并关联 Merge 中的 rule-providers），因此所有规则在界面内直接可见、可随时增删改。

安全性
------
- 每个 Merge / Rules 文件首次修改前备份为 <file>.bak（保留原始模板/内容，用于还原）。
- --dry-run 只预览不写入（同样适用于 --restore --dry-run）。
- 结尾有 MATCH→代理组 兜底：即使远程订阅更新新增了未在 delete 中的规则，也会被 MATCH 提前截获。
- --restore 用 .bak 还原所有订阅的 Merge 和 Rules 文件。

用法
----
  python clash_rebuild_rules.py --dry-run            # 预览（推荐先跑）
  python clash_rebuild_rules.py                      # 应用
  python clash_rebuild_rules.py --profile 订阅名      # 仅处理指定订阅（可重复指定）
  python clash_rebuild_rules.py --group 节点选择      # 手动指定目标主代理组名
  python clash_rebuild_rules.py --reset-rules        # 重置 Rules 增强，不保留界面手工新增规则
  python clash_rebuild_rules.py --source metacubex   # 使用 MetaCubeX 二进制 .mrs 规则集（体积小、低内存，需 Mihomo 内核）
  python clash_rebuild_rules.py --cdn jsdelivr       # 用 jsdelivr 镜像(国内多数可直连)
  python clash_rebuild_rules.py --no-proxy-download  # 规则下载不走代理(境外网络用)
  python clash_rebuild_rules.py --skip-download      # 只写配置文件，不预先拉取规则集
  python clash_rebuild_rules.py --restore            # 用 .bak 还原所有订阅
  python clash_rebuild_rules.py --dir D:\\xxx         # 手动指定 Clash Verge 配置目录

依赖：PyYAML（pip install pyyaml）
"""

import argparse
import os
import shutil
import sys
import time
import urllib.error
import urllib.request

try:
    import yaml
except ImportError:
    sys.exit('缺少 PyYAML，请先运行: pip install pyyaml')

# ---------------- 规则源 ----------------
# (provider 名, 相对路径, behavior)
RULE_SOURCES = {
    'loyalsoldier': {
        'label': 'Loyalsoldier/clash-rules (YAML)',
        'format': 'yaml',
        'path_tpl': './ruleset/clashrules_%s.yaml',
        'raw_base': 'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/',
        'cdn_base': 'https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/',
        'providers': [
            ('private', 'private.txt', 'domain'),   # 私有/局域网域名
            ('reject',  'reject.txt',  'domain'),   # 广告/跟踪域名 -> REJECT
            ('icloud',  'icloud.txt',  'domain'),   # iCloud 直连
            ('apple',   'apple.txt',   'domain'),   # Apple 国内 CDN 直连
            ('google',  'google.txt',  'domain'),   # Google 大陆可直连域名（此处强制拉回代理）
            ('gfw',     'gfw.txt',     'domain'),   # GFW 被墙域名清单
            ('direct',  'direct.txt',  'domain'),   # 国内直连域名与下载 CDN 清单
            ('proxy',   'proxy.txt',   'domain'),   # 海外常见代理清单（Claude/OpenAI/GitHub/Cursor 等）
            ('lancidr', 'lancidr.txt', 'ipcidr'),   # 局域网/保留网段
            ('cncidr',  'cncidr.txt',  'ipcidr'),   # 中国大陆 IP
        ],
    },
    'metacubex': {
        'label': 'MetaCubeX/meta-rules-dat (MRS 二进制，低内存)',
        'format': 'mrs',
        'path_tpl': './ruleset/metacubex_%s.mrs',
        'raw_base': 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/',
        'cdn_base': 'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/',
        'providers': [
            ('private', 'geo/geosite/private.mrs',          'domain'),  # 私有/局域网域名
            ('reject',  'geo/geosite/category-ads-all.mrs', 'domain'),  # 广告/跟踪域名 -> REJECT
            ('icloud',  'geo/geosite/icloud.mrs',           'domain'),  # iCloud 直连
            ('apple',   'geo/geosite/apple-cn.mrs',         'domain'),  # Apple 国内 CDN 直连
            ('google',  'geo/geosite/google.mrs',           'domain'),  # Google 全量域名走代理
            ('gfw',     'geo/geosite/gfw.mrs',              'domain'),  # GFW 被墙域名清单
            ('direct',  'geo/geosite/cn.mrs',               'domain'),  # 国内直连域名清单
            ('proxy',   'geo/geosite/geolocation-!cn.mrs',  'domain'),  # 非大陆海外常见服务清单
            ('lancidr', 'geo/geoip/private.mrs',            'ipcidr'),  # 局域网/保留网段
            ('cncidr',  'geo/geoip/cn.mrs',                 'ipcidr'),  # 中国大陆 IP
        ],
    },
}

RAW_BASE = RULE_SOURCES['loyalsoldier']['raw_base']
CDN_BASE = RULE_SOURCES['loyalsoldier']['cdn_base']
PROVIDERS = RULE_SOURCES['loyalsoldier']['providers']

# 完整规则，第一命中生效。{group} 替换成各订阅自己的主代理组名。
RULE_TEMPLATES = [
    'RULE-SET,private,DIRECT',
    'DOMAIN-SUFFIX,gvt2.com,{group}',        # 放行 Google/Chrome 组件下载（避免被 reject 误杀）
    'DOMAIN,statsig.anthropic.com,{group}',  # 放行 Claude 特性开关（避免被 reject 误杀）
    'RULE-SET,reject,REJECT',
    'DOMAIN-SUFFIX,bing.com,DIRECT',         # Bing 国内搜索直连（置于 reject 后保留广告拦截，置于 gfw/proxy 前防走代理）
    'DOMAIN-SUFFIX,bing.net,DIRECT',         # Bing 静态资源/缩略图 CDN 直连
    'DOMAIN-SUFFIX,bingapis.com,DIRECT',     # Bing 搜索联想 API 直连
    'DOMAIN-SUFFIX,bingj.com,DIRECT',        # Bing 网页快照直连
    'RULE-SET,icloud,DIRECT',
    'RULE-SET,apple,DIRECT',
    'RULE-SET,google,{group}',               # Google 大陆可直连域名强制走代理
    'DOMAIN-SUFFIX,gstatic.cn,{group}',      # Google gstatic.cn 强制走代理（避免命中 direct 的 +.cn）
    'RULE-SET,gfw,{group}',                  # 被墙域名走代理（优先于 direct）
    'RULE-SET,direct,DIRECT',                # 国内网站与微软/驱动/游戏下载 CDN 直连（优先于 proxy 防跑流量）
    'RULE-SET,proxy,{group}',                # 海外服务走代理（Claude/OpenAI/GitHub/Cursor 等，免本地 DNS 解析）
    'RULE-SET,lancidr,DIRECT,no-resolve',
    'RULE-SET,cncidr,DIRECT,no-resolve',
    'GEOIP,LAN,DIRECT',                      # 解析为私网 IP 的内网域名直连兜底（Mihomo 内置特判 lan，兼容 MMDB/geodata）
    'GEOIP,CN,DIRECT',
    'MATCH,{group}',                         # 其余全部走代理（兜底）
]


def _fix_stdout():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8', errors='replace')
        except Exception:
            pass


def find_config_dir(explicit=None):
    if explicit:
        if os.path.isfile(os.path.join(explicit, 'profiles.yaml')):
            return explicit
        return None
    env = os.environ.get('CLASH_VERGE_DIR')
    if env and os.path.isfile(os.path.join(env, 'profiles.yaml')):
        return env

    app_ids = [
        'io.github.clash-verge-rev.clash-verge-rev',
        'io.github.clash-verge.clash-verge',
    ]
    bases = []
    appdata = os.environ.get('APPDATA')                                 # Windows
    if appdata:
        bases.append(appdata)
    bases.append(os.path.expanduser('~/Library/Application Support'))   # macOS
    xdg = os.environ.get('XDG_DATA_HOME') or os.path.expanduser('~/.local/share')  # Linux
    bases.append(xdg)
    bases.append(os.path.expanduser('~/.config'))

    for base in bases:
        for app_id in app_ids:
            c = os.path.join(base, app_id)
            if os.path.isfile(os.path.join(c, 'profiles.yaml')):
                return c
    return None


def load_yaml_dict(path):
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _rule_key(rule):
    parts = [p.strip() for p in str(rule).split(',')]
    if not parts:
        return ''
    rtype = parts[0].upper()
    if rtype in ('MATCH', 'FINAL'):
        return rtype
    if len(parts) >= 2:
        return rtype + ',' + parts[1].lower()
    return rtype


MANAGED_PROVIDER_NAMES = {
    name
    for src in RULE_SOURCES.values()
    for name, _, _ in src['providers']
}
MANAGED_RULE_KEYS = {_rule_key(t) for t in RULE_TEMPLATES} | {'MATCH', 'FINAL'}


def _is_direct_or_reject_group(group_obj):
    proxies = group_obj.get('proxies') or []
    return bool(proxies) and isinstance(proxies[0], str) and proxies[0].strip().upper() in ('DIRECT', 'REJECT')


def _is_managed_rules(existing_rules):
    """判断现有 Rules 增强文件是否已由本脚本生成过（不依赖易被 UI 剥离的注释）。"""
    prepend = existing_rules.get('prepend') if isinstance(existing_rules, dict) else None
    if not isinstance(prepend, list):
        return False
    matched = 0
    for r in prepend:
        if not isinstance(r, str):
            continue
        parts = [p.strip() for p in r.split(',')]
        if len(parts) >= 2 and parts[0].upper() == 'RULE-SET' and parts[1] in MANAGED_PROVIDER_NAMES:
            matched += 1
            if matched >= 2:
                return True
    return False


def inspect_subscription(sub_yaml_path, selected_items):
    """读取订阅配置，返回 (推荐主代理组名, 去重后的原始规则列表, 全部有效代理组名列表)。"""
    cfg = load_yaml_dict(sub_yaml_path)
    raw_groups = cfg.get('proxy-groups') or []
    valid_groups = []
    group_map = {}
    group_idx = {}
    proxy_selects = []
    any_selects = []
    for g in raw_groups:
        if isinstance(g, dict) and isinstance(g.get('name'), str) and g['name'].strip():
            gname = g['name']
            if gname in group_map:
                continue
            group_idx[gname] = len(valid_groups)
            valid_groups.append(gname)
            group_map[gname] = g
            if g.get('type') == 'select' and gname.upper() not in ('DIRECT', 'REJECT'):
                any_selects.append(gname)
                if not _is_direct_or_reject_group(g):
                    proxy_selects.append(gname)
    valid_set = set(valid_groups)
    proxy_select_set = set(proxy_selects)

    raw_rules = [r for r in (cfg.get('rules') or []) if isinstance(r, str) and r.strip()]
    dedup_rules = list(dict.fromkeys(raw_rules))

    # 1. 从末尾 MATCH / FINAL 提取目标组；若其指向「漏网之鱼」等兜底组（引用了更靠前的 select 主组），则自动解包到主代理组
    for r in reversed(dedup_rules):
        parts = [p.strip() for p in r.split(',')]
        if len(parts) >= 2 and parts[0].upper() in ('MATCH', 'FINAL'):
            cand = parts[1]
            if cand in valid_set and cand.upper() not in ('DIRECT', 'REJECT'):
                visited = {cand}
                while group_map[cand].get('type') == 'select':
                    earlier = None
                    for ref in (group_map[cand].get('proxies') or []):
                        if (
                            isinstance(ref, str)
                            and ref in proxy_select_set
                            and ref not in visited
                            and group_idx[ref] < group_idx[cand]
                        ):
                            earlier = ref
                            break
                    if not earlier:
                        break
                    visited.add(earlier)
                    cand = earlier
                if not (_is_direct_or_reject_group(group_map[cand]) and proxy_selects):
                    return cand, dedup_rules, valid_groups
            break

    # 2. 退回订阅中第一个非 DIRECT/REJECT 优先的 type=select 代理组，其次任意 select 组
    if proxy_selects:
        return proxy_selects[0], dedup_rules, valid_groups
    if any_selects:
        return any_selects[0], dedup_rules, valid_groups

    # 3. 若订阅文件不存在或未解析出 proxy-groups，再尝试 profiles.yaml 的 selected
    for sel in (selected_items or []):
        if isinstance(sel, dict) and isinstance(sel.get('name'), str):
            cand = sel['name']
            if (not valid_set or cand in valid_set) and cand.upper() not in ('DIRECT', 'REJECT'):
                return cand, dedup_rules, valid_groups

    return None, dedup_rules, valid_groups


def build_merge_cfg(existing_merge, base_url, provider_proxy, source='loyalsoldier'):
    """基于现有 Merge 配置保留自定义字段，写入 rule-providers，并清理旧版遗留的 rules / Bing DNS。"""
    cfg = dict(existing_merge or {})
    # 移除 Merge 中的 rules，避免覆盖右键「编辑规则」面板（Rules 增强）
    cfg.pop('rules', None)

    # 清理旧版脚本写入 Merge 的 Bing nameserver-policy（避免被 Clash Verge DNS 覆盖丢弃并弹警告）
    if isinstance(cfg.get('dns'), dict):
        dns_cfg = dict(cfg['dns'])
        if isinstance(dns_cfg.get('nameserver-policy'), dict):
            ns_policy = dict(dns_cfg['nameserver-policy'])
            for k in ('+.bing.com', '+.bing.net', '+.bingapis.com'):
                if ns_policy.get(k) == ['223.5.5.5', '119.29.29.29']:
                    ns_policy.pop(k, None)
            if ns_policy:
                dns_cfg['nameserver-policy'] = ns_policy
            else:
                dns_cfg.pop('nameserver-policy', None)
        if dns_cfg:
            cfg['dns'] = dns_cfg
        else:
            cfg.pop('dns', None)

    src_cfg = RULE_SOURCES[source]
    providers = dict(cfg.get('rule-providers') or {}) if isinstance(cfg.get('rule-providers'), dict) else {}
    for name, rel_path, behavior in src_cfg['providers']:
        p = {
            'type': 'http',
            'behavior': behavior,
            'format': src_cfg['format'],
            'url': base_url + rel_path,
            'path': src_cfg['path_tpl'] % name,
            'interval': 86400,
        }
        if provider_proxy:
            p['proxy'] = provider_proxy
        providers[name] = p
    cfg['rule-providers'] = providers

    return cfg


def build_rules_cfg(group, sub_rules, existing_rules=None, reset_rules=False):
    managed_prepend = [t.format(group=group) for t in RULE_TEMPLATES]
    custom_prepend = []
    custom_append = []
    if not reset_rules and _is_managed_rules(existing_rules):
        seen_prepend = set()
        for r in (existing_rules.get('prepend') or []):
            if not isinstance(r, str) or not r.strip():
                continue
            if _rule_key(r) in MANAGED_RULE_KEYS:
                continue
            if r not in seen_prepend:
                seen_prepend.add(r)
                custom_prepend.append(r)
        seen_append = set()
        for r in (existing_rules.get('append') or []):
            if not isinstance(r, str) or not r.strip():
                continue
            if r not in seen_append:
                seen_append.add(r)
                custom_append.append(r)
    return {
        'prepend': custom_prepend + managed_prepend,
        'append': custom_append,
        'delete': list(sub_rules),
    }, len(custom_prepend) + len(custom_append)


def dump_yaml_with_header(cfg, title_line, source_label=None):
    if source_label is None:
        source_label = RULE_SOURCES['loyalsoldier']['label']
    header = (
        '# ================================================================\n'
        '# %s\n'
        '# 规则源: %s (RULE-SET，Clash 每日自动更新)\n'
        '# 还原方式: python clash_rebuild_rules.py --restore\n'
        '# ================================================================\n'
    ) % (title_line, source_label)
    body = yaml.safe_dump(
        cfg, sort_keys=False, allow_unicode=True,
        default_flow_style=False, width=1 << 20, indent=2,
    )
    return header + body


def backup_and_write(path, text):
    bak = path + '.bak'
    if os.path.isfile(path) and not os.path.exists(bak):
        shutil.copy2(path, bak)
        print('  已备份: %s' % bak)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(text)
    os.replace(tmp, path)
    print('  已写入: %s' % path)


def restore_file(path, dry_run=False):
    bak = path + '.bak'
    if not os.path.isfile(bak):
        print('  [skip] 没有备份 %s' % bak)
        return False
    if dry_run:
        print('  [dry-run] 将还原: %s <- %s' % (path, bak))
        return True
    shutil.copy2(bak, path)
    print('  已还原: %s <- %s' % (path, bak))
    return True


def _fmt_size(num_bytes):
    if num_bytes < 1024:
        return '%d B' % num_bytes
    if num_bytes < 1024 * 1024:
        return '%.1f KB' % (num_bytes / 1024.0)
    return '%.2f MB' % (num_bytes / (1024.0 * 1024.0))


def _bar_chars():
    enc = getattr(sys.stdout, 'encoding', None) or 'utf-8'
    try:
        '█░'.encode(enc)
        return '█', '░'
    except Exception:
        return '#', '-'


def _render_bar(ratio, width=20, tick=0, fill='█', empty='░'):
    if ratio is None:
        seg = 4
        span = max(1, width - seg)
        pos = tick % (span * 2)
        if pos > span:
            pos = span * 2 - pos
        return empty * pos + fill * seg + empty * (width - pos - seg)
    clamped = max(0.0, min(1.0, ratio))
    done = int(round(clamped * width))
    return fill * done + empty * (width - done)


def prefetch_rulesets(cfg_dir, source, base_url, no_proxy=False, timeout=30):
    """将当前规则源的全部规则集预拉取到 Clash Verge 本地 ruleset/ 缓存，并显示终端进度条。"""
    src_cfg = RULE_SOURCES[source]
    providers = src_cfg['providers']
    total_count = len(providers)
    is_tty = hasattr(sys.stdout, 'isatty') and sys.stdout.isatty()
    fill, empty = _bar_chars()
    opener = (
        urllib.request.build_opener(urllib.request.ProxyHandler({}))
        if no_proxy else urllib.request.build_opener()
    )

    print('正在拉取规则集（共 %d 份，源: %s）:' % (total_count, src_cfg['label']))
    total_bytes = 0
    ok_count = 0
    failed = []
    t_all = time.monotonic()

    for idx, (name, rel_path, _behavior) in enumerate(providers, 1):
        url = base_url + rel_path
        dst_path = os.path.normpath(os.path.join(cfg_dir, src_cfg['path_tpl'] % name))
        os.makedirs(os.path.dirname(dst_path), exist_ok=True)
        tmp_path = dst_path + '.tmp'
        prefix = '  [%2d/%d] %-8s' % (idx, total_count, name)
        t0 = time.monotonic()
        last_len = 0

        def emit_live(text):
            nonlocal last_len
            if not is_tty:
                return
            pad = ' ' * max(0, last_len - len(text))
            sys.stdout.write('\r' + text + pad)
            sys.stdout.flush()
            last_len = len(text)

        def emit_final(text):
            nonlocal last_len
            if is_tty:
                pad = ' ' * max(0, last_len - len(text))
                sys.stdout.write('\r' + text + pad + '\n')
                sys.stdout.flush()
                last_len = 0
            else:
                print(text)

        emit_live('%s [%s]  连接中...' % (prefix, empty * 20))
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'clash-rebuild-rules'})
            with opener.open(req, timeout=timeout) as resp:
                cl_hdr = resp.headers.get('Content-Length')
                expected = int(cl_hdr) if cl_hdr and cl_hdr.isdigit() and int(cl_hdr) > 0 else None
                downloaded = 0
                head_sample = b''
                last_draw = 0.0
                tick = 0
                with open(tmp_path, 'wb') as f:
                    while True:
                        chunk = resp.read(16384)
                        if not chunk:
                            break
                        if len(head_sample) < 256:
                            head_sample += chunk[:256 - len(head_sample)]
                        f.write(chunk)
                        downloaded += len(chunk)
                        now = time.monotonic()
                        if is_tty and (now - last_draw >= 0.05 or (expected and downloaded >= expected)):
                            elapsed = max(now - t0, 1e-3)
                            speed = _fmt_size(downloaded / elapsed) + '/s'
                            if expected:
                                ratio = downloaded / expected
                                pct = '%3d%%' % int(min(100, round(ratio * 100)))
                                size_info = '%s / %s' % (_fmt_size(downloaded), _fmt_size(expected))
                            else:
                                ratio = None
                                pct = ' --%'
                                size_info = _fmt_size(downloaded)
                            bar = _render_bar(ratio, 20, tick, fill, empty)
                            emit_live('%s [%s] %s  %-19s %s' % (prefix, bar, pct, size_info, speed))
                            last_draw = now
                            tick += 1

            if downloaded <= 0:
                raise ValueError('下载内容为空')
            if src_cfg['format'] == 'yaml':
                head_lower = head_sample.lstrip().lower()
                if head_lower.startswith(b'<!doctype html') or head_lower.startswith(b'<html'):
                    raise ValueError('返回内容为 HTML 错误页，非有效规则文件')

            os.replace(tmp_path, dst_path)
            cost = time.monotonic() - t0
            total_bytes += downloaded
            ok_count += 1
            emit_final('%s [%s] 100%%  %9s  %5.1fs  OK' % (prefix, fill * 20, _fmt_size(downloaded), cost))
        except Exception as exc:
            if os.path.exists(tmp_path):
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass
            cost = time.monotonic() - t0
            if isinstance(exc, urllib.error.HTTPError):
                reason = 'HTTP %s' % exc.code
            elif isinstance(exc, urllib.error.URLError):
                reason = str(exc.reason)
            else:
                reason = str(exc)
            failed.append((name, reason))
            emit_final('%s [%s] FAIL  %s (%.1fs)' % (prefix, '-' * 20, reason, cost))

    all_cost = time.monotonic() - t_all
    all_ratio = ok_count / total_count if total_count else 1.0
    all_bar = _render_bar(all_ratio, 20, 0, fill, empty)
    print('  总进度 [%s] %d/%d (%d%%)  合计 %s  耗时 %.1fs' % (
        all_bar, ok_count, total_count, int(round(all_ratio * 100)), _fmt_size(total_bytes), all_cost
    ))
    if failed:
        names = ', '.join(n for n, _ in failed)
        print('  [warn] 以下 %d 份规则集拉取失败: %s（可稍后重试，或加 --cdn jsdelivr 切换镜像）' % (len(failed), names))
    print()
    return ok_count, failed


def main():
    _fix_stdout()
    ap = argparse.ArgumentParser(description='整套重建 Clash Verge 所有订阅的分流规则（支持右键编辑规则查看）')
    ap.add_argument('--dir', help='Clash Verge 配置目录（默认自动找 %%APPDATA%% 下）')
    ap.add_argument('--dry-run', action='store_true', help='只预览，不写入')
    ap.add_argument('--profile', action='append',
                    help='仅处理指定订阅（按订阅名称、uid 或文件名匹配，可重复指定）')
    ap.add_argument('--group',
                    help='手动指定主代理组名（覆盖自动识别；多订阅组名不同时建议配合 --profile 使用）')
    ap.add_argument('--reset-rules', action='store_true',
                    help='重置 Rules 增强为模板默认规则，不保留此前在界面中手工新增的自定义规则')
    ap.add_argument('--source', choices=list(RULE_SOURCES.keys()), default='loyalsoldier',
                    help='规则集源：loyalsoldier=YAML文本(默认，易排查)，metacubex=Mihomo 二进制 .mrs(体积小、低内存)')
    ap.add_argument('--cdn', choices=['raw', 'jsdelivr'], default='raw',
                    help='规则下载源：raw=GitHub 原始地址(默认)，jsdelivr=国内 CDN 镜像')
    ap.add_argument('--no-proxy-download', action='store_true',
                    help='rule-providers 下载时不指定 proxy，且脚本预拉取规则集时不使用系统代理（境外网络或 CDN 可直连时用）')
    ap.add_argument('--skip-download', action='store_true',
                    help='只写入配置文件，不预先拉取规则集到本地 ruleset/ 缓存')
    ap.add_argument('--restore', action='store_true', help='用 .bak 还原所有订阅的 Merge 与 Rules 文件')
    args = ap.parse_args()

    cfg_dir = find_config_dir(args.dir)
    if not cfg_dir:
        sys.exit('未找到有效的 Clash Verge 配置目录，请用 --dir 指定（目录需包含 profiles.yaml）。')
    profiles_dir = os.path.join(cfg_dir, 'profiles')
    profiles_yaml = os.path.join(cfg_dir, 'profiles.yaml')
    print('配置目录: %s\n' % cfg_dir)

    pf = load_yaml_dict(profiles_yaml)
    items = pf.get('items') or []
    uid2file = {it.get('uid'): it.get('file') for it in items if isinstance(it, dict) and it.get('uid')}
    remotes = [it for it in items if isinstance(it, dict) and it.get('type') == 'remote']
    if not remotes:
        print('profiles.yaml 里没有 type: remote 的订阅。')
        return

    if args.profile:
        wanted = set(args.profile)
        matched_remotes = [
            it for it in remotes
            if it.get('name') in wanted or it.get('uid') in wanted or it.get('file') in wanted
        ]
        if not matched_remotes:
            avail = ', '.join(str(it.get('name') or it.get('uid') or '?') for it in remotes)
            sys.exit('未匹配到指定订阅（%s）。可用远程订阅: %s' % (', '.join(args.profile), avail))
        found_keys = set()
        for it in matched_remotes:
            found_keys.update(k for k in (it.get('name'), it.get('uid'), it.get('file')) if k)
        missing = [p for p in args.profile if p not in found_keys]
        if missing:
            print('[warn] 未找到以下订阅，已忽略: %s\n' % ', '.join(missing))
        remotes = matched_remotes

    src_cfg = RULE_SOURCES[args.source]
    base_url = src_cfg['cdn_base'] if args.cdn == 'jsdelivr' else src_cfg['raw_base']
    if not args.restore:
        print('规则集源: %s' % src_cfg['label'])
        print('下载地址: %s' % base_url)
        print('下载经代理: %s\n' % ('否（--no-proxy-download）' if args.no_proxy_download else '是（走各订阅主代理组）'))

    changed = 0
    seen_merge = {}
    seen_rules = {}

    for it in remotes:
        name = it.get('name') or it.get('file') or '?'
        sub_file = it.get('file')
        opt = it.get('option') if isinstance(it.get('option'), dict) else {}
        merge_uid = opt.get('merge')
        rules_uid = opt.get('rules')

        print('订阅: %s' % name)

        if not merge_uid or not rules_uid:
            print('  [skip] 该订阅缺少 merge 或 rules 增强配置（merge=%s, rules=%s）。\n' % (merge_uid, rules_uid))
            continue

        merge_file = uid2file.get(merge_uid) or (merge_uid + '.yaml')
        rules_file = uid2file.get(rules_uid) or (rules_uid + '.yaml')
        merge_path = os.path.join(profiles_dir, merge_file)
        rules_path = os.path.join(profiles_dir, rules_file)

        if args.restore:
            r1 = restore_file(merge_path, dry_run=args.dry_run)
            r2 = restore_file(rules_path, dry_run=args.dry_run)
            if r1 or r2:
                changed += 1
            print()
            continue

        if merge_uid in seen_merge or rules_uid in seen_rules:
            prev = seen_merge.get(merge_uid) or seen_rules.get(rules_uid)
            print('  [warn] 与订阅「%s」共用增强文件，跳过以防互相覆盖。\n' % prev)
            continue

        sub_path = os.path.join(profiles_dir, sub_file) if sub_file else ''
        detected_group, sub_rules, valid_groups = inspect_subscription(sub_path, it.get('selected'))
        if args.group is not None:
            if not args.group.strip() or args.group.strip().upper() in ('DIRECT', 'REJECT'):
                print('  [warn] --group 不能指定为空或 %s，跳过。\n' % (args.group or '空'))
                continue
            if valid_groups and args.group not in valid_groups:
                avail_groups = ', '.join(valid_groups[:8]) + (' ...' if len(valid_groups) > 8 else '')
                print('  [warn] 该订阅中不存在代理组「%s」（可用: %s），跳过。\n' % (args.group, avail_groups))
                continue
            group = args.group
        else:
            group = detected_group

        if not group:
            print('  [warn] 无法确定该订阅的有效主代理组名，跳过。\n')
            continue

        seen_merge[merge_uid] = name
        seen_rules[rules_uid] = name

        print('  主代理组: %s%s' % (group, '（--group 指定）' if args.group is not None else ''))
        print('  Merge 文件 (rule-providers):       %s' % merge_path)
        print('  Rules 文件 (右键「编辑规则」可见): %s（屏蔽原订阅规则 %d 条）' % (rules_path, len(sub_rules)))

        provider_proxy = None if args.no_proxy_download else group
        existing_merge = load_yaml_dict(merge_path)
        existing_rules = load_yaml_dict(rules_path)
        merge_cfg = build_merge_cfg(existing_merge, base_url, provider_proxy, source=args.source)
        rules_cfg, kept_custom = build_rules_cfg(
            group, sub_rules, existing_rules=existing_rules, reset_rules=args.reset_rules
        )
        if kept_custom:
            print('  已保留界面自定义规则: %d 条（位于模板规则之前，可加 --reset-rules 重置）' % kept_custom)

        merge_text = dump_yaml_with_header(
            merge_cfg, '由 clash_rebuild_rules.py 生成：rule-providers 规则集数据源', src_cfg['label']
        )
        rules_text = dump_yaml_with_header(
            rules_cfg, '由 clash_rebuild_rules.py 生成：右键「编辑规则」前置分流规则', src_cfg['label']
        )

        if args.dry_run:
            print('  ----- Merge 将写入的内容 -----')
            for line in merge_text.rstrip('\n').splitlines():
                print('  | ' + line)
            print('  ----- Rules (prepend 预览，delete 共 %d 条已省略) -----' % len(sub_rules))
            preview_rules = {
                'prepend': rules_cfg['prepend'],
                'append': rules_cfg['append'],
                'delete': ['<共 %d 条原订阅规则>' % len(sub_rules)],
            }
            for line in dump_yaml_with_header(preview_rules, '右键「编辑规则」预览', src_cfg['label']).rstrip('\n').splitlines():
                print('  | ' + line)
            print()
            continue

        backup_and_write(merge_path, merge_text)
        backup_and_write(rules_path, rules_text)
        changed += 1
        print()

    if not args.restore and not args.dry_run and not args.skip_download and changed > 0:
        prefetch_rulesets(cfg_dir, args.source, base_url, no_proxy=args.no_proxy_download)

    print('=' * 60)
    if args.restore:
        if args.dry_run:
            print('dry-run 还原预览完成（涉及 %d 个订阅），未写入任何文件。' % changed)
        else:
            print('还原完成（共处理 %d 个订阅）。请回 Clash Verge 重新激活订阅/重启内核生效。' % changed)
    elif args.dry_run:
        print('dry-run 模式，未写入任何文件。确认无误后去掉 --dry-run 再运行。')
    else:
        print('完成，共更新 %d 个订阅的 Merge + Rules 增强配置。' % changed)
        print('请回 Clash Verge 重新激活当前订阅（或点击刷新/重启内核）生效；右键订阅 ->「编辑规则」即可查看和修改规则。')
        print('如需还原：python clash_rebuild_rules.py --restore')


if __name__ == '__main__':
    main()
