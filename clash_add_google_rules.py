#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
给 Clash Verge (Rev) 所有订阅的「分流规则增强」加上 Claude / Codex(OpenAI) / Google 走代理 + Bing 走直连规则。

背景
----
- Clash Verge 里每个订阅可以挂一个「分流规则增强」文件（profiles/<uid>.yaml），
  内含 prepend / append / delete 三个列表；prepend 会插到订阅规则的最前面、优先级最高，
  而且订阅更新时不会被覆盖。
- 每个订阅的「代理组名」不一样，脚本会：
    1) 优先取 profiles.yaml 里该订阅 selected[0].name（Clash Verge 记录的主选择组）；
    2) 取不到时，回退到解析订阅配置里第一个 type=select 的代理组。

用法
----
  python clash_add_google_rules.py              # 应用（改动前自动备份为 .bak）
  python clash_add_google_rules.py --dry-run    # 只预览，不写入
  python clash_add_google_rules.py --dir D:\\xxx  # 手动指定 Clash Verge 配置目录

依赖：PyYAML（pip install pyyaml）
"""

import argparse
import os
import shutil
import sys

try:
    import yaml
except ImportError:
    sys.exit("缺少 PyYAML，请先运行: pip install pyyaml")

# 规则分组：[(分组名, [规则模板, ...]), ...]
#   - 含 {group} 的会替换成各订阅自己的代理组名（走代理）；
#   - 不含 {group} 的（如 DIRECT）原样写入。
# 说明：这些规则会插到订阅规则最前面，订阅更新后不会被覆盖。
RULE_GROUPS = [
    ('Bing 直连', [
        'DOMAIN-KEYWORD,bing,DIRECT',
    ]),
    ('Claude (Anthropic)', [
        'DOMAIN-SUFFIX,claude.ai,{group}',
        'DOMAIN-SUFFIX,claude.com,{group}',
        'DOMAIN-SUFFIX,anthropic.com,{group}',
        'DOMAIN-SUFFIX,claudeusercontent.com,{group}',
        'DOMAIN,servd-anthropic-website.b-cdn.net,{group}',
    ]),
    # 参考 blackmatrix7 OpenAI 类别里的 OpenAI 自有域名；共享第三方（auth0/stripe/sentry/algolia/livekit 根域等）不纳入，避免误伤其他网站
    ('Codex (OpenAI)', [
        'DOMAIN-SUFFIX,openai.com,{group}',
        'DOMAIN-SUFFIX,chatgpt.com,{group}',
        'DOMAIN-SUFFIX,oaistatic.com,{group}',
        'DOMAIN-SUFFIX,oaiusercontent.com,{group}',
        'DOMAIN-SUFFIX,sora.com,{group}',
        'DOMAIN-SUFFIX,ai.com,{group}',
        'DOMAIN-SUFFIX,openaiapi-site.azureedge.net,{group}',
        'DOMAIN-SUFFIX,openaicom.imgix.net,{group}',
        'DOMAIN-SUFFIX,chatgpt.livekit.cloud,{group}',
    ]),
    # 参考 blackmatrix7 Google 类别(701条)，只取非广告、且不含 google 关键字的域名；广告域名(doubleclick/admob/adsense 等)不纳入，避免覆盖订阅里的广告拦截
    ('Google', [
        'DOMAIN,safebrowsing.googleapis.com,{group}',
        'DOMAIN-SUFFIX,gstatic.com,{group}',
        'DOMAIN-SUFFIX,gstatic.cn,{group}',
        'DOMAIN-SUFFIX,gvt0.com,{group}',
        'DOMAIN-SUFFIX,gvt1.com,{group}',
        'DOMAIN-SUFFIX,gvt2.com,{group}',
        'DOMAIN-SUFFIX,gvt3.com,{group}',
        'DOMAIN-SUFFIX,gvt5.com,{group}',
        'DOMAIN-SUFFIX,gvt6.com,{group}',
        'DOMAIN-SUFFIX,gvt7.com,{group}',
        'DOMAIN-SUFFIX,gvt9.com,{group}',
        'DOMAIN-SUFFIX,g.co,{group}',
        'DOMAIN-SUFFIX,goo.gl,{group}',
        'DOMAIN-SUFFIX,ggpht.com,{group}',
        'DOMAIN-SUFFIX,gmodules.com,{group}',
        'DOMAIN-SUFFIX,googlemail.com,{group}',
        'DOMAIN-SUFFIX,gmail.com,{group}',
        'DOMAIN-SUFFIX,youtu.be,{group}',
        'DOMAIN-SUFFIX,ytimg.com,{group}',
        'DOMAIN-SUFFIX,youtube.com,{group}',
        'DOMAIN-SUFFIX,youtubekids.com,{group}',
        'DOMAIN-SUFFIX,youtube-nocookie.com,{group}',
        'DOMAIN-SUFFIX,withgoogle.com,{group}',
        'DOMAIN-SUFFIX,recaptcha.net,{group}',
        'DOMAIN-SUFFIX,android.com,{group}',
        'DOMAIN-SUFFIX,chromium.org,{group}',
        'DOMAIN-SUFFIX,deepmind.com,{group}',
    ]),
]


def _fix_stdout():
    # 避免在 GBK 控制台打印中文/emoji 组名时 UnicodeEncodeError 崩溃
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8', errors='replace')
        except Exception:
            pass


def find_config_dir(explicit=None):
    if explicit:
        return explicit
    env = os.environ.get('CLASH_VERGE_DIR')
    if env and os.path.isfile(os.path.join(env, 'profiles.yaml')):
        return env

    app_ids = [
        'io.github.clash-verge-rev.clash-verge-rev',
        'io.github.clash-verge.clash-verge',
    ]
    bases = []
    appdata = os.environ.get('APPDATA')          # Windows
    if appdata:
        bases.append(appdata)
    bases.append(os.path.expanduser('~/Library/Application Support'))  # macOS
    xdg = os.environ.get('XDG_DATA_HOME') or os.path.expanduser('~/.local/share')  # Linux
    bases.append(xdg)
    bases.append(os.path.expanduser('~/.config'))

    for base in bases:
        for app_id in app_ids:
            c = os.path.join(base, app_id)
            if os.path.isfile(os.path.join(c, 'profiles.yaml')):
                return c
    return None


def find_first_select_group(sub_yaml_path):
    """在订阅配置里找第一个 type=select 的代理组名，解析失败返回 None。"""
    try:
        with open(sub_yaml_path, 'r', encoding='utf-8') as f:
            cfg = yaml.safe_load(f)
        for g in (cfg or {}).get('proxy-groups') or []:
            if isinstance(g, dict) and g.get('type') == 'select' and g.get('name'):
                return g['name']
    except Exception:
        pass
    return None


def load_rules(path):
    with open(path, 'r', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
    data.setdefault('prepend', [])
    data.setdefault('append', [])
    data.setdefault('delete', [])
    return data


def _quote(s):
    return "'" + str(s).replace("'", "''") + "'"


def _flow(items):
    if not items:
        return '[]'
    return '[' + ', '.join(_quote(i) for i in items) + ']'


def dump_rules(data):
    """按 Clash Verge 自己的格式写回，避免 YAML 序列化风格差异。"""
    lines = []
    prepend = data.get('prepend') or []
    if prepend:
        lines.append('prepend:')
        for r in prepend:
            lines.append('  - ' + _quote(r))
    else:
        lines.append('prepend: []')
    lines.append('append: ' + _flow(data.get('append') or []))
    lines.append('delete: ' + _flow(data.get('delete') or []))
    return '\n'.join(lines) + '\n'


def main():
    _fix_stdout()
    ap = argparse.ArgumentParser(description='给所有订阅加 Google 走代理规则')
    ap.add_argument('--dir', help='Clash Verge 配置目录（默认自动找 %%APPDATA%% 下）')
    ap.add_argument('--dry-run', action='store_true', help='只预览，不写入')
    args = ap.parse_args()

    cfg_dir = find_config_dir(args.dir)
    if not cfg_dir:
        sys.exit('未找到 Clash Verge 配置目录，请用 --dir 指定（目录需包含 profiles.yaml）。')
    profiles_dir = os.path.join(cfg_dir, 'profiles')
    profiles_yaml = os.path.join(cfg_dir, 'profiles.yaml')
    print('配置目录: %s\n' % cfg_dir)

    with open(profiles_yaml, 'r', encoding='utf-8') as f:
        pf = yaml.safe_load(f) or {}

    remotes = [it for it in (pf.get('items') or []) if it.get('type') == 'remote']
    if not remotes:
        print('profiles.yaml 里没有 type: remote 的订阅。')
        return

    changed = 0
    for it in remotes:
        name = it.get('name') or it.get('file') or '?'
        sub_file = it.get('file')
        opt = it.get('option') or {}
        rules_uid = opt.get('rules')
        selected = it.get('selected') or []
        main_group = selected[0].get('name') if selected else None

        print('订阅: %s' % name)
        if not rules_uid:
            print('  [skip] 该订阅没有「分流规则增强」，请先在 UI 里给订阅勾选/创建一个。\n')
            continue
        rules_path = os.path.join(profiles_dir, rules_uid + '.yaml')
        if not os.path.isfile(rules_path):
            print('  [warn] 找不到规则增强文件 %s，跳过。\n' % rules_path)
            continue

        group = main_group
        if not group and sub_file:
            sub_path = os.path.join(profiles_dir, sub_file)
            if os.path.isfile(sub_path):
                group = find_first_select_group(sub_path)
        if not group:
            print('  [warn] 无法确定该订阅的代理组名，跳过。\n')
            continue
        print('  目标代理组: %s' % group)

        data = load_rules(rules_path)
        prepend = data['prepend']
        existing = set()
        for r in prepend:
            parts = str(r).split(',', 2)
            if len(parts) >= 2:
                existing.add(parts[0] + ',' + parts[1])

        to_add = []
        for _grp, templates in RULE_GROUPS:
            for tmpl in templates:
                rule = tmpl.format(group=group)
                prefix = ','.join(rule.split(',', 2)[:2])
                if prefix in existing:
                    print('  [已存在] %s' % rule)
                else:
                    to_add.append(rule)

        if not to_add:
            print('  无需改动。\n')
            continue

        print('  将新增 %d 条:' % len(to_add))
        for r in to_add:
            print('    + %s' % r)

        if args.dry_run:
            print()
            continue

        bak = rules_path + '.bak'
        if not os.path.exists(bak):
            shutil.copy2(rules_path, bak)
            print('  已备份: %s' % bak)
        data['prepend'] = prepend + to_add
        with open(rules_path, 'w', encoding='utf-8') as f:
            f.write(dump_rules(data))
        changed += 1
        print('  已写入: %s\n' % rules_path)

    print('=' * 55)
    if args.dry_run:
        print('dry-run 模式，未写入任何文件。确认无误后去掉 --dry-run 再运行。')
    else:
        print('完成，共修改 %d 个规则增强文件。' % changed)
        print('请回到 Clash Verge 重新激活一次订阅（或重启内核）让规则生效。')


if __name__ == '__main__':
    main()
