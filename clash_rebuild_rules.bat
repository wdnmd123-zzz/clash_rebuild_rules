@echo off
setlocal
chcp 65001 >nul
set "CLASH_BAT_SELF=%~f0"
set "_CLASH_N=0"
:clash_arg_loop
if "%~1"=="" (
    if %1.==. goto :clash_arg_done
)
set /a _CLASH_N+=1
set "CLASH_ARG_%_CLASH_N%=%~1"
shift
goto :clash_arg_loop
:clash_arg_done
set "CLASH_ARGC=%_CLASH_N%"
set "_PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%_PS_EXE%" set "_PS_EXE=powershell.exe"
"%_PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$u=[System.Text.UTF8Encoding]::new($false); [Console]::OutputEncoding=$u; $OutputEncoding=$u; $r=[System.IO.File]::ReadAllText($env:CLASH_BAT_SELF,[System.Text.Encoding]::UTF8); $m='#<<<'+'PS_START>>>'; $i=$r.IndexOf($m); if($i -lt 0){throw 'Script marker not found'}; & ([scriptblock]::Create($r.Substring($i+$m.Length)))"
set "_CLASH_EC=%ERRORLEVEL%"
endlocal & exit /b %_CLASH_EC%
#<<<PS_START>>>
# ==============================================================================
# clash_rebuild_rules.bat - Clash Verge 分流规则重建工具（免 Python 独立版）
# 内置纯 PowerShell YAML 解析/序列化与交互菜单，零外部依赖，双击即可使用。
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 启用 TLS 1.2 / 1.3（Windows PowerShell 5.1 默认仅启用旧版 TLS）
try {
    $proto = [System.Net.ServicePointManager]::SecurityProtocol
    $proto = $proto -bor 3072   # TLS 1.2
    try { $proto = $proto -bor 12288 } catch {} # TLS 1.3 (Win11 / .NET 4.8+)
    [System.Net.ServicePointManager]::SecurityProtocol = $proto
} catch {}

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:InvCulture = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------- 规则源定义（与 clash_rebuild_rules.py 保持一致） ----------------
$script:RuleSources = [ordered]@{
    'loyalsoldier' = @{
        label     = 'Loyalsoldier/clash-rules (YAML)'
        format    = 'yaml'
        path_tpl  = './ruleset/clashrules_{0}.yaml'
        raw_base  = 'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/'
        cdn_base  = 'https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/'
        providers = @(
            @('private', 'private.txt', 'domain'),
            @('reject',  'reject.txt',  'domain'),
            @('icloud',  'icloud.txt',  'domain'),
            @('apple',   'apple.txt',   'domain'),
            @('google',  'google.txt',  'domain'),
            @('gfw',     'gfw.txt',     'domain'),
            @('direct',  'direct.txt',  'domain'),
            @('proxy',   'proxy.txt',   'domain'),
            @('lancidr', 'lancidr.txt', 'ipcidr'),
            @('cncidr',  'cncidr.txt',  'ipcidr')
        )
    }
    'metacubex' = @{
        label     = 'MetaCubeX/meta-rules-dat (MRS 二进制，低内存)'
        format    = 'mrs'
        path_tpl  = './ruleset/metacubex_{0}.mrs'
        raw_base  = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/'
        cdn_base  = 'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/'
        providers = @(
            @('private', 'geo/geosite/private.mrs',          'domain'),
            @('reject',  'geo/geosite/category-ads-all.mrs', 'domain'),
            @('icloud',  'geo/geosite/icloud.mrs',           'domain'),
            @('apple',   'geo/geosite/apple-cn.mrs',         'domain'),
            @('google',  'geo/geosite/google.mrs',           'domain'),
            @('gfw',     'geo/geosite/gfw.mrs',              'domain'),
            @('direct',  'geo/geosite/cn.mrs',               'domain'),
            @('proxy',   'geo/geosite/geolocation-!cn.mrs',  'domain'),
            @('lancidr', 'geo/geoip/private.mrs',            'ipcidr'),
            @('cncidr',  'geo/geoip/cn.mrs',                 'ipcidr')
        )
    }
}

$script:RuleTemplates = @(
    'RULE-SET,private,DIRECT',
    'DOMAIN-SUFFIX,gvt2.com,{group}',
    'DOMAIN,statsig.anthropic.com,{group}',
    'RULE-SET,reject,REJECT',
    'DOMAIN-SUFFIX,bing.com,DIRECT',
    'DOMAIN-SUFFIX,bing.net,DIRECT',
    'DOMAIN-SUFFIX,bingapis.com,DIRECT',
    'DOMAIN-SUFFIX,bingj.com,DIRECT',
    'RULE-SET,icloud,DIRECT',
    'RULE-SET,apple,DIRECT',
    'RULE-SET,google,{group}',
    'DOMAIN-SUFFIX,gstatic.cn,{group}',
    'RULE-SET,gfw,{group}',
    'RULE-SET,direct,DIRECT',
    'RULE-SET,proxy,{group}',
    'RULE-SET,lancidr,DIRECT,no-resolve',
    'RULE-SET,cncidr,DIRECT,no-resolve',
    'GEOIP,LAN,DIRECT',
    'GEOIP,CN,DIRECT',
    'MATCH,{group}'
)

function Get-RuleKey([string]$Rule) {
    $parts = $Rule.Split(',')
    if ($parts.Length -eq 0) { return '' }
    $rtype = $parts[0].Trim().ToUpperInvariant()
    if ($rtype -ceq 'MATCH' -or $rtype -ceq 'FINAL') {
        return $rtype
    }
    if ($parts.Length -ge 2) {
        return $rtype + ',' + $parts[1].Trim().ToLowerInvariant()
    }
    return $rtype
}

$script:ManagedProviderNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($srcKey in $script:RuleSources.Keys) {
    foreach ($p in $script:RuleSources[$srcKey].providers) {
        [void]$script:ManagedProviderNames.Add($p[0])
    }
}

$script:ManagedRuleKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($tpl in $script:RuleTemplates) {
    [void]$script:ManagedRuleKeys.Add((Get-RuleKey $tpl))
}
[void]$script:ManagedRuleKeys.Add('MATCH')
[void]$script:ManagedRuleKeys.Add('FINAL')

# ==============================================================================
# 自包含纯 PowerShell YAML 解析器 & 序列化器
# ==============================================================================

function New-OrderedDict {
    return (New-Object System.Collections.Specialized.OrderedDictionary)
}

function New-ObjList {
    return ,(New-Object 'System.Collections.Generic.List[object]')
}

function Get-LineIndent([string]$Line) {
    $n = 0
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($ch -eq ' ') { $n++ }
        elseif ($ch -eq "`t") { $n += 2 }
        else { break }
    }
    return $n
}

