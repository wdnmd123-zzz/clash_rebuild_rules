#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 GitHub 规则集整套重建 Clash Verge (Rev) 所有订阅的分流规则，并支持在右键「编辑规则」中查看与微调。

做什么
------
对每个远程订阅同时写入两个增强文件（profiles/<uid>.yaml）：
  1. 合并(Merge)增强:
     - rule-providers: 指向 Loyalsoldier/clash-rules 在线规则集（自动更新，interval=86400s）
     - 保留 Merge 文件中用户原有的其它配置项（如 tun/profile/sniffer 等），并移除旧版遗留的 rules 字段
  2. 规则(Rules)增强（即 Clash Verge 右键订阅 ->「编辑规则」所读写的配置）:
     - prepend: 完整的分流规则（含 Bing 国内直连、防误杀、RULE-SET、结尾 MATCH 兜底）
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
  python clash_rebuild_rules.py --cdn jsdelivr       # 用 jsdelivr 镜像(国内多数可直连)
  python clash_rebuild_rules.py --no-proxy-download  # 规则下载不走代理(境外网络用)
  python clash_rebuild_rules.py --restore            # 用 .bak 还原所有订阅
  python clash_rebuild_rules.py --dir D:\\xxx         # 手动指定 Clash Verge 配置目录

依赖：PyYAML（pip install pyyaml）
"""

import argparse
import os
import shutil
import sys

try:
    import yaml
except ImportError:
    sys.exit('缺少 PyYAML，请先运行: pip install pyyaml')

# ---------------- 规则源 ----------------
RAW_BASE = 'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/'
CDN_BASE = 'https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/'

# (provider 名, 文件名, behavior)
PROVIDERS = [
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
]

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


def inspect_subscription(sub_yaml_path, selected_items):
    """读取订阅配置，返回 (主代理组名, 去重后的原始规则列表)。"""
    cfg = load_yaml_dict(sub_yaml_path)
    raw_groups = cfg.get('proxy-groups') or []
    valid_groups = []
    first_select = None
    for g in raw_groups:
        if isinstance(g, dict) and isinstance(g.get('name'), str) and g['name'].strip():
            gname = g['name']
            valid_groups.append(gname)
            if first_select is None and g.get('type') == 'select' and gname.upper() not in ('DIRECT', 'REJECT'):
                first_select = gname
    valid_set = set(valid_groups)

    raw_rules = [r for r in (cfg.get('rules') or []) if isinstance(r, str) and r.strip()]
    dedup_rules = list(dict.fromkeys(raw_rules))

    # 1. 优先从订阅自带的末尾 MATCH / FINAL 规则提取主代理组
    for r in reversed(dedup_rules):
        parts = [p.strip() for p in r.split(',')]
        if len(parts) >= 2 and parts[0].upper() in ('MATCH', 'FINAL'):
            cand = parts[1]
            if cand in valid_set and cand.upper() not in ('DIRECT', 'REJECT'):
                return cand, dedup_rules

    # 2. 退回订阅中第一个 type=select 的代理组
    if first_select:
        return first_select, dedup_rules

    # 3. 若订阅文件不存在或未解析出 proxy-groups，再尝试 profiles.yaml 的 selected
    for sel in (selected_items or []):
        if isinstance(sel, dict) and isinstance(sel.get('name'), str):
            cand = sel['name']
            if (not valid_set or cand in valid_set) and cand.upper() not in ('DIRECT', 'REJECT'):
                return cand, dedup_rules

    return None, dedup_rules


def build_merge_cfg(existing_merge, base_url, provider_proxy):
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

    providers = dict(cfg.get('rule-providers') or {}) if isinstance(cfg.get('rule-providers'), dict) else {}
    for name, fname, behavior in PROVIDERS:
        p = {
            'type': 'http',
            'behavior': behavior,
            'format': 'yaml',
            'url': base_url + fname,
            'path': './ruleset/clashrules_%s.yaml' % name,
            'interval': 86400,
        }
        if provider_proxy:
            p['proxy'] = provider_proxy
        providers[name] = p
    cfg['rule-providers'] = providers

    return cfg


def build_rules_cfg(group, sub_rules):
    return {
        'prepend': [t.format(group=group) for t in RULE_TEMPLATES],
        'append': [],
        'delete': list(sub_rules),
    }


def dump_yaml_with_header(cfg, title_line):
    header = (
        '# ================================================================\n'
        '# %s\n'
        '# 规则源: Loyalsoldier/clash-rules (RULE-SET，Clash 每日自动更新)\n'
        '# 还原方式: python clash_rebuild_rules.py --restore\n'
        '# ================================================================\n'
    ) % title_line
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


def main():
    _fix_stdout()
    ap = argparse.ArgumentParser(description='整套重建 Clash Verge 所有订阅的分流规则（支持右键编辑规则查看）')
    ap.add_argument('--dir', help='Clash Verge 配置目录（默认自动找 %%APPDATA%% 下）')
    ap.add_argument('--dry-run', action='store_true', help='只预览，不写入')
    ap.add_argument('--cdn', choices=['raw', 'jsdelivr'], default='raw',
                    help='规则下载源：raw=GitHub 原始地址(默认)，jsdelivr=国内 CDN 镜像')
    ap.add_argument('--no-proxy-download', action='store_true',
                    help='rule-providers 下载时不指定 proxy（境外网络或 CDN 可直连时用）')
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

    base_url = CDN_BASE if args.cdn == 'jsdelivr' else RAW_BASE
    if not args.restore:
        print('规则源: %s' % base_url)
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
        seen_merge[merge_uid] = name
        seen_rules[rules_uid] = name

        sub_path = os.path.join(profiles_dir, sub_file) if sub_file else ''
        group, sub_rules = inspect_subscription(sub_path, it.get('selected'))
        if not group:
            print('  [warn] 无法确定该订阅的有效主代理组名，跳过。\n')
            continue

        print('  主代理组: %s' % group)
        print('  Merge 文件 (rule-providers):       %s' % merge_path)
        print('  Rules 文件 (右键「编辑规则」可见): %s（屏蔽原订阅规则 %d 条）' % (rules_path, len(sub_rules)))

        provider_proxy = None if args.no_proxy_download else group
        existing_merge = load_yaml_dict(merge_path)
        merge_cfg = build_merge_cfg(existing_merge, base_url, provider_proxy)
        rules_cfg = build_rules_cfg(group, sub_rules)

        merge_text = dump_yaml_with_header(merge_cfg, '由 clash_rebuild_rules.py 生成：rule-providers 规则集数据源')
        rules_text = dump_yaml_with_header(rules_cfg, '由 clash_rebuild_rules.py 生成：右键「编辑规则」前置分流规则')

        if args.dry_run:
            print('  ----- Merge 将写入的内容 -----')
            for line in merge_text.rstrip('\n').splitlines():
                print('  | ' + line)
            print('  ----- Rules (prepend 预览，delete 共 %d 条已省略) -----' % len(sub_rules))
            preview_rules = {'prepend': rules_cfg['prepend'], 'append': [], 'delete': ['<共 %d 条原订阅规则>' % len(sub_rules)]}
            for line in dump_yaml_with_header(preview_rules, '右键「编辑规则」预览').rstrip('\n').splitlines():
                print('  | ' + line)
            print()
            continue

        backup_and_write(merge_path, merge_text)
        backup_and_write(rules_path, rules_text)
        changed += 1
        print()

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