function Strip-YamlComment([string]$Text) {
    $inSingle = $false
    $inDouble = $false
    $len = $Text.Length
    for ($i = 0; $i -lt $len; $i++) {
        $ch = $Text[$i]
        if ($inSingle) {
            if ($ch -eq "'") {
                if (($i + 1) -lt $len -and $Text[$i + 1] -eq "'") { $i++ }
                else { $inSingle = $false }
            }
        } elseif ($inDouble) {
            if ($ch -eq '\') { $i++ }
            elseif ($ch -eq '"') { $inDouble = $false }
        } else {
            if ($ch -eq "'") { $inSingle = $true }
            elseif ($ch -eq '"') { $inDouble = $true }
            elseif ($ch -eq '#') {
                if ($i -eq 0 -or $Text[$i - 1] -eq ' ' -or $Text[$i - 1] -eq "`t") {
                    return $Text.Substring(0, $i).TrimEnd()
                }
            }
        }
    }
    return $Text.TrimEnd()
}

function Unescape-YamlDoubleQuoted([string]$Inner) {
    $sb = New-Object System.Text.StringBuilder ($Inner.Length)
    $len = $Inner.Length
    for ($i = 0; $i -lt $len; $i++) {
        $ch = $Inner[$i]
        if ($ch -eq '\' -and ($i + 1) -lt $len) {
            $i++
            $esc = $Inner[$i]
            switch -CaseSensitive ($esc) {
                'n'  { [void]$sb.Append("`n") }
                'r'  { [void]$sb.Append("`r") }
                't'  { [void]$sb.Append("`t") }
                'b'  { [void]$sb.Append("`b") }
                'f'  { [void]$sb.Append("`f") }
                '0'  { [void]$sb.Append([char]0) }
                'a'  { [void]$sb.Append([char]7) }
                'v'  { [void]$sb.Append([char]11) }
                'e'  { [void]$sb.Append([char]27) }
                '"'  { [void]$sb.Append('"') }
                '\'  { [void]$sb.Append('\') }
                '/'  { [void]$sb.Append('/') }
                ' '  { [void]$sb.Append(' ') }
                'N'  { [void]$sb.Append([char]0x85) }
                '_'  { [void]$sb.Append([char]0xA0) }
                'x'  {
                    if (($i + 2) -lt $len) {
                        $hex = $Inner.Substring($i + 1, 2)
                        $code = 0
                        if ([int]::TryParse($hex, [System.Globalization.NumberStyles]::HexNumber, $script:InvCulture, [ref]$code)) {
                            [void]$sb.Append([char]$code)
                            $i += 2
                        } else { [void]$sb.Append('\x') }
                    } else { [void]$sb.Append('\x') }
                }
                'u'  {
                    if (($i + 4) -lt $len) {
                        $hex = $Inner.Substring($i + 1, 4)
                        $code = 0
                        if ([int]::TryParse($hex, [System.Globalization.NumberStyles]::HexNumber, $script:InvCulture, [ref]$code)) {
                            [void]$sb.Append([char]$code)
                            $i += 4
                        } else { [void]$sb.Append('\u') }
                    } else { [void]$sb.Append('\u') }
                }
                'U'  {
                    if (($i + 8) -lt $len) {
                        $hex = $Inner.Substring($i + 1, 8)
                        $code = 0
                        if ([int]::TryParse($hex, [System.Globalization.NumberStyles]::HexNumber, $script:InvCulture, [ref]$code)) {
                            [void]$sb.Append([char]::ConvertFromUtf32($code))
                            $i += 8
                        } else { [void]$sb.Append('\U') }
                    } else { [void]$sb.Append('\U') }
                }
                default { [void]$sb.Append($esc) }
            }
        } else {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString()
}

function Convert-YamlPlainScalar([string]$Text) {
    $t = $Text.Trim()
    if ($t.Length -eq 0) { return $null }
    if ($t -ceq 'null' -or $t -ceq 'Null' -or $t -ceq 'NULL' -or $t -ceq '~') { return $null }
    if ($t -ceq 'true' -or $t -ceq 'True' -or $t -ceq 'TRUE') { return $true }
    if ($t -ceq 'false' -or $t -ceq 'False' -or $t -ceq 'FALSE') { return $false }
    if ($t -cmatch '^-?(0|[1-9][0-9]*)$') {
        $iv = [long]0
        if ([long]::TryParse($t, [System.Globalization.NumberStyles]::Integer, $script:InvCulture, [ref]$iv)) {
            return $iv
        }
    }
    if ($t -cmatch '^-?(0|[1-9][0-9]*)\.[0-9]+([eE][+-]?[0-9]+)?$' -or $t -cmatch '^-?(0|[1-9][0-9]*)[eE][+-]?[0-9]+$') {
        $dv = [double]0
        if ([double]::TryParse($t, [System.Globalization.NumberStyles]::Float, $script:InvCulture, [ref]$dv)) {
            return $dv
        }
    }
    return $t
}

function Parse-YamlScalarToken([string]$Text, [hashtable]$Anchors) {
    $t = $Text.Trim()
    if ($t.Length -eq 0) { return $null }

    # 处理前导锚点 &name
    $anchorName = $null
    if ($t[0] -eq '&') {
        if ($t -cmatch '^&([^\s,\[\]\{\}]+)(?:\s+(.*))?$') {
            $anchorName = $Matches[1]
            $t = if ($Matches[2]) { $Matches[2].Trim() } else { '' }
        }
    }

    # 处理别名 *name
    if ($t.Length -gt 1 -and $t[0] -eq '*') {
        $aliasName = $t.Substring(1).Trim()
        if ($Anchors.ContainsKey($aliasName)) {
            $val = $Anchors[$aliasName]
            if ($anchorName) { $Anchors[$anchorName] = $val }
            return ,$val
        }
    }

    # 剥离本地标签如 !!str
    $forceStr = $false
    if ($t -cmatch '^!!str(?:\s+(.*))?$') {
        $forceStr = $true
        $t = if ($Matches[1]) { $Matches[1].Trim() } else { '' }
    }

    $result = $null
    if ($t.Length -ge 2 -and $t[0] -eq "'" -and $t[$t.Length - 1] -eq "'") {
        $result = $t.Substring(1, $t.Length - 2).Replace("''", "'")
    } elseif ($t.Length -ge 2 -and $t[0] -eq '"' -and $t[$t.Length - 1] -eq '"') {
        $result = Unescape-YamlDoubleQuoted $t.Substring(1, $t.Length - 2)
    } elseif ($forceStr) {
        $result = $t
    } else {
        $result = Convert-YamlPlainScalar $t
    }

    if ($anchorName) { $Anchors[$anchorName] = $result }
    return ,$result
}

function Parse-YamlKeyString([string]$RawKey) {
    $k = $RawKey.Trim()
    if ($k.Length -ge 2 -and $k[0] -eq "'" -and $k[$k.Length - 1] -eq "'") {
        return $k.Substring(1, $k.Length - 2).Replace("''", "'")
    }
    if ($k.Length -ge 2 -and $k[0] -eq '"' -and $k[$k.Length - 1] -eq '"') {
        return Unescape-YamlDoubleQuoted $k.Substring(1, $k.Length - 2)
    }
    return $k
}

function Split-YamlMappingLine([string]$Trimmed) {
    if ($Trimmed.Length -eq 0) { return $null }
    $first = $Trimmed[0]
    if ($first -eq '{' -or $first -eq '[') { return $null }
    if ($first -eq '-' -and ($Trimmed.Length -eq 1 -or $Trimmed[1] -eq ' ' -or $Trimmed[1] -eq "`t")) { return $null }

    $inSingle = $false
    $inDouble = $false
    $depth = 0
    $len = $Trimmed.Length
    for ($i = 0; $i -lt $len; $i++) {
        $ch = $Trimmed[$i]
        if ($inSingle) {
            if ($ch -eq "'") {
                if (($i + 1) -lt $len -and $Trimmed[$i + 1] -eq "'") { $i++ }
                else { $inSingle = $false }
            }
        } elseif ($inDouble) {
            if ($ch -eq '\') { $i++ }
            elseif ($ch -eq '"') { $inDouble = $false }
        } else {
            if ($ch -eq "'") { $inSingle = $true }
            elseif ($ch -eq '"') { $inDouble = $true }
            elseif ($ch -eq '[' -or $ch -eq '{') { $depth++ }
            elseif ($ch -eq ']' -or $ch -eq '}') { if ($depth -gt 0) { $depth-- } }
            elseif ($ch -eq ':' -and $depth -eq 0) {
                $isBoundary = (($i + 1) -eq $len) -or ($Trimmed[$i + 1] -eq ' ') -or ($Trimmed[$i + 1] -eq "`t")
                if ($isBoundary) {
                    $keyPart = $Trimmed.Substring(0, $i).Trim()
                    $valPart = if (($i + 1) -lt $len) { $Trimmed.Substring($i + 1).Trim() } else { '' }
                    return [PSCustomObject]@{
                        Key = (Parse-YamlKeyString $keyPart)
                        Val = $valPart
                    }
                }
            }
        }
    }
    return $null
}

function Is-FlowBalanced([string]$Text) {
    $inSingle = $false
    $inDouble = $false
    $depth = 0
    $len = $Text.Length
    for ($i = 0; $i -lt $len; $i++) {
        $ch = $Text[$i]
        if ($inSingle) {
            if ($ch -eq "'") {
                if (($i + 1) -lt $len -and $Text[$i + 1] -eq "'") { $i++ }
                else { $inSingle = $false }
            }
        } elseif ($inDouble) {
            if ($ch -eq '\') { $i++ }
            elseif ($ch -eq '"') { $inDouble = $false }
        } else {
            if ($ch -eq "'") { $inSingle = $true }
            elseif ($ch -eq '"') { $inDouble = $true }
            elseif ($ch -eq '#') {
                if ($i -eq 0 -or $Text[$i - 1] -eq ' ' -or $Text[$i - 1] -eq "`t" -or $Text[$i - 1] -eq "`n") {
                    while ($i -lt $len -and $Text[$i] -ne "`n") { $i++ }
                }
            }
            elseif ($ch -eq '[' -or $ch -eq '{') { $depth++ }
            elseif ($ch -eq ']' -or $ch -eq '}') { $depth-- }
        }
    }
    return (-not $inSingle -and -not $inDouble -and $depth -le 0)
}

function Skip-FlowWS([string]$Text, [ref]$Pos) {
    $len = $Text.Length
    while ($Pos.Value -lt $len) {
        $ch = $Text[$Pos.Value]
        if ($ch -eq ' ' -or $ch -eq "`t" -or $ch -eq "`r" -or $ch -eq "`n") {
            $Pos.Value++
        } elseif ($ch -eq '#') {
            while ($Pos.Value -lt $len -and $Text[$Pos.Value] -ne "`n") { $Pos.Value++ }
        } else {
            break
        }
    }
}

function Parse-FlowValue([string]$Text, [ref]$Pos, [hashtable]$Anchors) {
    Skip-FlowWS $Text $Pos
    $len = $Text.Length
    if ($Pos.Value -ge $len) { return [PSCustomObject]@{ Value = $null } }

    # 锚点
    $anchorName = $null
    if ($Text[$Pos.Value] -eq '&') {
        $Pos.Value++
        $start = $Pos.Value
        while ($Pos.Value -lt $len -and $Text[$Pos.Value] -cnotin @(' ', "`t", "`r", "`n", ',', ']', '}', '[', '{')) {
            $Pos.Value++
        }
        $anchorName = $Text.Substring($start, $Pos.Value - $start)
        Skip-FlowWS $Text $Pos
        if ($Pos.Value -ge $len) {
            $Anchors[$anchorName] = $null
            return [PSCustomObject]@{ Value = $null }
        }
    }

    $ch = $Text[$Pos.Value]
    $val = $null

    if ($ch -eq '{') {
        $Pos.Value++
        $dict = New-OrderedDict
        while ($true) {
            Skip-FlowWS $Text $Pos
            if ($Pos.Value -ge $len) { break }
            if ($Text[$Pos.Value] -eq '}') { $Pos.Value++; break }

            # 解析 key
            $kch = $Text[$Pos.Value]
            $keyStr = ''
            $keyWasQuoted = $false
            if ($kch -eq "'" -or $kch -eq '"') {
                $keyWasQuoted = $true
                $kv = Parse-FlowValue $Text $Pos $Anchors
                $keyStr = [string]$kv.Value
                Skip-FlowWS $Text $Pos
            } else {
                $kstart = $Pos.Value
                while ($Pos.Value -lt $len) {
                    $c = $Text[$Pos.Value]
                    if ($c -eq ':' -and (($Pos.Value + 1) -ge $len -or $Text[$Pos.Value + 1] -cin @(' ', "`t", "`r", "`n", ',', '}', ']'))) { break }
                    if ($c -eq ',' -or $c -eq '}') { break }
                    $Pos.Value++
                }
                $keyStr = $Text.Substring($kstart, $Pos.Value - $kstart).Trim()
            }

            Skip-FlowWS $Text $Pos
            $itemVal = $null
            if ($Pos.Value -lt $len -and $Text[$Pos.Value] -eq ':') {
                $Pos.Value++
                Skip-FlowWS $Text $Pos
                if ($Pos.Value -lt $len -and $Text[$Pos.Value] -ne ',' -and $Text[$Pos.Value] -ne '}') {
                    $itemVal = (Parse-FlowValue $Text $Pos $Anchors).Value
                }
            }

            if ($keyStr -ceq '<<' -and -not $keyWasQuoted) {
                Merge-YamlAnchorValue $dict $itemVal
            } elseif ($keyStr.Length -gt 0 -or $keyWasQuoted) {
                $dict[$keyStr] = $itemVal
            }

            Skip-FlowWS $Text $Pos
            if ($Pos.Value -lt $len -and $Text[$Pos.Value] -eq ',') {
                $Pos.Value++
                continue
            }
            if ($Pos.Value -lt $len -and $Text[$Pos.Value] -eq '}') {
                $Pos.Value++
                break
            }
        }
        $val = $dict
    } elseif ($ch -eq '[') {
        $Pos.Value++
        $list = New-ObjList
        while ($true) {
            Skip-FlowWS $Text $Pos
            if ($Pos.Value -ge $len) { break }
            if ($Text[$Pos.Value] -eq ']') { $Pos.Value++; break }
            $elem = (Parse-FlowValue $Text $Pos $Anchors).Value
            [void]$list.Add($elem)
            Skip-FlowWS $Text $Pos
            if ($Pos.Value -lt $len -and $Text[$Pos.Value] -eq ',') {
                $Pos.Value++
                continue
            }
            if ($Pos.Value -lt $len -and $Text[$Pos.Value] -eq ']') {
                $Pos.Value++
                break
            }
        }
        $val = $list
    } elseif ($ch -eq "'") {
        $Pos.Value++
        $sb = New-Object System.Text.StringBuilder
        while ($Pos.Value -lt $len) {
            $c = $Text[$Pos.Value]
            if ($c -eq "'") {
                if (($Pos.Value + 1) -lt $len -and $Text[$Pos.Value + 1] -eq "'") {
                    [void]$sb.Append("'")
                    $Pos.Value += 2
                } else {
                    $Pos.Value++
                    break
                }
            } else {
                [void]$sb.Append($c)
                $Pos.Value++
            }
        }
        $val = $sb.ToString()
    } elseif ($ch -eq '"') {
        $Pos.Value++
        $start = $Pos.Value
        while ($Pos.Value -lt $len) {
            $c = $Text[$Pos.Value]
            if ($c -eq '\') { $Pos.Value += 2; continue }
            if ($c -eq '"') { break }
            $Pos.Value++
        }
        $inner = $Text.Substring($start, [Math]::Min($Pos.Value, $len) - $start)
        if ($Pos.Value -lt $len -and $Text[$Pos.Value] -eq '"') { $Pos.Value++ }
        $val = Unescape-YamlDoubleQuoted $inner
    } elseif ($ch -eq '*') {
        $Pos.Value++
        $start = $Pos.Value
        while ($Pos.Value -lt $len -and $Text[$Pos.Value] -cnotin @(' ', "`t", "`r", "`n", ',', ']', '}')) {
            $Pos.Value++
        }
        $aliasName = $Text.Substring($start, $Pos.Value - $start)
        $val = if ($Anchors.ContainsKey($aliasName)) { $Anchors[$aliasName] } else { '*' + $aliasName }
    } else {
        $start = $Pos.Value
        while ($Pos.Value -lt $len) {
            $c = $Text[$Pos.Value]
            if ($c -eq ',' -or $c -eq ']' -or $c -eq '}') { break }
            if ($c -eq '#' -and $Pos.Value -gt $start -and ($Text[$Pos.Value - 1] -eq ' ' -or $Text[$Pos.Value - 1] -eq "`t")) { break }
            $Pos.Value++
        }
        $raw = $Text.Substring($start, $Pos.Value - $start).Trim()
        $val = Convert-YamlPlainScalar $raw
    }

    if ($anchorName) { $Anchors[$anchorName] = $val }
    return [PSCustomObject]@{ Value = $val }
}

function Merge-YamlAnchorValue($TargetDict, $SourceVal) {
    if ($SourceVal -is [System.Collections.IDictionary]) {
        foreach ($entry in $SourceVal.GetEnumerator()) {
            $k = [string]$entry.Key
            if (-not $TargetDict.Contains($k)) {
                $TargetDict[$k] = $entry.Value
            }
        }
    } elseif ($SourceVal -is [System.Collections.IList]) {
        foreach ($item in $SourceVal) {
            if ($item -is [System.Collections.IDictionary]) {
                foreach ($entry in $item.GetEnumerator()) {
                    $k = [string]$entry.Key
                    if (-not $TargetDict.Contains($k)) {
                        $TargetDict[$k] = $entry.Value
                    }
                }
            }
        }
    }
}

function Collect-FlowText([string[]]$Lines, [int]$Index, [string]$InitialText) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($InitialText)
    $i = $Index
    while (-not (Is-FlowBalanced $sb.ToString()) -and ($i + 1) -lt $Lines.Length) {
        $i++
        [void]$sb.Append("`n")
        [void]$sb.Append($Lines[$i])
    }
    return [PSCustomObject]@{
        Text = $sb.ToString()
        Next = ($i + 1)
    }
}

function Parse-BlockScalar([string[]]$Lines, [int]$StartIndex, [int]$ParentIndent, [string]$Header) {
    $style = $Header[0] # | or >
    $chomp = ''
    $explicitIndent = 0
    for ($k = 1; $k -lt $Header.Length; $k++) {
        $c = $Header[$k]
        if ($c -eq '-' -or $c -eq '+') { $chomp = $c }
        elseif ($c -ge '1' -and $c -le '9') { $explicitIndent = [int]([string]$c) }
    }

    $blockIndent = if ($explicitIndent -gt 0) { $ParentIndent + $explicitIndent } else { -1 }
    $collected = New-Object 'System.Collections.Generic.List[string]'
    $i = $StartIndex
    while ($i -lt $Lines.Length) {
        $ln = $Lines[$i]
        if ($ln.Trim().Length -eq 0) {
            [void]$collected.Add('')
            $i++
            continue
        }
        $ind = Get-LineIndent $ln
        if ($blockIndent -lt 0) {
            if ($ind -le $ParentIndent) { break }
            $blockIndent = $ind
        } elseif ($ind -lt $blockIndent) {
            break
        }
        $sub = if ($ln.Length -ge $blockIndent) { $ln.Substring($blockIndent) } else { '' }
        [void]$collected.Add($sub)
        $i++
    }

    # 计算尾部空行
    $trailingEmpty = 0
    for ($k = $collected.Count - 1; $k -ge 0; $k--) {
        if ($collected[$k].Length -eq 0) { $trailingEmpty++ } else { break }
    }
    $contentCount = $collected.Count - $trailingEmpty

    $body = ''
    if ($contentCount -gt 0) {
        if ($style -eq '|') {
            $parts = New-Object 'System.Collections.Generic.List[string]'
            for ($k = 0; $k -lt $contentCount; $k++) { [void]$parts.Add($collected[$k]) }
            $body = [string]::Join("`n", $parts)
        } else {
            # Folded (>)
            $sb = New-Object System.Text.StringBuilder
            for ($k = 0; $k -lt $contentCount; $k++) {
                $cur = $collected[$k]
                if ($k -gt 0) {
                    $prev = $collected[$k - 1]
                    if ($cur.Length -eq 0 -or $prev.Length -eq 0 -or $cur[0] -eq ' ' -or $prev[0] -eq ' ') {
                        [void]$sb.Append("`n")
                    } else {
                        [void]$sb.Append(' ')
                    }
                }
                [void]$sb.Append($cur)
            }
            $body = $sb.ToString()
        }
    }

    if ($chomp -eq '-') {
        # strip trailing newlines
    } elseif ($chomp -eq '+') {
        if ($contentCount -gt 0) { $body += "`n" }
        if ($trailingEmpty -gt 0) { $body += ("`n" * $trailingEmpty) }
    } else {
        if ($contentCount -gt 0) { $body += "`n" }
    }

    return [PSCustomObject]@{ Value = $body; Next = $i }
}

function Next-NonEmptyYamlLine([string[]]$Lines, [int]$Index) {
    $i = $Index
    while ($i -lt $Lines.Length) {
        $stripped = (Strip-YamlComment $Lines[$i]).Trim()
        if ($stripped.Length -gt 0 -and $stripped -cne '---') {
            if ($stripped -ceq '...') { return $Lines.Length }
            return $i
        }
        $i++
    }
    return $Lines.Length
}

function Parse-YamlInlineOrNested([string[]]$Lines, [int]$CurIndex, [int]$ParentIndent, [string]$ValText, [hashtable]$Anchors, [bool]$AllowSameIndentSeq) {
    $v = $ValText.Trim()

    # 提取前导锚点
    $anchorName = $null
    if ($v.Length -gt 0 -and $v[0] -eq '&') {
        if ($v -cmatch '^&([^\s,\[\]\{\}]+)(?:\s+(.*))?$') {
            $anchorName = $Matches[1]
            $v = if ($Matches[2]) { $Matches[2].Trim() } else { '' }
        }
    }

    if ($v.Length -eq 0) {
        $ni = Next-NonEmptyYamlLine $Lines ($CurIndex + 1)
        if ($ni -lt $Lines.Length) {
            $nLine = $Lines[$ni]
            $nIndent = Get-LineIndent $nLine
            $nTrim = (Strip-YamlComment $nLine).Trim()
            $isSeq = ($nTrim -ceq '-' -or $nTrim.StartsWith('- ') -or $nTrim.StartsWith("-`t"))
            if ($nIndent -gt $ParentIndent -or ($AllowSameIndentSeq -and $isSeq -and $nIndent -ge $ParentIndent)) {
                $res = Parse-YamlBlock $Lines $ni $nIndent $Anchors
                if ($anchorName) { $Anchors[$anchorName] = $res.Value }
                return $res
            }
        }
        if ($anchorName) { $Anchors[$anchorName] = $null }
        return [PSCustomObject]@{ Value = $null; Next = ($CurIndex + 1) }
    }

    # 块标量 (| / >)
    if ($v -cmatch '^[|>][+-]?[1-9]?[+-]?$') {
        $res = Parse-BlockScalar $Lines ($CurIndex + 1) $ParentIndent $v
        if ($anchorName) { $Anchors[$anchorName] = $res.Value }
        return $res
    }

    # 流式集合 ({...} / [...])
    if ($v[0] -eq '{' -or $v[0] -eq '[') {
        $collected = Collect-FlowText $Lines $CurIndex $v
        $pos = 0
        $fv = (Parse-FlowValue $collected.Text ([ref]$pos) $Anchors).Value
        if ($anchorName) { $Anchors[$anchorName] = $fv }
        return [PSCustomObject]@{ Value = $fv; Next = $collected.Next }
    }

    # 普通标量 / 引号标量 / 别名
    $sv = Parse-YamlScalarToken $v $Anchors
    if ($anchorName) { $Anchors[$anchorName] = $sv }
    return [PSCustomObject]@{ Value = $sv; Next = ($CurIndex + 1) }
}

function Parse-YamlBlock([string[]]$Lines, [int]$StartIndex, [int]$ExpectedIndent, [hashtable]$Anchors) {
    $i = Next-NonEmptyYamlLine $Lines $StartIndex
    if ($i -ge $Lines.Length) {
        return [PSCustomObject]@{ Value = $null; Next = $i }
    }

    $firstTrim = (Strip-YamlComment $Lines[$i]).Trim()
    $firstIndent = Get-LineIndent $Lines[$i]

    # 判断是序列还是映射还是单值
    $isSeq = ($firstTrim -ceq '-' -or $firstTrim.StartsWith('- ') -or $firstTrim.StartsWith("-`t"))
    if ($isSeq) {
        $seqIndent = $firstIndent
        $list = New-ObjList
        while ($i -lt $Lines.Length) {
            $i = Next-NonEmptyYamlLine $Lines $i
            if ($i -ge $Lines.Length) { break }
            $ln = $Lines[$i]
            $ind = Get-LineIndent $ln
            if ($ind -lt $seqIndent) { break }
            if ($ind -gt $seqIndent) { break }
            $trimmed = (Strip-YamlComment $ln).Trim()
            if (-not ($trimmed -ceq '-' -or $trimmed.StartsWith('- ') -or $trimmed.StartsWith("-`t"))) {
                break
            }

            $rest = if ($trimmed.Length -gt 1) { $trimmed.Substring(1).TrimStart() } else { '' }
            if ($rest.Length -eq 0) {
                $ni = Next-NonEmptyYamlLine $Lines ($i + 1)
                if ($ni -lt $Lines.Length -and (Get-LineIndent $Lines[$ni]) -gt $seqIndent) {
                    $sub = Parse-YamlBlock $Lines $ni (Get-LineIndent $Lines[$ni]) $Anchors
                    [void]$list.Add($sub.Value)
                    $i = $sub.Next
                } else {
                    [void]$list.Add($null)
                    $i++
                }
                continue
            }

            # 紧凑嵌套序列: - - item
            if ($rest -ceq '-' -or $rest.StartsWith('- ') -or $rest.StartsWith("-`t")) {
                $dashOffset = $ln.IndexOf('-', $ind) + 1
                $subIndent = $dashOffset
                while ($subIndent -lt $ln.Length -and $ln[$subIndent] -eq ' ') { $subIndent++ }
                $synthLine = (' ' * $subIndent) + $rest
                $saved = $Lines[$i]
                $Lines[$i] = $synthLine
                $sub = Parse-YamlBlock $Lines $i $subIndent $Anchors
                $Lines[$i] = $saved
                [void]$list.Add($sub.Value)
                $i = $sub.Next
                continue
            }

            # 紧凑内联映射: - key: val
            $mapSplit = Split-YamlMappingLine $rest
            if ($null -ne $mapSplit) {
                $dashPos = $ln.IndexOf('-', $ind)
                $itemKeyIndent = $dashPos + 1
                while ($itemKeyIndent -lt $ln.Length -and ($ln[$itemKeyIndent] -eq ' ' -or $ln[$itemKeyIndent] -eq "`t")) {
                    $itemKeyIndent++
                }
                $dict = New-OrderedDict
                $valRes = Parse-YamlInlineOrNested $Lines $i $itemKeyIndent $mapSplit.Val $Anchors $true
                if ($mapSplit.Key -ceq '<<' -and -not $rest.StartsWith("'") -and -not $rest.StartsWith('"')) {
                    Merge-YamlAnchorValue $dict $valRes.Value
                } else {
                    $dict[$mapSplit.Key] = $valRes.Value
                }
                $i = $valRes.Next

                # 读取同一内联映射后续字段
                while ($i -lt $Lines.Length) {
                    $i = Next-NonEmptyYamlLine $Lines $i
                    if ($i -ge $Lines.Length) { break }
                    $nln = $Lines[$i]
                    $nind = Get-LineIndent $nln
                    if ($nind -ne $itemKeyIndent) { break }
                    $ntrim = (Strip-YamlComment $nln).Trim()
                    $nsplit = Split-YamlMappingLine $ntrim
                    if ($null -eq $nsplit) { break }
                    $nvRes = Parse-YamlInlineOrNested $Lines $i $itemKeyIndent $nsplit.Val $Anchors $true
                    if ($nsplit.Key -ceq '<<' -and -not $ntrim.StartsWith("'") -and -not $ntrim.StartsWith('"')) {
                        Merge-YamlAnchorValue $dict $nvRes.Value
                    } else {
                        $dict[$nsplit.Key] = $nvRes.Value
                    }
                    $i = $nvRes.Next
                }
                [void]$list.Add($dict)
                continue
            }

            # 普通列表项（标量 / 流式 / 块标量）
            $itemRes = Parse-YamlInlineOrNested $Lines $i $seqIndent $rest $Anchors $false
            [void]$list.Add($itemRes.Value)
            $i = $itemRes.Next
        }
        return [PSCustomObject]@{ Value = $list; Next = $i }
    }

    # 块级映射
    $firstSplit = Split-YamlMappingLine $firstTrim
    if ($null -ne $firstSplit) {
        $mapIndent = $firstIndent
        $dict = New-OrderedDict
        while ($i -lt $Lines.Length) {
            $i = Next-NonEmptyYamlLine $Lines $i
            if ($i -ge $Lines.Length) { break }
            $ln = $Lines[$i]
            $ind = Get-LineIndent $ln
            if ($ind -lt $mapIndent) { break }
            if ($ind -gt $mapIndent) { break }
            $trimmed = (Strip-YamlComment $ln).Trim()
            $sp = Split-YamlMappingLine $trimmed
            if ($null -eq $sp) { break }

            $vRes = Parse-YamlInlineOrNested $Lines $i $mapIndent $sp.Val $Anchors $true
            if ($sp.Key -ceq '<<' -and -not $trimmed.StartsWith("'") -and -not $trimmed.StartsWith('"')) {
                Merge-YamlAnchorValue $dict $vRes.Value
            } else {
                $dict[$sp.Key] = $vRes.Value
            }
            $i = $vRes.Next
        }
        return [PSCustomObject]@{ Value = $dict; Next = $i }
    }

    # 流式集合或单标量文档
    return (Parse-YamlInlineOrNested $Lines $i $firstIndent $firstTrim $Anchors $false)
}

function ConvertFrom-YamlText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) {
        $Text = $Text.Substring(1)
    }
    $norm = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $norm.Split("`n")
    $anchors = @{}
    $res = Parse-YamlBlock $lines 0 0 $anchors
    return ,$res.Value
}

function Load-YamlDict([string]$Path) {
    if (-not [string]::IsNullOrEmpty($Path) -and [System.IO.File]::Exists($Path)) {
        try {
            $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
            $data = ConvertFrom-YamlText $text
            if ($data -is [System.Collections.IDictionary]) {
                return $data
            }
        } catch {
            return (New-OrderedDict)
        }
    }
    return (New-OrderedDict)
}

function Load-SubscriptionYamlFast([string]$Path) {
    # 快速解析大型机场订阅 YAML：跳过巨大的 proxies 段，快速读取万行级 rules，完整解析 proxy-groups 与锚点
    $result = New-OrderedDict
    if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.File]::Exists($Path)) {
        return $result
    }
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        $lines = $text.Replace("`r`n", "`n").Replace("`r", "`n").Split("`n")

        $otherLines = New-Object 'System.Collections.Generic.List[string]'
        $rulesLines = New-Object 'System.Collections.Generic.List[string]'
        $rulesInlineVal = $null
        $section = ''

        for ($i = 0; $i -lt $lines.Length; $i++) {
            $ln = $lines[$i]
            if ($ln.Length -gt 0 -and $ln[0] -ne ' ' -and $ln[0] -ne "`t" -and $ln[0] -ne '#') {
                $t = (Strip-YamlComment $ln).Trim()
                if ($t -ceq '---') { continue }
                if ($t -ceq '...') { break }
                if ($t -cne '-' -and -not $t.StartsWith('- ') -and -not $t.StartsWith("-`t")) {
                    $sp = Split-YamlMappingLine $t
                    if ($null -ne $sp) {
                        $section = $sp.Key
                        if ($section -ceq 'rules') {
                            $rulesInlineVal = $sp.Val
                            [void]$rulesLines.Add($ln)
                            continue
                        }
                        if ($section -ceq 'proxies') {
                            continue
                        }
                    }
                }
            }

            if ($section -ceq 'proxies') {
                continue
            } elseif ($section -ceq 'rules') {
                [void]$rulesLines.Add($ln)
            } else {
                [void]$otherLines.Add($ln)
            }
        }

        if ($otherLines.Count -gt 0) {
            $parsed = ConvertFrom-YamlText ([string]::Join("`n", $otherLines))
            if ($parsed -is [System.Collections.IDictionary]) {
                $result = $parsed
            }
        }

        # 解析 rules 段（优先极速块列表路径，遇到流式/锚点则回退完整 YAML 解析）
        if ($rulesLines.Count -gt 0) {
            $useFallback = $false
            if (-not [string]::IsNullOrWhiteSpace($rulesInlineVal)) {
                $useFallback = $true
            }
            $fastRules = New-ObjList
            if (-not $useFallback) {
                for ($j = 1; $j -lt $rulesLines.Count; $j++) {
                    $rl = (Strip-YamlComment $rulesLines[$j]).Trim()
                    if ($rl.Length -eq 0) { continue }
                    if ($rl.StartsWith('- ') -or $rl.StartsWith("-`t")) {
                        $item = $rl.Substring(1).Trim()
                        if ($item.Length -eq 0) { continue }
                        if ($item[0] -eq '&' -or $item[0] -eq '*' -or $item[0] -eq '{' -or $item[0] -eq '[' -or $item[0] -eq '|' -or $item[0] -eq '>') {
                            $useFallback = $true
                            break
                        }
                        if ($item[0] -eq "'" -or $item[0] -eq '"') {
                            if ($item.Length -lt 2 -or $item[$item.Length - 1] -ne $item[0]) {
                                $useFallback = $true
                                break
                            }
                            if ($item[0] -eq "'") {
                                $item = $item.Substring(1, $item.Length - 2).Replace("''", "'")
                            } else {
                                $item = Unescape-YamlDoubleQuoted $item.Substring(1, $item.Length - 2)
                            }
                        }
                        [void]$fastRules.Add($item)
                    } else {
                        $useFallback = $true
                        break
                    }
                }
            }

            if ($useFallback) {
                $parsedRules = ConvertFrom-YamlText ([string]::Join("`n", $rulesLines))
                if ($parsedRules -is [System.Collections.IDictionary] -and $parsedRules.Contains('rules')) {
                    $result['rules'] = $parsedRules['rules']
                }
            } else {
                $result['rules'] = $fastRules
            }
        }
    } catch {
        return (Load-YamlDict $Path)
    }
    return $result
}

function Format-YamlDoubleQuoted([string]$Text) {
    $sb = New-Object System.Text.StringBuilder ($Text.Length + 4)
    [void]$sb.Append('"')
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        $code = [int]$ch
        switch ($ch) {
            '\'  { [void]$sb.Append('\\') }
            '"'  { [void]$sb.Append('\"') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            "`b" { [void]$sb.Append('\b') }
            "`f" { [void]$sb.Append('\f') }
            default {
                if ($code -lt 0x20 -or $code -eq 0x7F) {
                    [void]$sb.AppendFormat('\x{0:x2}', $code)
                } else {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Test-YamlNeedsQuoting([string]$Text, [bool]$IsKey) {
    if ($Text.Length -eq 0) { return $true }
    if ($Text[0] -eq ' ' -or $Text[0] -eq "`t" -or $Text[$Text.Length - 1] -eq ' ' -or $Text[$Text.Length - 1] -eq "`t") { return $true }

    # 控制字符 / 换行
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = [int]$Text[$i]
        if ($c -lt 0x20 -or $c -eq 0x7F) { return $true }
    }

    # 特殊起始字符
    $first = $Text[0]
    if ($first -cin @('-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', "'", '"', '%', '@', '`', '+')) {
        return $true
    }

    # 易歧义字面量（YAML 1.1 / 1.2 bool / null / float）
    $lower = $Text.ToLowerInvariant()
    if ($lower -cin @('null', '~', 'true', 'false', 'yes', 'no', 'on', 'off', 'y', 'n', '.inf', '+.inf', '-.inf', '.nan')) {
        return $true
    }

    # 数字、十六进制、八进制、六十进制、日期
    if ($Text -cmatch '^[+-]?[0-9][0-9_]*(\.[0-9_]*)?([eE][+-]?[0-9]+)?$' -or
        $Text -cmatch '^[+-]?\.[0-9_]+([eE][+-]?[0-9]+)?$' -or
        $Text -cmatch '^[+-]?0[xXoObB][0-9a-fA-F_]+$' -or
        $Text -cmatch '^[+-]?[0-9]+(:[0-5]?[0-9])+(\.[0-9]*)?$' -or
        $Text -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}') {
        return $true
    }

    # 内含破坏结构的字符序列
    if ($Text.EndsWith(':') -or $Text.Contains(': ') -or $Text.Contains(":`t") -or $Text.Contains(' #') -or $Text.Contains("`t#")) {
        return $true
    }

    if ($IsKey) {
        if ($Text.IndexOfAny([char[]]@(':', ',', '[', ']', '{', '}', '#')) -ge 0) {
            return $true
        }
    }

    return $false
}

function Format-YamlString([string]$Text, [bool]$IsKey) {
    if (-not (Test-YamlNeedsQuoting $Text $IsKey)) {
        return $Text
    }
    # 含控制字符或换行用双引号，其余优先单引号（更简洁可读）
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = [int]$Text[$i]
        if ($c -lt 0x20 -or $c -eq 0x7F) {
            return (Format-YamlDoubleQuoted $Text)
        }
    }
    return "'" + $Text.Replace("'", "''") + "'"
}

function Format-YamlScalar($Val) {
    if ($null -eq $Val) { return 'null' }
    if ($Val -is [bool]) { return $(if ($Val) { 'true' } else { 'false' }) }
    if ($Val -is [int] -or $Val -is [long] -or $Val -is [int16] -or $Val -is [byte] -or $Val -is [decimal]) {
        return $Val.ToString($script:InvCulture)
    }
    if ($Val -is [double] -or $Val -is [float]) {
        if ([double]::IsNaN($Val)) { return '.nan' }
        if ([double]::IsPositiveInfinity($Val)) { return '.inf' }
        if ([double]::IsNegativeInfinity($Val)) { return '-.inf' }
        return $Val.ToString('R', $script:InvCulture)
    }
    return (Format-YamlString ([string]$Val) $false)
}

function Write-YamlNode($Node, [int]$Indent, [System.Text.StringBuilder]$Sb) {
    $pad = ' ' * $Indent
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Count -eq 0) {
            [void]$Sb.Append($pad).Append("{}`n")
            return
        }
        foreach ($entry in $Node.GetEnumerator()) {
            $kStr = Format-YamlString ([string]$entry.Key) $true
            $v = $entry.Value
            if ($v -is [System.Collections.IDictionary]) {
                if ($v.Count -eq 0) {
                    [void]$Sb.Append($pad).Append($kStr).Append(": {}`n")
                } else {
                    [void]$Sb.Append($pad).Append($kStr).Append(":`n")
                    Write-YamlNode $v ($Indent + 2) $Sb
                }
            } elseif ($v -is [System.Collections.IList]) {
                if ($v.Count -eq 0) {
                    [void]$Sb.Append($pad).Append($kStr).Append(": []`n")
                } else {
                    [void]$Sb.Append($pad).Append($kStr).Append(":`n")
                    Write-YamlNode $v ($Indent + 2) $Sb
                }
            } else {
                [void]$Sb.Append($pad).Append($kStr).Append(': ').Append((Format-YamlScalar $v)).Append("`n")
            }
        }
        return
    }

    if ($Node -is [System.Collections.IList]) {
        if ($Node.Count -eq 0) {
            [void]$Sb.Append($pad).Append("[]`n")
            return
        }
        foreach ($item in $Node) {
            if ($item -is [System.Collections.IDictionary]) {
                if ($item.Count -eq 0) {
                    [void]$Sb.Append($pad).Append("- {}`n")
                } else {
                    $first = $true
                    foreach ($entry in $item.GetEnumerator()) {
                        $prefix = if ($first) { $pad + '- ' } else { $pad + '  ' }
                        $first = $false
                        $kStr = Format-YamlString ([string]$entry.Key) $true
                        $v = $entry.Value
                        if ($v -is [System.Collections.IDictionary]) {
                            if ($v.Count -eq 0) {
                                [void]$Sb.Append($prefix).Append($kStr).Append(": {}`n")
                            } else {
                                [void]$Sb.Append($prefix).Append($kStr).Append(":`n")
                                Write-YamlNode $v ($Indent + 4) $Sb
                            }
                        } elseif ($v -is [System.Collections.IList]) {
                            if ($v.Count -eq 0) {
                                [void]$Sb.Append($prefix).Append($kStr).Append(": []`n")
                            } else {
                                [void]$Sb.Append($prefix).Append($kStr).Append(":`n")
                                Write-YamlNode $v ($Indent + 4) $Sb
                            }
                        } else {
                            [void]$Sb.Append($prefix).Append($kStr).Append(': ').Append((Format-YamlScalar $v)).Append("`n")
                        }
                    }
                }
            } elseif ($item -is [System.Collections.IList]) {
                if ($item.Count -eq 0) {
                    [void]$Sb.Append($pad).Append("- []`n")
                } else {
                    [void]$Sb.Append($pad).Append("-`n")
                    Write-YamlNode $item ($Indent + 2) $Sb
                }
            } else {
                [void]$Sb.Append($pad).Append('- ').Append((Format-YamlScalar $item)).Append("`n")
            }
        }
        return
    }

    [void]$Sb.Append($pad).Append((Format-YamlScalar $Node)).Append("`n")
}

function ConvertTo-YamlText($Obj) {
    $sb = New-Object System.Text.StringBuilder
    Write-YamlNode $Obj 0 $sb
    return $sb.ToString()
}

# ==============================================================================
# 核心业务逻辑（与 clash_rebuild_rules.py 功能完全对等）
# ==============================================================================

function Find-ConfigDir([string]$Explicit) {
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        $p = $Explicit.Trim().Trim('"')
        if ([System.IO.File]::Exists((Join-Path $p 'profiles.yaml'))) {
            return $p
        }
        return $null
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CLASH_VERGE_DIR)) {
        if ([System.IO.File]::Exists((Join-Path $env:CLASH_VERGE_DIR 'profiles.yaml'))) {
            return $env:CLASH_VERGE_DIR
        }
    }
    $appIds = @(
        'io.github.clash-verge-rev.clash-verge-rev',
        'io.github.clash-verge.clash-verge'
    )
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        foreach ($aid in $appIds) {
            $cand = Join-Path $env:APPDATA $aid
            if ([System.IO.File]::Exists((Join-Path $cand 'profiles.yaml'))) {
                return $cand
            }
        }
    }
    return $null
}

function Test-DirectOrRejectGroup($GroupObj) {
    if (-not ($GroupObj -is [System.Collections.IDictionary]) -or -not $GroupObj.Contains('proxies')) {
        return $false
    }
    $proxies = $GroupObj['proxies']
    if (-not ($proxies -is [System.Collections.IList]) -or $proxies.Count -eq 0) {
        return $false
    }
    $first = $proxies[0]
    if ($first -is [string]) {
        $u = $first.Trim().ToUpperInvariant()
        return ($u -ceq 'DIRECT' -or $u -ceq 'REJECT')
    }
    return $false
}

function Test-ManagedRules($ExistingRules) {
    if (-not ($ExistingRules -is [System.Collections.IDictionary]) -or -not $ExistingRules.Contains('prepend')) {
        return $false
    }
    $prepend = $ExistingRules['prepend']
    if (-not ($prepend -is [System.Collections.IList])) {
        return $false
    }
    $matched = 0
    foreach ($r in $prepend) {
        if (-not ($r -is [string])) { continue }
        $parts = $r.Split(',')
        if ($parts.Length -ge 2) {
            $rtype = $parts[0].Trim().ToUpperInvariant()
            $pname = $parts[1].Trim()
            if ($rtype -ceq 'RULE-SET' -and $script:ManagedProviderNames.Contains($pname)) {
                $matched++
                if ($matched -ge 2) { return $true }
            }
        }
    }
    return $false
}

function Inspect-Subscription([string]$SubYamlPath, $SelectedItems) {
    $cfg = Load-SubscriptionYamlFast $SubYamlPath
    $rawGroups = if ($cfg.Contains('proxy-groups') -and ($cfg['proxy-groups'] -is [System.Collections.IList])) {
        $cfg['proxy-groups']
    } else {
        New-ObjList
    }

    $validGroups = New-Object 'System.Collections.Generic.List[string]'
    $validSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $groupMap = New-OrderedDict
    $groupIdx = New-OrderedDict
    $proxySelects = New-Object 'System.Collections.Generic.List[string]'
    $proxySelectSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $anySelects = New-Object 'System.Collections.Generic.List[string]'

    foreach ($g in $rawGroups) {
        if ($g -is [System.Collections.IDictionary] -and $g.Contains('name') -and ($g['name'] -is [string]) -and -not [string]::IsNullOrWhiteSpace($g['name'])) {
            $gname = $g['name']
            if ($groupMap.Contains($gname)) { continue }
            $groupIdx[$gname] = $validGroups.Count
            [void]$validGroups.Add($gname)
            [void]$validSet.Add($gname)
            $groupMap[$gname] = $g

            $gtype = if ($g.Contains('type') -and ($g['type'] -is [string])) { $g['type'] } else { '' }
            $gUpper = $gname.ToUpperInvariant()
            if ($gtype -ceq 'select' -and $gUpper -cne 'DIRECT' -and $gUpper -cne 'REJECT') {
                [void]$anySelects.Add($gname)
                if (-not (Test-DirectOrRejectGroup $g)) {
                    [void]$proxySelects.Add($gname)
                    [void]$proxySelectSet.Add($gname)
                }
            }
        }
    }

    $dedupRules = New-Object 'System.Collections.Generic.List[string]'
    $seenRules = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($cfg.Contains('rules') -and ($cfg['rules'] -is [System.Collections.IList])) {
        foreach ($r in $cfg['rules']) {
            if (($r -is [string]) -and -not [string]::IsNullOrWhiteSpace($r)) {
                if ($seenRules.Add($r)) {
                    [void]$dedupRules.Add($r)
                }
            }
        }
    }

    # 1. 从末尾 MATCH / FINAL 提取目标组，必要时解包到更靠前的 select 主代理组
    for ($idx = $dedupRules.Count - 1; $idx -ge 0; $idx--) {
        $parts = $dedupRules[$idx].Split(',')
        if ($parts.Length -ge 2) {
            $rt = $parts[0].Trim().ToUpperInvariant()
            if ($rt -ceq 'MATCH' -or $rt -ceq 'FINAL') {
                $cand = $parts[1].Trim()
                $cUpper = $cand.ToUpperInvariant()
                if ($validSet.Contains($cand) -and $cUpper -cne 'DIRECT' -and $cUpper -cne 'REJECT') {
                    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
                    [void]$visited.Add($cand)
                    while ($true) {
                        $gObj = $groupMap[$cand]
                        $gType = if ($gObj.Contains('type') -and ($gObj['type'] -is [string])) { $gObj['type'] } else { '' }
                        if ($gType -cne 'select') { break }
                        $earlier = $null
                        if ($gObj.Contains('proxies') -and ($gObj['proxies'] -is [System.Collections.IList])) {
                            foreach ($ref in $gObj['proxies']) {
                                if (($ref -is [string]) -and $proxySelectSet.Contains($ref) -and (-not $visited.Contains($ref)) -and ($groupIdx[$ref] -lt $groupIdx[$cand])) {
                                    $earlier = $ref
                                    break
                                }
                            }
                        }
                        if ($null -eq $earlier) { break }
                        [void]$visited.Add($earlier)
                        $cand = $earlier
                    }
                    if (-not ((Test-DirectOrRejectGroup $groupMap[$cand]) -and $proxySelects.Count -gt 0)) {
                        return [PSCustomObject]@{
                            Group       = $cand
                            Rules       = $dedupRules
                            ValidGroups = $validGroups
                        }
                    }
                }
                break
            }
        }
    }

    # 2. 退回订阅中第一个非 DIRECT/REJECT 优先的 select 组，其次任意 select 组
    if ($proxySelects.Count -gt 0) {
        return [PSCustomObject]@{ Group = $proxySelects[0]; Rules = $dedupRules; ValidGroups = $validGroups }
    }
    if ($anySelects.Count -gt 0) {
        return [PSCustomObject]@{ Group = $anySelects[0]; Rules = $dedupRules; ValidGroups = $validGroups }
    }

    # 3. 退回 profiles.yaml 的 selected
    if ($SelectedItems -is [System.Collections.IList]) {
        foreach ($sel in $SelectedItems) {
            if ($sel -is [System.Collections.IDictionary] -and $sel.Contains('name') -and ($sel['name'] -is [string])) {
                $cand = $sel['name']
                $cUpper = $cand.ToUpperInvariant()
                if (($validSet.Count -eq 0 -or $validSet.Contains($cand)) -and $cUpper -cne 'DIRECT' -and $cUpper -cne 'REJECT') {
                    return [PSCustomObject]@{ Group = $cand; Rules = $dedupRules; ValidGroups = $validGroups }
                }
            }
        }
    }

    return [PSCustomObject]@{ Group = $null; Rules = $dedupRules; ValidGroups = $validGroups }
}

function Test-IsLegacyBingDnsList($Val) {
    if (-not ($Val -is [System.Collections.IList]) -or $Val.Count -ne 2) { return $false }
    return (([string]$Val[0] -ceq '223.5.5.5') -and ([string]$Val[1] -ceq '119.29.29.29'))
}

function Copy-OrderedDict($Src) {
    $dst = New-OrderedDict
    if ($Src -is [System.Collections.IDictionary]) {
        foreach ($entry in $Src.GetEnumerator()) {
            $dst[[string]$entry.Key] = $entry.Value
        }
    }
    return $dst
}

function Build-MergeCfg($ExistingMerge, [string]$BaseUrl, [string]$ProviderProxy, [string]$Source) {
    $cfg = Copy-OrderedDict $ExistingMerge
    if ($cfg.Contains('rules')) { $cfg.Remove('rules') }

    # 清理旧版写入 Merge 的 Bing nameserver-policy
    if ($cfg.Contains('dns') -and ($cfg['dns'] -is [System.Collections.IDictionary])) {
        $dnsCfg = Copy-OrderedDict $cfg['dns']
        if ($dnsCfg.Contains('nameserver-policy') -and ($dnsCfg['nameserver-policy'] -is [System.Collections.IDictionary])) {
            $nsPolicy = Copy-OrderedDict $dnsCfg['nameserver-policy']
            foreach ($k in @('+.bing.com', '+.bing.net', '+.bingapis.com')) {
                if ($nsPolicy.Contains($k) -and (Test-IsLegacyBingDnsList $nsPolicy[$k])) {
                    $nsPolicy.Remove($k)
                }
            }
            if ($nsPolicy.Count -gt 0) {
                $dnsCfg['nameserver-policy'] = $nsPolicy
            } else {
                $dnsCfg.Remove('nameserver-policy')
            }
        }
        if ($dnsCfg.Count -gt 0) {
            $cfg['dns'] = $dnsCfg
        } else {
            $cfg.Remove('dns')
        }
    }

    $srcCfg = $script:RuleSources[$Source]
    $providers = if ($cfg.Contains('rule-providers') -and ($cfg['rule-providers'] -is [System.Collections.IDictionary])) {
        Copy-OrderedDict $cfg['rule-providers']
    } else {
        New-OrderedDict
    }

    foreach ($item in $srcCfg.providers) {
        $pname = $item[0]
        $relPath = $item[1]
        $behavior = $item[2]
        $p = New-OrderedDict
        $p['type'] = 'http'
        $p['behavior'] = $behavior
        $p['format'] = $srcCfg.format
        $p['url'] = $BaseUrl + $relPath
        $p['path'] = [string]::Format($srcCfg.path_tpl, $pname)
        $p['interval'] = [long]86400
        if (-not [string]::IsNullOrEmpty($ProviderProxy)) {
            $p['proxy'] = $ProviderProxy
        }
        $providers[$pname] = $p
    }
    $cfg['rule-providers'] = $providers
    return $cfg
}

function Build-RulesCfg([string]$Group, $SubRules, $ExistingRules, [bool]$ResetRules) {
    $managedPrepend = New-ObjList
    foreach ($tpl in $script:RuleTemplates) {
        [void]$managedPrepend.Add($tpl.Replace('{group}', $Group))
    }

    $customPrepend = New-ObjList
    $customAppend = New-ObjList

    if (-not $ResetRules -and (Test-ManagedRules $ExistingRules)) {
        $seenPrepend = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        if ($ExistingRules.Contains('prepend') -and ($ExistingRules['prepend'] -is [System.Collections.IList])) {
            foreach ($r in $ExistingRules['prepend']) {
                if (-not ($r -is [string]) -or [string]::IsNullOrWhiteSpace($r)) { continue }
                if ($script:ManagedRuleKeys.Contains((Get-RuleKey $r))) { continue }
                if ($seenPrepend.Add($r)) { [void]$customPrepend.Add($r) }
            }
        }
        $seenAppend = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        if ($ExistingRules.Contains('append') -and ($ExistingRules['append'] -is [System.Collections.IList])) {
            foreach ($r in $ExistingRules['append']) {
                if (-not ($r -is [string]) -or [string]::IsNullOrWhiteSpace($r)) { continue }
                if ($seenAppend.Add($r)) { [void]$customAppend.Add($r) }
            }
        }
    }

    $finalPrepend = New-ObjList
    foreach ($r in $customPrepend) { [void]$finalPrepend.Add($r) }
    foreach ($r in $managedPrepend) { [void]$finalPrepend.Add($r) }

    $finalDelete = New-ObjList
    foreach ($r in $SubRules) { [void]$finalDelete.Add($r) }

    $cfg = New-OrderedDict
    $cfg['prepend'] = $finalPrepend
    $cfg['append'] = $customAppend
    $cfg['delete'] = $finalDelete

    return [PSCustomObject]@{
        Config     = $cfg
        KeptCustom = ($customPrepend.Count + $customAppend.Count)
    }
}

function Format-YamlWithHeader($Cfg, [string]$TitleLine, [string]$SourceLabel) {
    $header = @(
        '# ================================================================',
        "# $TitleLine",
        "# 规则源: $SourceLabel (RULE-SET，Clash 每日自动更新)",
        '# 还原方式: clash_rebuild_rules.bat --restore',
        '# ================================================================'
    ) -join "`n"
    $body = ConvertTo-YamlText $Cfg
    return $header + "`n" + $body
}

function Write-TextAtomic([string]$Path, [string]$Text) {
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrEmpty($parent) -and -not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Text, $script:Utf8NoBom)
    if ([System.IO.File]::Exists($Path)) {
        try {
            [System.IO.File]::Replace($tmp, $Path, $null)
        } catch {
            [System.IO.File]::Copy($tmp, $Path, $true)
            [System.IO.File]::Delete($tmp)
        }
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Backup-AndWrite([string]$Path, [string]$Text) {
    $bak = $Path + '.bak'
    if ([System.IO.File]::Exists($Path) -and -not [System.IO.File]::Exists($bak)) {
        [System.IO.File]::Copy($Path, $bak, $false)
        Write-Host "  已备份: $bak"
    }
    Write-TextAtomic $Path $Text
    Write-Host "  已写入: $Path"
}

function Restore-FromBackup([string]$Path, [bool]$DryRun) {
    $bak = $Path + '.bak'
    if (-not [System.IO.File]::Exists($bak)) {
        Write-Host "  [skip] 没有备份 $bak" -ForegroundColor DarkGray
        return $false
    }
    if ($DryRun) {
        Write-Host "  [dry-run] 将还原: $Path <- $bak" -ForegroundColor Yellow
        return $true
    }
    [System.IO.File]::Copy($bak, $Path, $true)
    Write-Host "  已还原: $Path <- $bak" -ForegroundColor Green
    return $true
}

# ==============================================================================
# 规则集预拉取（带终端实时进度条）
# ==============================================================================

function Format-ByteSize([double]$NumBytes) {
    if ($NumBytes -lt 1024) {
        return ('{0} B' -f [long][Math]::Floor($NumBytes))
    }
    if ($NumBytes -lt 1048576) {
        return ('{0:F1} KB' -f ($NumBytes / 1024.0))
    }
    return ('{0:F2} MB' -f ($NumBytes / 1048576.0))
}

function Get-DisplayWidth([string]$Text) {
    $w = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $code = [int]$Text[$i]
        if ($code -ge 0x2E80) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Render-ProgressBar($Ratio, [int]$Width, [int]$Tick, [string]$Fill, [string]$Empty) {
    if ($null -eq $Ratio) {
        $seg = 4
        $span = [Math]::Max(1, $Width - $seg)
        $pos = $Tick % ($span * 2)
        if ($pos -gt $span) { $pos = $span * 2 - $pos }
        return ($Empty * $pos) + ($Fill * $seg) + ($Empty * ($Width - $pos - $seg))
    }
    $clamped = [Math]::Max(0.0, [Math]::Min(1.0, [double]$Ratio))
    $done = [int][Math]::Round($clamped * $Width)
    return ($Fill * $done) + ($Empty * ($Width - $done))
}

function Resolve-WebProxy([bool]$NoProxy) {
    if ($NoProxy) { return $null }
    foreach ($envName in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
        $val = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            try {
                return (New-Object System.Net.WebProxy($val.Trim()))
            } catch {}
        }
    }
    return [System.Net.WebRequest]::GetSystemWebProxy()
}

function Invoke-PrefetchRulesets([string]$CfgDir, [string]$Source, [string]$BaseUrl, [bool]$NoProxy, [int]$TimeoutSec = 30) {
    $srcCfg = $script:RuleSources[$Source]
    $providers = $srcCfg.providers
    $totalCount = $providers.Length
    $isTty = $false
    try { $isTty = -not [Console]::IsOutputRedirected } catch { $isTty = $false }
    $fill = [string][char]0x2588   # █
    $empty = [string][char]0x2591  # ░
    $proxy = Resolve-WebProxy $NoProxy

    Write-Host ("正在拉取规则集（共 {0} 份，源: {1}）:" -f $totalCount, $srcCfg.label) -ForegroundColor Cyan
    [long]$totalBytes = 0
    $okCount = 0
    $failed = New-Object 'System.Collections.Generic.List[object]'
    $swAll = [System.Diagnostics.Stopwatch]::StartNew()
    $buffer = New-Object byte[] 16384

    for ($idx = 0; $idx -lt $totalCount; $idx++) {
        $name = $providers[$idx][0]
        $relPath = $providers[$idx][1]
        $url = $BaseUrl + $relPath
        $relDst = [string]::Format($srcCfg.path_tpl, $name)
        $dstPath = [System.IO.Path]::GetFullPath((Join-Path $CfgDir $relDst))
        $dstDir = [System.IO.Path]::GetDirectoryName($dstPath)
        if (-not [System.IO.Directory]::Exists($dstDir)) {
            [void][System.IO.Directory]::CreateDirectory($dstDir)
        }
        $tmpPath = $dstPath + '.tmp'
        $prefix = '  [{0,2}/{1}] {2,-8}' -f ($idx + 1), $totalCount, $name
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastCols = 0

        if ($isTty) {
            $initLine = '{0} [{1}]  连接中...' -f $prefix, ($empty * 20)
            [Console]::Write("`r" + $initLine)
            $lastCols = Get-DisplayWidth $initLine
        }

        $resp = $null
        $netStream = $null
        $fileStream = $null
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.UserAgent = 'clash-rebuild-rules'
            $req.Timeout = $TimeoutSec * 1000
            $req.ReadWriteTimeout = $TimeoutSec * 1000
            $req.Proxy = $proxy
            $resp = [System.Net.HttpWebResponse]$req.GetResponse()

            $expected = $null
            if ($resp.ContentLength -gt 0) { $expected = [long]$resp.ContentLength }
            [long]$downloaded = 0
            $headBytes = New-Object 'System.Collections.Generic.List[byte]'
            $lastDrawMs = -1000.0
            $tick = 0

            $netStream = $resp.GetResponseStream()
            $fileStream = [System.IO.File]::Create($tmpPath)
            while ($true) {
                $read = $netStream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                if ($headBytes.Count -lt 256) {
                    $take = [Math]::Min($read, 256 - $headBytes.Count)
                    for ($b = 0; $b -lt $take; $b++) { [void]$headBytes.Add($buffer[$b]) }
                }
                $fileStream.Write($buffer, 0, $read)
                $downloaded += $read
                $nowMs = $sw.Elapsed.TotalMilliseconds
                if ($isTty -and (($nowMs - $lastDrawMs) -ge 50.0 -or ($null -ne $expected -and $downloaded -ge $expected))) {
                    $elapsedSec = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                    $speed = (Format-ByteSize ($downloaded / $elapsedSec)) + '/s'
                    if ($null -ne $expected) {
                        $ratio = [double]$downloaded / [double]$expected
                        $pct = '{0,3}%' -f [int][Math]::Min(100, [Math]::Round($ratio * 100))
                        $sizeInfo = '{0} / {1}' -f (Format-ByteSize $downloaded), (Format-ByteSize $expected)
                    } else {
                        $ratio = $null
                        $pct = ' --%'
                        $sizeInfo = Format-ByteSize $downloaded
                    }
                    $bar = Render-ProgressBar $ratio 20 $tick $fill $empty
                    $line = '{0} [{1}] {2}  {3,-19} {4}' -f $prefix, $bar, $pct, $sizeInfo, $speed
                    $cols = Get-DisplayWidth $line
                    $padCount = [Math]::Max(0, $lastCols - $cols)
                    [Console]::Write("`r" + $line + (' ' * $padCount))
                    $lastCols = $cols
                    $lastDrawMs = $nowMs
                    $tick++
                }
            }
            $fileStream.Close(); $fileStream = $null
            $netStream.Close(); $netStream = $null
            $resp.Close(); $resp = $null

            if ($downloaded -le 0) { throw '下载内容为空' }
            if ($srcCfg.format -ceq 'yaml') {
                $headStr = [System.Text.Encoding]::UTF8.GetString($headBytes.ToArray()).TrimStart().ToLowerInvariant()
                if ($headStr.StartsWith('<!doctype html') -or $headStr.StartsWith('<html')) {
                    throw '返回内容为 HTML 错误页，非有效规则文件'
                }
            }

            if ([System.IO.File]::Exists($dstPath)) {
                try {
                    [System.IO.File]::Replace($tmpPath, $dstPath, $null)
                } catch {
                    [System.IO.File]::Copy($tmpPath, $dstPath, $true)
                    [System.IO.File]::Delete($tmpPath)
                }
            } else {
                [System.IO.File]::Move($tmpPath, $dstPath)
            }

            $cost = $sw.Elapsed.TotalSeconds
            $totalBytes += $downloaded
            $okCount++
            $doneLine = '{0} [{1}] 100%  {2,9}  {3,5:F1}s  OK' -f $prefix, ($fill * 20), (Format-ByteSize $downloaded), $cost
            if ($isTty) {
                $cols = Get-DisplayWidth $doneLine
                $padCount = [Math]::Max(0, $lastCols - $cols)
                [Console]::Write("`r" + $doneLine + (' ' * $padCount) + "`n")
            } else {
                Write-Host $doneLine
            }
        } catch {
            if ($null -ne $fileStream) { try { $fileStream.Close() } catch {} }
            if ($null -ne $netStream) { try { $netStream.Close() } catch {} }
            if ($null -ne $resp) { try { $resp.Close() } catch {} }
            if ([System.IO.File]::Exists($tmpPath)) { try { [System.IO.File]::Delete($tmpPath) } catch {} }

            $cost = $sw.Elapsed.TotalSeconds
            $ex = $_.Exception
            $reason = $ex.Message
            if ($ex -is [System.Net.WebException] -and $null -ne $ex.Response) {
                try {
                    $httpResp = [System.Net.HttpWebResponse]$ex.Response
                    $reason = 'HTTP {0}' -f [int]$httpResp.StatusCode
                } catch {}
            }
            [void]$failed.Add([PSCustomObject]@{ Name = $name; Reason = $reason })
            $failLine = '{0} [{1}] FAIL  {2} ({3:F1}s)' -f $prefix, ('-' * 20), $reason, $cost
            if ($isTty) {
                $cols = Get-DisplayWidth $failLine
                $padCount = [Math]::Max(0, $lastCols - $cols)
                [Console]::Write("`r" + $failLine + (' ' * $padCount) + "`n")
            } else {
                Write-Host $failLine
            }
        }
    }

    $allCost = $swAll.Elapsed.TotalSeconds
    $allRatio = if ($totalCount -gt 0) { [double]$okCount / [double]$totalCount } else { 1.0 }
    $allBar = Render-ProgressBar $allRatio 20 0 $fill $empty
    Write-Host ('  总进度 [{0}] {1}/{2} ({3}%)  合计 {4}  耗时 {5:F1}s' -f `
        $allBar, $okCount, $totalCount, [int][Math]::Round($allRatio * 100), (Format-ByteSize $totalBytes), $allCost)
    if ($failed.Count -gt 0) {
        $names = ($failed | ForEach-Object { $_.Name }) -join ', '
        Write-Host ("  [warn] 以下 {0} 份规则集拉取失败: {1}（可稍后重试，或切换 jsDelivr 镜像）" -f $failed.Count, $names) -ForegroundColor Yellow
    }
    Write-Host ''
    return [PSCustomObject]@{ OkCount = $okCount; Failed = $failed }
}

# ==============================================================================
# 读取订阅列表与执行主流程
# ==============================================================================

function Get-RemoteProfilesInfo([string]$CfgDir) {
    $profilesYaml = Join-Path $CfgDir 'profiles.yaml'
    $profilesDir = Join-Path $CfgDir 'profiles'
    $pf = Load-YamlDict $profilesYaml
    $items = if ($pf.Contains('items') -and ($pf['items'] -is [System.Collections.IList])) { $pf['items'] } else { New-ObjList }

    $uid2file = New-OrderedDict
    $remotes = New-ObjList
    foreach ($it in $items) {
        if ($it -is [System.Collections.IDictionary]) {
            $uid = if ($it.Contains('uid') -and ($it['uid'] -is [string])) { $it['uid'] } else { '' }
            $file = if ($it.Contains('file') -and ($it['file'] -is [string])) { $it['file'] } else { '' }
            if ($uid.Length -gt 0) { $uid2file[$uid] = $file }
            $itype = if ($it.Contains('type') -and ($it['type'] -is [string])) { $it['type'] } else { '' }
            if ($itype -ceq 'remote') {
                [void]$remotes.Add($it)
            }
        }
    }
    return [PSCustomObject]@{
        ProfilesDir  = $profilesDir
        ProfilesYaml = $profilesYaml
        Uid2File     = $uid2file
        Remotes      = $remotes
    }
}

function Invoke-RebuildAction($Opts) {
    $cfgDir = Find-ConfigDir $Opts.Dir
    if ([string]::IsNullOrEmpty($cfgDir)) {
        Write-Host '未找到有效的 Clash Verge 配置目录，请指定包含 profiles.yaml 的目录（--dir 或菜单 [9]）。' -ForegroundColor Red
        return 1
    }
    Write-Host "配置目录: $cfgDir`n"

    $info = Get-RemoteProfilesInfo $cfgDir
    $profilesDir = $info.ProfilesDir
    $uid2file = $info.Uid2File
    $remotes = $info.Remotes

    if ($remotes.Count -eq 0) {
        Write-Host 'profiles.yaml 里没有 type: remote 的订阅。' -ForegroundColor Yellow
        return 0
    }

    if ($Opts.Profiles.Count -gt 0) {
        $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($p in $Opts.Profiles) { [void]$wanted.Add($p) }
        $matched = New-ObjList
        $foundKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($it in $remotes) {
            $n = if ($it.Contains('name') -and ($it['name'] -is [string])) { $it['name'] } else { '' }
            $u = if ($it.Contains('uid') -and ($it['uid'] -is [string])) { $it['uid'] } else { '' }
            $f = if ($it.Contains('file') -and ($it['file'] -is [string])) { $it['file'] } else { '' }
            if (($n.Length -gt 0 -and $wanted.Contains($n)) -or ($u.Length -gt 0 -and $wanted.Contains($u)) -or ($f.Length -gt 0 -and $wanted.Contains($f))) {
                [void]$matched.Add($it)
                if ($n.Length -gt 0) { [void]$foundKeys.Add($n) }
                if ($u.Length -gt 0) { [void]$foundKeys.Add($u) }
                if ($f.Length -gt 0) { [void]$foundKeys.Add($f) }
            }
        }
        if ($matched.Count -eq 0) {
            $availList = New-Object 'System.Collections.Generic.List[string]'
            foreach ($it in $remotes) {
                $label = if ($it.Contains('name') -and $it['name']) { [string]$it['name'] } elseif ($it.Contains('uid') -and $it['uid']) { [string]$it['uid'] } else { '?' }
                [void]$availList.Add($label)
            }
            Write-Host ("未匹配到指定订阅（{0}）。可用远程订阅: {1}" -f ($Opts.Profiles -join ', '), ($availList -join ', ')) -ForegroundColor Red
            return 1
        }
        $missing = New-Object 'System.Collections.Generic.List[string]'
        foreach ($p in $Opts.Profiles) {
            if (-not $foundKeys.Contains($p)) { [void]$missing.Add($p) }
        }
        if ($missing.Count -gt 0) {
            Write-Host ("[warn] 未找到以下订阅，已忽略: {0}`n" -f ($missing -join ', ')) -ForegroundColor Yellow
        }
        $remotes = $matched
    }

    $srcCfg = $script:RuleSources[$Opts.Source]
    $baseUrl = if ($Opts.Cdn -ceq 'jsdelivr') { $srcCfg.cdn_base } else { $srcCfg.raw_base }
    if (-not $Opts.Restore) {
        Write-Host ("规则集源: {0}" -f $srcCfg.label)
        Write-Host ("下载地址: {0}" -f $baseUrl)
        Write-Host ("下载经代理: {0}`n" -f $(if ($Opts.NoProxyDownload) { '否（--no-proxy-download）' } else { '是（走各订阅主代理组）' }))
    }

    $changed = 0
    $seenMerge = New-OrderedDict
    $seenRules = New-OrderedDict

    foreach ($it in $remotes) {
        $name = if ($it.Contains('name') -and $it['name']) { [string]$it['name'] } elseif ($it.Contains('file') -and $it['file']) { [string]$it['file'] } else { '?' }
        $subFile = if ($it.Contains('file') -and ($it['file'] -is [string])) { $it['file'] } else { '' }
        $opt = if ($it.Contains('option') -and ($it['option'] -is [System.Collections.IDictionary])) { $it['option'] } else { New-OrderedDict }
        $mergeUid = if ($opt.Contains('merge') -and ($opt['merge'] -is [string])) { $opt['merge'] } else { '' }
        $rulesUid = if ($opt.Contains('rules') -and ($opt['rules'] -is [string])) { $opt['rules'] } else { '' }

        Write-Host "订阅: $name" -ForegroundColor Cyan

        if ([string]::IsNullOrEmpty($mergeUid) -or [string]::IsNullOrEmpty($rulesUid)) {
            Write-Host ("  [skip] 该订阅缺少 merge 或 rules 增强配置（merge={0}, rules={1}）。`n" -f $(if ($mergeUid) { $mergeUid } else { 'None' }), $(if ($rulesUid) { $rulesUid } else { 'None' })) -ForegroundColor Yellow
            continue
        }

        $mergeFile = if ($uid2file.Contains($mergeUid) -and $uid2file[$mergeUid]) { [string]$uid2file[$mergeUid] } else { "$mergeUid.yaml" }
        $rulesFile = if ($uid2file.Contains($rulesUid) -and $uid2file[$rulesUid]) { [string]$uid2file[$rulesUid] } else { "$rulesUid.yaml" }
        $mergePath = Join-Path $profilesDir $mergeFile
        $rulesPath = Join-Path $profilesDir $rulesFile

        if ($Opts.Restore) {
            $r1 = Restore-FromBackup $mergePath $Opts.DryRun
            $r2 = Restore-FromBackup $rulesPath $Opts.DryRun
            if ($r1 -or $r2) { $changed++ }
            Write-Host ''
            continue
        }

        if ($seenMerge.Contains($mergeUid) -or $seenRules.Contains($rulesUid)) {
            $prev = if ($seenMerge.Contains($mergeUid)) { $seenMerge[$mergeUid] } else { $seenRules[$rulesUid] }
            Write-Host ("  [warn] 与订阅「{0}」共用增强文件，跳过以防互相覆盖。`n" -f $prev) -ForegroundColor Yellow
            continue
        }

        $subPath = if ($subFile.Length -gt 0) { Join-Path $profilesDir $subFile } else { '' }
        $selItems = if ($it.Contains('selected')) { $it['selected'] } else { $null }
        $insp = Inspect-Subscription $subPath $selItems
        $subRules = $insp.Rules
        $validGroups = $insp.ValidGroups

        $group = $null
        if ($null -ne $Opts.Group) {
            $gTrim = $Opts.Group.Trim()
            if ($gTrim.Length -eq 0 -or $gTrim.ToUpperInvariant() -ceq 'DIRECT' -or $gTrim.ToUpperInvariant() -ceq 'REJECT') {
                Write-Host ("  [warn] --group 不能指定为空或 {0}，跳过。`n" -f $(if ($Opts.Group) { $Opts.Group } else { '空' })) -ForegroundColor Yellow
                continue
            }
            if ($validGroups.Count -gt 0) {
                $foundGrp = $false
                foreach ($vg in $validGroups) {
                    if ($vg -ceq $Opts.Group) { $foundGrp = $true; break }
                }
                if (-not $foundGrp) {
                    $sample = New-Object 'System.Collections.Generic.List[string]'
                    for ($k = 0; $k -lt [Math]::Min(8, $validGroups.Count); $k++) { [void]$sample.Add($validGroups[$k]) }
                    $availGroups = ($sample -join ', ') + $(if ($validGroups.Count -gt 8) { ' ...' } else { '' })
                    Write-Host ("  [warn] 该订阅中不存在代理组「{0}」（可用: {1}），跳过。`n" -f $Opts.Group, $availGroups) -ForegroundColor Yellow
                    continue
                }
            }
            $group = $Opts.Group
        } else {
            $group = $insp.Group
        }

        if ([string]::IsNullOrEmpty($group)) {
            Write-Host "  [warn] 无法确定该订阅的有效主代理组名，跳过。`n" -ForegroundColor Yellow
            continue
        }

        $seenMerge[$mergeUid] = $name
        $seenRules[$rulesUid] = $name

        Write-Host ("  主代理组: {0}{1}" -f $group, $(if ($null -ne $Opts.Group) { '（--group 指定）' } else { '' }))
        Write-Host ("  Merge 文件 (rule-providers):       {0}" -f $mergePath)
        Write-Host ("  Rules 文件 (右键「编辑规则」可见): {0}（屏蔽原订阅规则 {1} 条）" -f $rulesPath, $subRules.Count)

        $providerProxy = if ($Opts.NoProxyDownload) { '' } else { $group }
        $existingMerge = Load-YamlDict $mergePath
        $existingRules = Load-YamlDict $rulesPath
        $mergeCfg = Build-MergeCfg $existingMerge $baseUrl $providerProxy $Opts.Source
        $rulesBuild = Build-RulesCfg $group $subRules $existingRules $Opts.ResetRules
        $rulesCfg = $rulesBuild.Config
        $keptCustom = $rulesBuild.KeptCustom

        if ($keptCustom -gt 0) {
            Write-Host ("  已保留界面自定义规则: {0} 条（位于模板规则之前，可开启重置选项清空）" -f $keptCustom) -ForegroundColor Green
        }

        $mergeText = Format-YamlWithHeader $mergeCfg '由 clash_rebuild_rules.bat 生成：rule-providers 规则集数据源' $srcCfg.label
        $rulesText = Format-YamlWithHeader $rulesCfg '由 clash_rebuild_rules.bat 生成：右键「编辑规则」前置分流规则' $srcCfg.label

        if ($Opts.DryRun) {
            Write-Host '  ----- Merge 将写入的内容 -----'
            foreach ($line in ($mergeText.TrimEnd("`n").Split("`n"))) {
                Write-Host ('  | ' + $line)
            }
            Write-Host ("  ----- Rules (prepend 预览，delete 共 {0} 条已省略) -----" -f $subRules.Count)
            $previewRules = New-OrderedDict
            $previewRules['prepend'] = $rulesCfg['prepend']
            $previewRules['append'] = $rulesCfg['append']
            $delSummary = New-ObjList
            [void]$delSummary.Add("<共 $($subRules.Count) 条原订阅规则>")
            $previewRules['delete'] = $delSummary
            $previewText = Format-YamlWithHeader $previewRules '右键「编辑规则」预览' $srcCfg.label
            foreach ($line in ($previewText.TrimEnd("`n").Split("`n"))) {
                Write-Host ('  | ' + $line)
            }
            Write-Host ''
            continue
        }

        Backup-AndWrite $mergePath $mergeText
        Backup-AndWrite $rulesPath $rulesText
        $changed++
        Write-Host ''
    }

    if (-not $Opts.Restore -and -not $Opts.DryRun -and -not $Opts.SkipDownload -and $changed -gt 0) {
        [void](Invoke-PrefetchRulesets $cfgDir $Opts.Source $baseUrl $Opts.NoProxyDownload)
    }

    Write-Host ('=' * 60)
    if ($Opts.Restore) {
        if ($Opts.DryRun) {
            Write-Host ("dry-run 还原预览完成（涉及 {0} 个订阅），未写入任何文件。" -f $changed) -ForegroundColor Yellow
        } else {
            Write-Host ("还原完成（共处理 {0} 个订阅）。请回 Clash Verge 重新激活订阅/重启内核生效。" -f $changed) -ForegroundColor Green
        }
    } elseif ($Opts.DryRun) {
        Write-Host 'dry-run 模式，未写入任何文件。确认无误后可执行正式写入。' -ForegroundColor Yellow
    } else {
        Write-Host ("完成，共更新 {0} 个订阅的 Merge + Rules 增强配置。" -f $changed) -ForegroundColor Green
        Write-Host '请回 Clash Verge 重新激活当前订阅（或点击刷新/重启内核）生效；右键订阅 ->「编辑规则」即可查看和修改规则。'
        Write-Host '如需还原：再次打开本工具选择 [10] 还原备份，或运行 clash_rebuild_rules.bat --restore'
    }
    return 0
}

# ==============================================================================
# 交互式菜单界面（双击运行，纯数字选择，与 clash_rebuild_rules.py 功能一一对应）
# ==============================================================================

function New-RunOpts([string]$Dir) {
    return [PSCustomObject]@{
        Dir             = $Dir
        DryRun          = $false
        Restore         = $false
        Source          = 'loyalsoldier'
        Cdn             = 'raw'
        SkipDownload    = $false
        NoProxyDownload = $false
        ResetRules      = $false
        Profiles        = (New-Object 'System.Collections.Generic.List[string]')
        Group           = $null
    }
}

function Read-MenuInput([string]$Prompt) {
    $val = Read-Host $Prompt
    if ($null -eq $val) { return $null }
    return $val.Trim()
}

function Pause-ForMenu([string]$Message = '按回车键返回主菜单...') {
    Write-Host ''
    [void](Read-Host $Message)
}

function Clear-ConsoleSafe {
    try { Clear-Host } catch {}
}

function Get-ScanSummary([string]$ExplicitDir) {
    $cfgDir = Find-ConfigDir $ExplicitDir
    $subs = New-Object 'System.Collections.Generic.List[object]'
    $hasBak = $false
    if (-not [string]::IsNullOrEmpty($cfgDir)) {
        $info = Get-RemoteProfilesInfo $cfgDir
        foreach ($it in $info.Remotes) {
            $name = if ($it.Contains('name') -and $it['name']) { [string]$it['name'] } elseif ($it.Contains('file') -and $it['file']) { [string]$it['file'] } else { '?' }
            $uid = if ($it.Contains('uid') -and ($it['uid'] -is [string])) { $it['uid'] } else { '' }
            $subFile = if ($it.Contains('file') -and ($it['file'] -is [string])) { $it['file'] } else { '' }
            $opt = if ($it.Contains('option') -and ($it['option'] -is [System.Collections.IDictionary])) { $it['option'] } else { New-OrderedDict }
            $mergeUid = if ($opt.Contains('merge') -and ($opt['merge'] -is [string])) { $opt['merge'] } else { '' }
            $rulesUid = if ($opt.Contains('rules') -and ($opt['rules'] -is [string])) { $opt['rules'] } else { '' }
            $bakOk = $false
            if ($mergeUid.Length -gt 0 -and $rulesUid.Length -gt 0) {
                $mf = if ($info.Uid2File.Contains($mergeUid) -and $info.Uid2File[$mergeUid]) { [string]$info.Uid2File[$mergeUid] } else { "$mergeUid.yaml" }
                $rf = if ($info.Uid2File.Contains($rulesUid) -and $info.Uid2File[$rulesUid]) { [string]$info.Uid2File[$rulesUid] } else { "$rulesUid.yaml" }
                if ([System.IO.File]::Exists((Join-Path $info.ProfilesDir ($mf + '.bak'))) -or
                    [System.IO.File]::Exists((Join-Path $info.ProfilesDir ($rf + '.bak')))) {
                    $bakOk = $true
                    $hasBak = $true
                }
            }
            [void]$subs.Add([PSCustomObject]@{
                Name     = $name
                Uid      = $uid
                File     = $subFile
                SubPath  = if ($subFile.Length -gt 0) { Join-Path $info.ProfilesDir $subFile } else { '' }
                Selected = if ($it.Contains('selected')) { $it['selected'] } else { $null }
                HasBak   = $bakOk
            })
        }
    }
    return [PSCustomObject]@{
        ConfigDir = $cfgDir
        Subs      = $subs
        HasBak    = $hasBak
    }
}

function Prompt-Profiles($Opts, $Scan) {
    Write-Host ''
    if ($Scan.Subs.Count -gt 0) {
        Write-Host '可用远程订阅:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $Scan.Subs.Count; $i++) {
            $s = $Scan.Subs[$i]
            Write-Host ("  [{0}] {1}  (uid: {2})" -f ($i + 1), $s.Name, $s.Uid)
        }
        $raw = Read-MenuInput '请输入订阅编号或名称（多个用逗号分隔，直接回车=全部订阅）'
    } else {
        $raw = Read-MenuInput '请输入订阅名称或 uid（多个用逗号分隔，直接回车=全部订阅）'
    }
    if ($null -eq $raw) { return $false }
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw -ceq '0') { return $true }

    if ($raw -cmatch '^\d+(\s+\d+)+$') {
        $tokens = $raw -split '\s+'
    } else {
        $tokens = $raw.Split(@(',', '，'), [System.StringSplitOptions]::RemoveEmptyEntries)
    }
    $added = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($rawTok in $tokens) {
        $tok = $rawTok.Trim()
        if ($tok.Length -eq 0) { continue }
        $num = 0
        if ([int]::TryParse($tok, [ref]$num) -and $num -ge 1 -and $num -le $Scan.Subs.Count) {
            $picked = $Scan.Subs[$num - 1].Name
            if ($added.Add($picked)) { [void]$Opts.Profiles.Add($picked) }
        } else {
            if ($added.Add($tok)) { [void]$Opts.Profiles.Add($tok) }
        }
    }
    return $true
}

function Prompt-Group($Opts, $Scan) {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($Scan.Subs.Count -gt 0) {
        $targetSubs = $Scan.Subs
        if ($Opts.Profiles.Count -gt 0) {
            $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            foreach ($p in $Opts.Profiles) { [void]$wanted.Add($p) }
            $filtered = New-Object 'System.Collections.Generic.List[object]'
            foreach ($s in $Scan.Subs) {
                if ($wanted.Contains($s.Name) -or $wanted.Contains($s.Uid) -or $wanted.Contains($s.File)) {
                    [void]$filtered.Add($s)
                }
            }
            if ($filtered.Count -gt 0) { $targetSubs = $filtered }
        }
        foreach ($s in $targetSubs) {
            $insp = Inspect-Subscription $s.SubPath $s.Selected
            foreach ($g in $insp.ValidGroups) {
                $gu = $g.ToUpperInvariant()
                if ($gu -cne 'DIRECT' -and $gu -cne 'REJECT' -and $seen.Add($g)) {
                    [void]$candidates.Add($g)
                }
            }
        }
    }

    Write-Host ''
    if ($candidates.Count -gt 0) {
        Write-Host '可用代理组:' -ForegroundColor Cyan
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $candidates[$i])
        }
        $raw = Read-MenuInput '请输入主代理组编号或名称（直接回车=自动识别）'
    } else {
        $raw = Read-MenuInput '请输入主代理组名称（直接回车=自动识别）'
    }
    if ($null -eq $raw) { return $false }
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw -ceq '0') { return $true }

    $num = 0
    if ([int]::TryParse($raw, [ref]$num) -and $num -ge 1 -and $num -le $candidates.Count) {
        $Opts.Group = $candidates[$num - 1]
    } else {
        $Opts.Group = $raw
    }
    return $true
}

function Invoke-InteractiveMenu($InitialOpts = $null) {
    try { $Host.UI.RawUI.WindowTitle = 'Clash Verge 分流规则重建工具 (免 Python 版)' } catch {}
    $customDir = if ($null -ne $InitialOpts) { $InitialOpts.Dir } else { $null }

    while ($true) {
        Clear-ConsoleSafe
        $scan = Get-ScanSummary $customDir

        Write-Host '================================================================' -ForegroundColor Cyan
        Write-Host '  Clash Verge 分流规则重建工具  (免 Python 版)' -ForegroundColor White
        Write-Host '================================================================' -ForegroundColor Cyan
        if (-not [string]::IsNullOrEmpty($scan.ConfigDir)) {
            Write-Host ('  配置目录 : ' + $scan.ConfigDir) -ForegroundColor Green
            if ($scan.Subs.Count -gt 0) {
                $subNames = ($scan.Subs | ForEach-Object { $_.Name }) -join ', '
                $bakTag = if ($scan.HasBak) { ' [已有 .bak 备份]' } else { '' }
                Write-Host ('  远程订阅 : 共 {0} 个 ({1}){2}' -f $scan.Subs.Count, $subNames, $bakTag)
            } else {
                Write-Host '  远程订阅 : 0 个（profiles.yaml 中未发现 remote 订阅）' -ForegroundColor Yellow
            }
        } else {
            Write-Host '  配置目录 : 未自动检测到（请选择 [9] 手动指定）' -ForegroundColor Yellow
        }

        Write-Host '----------------------------------------------------------------' -ForegroundColor DarkGray
        Write-Host '  请选择要执行的功能（输入数字回车）:' -ForegroundColor White
        Write-Host '    [1] 预览配置，不修改文件           (--dry-run)'
        Write-Host '    [2] 正式写入并预拉取规则集         (默认应用)'
        Write-Host '    [3] 仅写入配置，不预拉取规则集     (--skip-download)'
        Write-Host '    [4] 指定订阅 / 指定主代理组        (--profile / --group)'
        Write-Host '    [5] 重置规则为默认模板             (--reset-rules)'
        Write-Host '    [6] 使用 MetaCubeX 二进制 .mrs 源  (--source metacubex)'
        Write-Host '    [7] 使用 jsDelivr CDN 镜像拉取     (--cdn jsdelivr)'
        Write-Host '    [8] 下载规则集不走代理（直连）     (--no-proxy-download)'
        Write-Host '    [9] 手动指定配置目录               (--dir)'
        Write-Host '   [10] 还原 .bak 备份                 (--restore)'
        Write-Host '    [0] 退出' -ForegroundColor DarkGray
        Write-Host '================================================================' -ForegroundColor Cyan

        $choice = Read-MenuInput '请输入数字 (0-10)'
        if ($null -eq $choice) { return 0 }

        switch ($choice) {
            '1' {
                Write-Host ''
                $opts = New-RunOpts $customDir
                $opts.DryRun = $true
                [void](Invoke-RebuildAction $opts)
                Pause-ForMenu
            }
            '2' {
                Write-Host ''
                $opts = New-RunOpts $customDir
                [void](Invoke-RebuildAction $opts)
                Pause-ForMenu
            }
            '3' {
                Write-Host ''
                $opts = New-RunOpts $customDir
                $opts.SkipDownload = $true
                [void](Invoke-RebuildAction $opts)
                Pause-ForMenu
            }
            '4' {
                $opts = New-RunOpts $customDir
                if (-not (Prompt-Profiles $opts $scan)) { return 0 }
                if (-not (Prompt-Group $opts $scan)) { return 0 }
                Write-Host ''
                Write-Host '  [1] 正式写入（默认直接回车）'
                Write-Host '  [2] 仅预览 (--dry-run)'
                Write-Host '  [3] 仅写入配置，不预拉取规则集 (--skip-download)'
                Write-Host '  [0] 返回主菜单'
                $mode = Read-MenuInput '请选择执行方式 (0-3)'
                if ($null -eq $mode) { return 0 }
                if ($mode -ceq '0') { continue }
                if ($mode -ceq '2') { $opts.DryRun = $true }
                elseif ($mode -ceq '3') { $opts.SkipDownload = $true }
                elseif ($mode -cne '' -and $mode -cne '1') {
                    Write-Host "无效选项: $mode" -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 700
                    continue
                }
                Write-Host ''
                [void](Invoke-RebuildAction $opts)
                Pause-ForMenu
            }
            '5' {
                Write-Host ''
                Write-Host '提示：--reset-rules 会重置 Rules 增强为模板默认规则，清空界面手工新增的自定义规则。' -ForegroundColor Yellow
                Write-Host '  [1] 正式重置并写入'
                Write-Host '  [2] 仅预览 (--reset-rules --dry-run)'
                Write-Host '  [0] 返回主菜单（默认直接回车）'
                $mode = Read-MenuInput '请选择 (0-2)'
                if ($null -eq $mode) { return 0 }
                if ($mode -ceq '' -or $mode -ceq '0') { continue }
                $opts = New-RunOpts $customDir
                $opts.ResetRules = $true
                if ($mode -ceq '2') { $opts.DryRun = $true }
                elseif ($mode -cne '1') {
                    Write-Host "无效选项: $mode" -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 700
                    continue
                }
                Write-Host ''
                [void](Invoke-RebuildAction $opts)
                Pause-ForMenu
            }
            '6' {
                Write-Host ''
                Write-Host '选择 MetaCubeX (.mrs) 规则集下载地址:' -ForegroundColor Cyan
                Write-Host '  [1] GitHub 原始地址（默认直接回车）'
                Write-Host '  [2] jsDelivr CDN 镜像 (--cdn jsdelivr)'
                Write-Host '  [3] 仅预览 (--source metacubex --dry-run)'
                Write-Host '  [0] 返回主菜单'
                $mode = Read-MenuInput '请选择 (0-3)'
                if ($null -eq $mode) { return 0 }
                if ($mode -ceq '0') { continue }
                $opts = New-RunOpts $customDir
                $opts.Source = 'metacubex'
                if ($mode -ceq '2') { $opts.Cdn = 'jsdelivr' }
                elseif ($mode -ceq '3') { $opts.DryRun = $true }
                elseif ($mode -cne '' -and $mode -cne '1') {
                    Write-Host "无效选项: $mode" -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 700
                    continue
                }
                Write-Host ''
                [void](Invoke-RebuildAction $opts)
                Pause-ForMenu
            }
            '7' {
                Write-Host ''
                $opts = New-RunOpts $customDir
                $opts.Cdn = 'jsdelivr'
                [void](Invoke-RebuildAction $opts)
                Pause-ForMenu
            }
            '8' {
                Write-Host ''
                $opts = New-RunOpts $customDir
                $opts.NoProxyDownload = $true
                [void](Invoke-RebuildAction $opts)
                Pause-ForMenu
            }
            '9' {
                Write-Host ''
                Write-Host '提示：可直接将 Clash Verge 配置目录拖入窗口（目录内需有 profiles.yaml），直接回车恢复自动识别。' -ForegroundColor DarkGray
                $rawDir = Read-MenuInput '请输入配置目录路径'
                if ($null -eq $rawDir) { return 0 }
                $rawDir = $rawDir.Trim('"')
                if ([string]::IsNullOrWhiteSpace($rawDir)) {
                    $customDir = $null
                    continue
                }
                if (-not [System.IO.File]::Exists((Join-Path $rawDir 'profiles.yaml'))) {
                    Write-Host "[warn] 该目录下未找到 profiles.yaml: $rawDir" -ForegroundColor Yellow
                    Pause-ForMenu
                    continue
                }
                $customDir = $rawDir
                Write-Host "已切换配置目录为: $customDir" -ForegroundColor Green
                Write-Host '  [1] 立即预览配置 (--dry-run)'
                Write-Host '  [2] 立即正式写入'
                Write-Host '  [0] 返回主菜单继续选择其它功能（默认直接回车）'
                $sub = Read-MenuInput '请选择 (0-2)'
                if ($null -eq $sub) { return 0 }
                if ($sub -ceq '1' -or $sub -ceq '2') {
                    Write-Host ''
                    $opts = New-RunOpts $customDir
                    if ($sub -ceq '1') { $opts.DryRun = $true }
                    [void](Invoke-RebuildAction $opts)
                    Pause-ForMenu
                }
            }
            '10' {
                Write-Host ''
                Write-Host '还原 .bak 备份:' -ForegroundColor Cyan
                Write-Host '  [1] 预览还原，不修改文件 (--restore --dry-run)'
                Write-Host '  [2] 正式还原所有订阅备份 (--restore)'
                Write-Host '  [0] 返回主菜单（默认直接回车）'
                $mode = Read-MenuInput '请选择 (0-2)'
                if ($null -eq $mode) { return 0 }
                if ($mode -ceq '' -or $mode -ceq '0') { continue }
                $opts = New-RunOpts $customDir
                $opts.Restore = $true
                $opts.SkipDownload = $true
                if ($mode -ceq '1') { $opts.DryRun = $true }
                elseif ($mode -cne '2') {
                    Write-Host "无效选项: $mode" -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 700
                    continue
                }
                Write-Host ''
                [void](Invoke-RebuildAction $opts)
                Pause-ForMenu
            }
            '0' { return 0 }
            default {
                Write-Host "无效选项: $choice（请输入 0-10 的数字）" -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

# ==============================================================================
# 命令行参数解析与入口
# ==============================================================================

function Show-CliHelp {
    Write-Host @'
用法:
  clash_rebuild_rules.bat                      双击或无参数运行：打开交互式功能菜单
  clash_rebuild_rules.bat [选项]               命令行模式（无需安装 Python，与 .py 参数兼容）

常用选项:
  --dry-run                只预览将要写入或还原的内容，不修改任何文件
  --apply                  直接以默认参数执行正式写入（命令行无其它标志时使用）
  --restore                用首次生成的 .bak 备份还原 Merge 与 Rules 文件
  --source <源>            规则集源：loyalsoldier（默认 YAML）或 metacubex（.mrs 低内存）
  --cdn <镜像>             下载源：raw（默认 GitHub）或 jsdelivr（国内 CDN）
  --skip-download          只写入配置文件，不预先拉取规则集到本地缓存
  --no-proxy-download      下载规则集时不指定 proxy，且预拉取不走系统代理
  --reset-rules            重置 Rules 增强为模板默认规则，不保留界面手工新增规则
  --profile <名称/uid>     仅处理指定订阅（可重复指定）
  --group <代理组名>       手动指定主代理组名（覆盖自动识别）
  --dir <目录>             手动指定 Clash Verge 配置目录
  -h, --help               显示此帮助信息
'@
}

function Parse-CliArgs([System.Collections.Generic.List[string]]$ArgList) {
    $opts = [PSCustomObject]@{
        ShowHelp        = $false
        OpenMenu        = $false
        Dir             = $null
        DryRun          = $false
        Restore         = $false
        Source          = 'loyalsoldier'
        Cdn             = 'raw'
        SkipDownload    = $false
        NoProxyDownload = $false
        ResetRules      = $false
        Profiles        = (New-Object 'System.Collections.Generic.List[string]')
        Group           = $null
        Error           = $null
    }

    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $arg = $ArgList[$i]
        $valInline = $null
        if ($arg.StartsWith('--') -and $arg.Contains('=')) {
            $eq = $arg.IndexOf('=')
            $valInline = $arg.Substring($eq + 1)
            $arg = $arg.Substring(0, $eq)
        }

        switch ($arg) {
            '-h'                  { $opts.ShowHelp = $true }
            '--help'              { $opts.ShowHelp = $true }
            '--menu'              { $opts.OpenMenu = $true }
            '--apply'             { }
            '--dry-run'           { $opts.DryRun = $true }
            '--restore'           { $opts.Restore = $true }
            '--skip-download'     { $opts.SkipDownload = $true }
            '--no-proxy-download' { $opts.NoProxyDownload = $true }
            '--reset-rules'       { $opts.ResetRules = $true }
            '--dir' {
                if ($null -ne $valInline) { $opts.Dir = $valInline }
                elseif (($i + 1) -lt $ArgList.Count) { $i++; $opts.Dir = $ArgList[$i] }
                else { $opts.Error = '--dir 缺少参数值'; return $opts }
            }
            '--profile' {
                if ($null -ne $valInline) { [void]$opts.Profiles.Add($valInline) }
                elseif (($i + 1) -lt $ArgList.Count) { $i++; [void]$opts.Profiles.Add($ArgList[$i]) }
                else { $opts.Error = '--profile 缺少参数值'; return $opts }
            }
            '--group' {
                if ($null -ne $valInline) { $opts.Group = $valInline }
                elseif (($i + 1) -lt $ArgList.Count) { $i++; $opts.Group = $ArgList[$i] }
                else { $opts.Error = '--group 缺少参数值'; return $opts }
            }
            '--source' {
                $sv = if ($null -ne $valInline) { $valInline } elseif (($i + 1) -lt $ArgList.Count) { $i++; $ArgList[$i] } else { $null }
                if ($null -eq $sv -or -not $script:RuleSources.Contains($sv)) {
                    $opts.Error = "--source 仅支持: $($script:RuleSources.Keys -join ', ')"
                    return $opts
                }
                $opts.Source = $sv
            }
            '--cdn' {
                $cv = if ($null -ne $valInline) { $valInline } elseif (($i + 1) -lt $ArgList.Count) { $i++; $ArgList[$i] } else { $null }
                if ($cv -cne 'raw' -and $cv -cne 'jsdelivr') {
                    $opts.Error = '--cdn 仅支持: raw, jsdelivr'
                    return $opts
                }
                $opts.Cdn = $cv
            }
            default {
                $opts.Error = "未知参数: $arg（可用 --help 查看用法）"
                return $opts
            }
        }
    }
    return $opts
}

# 读取由 .bat 头部传入的参数
$cliArgs = New-Object 'System.Collections.Generic.List[string]'
$argc = 0
[void][int]::TryParse($env:CLASH_ARGC, [ref]$argc)
for ($idx = 1; $idx -le $argc; $idx++) {
    $v = [Environment]::GetEnvironmentVariable("CLASH_ARG_$idx")
    if ($null -eq $v) { $v = '' }
    [void]$cliArgs.Add($v)
}

try {
    if ($cliArgs.Count -eq 0) {
        $code = Invoke-InteractiveMenu
        exit $code
    }
    $parsed = Parse-CliArgs $cliArgs
    if ($null -ne $parsed.Error) {
        Write-Host $parsed.Error -ForegroundColor Red
        exit 2
    }
    if ($parsed.ShowHelp) {
        Show-CliHelp
        exit 0
    }
    if ($parsed.OpenMenu) {
        $code = Invoke-InteractiveMenu $parsed
        exit $code
    }
    $code = Invoke-RebuildAction $parsed
    exit $code
} catch {
    Write-Host ''
    Write-Host ('[ERROR] 运行出错: ' + $_.Exception.Message) -ForegroundColor Red
    if ($cliArgs.Count -eq 0) {
        Write-Host ''
        try { [void](Read-Host '按回车键退出...') } catch {}
    }
    exit 1
}
