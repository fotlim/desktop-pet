<#
  桌面宠物 DesktopPet —— 独立版
  把校园网那个项目里的桌宠整块搬出来,不再依赖守护进程/托盘登录逻辑。

  素材:PC2005-cloud/dsh-pet(MIT),见 pet/NOTICE.txt
  模型:models/<包名>/,一个包 = 一套帧 + pet.json(可带多套配色变体)
#>
[CmdletBinding()]
param(
    [ValidateSet('run', 'launch', 'pet', 'weather', 'install', 'uninstall', 'list', 'selftest')]
    [string]$Mode = 'run',
    [string]$Model = '',
    [string]$Variant = '',
    [switch]$NoTray,
    [switch]$Background,
    [switch]$Force,
    [switch]$Elevated
)

$script:AppName   = '桌面宠物'
$script:AppVersion = '1.2.5'
$script:SelfScript = $MyInvocation.MyCommand.Path
$script:AppDir     = Split-Path -Parent $script:SelfScript
if (-not $script:AppDir) { $script:AppDir = (Get-Location).Path }
$script:ModelsDir  = Join-Path $script:AppDir 'models'
$script:SettingsFn = Join-Path $script:AppDir 'settings.json'
$script:LogFile    = Join-Path $script:AppDir 'pet.log'
$script:TaskName   = 'DesktopPet'
$script:VbsFile    = Join-Path $script:AppDir 'run-hidden.vbs'

# 当前模型(包 id + 配色 id),启动时从 settings.json 读,菜单里可以随时换
$script:ModelId    = ''
$script:VariantId  = 'default'
$script:PetDir     = ''
$script:PetUrl     = ''
$script:PetTint    = $null

# 网速采样(悬停信息框里显示)
$script:SpeedLast  = $null
$script:SpeedResult = $null
$script:SpeedPeakD = 0
$script:SpeedPeakU = 0
$script:SpeedTotalD = 0
$script:SpeedTotalU = 0
$script:NicList    = $null
$script:NicListAt  = [datetime]::MinValue

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [' + $Level + '] ' + $Message
    try {
        if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 2MB) {
            Move-Item $script:LogFile ($script:LogFile + '.old') -Force
        }
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    } catch { }
    if (-not $Background) {
        $col = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
        try { Write-Host $line -ForegroundColor $col } catch { }
    }
}

# ---------------- 设置 ----------------
function Get-PetDefaults {
    [pscustomobject]@{
        model              = ''
        variant            = 'default'
        pet                = $true
        petX               = 0
        petY               = 0
        petScale           = 1.0
        petFps             = 60
        petWander          = $true
        petRandomMin       = 5
        petGravity         = 1400
        petRestitution     = 0.78
        petGroundFriction  = 2.5
        petThrowPower      = 1.0
        petCeilingBounce   = $true
        petSay             = $true
        petSayEvery        = 6
        petSayDur          = 0
        petWeather         = $true
        petWeatherCity     = ''
        caiyunToken        = ''
        petOverlayW        = 0
        petOverlayH        = 0
        petOverlayFont     = 9.5
        petOverlayOpacity  = 0.94
        iconPlay           = $true
        iconAuto           = $true
        iconWander         = $false
        iconEatSec         = 180
        iconReady          = $false
    }
}

function Get-Settings {
    $def = Get-PetDefaults
    if (-not (Test-Path $script:SettingsFn)) { return $def }
    try {
        $s = [System.IO.File]::ReadAllText($script:SettingsFn, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $def.PSObject.Properties) {
            $cur = $s.PSObject.Properties[$p.Name]
            if (-not $cur -or $null -eq $cur.Value) {
                $s | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
        }
        if ([double]$s.petScale -le 0) { $s.petScale = 1.0 }
        if ([int]$s.petFps -lt 12) { $s.petFps = 60 }
        if ([double]$s.petOverlayFont -le 0) { $s.petOverlayFont = $def.petOverlayFont }
        if ([double]$s.petOverlayOpacity -le 0) { $s.petOverlayOpacity = $def.petOverlayOpacity }
        return $s
    } catch {
        return $def
    }
}

function Save-Settings {
    param($Settings)
    try {
        $json = $Settings | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($script:SettingsFn, $json, (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch {
        Write-Log ('保存设置失败:' + $_.Exception.Message) 'WARN'
        return $false
    }
}

# ---------------- 模型包 ----------------
function Get-PetModels {
    # 扫 models/<包名>/pet.json;一个包可以声明多套配色变体(variants),
    # 变体不额外占磁盘 —— 只换一张颜色矩阵,帧还是那套帧。
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path $script:ModelsDir)) { return @() }
    foreach ($dir in (Get-ChildItem -LiteralPath $script:ModelsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $man = Join-Path $dir.FullName 'pet.json'
        if (-not (Test-Path $man)) { continue }
        $m = $null
        try { $m = [System.IO.File]::ReadAllText($man, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        if (-not $m) { continue }
        $packName = $(if ($m.name) { [string]$m.name } else { $dir.Name })
        $vars = @($m.variants)
        if ($vars.Count -eq 0) { $vars = @([pscustomobject]@{ id = 'default'; name = '原色' }) }
        foreach ($v in $vars) {
            $vn = $(if ($v.name) { [string]$v.name } else { [string]$v.id })
            $label = $(if ($vars.Count -gt 1) { $packName + ' · ' + $vn } else { $packName })
            [void]$out.Add([pscustomobject]@{
                    Id          = $dir.Name
                    Variant     = $(if ($v.id) { [string]$v.id } else { 'default' })
                    Name        = $packName
                    VariantName = $vn
                    Label       = $label
                    Dir         = $dir.FullName
                    Manifest    = $m
                    Filters     = $v.filters
                })
        }
    }
    return @($out)
}

function Resolve-PetModel {
    # 把 model/variant 解析成真实目录 + 颜色矩阵;解析不到就退回第一个包
    $all = @(Get-PetModels)
    if ($all.Count -eq 0) {
        $script:PetDir = ''
        $script:PetManifest = $null
        $script:PetTint = $null
        return $null
    }
    $pick = $null
    if ($script:ModelId) {
        $pick = @($all | Where-Object { $_.Id -eq $script:ModelId -and $_.Variant -eq $script:VariantId })[0]
        if (-not $pick) { $pick = @($all | Where-Object { $_.Id -eq $script:ModelId })[0] }
    }
    if (-not $pick) { $pick = $all[0] }
    $script:ModelId = $pick.Id
    $script:VariantId = $pick.Variant
    $script:PetDir = $pick.Dir
    $script:PetManifest = $pick.Manifest
    $script:PetUrl = $(if ($pick.Manifest.source) { [string]$pick.Manifest.source } else { '' })
    if ($pick.Filters) {
        $script:PetTint = New-PetFilterMatrix -Filters $pick.Filters
    } else {
        $script:PetTint = $null
    }
    return $pick
}

function Set-PetModel {
    # 换模型:清缓存 → 换目录/矩阵 → 原地重启宠物(位置和大小都保留)
    param([string]$Id, [string]$Variant = '')
    $all = @(Get-PetModels)
    $pick = @($all | Where-Object { $_.Id -eq $Id -and $_.Variant -eq $Variant })[0]
    if (-not $pick) { $pick = @($all | Where-Object { $_.Id -eq $Id })[0] }
    if (-not $pick) {
        Write-Log ('没有这个模型:' + $Id + '/' + $Variant) 'WARN'
        return $false
    }

    $wasOn = [bool]($script:PetForm -and -not $script:PetForm.IsDisposed)
    $x = [int]$script:PetX
    $y = [int]$script:PetY
    if ($wasOn) { Stop-Pet }

    $script:ModelId = $pick.Id
    $script:VariantId = $pick.Variant
    $script:PetManifest = $null
    $null = Resolve-PetModel

    try {
        $s = Get-Settings
        $s.model = $pick.Id
        $s.variant = $pick.Variant
        if ($x -gt 0 -and $y -gt 0) { $s.petX = $x; $s.petY = $y }
        [void](Save-Settings -Settings $s)
    } catch { }

    if ($wasOn) {
        if ($x -gt 0 -and $y -gt 0) { $script:PetX = $x; $script:PetY = $y }
        [void](Start-Pet)
    }
    Write-Log ('切换模型:' + $pick.Label + '(' + $pick.Id + '/' + $pick.Variant + ')') 'OK'
    return $true
}

# ---------------- 配色矩阵(hue / saturate / bright) ----------------
function Multiply-Matrix3 {
    param([double[]]$A, [double[]]$B)
    $r = New-Object 'double[]' 9
    for ($i = 0; $i -lt 3; $i++) {
        for ($j = 0; $j -lt 3; $j++) {
            $sum = 0.0
            for ($k = 0; $k -lt 3; $k++) { $sum += $A[$i * 3 + $k] * $B[$k * 3 + $j] }
            $r[$i * 3 + $j] = $sum
        }
    }
    return $r
}

function New-PetFilterMatrix {
    # pet.json 里的 filters:{"hue":角度,"saturate":倍数,"bright":倍数} → ColorMatrix(alpha 不动)
    param($Filters)
    if (-not $Filters) { return $null }
    $hue = 0.0; $sat = 1.0; $bri = 1.0
    foreach ($p in $Filters.PSObject.Properties) {
        switch ($p.Name) {
            'hue' { $hue = [double]$p.Value }
            'saturate' { $sat = [double]$p.Value }
            'bright' { $bri = [double]$p.Value }
        }
    }
    if ([Math]::Abs($hue) -lt 0.01 -and [Math]::Abs($sat - 1) -lt 0.001 -and [Math]::Abs($bri - 1) -lt 0.001) { return $null }

    $m = @(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
    if ([Math]::Abs($sat - 1) -gt 0.001) {
        $rw = 0.213; $gw = 0.715; $bw = 0.072
        # 注意 GDI+ 的 ColorMatrix 是按「行 = 输入通道、列 = 输出通道」用的
        # (out = in × M),所以饱和度矩阵要把亮度权重放在每一行里。
        $s3 = @(
            ($rw * (1 - $sat) + $sat), ($rw * (1 - $sat)), ($rw * (1 - $sat)),
            ($gw * (1 - $sat)), ($gw * (1 - $sat) + $sat), ($gw * (1 - $sat)),
            ($bw * (1 - $sat)), ($bw * (1 - $sat)), ($bw * (1 - $sat) + $sat)
        )
        $m = Multiply-Matrix3 $s3 $m
    }
    if ([Math]::Abs($hue) -gt 0.01) {
        # 负号是因为这张色相矩阵在 GDI+ 的行向量约定下方向相反(实测 hue=+120 会把红转成蓝)
        $rad = -$hue * [Math]::PI / 180.0
        $c = [Math]::Cos($rad); $s2 = [Math]::Sin($rad)
        $h3 = @(
            (0.213 + $c * 0.787 - $s2 * 0.213), (0.715 - $c * 0.715 - $s2 * 0.715), (0.072 - $c * 0.072 + $s2 * 0.928),
            (0.213 - $c * 0.213 + $s2 * 0.143), (0.715 + $c * 0.285 + $s2 * 0.140), (0.072 - $c * 0.072 - $s2 * 0.283),
            (0.213 - $c * 0.213 - $s2 * 0.787), (0.715 - $c * 0.715 + $s2 * 0.715), (0.072 + $c * 0.928 + $s2 * 0.072)
        )
        $m = Multiply-Matrix3 $h3 $m
    }
    if ([Math]::Abs($bri - 1) -gt 0.001) {
        $b3 = @($bri, 0.0, 0.0, 0.0, $bri, 0.0, 0.0, 0.0, $bri)
        $m = Multiply-Matrix3 $b3 $m
    }
    $cm = New-Object System.Drawing.Imaging.ColorMatrix
    $cm.Matrix00 = [single]$m[0]; $cm.Matrix01 = [single]$m[1]; $cm.Matrix02 = [single]$m[2]
    $cm.Matrix10 = [single]$m[3]; $cm.Matrix11 = [single]$m[4]; $cm.Matrix12 = [single]$m[5]
    $cm.Matrix20 = [single]$m[6]; $cm.Matrix21 = [single]$m[7]; $cm.Matrix22 = [single]$m[8]
    return $cm
}

function Apply-PetTint {
    # 把颜色矩阵烘进帧(载入时做一次,播放时零开销)
    param($Bitmap, $Matrix)
    if (-not $Bitmap -or -not $Matrix) { return $Bitmap }
    $w = $Bitmap.Width; $h = $Bitmap.Height
    $out = $null
    try {
        $out = New-Object System.Drawing.Bitmap -ArgumentList $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($out)
        $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $g.Clear([System.Drawing.Color]::Transparent)
        $ia = New-Object System.Drawing.Imaging.ImageAttributes
        $ia.SetColorMatrix($Matrix)
        $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $w, $h
        $g.DrawImage($Bitmap, $rect, 0, 0, $w, $h, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $ia.Dispose()
        $g.Dispose()
        $Bitmap.Dispose()
        return $out
    } catch {
        if ($out) { try { $out.Dispose() } catch { } }
        return $Bitmap
    }
}

# ---------------- 网速(悬停信息框用) ----------------
function Get-NicByteCounters {
    # 累加「已启用 + 非回环 + 非隧道」网卡;网卡列表缓存 30 秒,只重读统计值
    $rx = [long]0
    $tx = [long]0
    try {
        $now = Get-Date
        if (-not $script:NicList -or ($now - $script:NicListAt).TotalSeconds -ge 30) {
            $list = New-Object System.Collections.ArrayList
            foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                try {
                    if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
                    $t = $ni.NetworkInterfaceType
                    if ($t -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
                    if ($t -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) { continue }
                    [void]$list.Add($ni)
                } catch { }
            }
            $script:NicList = $list
            $script:NicListAt = $now
        }
        foreach ($ni in $script:NicList) {
            try {
                $st = $ni.GetIPv4Statistics()
                if ($st) { $rx += $st.BytesReceived; $tx += $st.BytesSent }
            } catch { }
        }
    } catch { }
    return [pscustomobject]@{ Rx = $rx; Tx = $tx }
}

function Format-Speed {
    param([double]$BytesPerSec, [switch]$Short)
    if ($BytesPerSec -lt 0) { $BytesPerSec = 0 }
    if ($Short) {
        if ($BytesPerSec -lt 1024) { return ('{0:N0}B' -f $BytesPerSec) }
        if ($BytesPerSec -lt 1048576) { return ('{0:N0}K' -f ($BytesPerSec / 1024)) }
        return ('{0:N1}M' -f ($BytesPerSec / 1048576))
    }
    if ($BytesPerSec -lt 1024) { return ('{0:N0} B/s' -f $BytesPerSec) }
    if ($BytesPerSec -lt 1048576) { return ('{0:N0} KB/s' -f ($BytesPerSec / 1024)) }
    if ($BytesPerSec -lt 1073741824) { return ('{0:N2} MB/s' -f ($BytesPerSec / 1048576)) }
    return ('{0:N2} GB/s' -f ($BytesPerSec / 1073741824))
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -lt 1024) { return ('{0:N0} B' -f $Bytes) }
    if ($Bytes -lt 1048576) { return ('{0:N0} KB' -f ($Bytes / 1024)) }
    if ($Bytes -lt 1073741824) { return ('{0:N1} MB' -f ($Bytes / 1048576)) }
    return ('{0:N2} GB' -f ($Bytes / 1073741824))
}

function Get-NetSpeed {
    param([switch]$Reset)
    if ($Reset) {
        $script:SpeedLast = $null; $script:SpeedResult = $null
        $script:SpeedPeakD = 0; $script:SpeedPeakU = 0
        $script:SpeedTotalD = 0; $script:SpeedTotalU = 0
        return $null
    }
    $now = Get-Date
    $c = Get-NicByteCounters
    if (-not $script:SpeedLast) {
        $script:SpeedLast = [pscustomobject]@{ Time = $now; Rx = $c.Rx; Tx = $c.Tx }
        $script:SpeedResult = [pscustomobject]@{
            Ready = $false; Down = [double]0; Up = [double]0
            DownText = '—'; UpText = '—'; DownShort = '—'; UpShort = '—'
            PeakDownText = '—'; PeakUpText = '—'; TotalText = '—'
        }
        return $script:SpeedResult
    }
    $el = ($now - $script:SpeedLast.Time).TotalSeconds
    if ($el -lt 0.5 -and $script:SpeedResult) { return $script:SpeedResult }
    if ($el -le 0) { $el = 0.5 }
    $dRx = $c.Rx - $script:SpeedLast.Rx
    $dTx = $c.Tx - $script:SpeedLast.Tx
    if ($dRx -lt 0 -or $dTx -lt 0) { $dRx = 0; $dTx = 0 }
    $down = [double]$dRx / $el
    $up = [double]$dTx / $el
    $script:SpeedLast = [pscustomobject]@{ Time = $now; Rx = $c.Rx; Tx = $c.Tx }
    $script:SpeedTotalD += $dRx
    $script:SpeedTotalU += $dTx
    if ($down -gt $script:SpeedPeakD) { $script:SpeedPeakD = $down }
    if ($up -gt $script:SpeedPeakU) { $script:SpeedPeakU = $up }
    $script:SpeedResult = [pscustomobject]@{
        Ready        = $true
        Down         = $down
        Up           = $up
        DownText     = (Format-Speed $down)
        UpText       = (Format-Speed $up)
        DownShort    = (Format-Speed $down -Short)
        UpShort      = (Format-Speed $up -Short)
        PeakDownText = (Format-Speed $script:SpeedPeakD)
        PeakUpText   = (Format-Speed $script:SpeedPeakU)
        TotalText    = ('↓' + (Format-Bytes $script:SpeedTotalD) + '  ↑' + (Format-Bytes $script:SpeedTotalU))
    }
    return $script:SpeedResult
}

# ================= 以下是从校园网项目整块搬过来的桌宠代码(已去依赖) =================

# ================= 桌面宠物 =================
# 素材来自 @PC2005-cloud/dsh-pet(MIT):https://github.com/PC2005-cloud/dsh-pet
# 原版是在 Electron/WebGL 里直接放黑底 webm,一个宠物进程要 100MB 上下。
# 这里的做法:构建时把 webm 抠图(含去黑边)+ 按 24fps 逐帧导出 PNG,
# 运行时用 GDI 分层窗口(UpdateLayeredWindow)直接画在**已有的托盘进程**里。
$script:PetDir    = ''            # 由 Resolve-PetModel 按 settings 里的 model 填
$script:PetUrl    = 'https://github.com/PC2005-cloud/dsh-pet'
$script:PetCache  = @{}          # 动作 -> @{ Hbs; W; H; Count }
$script:PetForm   = $null
$script:PetTimer  = $null
$script:PetSw     = $null
$script:PetAnim   = ''
# 切换动画时的交叉淡入(过渡用):PetFadeFromBmp 是「上一帧」的位图,前几帧按比例混过去
$script:PetFadeFromBmp = $null
$script:PetFadeLeft = 0
$script:PetFadeTotal = 0
$script:PetLastHb = [IntPtr]::Zero
$script:PetLastAnim = ''
$script:PetLastFrameIdx = 0
$script:PetBuilding = $null
$script:PetLastIdx = -1
$script:PetAction = ''
$script:PetActionEnd = [datetime]::MinValue
$script:PetActionStart = [datetime]::MinValue
$script:PetActionPingPong = $true
$script:PetActionDurSec = 0.0
$script:PetX      = 0
$script:PetY      = 0
$script:PetXf     = 0.0
$script:PetYf     = 0.0
$script:PetLastDrawX = -99999
$script:PetLastDrawY = -99999
$script:PetCfg    = $null
$script:PetCfgAt  = [datetime]::MinValue
$script:PetLastScale = 1.0
$script:PetDrag   = $null
$script:PetSettingsStamp = 0
$script:PetFpsLog  = $false
$script:PetFpsLog2 = $false
$script:PetTicks   = 0
$script:PetTicksWarm = 0
$script:PetWarmAt  = [datetime]::MinValue
$script:PetTickStart = [datetime]::MinValue
$script:PetTickAll = 0
$script:PetManifest = $null
$script:PetSleepCache = $false
$script:PetSleepAt = [datetime]::MinValue
$script:PetSleepHits = 0
$script:PetStateStamp = 0
# 键鼠静止多少分钟就打盹
$script:PetIdleSleepMin = 10
# 桌面图标互动(吃掉 / 搬运 / 整理)
$script:IconDir = $script:AppDir
$script:IconLv = [IntPtr]::Zero
$script:IconEaten = @()
$script:IconPlay = $true
$script:IconAutoWander = $false
$script:IconEatSeconds = 180
$script:IconReady = $false
$script:IconEventAt = [datetime]::MinValue
$script:IconLayoutFn = Join-Path $script:IconDir 'icon-layout.json'
$script:IconStateFn = Join-Path $script:IconDir 'icon-state.json'
$script:ScreenW = 0
$script:ScreenH = 0
$script:PetFrameW = 1
$script:PetFrameH = 1
$script:PetOverlayFontSize = 9.5
$script:PetOverlayLineH = 22
$script:PetOverlayPad = 10
$script:TrayAlive = $false
$script:TrayAliveAt = [datetime]::MinValue

# 走动 / 随机事件
$script:PetTarget = $null
$script:PetVx = 0.0
$script:PetVy = 0.0
$script:PetPhys = $false
$script:PetLastPhysAt = [datetime]::MinValue
$script:PetSayUntil = [datetime]::MinValue
$script:PetSayings = $null
$script:PetStillSince = [datetime]::MinValue
$script:PetNextRandom = [datetime]::MinValue
$script:PetMemeUntil = [datetime]::MinValue

# 悬停面板
$script:PetOverlay = $null
$script:PetOverlayHb = [IntPtr]::Zero
$script:PetOverlaySize = $null
$script:PetOverlayButtons = @()
$script:PetOverlayKind = ''
$script:PetOverlayDrawWarned = $false
$script:PetHover = $false
$script:PetHoverOffAt = [datetime]::MinValue
$script:PetOverlayHover = $false
$script:PetOverlayRefreshAt = [datetime]::MinValue

# 媒体 / 天气
$script:PetMedia = $null
$script:PetMediaAt = [datetime]::MinValue
$script:PetMediaActions = $null
$script:PetWeather = $null
$script:PetWeatherAt = [datetime]::MinValue
$script:PetWeatherFile = Join-Path $script:AppDir 'pet-weather.json'
# 彩云天气接口根(测试时可用环境变量指到本地假服务)
$script:CaiyunApiBase = $(if ($env:DPET_CAIYUN_BASE) { [string]$env:DPET_CAIYUN_BASE } else { 'https://api.caiyunapp.com' })
$script:PetMemeCache = @{}

$script:LayeredCs = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

namespace DeskPet {
    public static class Layered {
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
        [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx; public int cy; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
        [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hDC);
        [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hDC);
        [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr hObject);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
        [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")]
        static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize,
            IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);

        public static bool MakeDpiAware() {
            try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); }   // PER_MONITOR_AWARE_V2
            catch { return false; }
        }

        // WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
        public static void Enable(IntPtr hwnd) {
            int ex = GetWindowLong(hwnd, -20);
            SetWindowLong(hwnd, -20, ex | 0x80000 | 0x80 | 0x8000000);
        }

        [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
        [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);
        public static void BeginHighRes() { try { timeBeginPeriod(1); } catch { } }
        public static void EndHighRes() { try { timeEndPeriod(1); } catch { } }

        [StructLayout(LayoutKind.Sequential)]
        struct POWER_THROTTLING_STATE { public uint Version; public uint ControlMask; public uint StateMask; }
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetProcessInformation(IntPtr hProcess, int infoClass, ref POWER_THROTTLING_STATE state, uint size);

        public static bool DisablePowerThrottling() {
            try {
                var st = new POWER_THROTTLING_STATE();
                st.Version = 1; st.ControlMask = 0x1; st.StateMask = 0;
                return SetProcessInformation(GetCurrentProcess(), 4, ref st, (uint)Marshal.SizeOf(st));
            } catch { return false; }
        }

        public static IntPtr ToHBitmap(Bitmap bmp) { return bmp.GetHbitmap(Color.FromArgb(0)); }
        public static void FreeHBitmap(IntPtr h) { if (h != IntPtr.Zero) DeleteObject(h); }

        [ThreadStatic] public static int LastError;

        public static bool Draw(IntPtr hwnd, IntPtr hbmp, int w, int h, int x, int y, byte alpha) {
            IntPtr screenDc = GetDC(IntPtr.Zero);
            IntPtr memDc = CreateCompatibleDC(screenDc);
            IntPtr old = SelectObject(memDc, hbmp);
            try {
                SIZE size = new SIZE(); size.cx = w; size.cy = h;
                POINT src = new POINT();
                POINT dst = new POINT(); dst.X = x; dst.Y = y;
                BLENDFUNCTION blend = new BLENDFUNCTION();
                blend.BlendOp = 0; blend.BlendFlags = 0;
                blend.SourceConstantAlpha = alpha; blend.AlphaFormat = 1;
                bool ok = UpdateLayeredWindow(hwnd, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, 2);
                if (!ok) LastError = Marshal.GetLastWin32Error();
                return ok;
            } finally {
                SelectObject(memDc, old);
                DeleteDC(memDc);
                ReleaseDC(IntPtr.Zero, screenDc);
            }
        }
    }
}
'@
function Get-PetFrameBitmap {
    # 按当前缩放 / 配色 / 画布把某一帧重新解码成**带透明通道**的 Bitmap。
    # 用途:动作切换的淡入起点。不能拿 HBITMAP 走 Image.FromHbitmap —— GDI+ 会丢掉 alpha,
    # 透明区域变成黑底,淡入时就出现一个黑框。
    param([string]$Anim, [int]$Index)
    if (-not $Anim) { return $null }
    $dir = Join-Path $script:PetDir $Anim
    $f = Join-Path $dir ('{0:000}.png' -f [int]$Index)
    if (-not (Test-Path $f)) {
        $all = @(Get-ChildItem -LiteralPath $dir -Filter '*.png' -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($all.Count -eq 0) { return $null }
        $f = $all[[Math]::Min([int]$Index, $all.Count - 1)].FullName
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($f)
        $ms = New-Object System.IO.MemoryStream -ArgumentList (,$bytes)
        $img = [System.Drawing.Image]::FromStream($ms)
        $scale = [double](Get-PetCfg).Scale
        if ($scale -lt 0.5) { $scale = 0.5 }
        if ($scale -gt 2.0) { $scale = 2.0 }
        $dw = [Math]::Max(1, [int][Math]::Round($img.Width * $scale))
        $dh = [Math]::Max(1, [int][Math]::Round($img.Height * $scale))
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList $dw, $dh, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($img, 0, 0, $dw, $dh)
        $g.Dispose(); $img.Dispose(); $ms.Dispose()
        if ($script:PetTint) { $bmp = Apply-PetTint -Bitmap $bmp -Matrix $script:PetTint }
        # 垫进统一画布,和播放用的是同一套坐标
        $man = Get-PetManifest
        if ($man -and $man.PSObject.Properties['canvas'] -and $man.canvas) {
            $cw = [int][Math]::Round([double]$man.canvas.w * $scale)
            $ch = [int][Math]::Round([double]$man.canvas.h * $scale)
            $ox = 0; $oy = 0
            foreach ($a in (Get-PetAnimList)) {
                if ([string]$a.id -eq $Anim) {
                    if ($a.PSObject.Properties['ox']) { $ox = [int][Math]::Round([double]$a.ox * $scale) }
                    if ($a.PSObject.Properties['oy']) { $oy = [int][Math]::Round([double]$a.oy * $scale) }
                    break
                }
            }
            if ($cw -gt 0 -and ($cw -ne $bmp.Width -or $ch -ne $bmp.Height)) {
                $pad = New-Object System.Drawing.Bitmap -ArgumentList $cw, $ch, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $gp = [System.Drawing.Graphics]::FromImage($pad)
                $gp.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $gp.Clear([System.Drawing.Color]::Transparent)
                $gp.DrawImage($bmp, $ox, $oy, $bmp.Width, $bmp.Height)
                $gp.Dispose(); $bmp.Dispose()
                $bmp = $pad
            }
        }
        return $bmp
    } catch { return $null }
}
function Test-PetAssets {
    if (-not (Test-Path (Join-Path $script:PetDir 'idle'))) { return $false }
    return $true
}

function Set-PetDpiAware {
    if (-not ('DeskPet.Dpi' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DeskPet {
    public static class Dpi {
        [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
        public static bool Make() {
            try { return SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { return false; }
        }
    }
}
'@
        } catch { }
    }
    try { return [DeskPet.Dpi]::Make() } catch { return $false }
}

function Get-PetManifest {
    if ($script:PetManifest) { return $script:PetManifest }
    $f = Join-Path $script:PetDir 'pet.json'
    if (-not (Test-Path $f)) { return $null }
    try {
        $script:PetManifest = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        return $script:PetManifest
    } catch { return $null }
}

function Get-PetFps { $m = Get-PetManifest; if ($m -and [int]$m.fps -ge 1) { return [int]$m.fps }; return 24 }
function Get-PetAnimList { $m = Get-PetManifest; if (-not $m -or -not $m.anims) { return @() }; return @($m.anims) }
function Get-PetMemeList { $m = Get-PetManifest; if (-not $m -or -not $m.memes) { return @() }; return @($m.memes) }

function Get-PetLabel {
    param([string]$Id)
    foreach ($a in (Get-PetAnimList)) { if ($a.id -eq $Id) { return [string]$a.label } }
    return $Id
}

function Merge-PetBitmap {
    # 两张同尺寸帧线性混合(0.5 就是中间帧),用来把 24fps 素材插成 48fps
    param($A, $B, [double]$Alpha = 0.5)
    if (-not $A -or -not $B) { return $null }
    if ($A.Width -ne $B.Width -or $A.Height -ne $B.Height) { return $null }
    $w = $A.Width; $h = $A.Height
    $out = $null
    try {
        $out = New-Object System.Drawing.Bitmap -ArgumentList $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($out)
        $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($A, 0, 0, $w, $h)

        $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceOver
        $ia = New-Object System.Drawing.Imaging.ImageAttributes
        $cm = New-Object System.Drawing.Imaging.ColorMatrix
        $cm.Matrix33 = [single]$Alpha
        $ia.SetColorMatrix($cm)
        $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $w, $h
        $g.DrawImage($B, $rect, 0, 0, $w, $h, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $ia.Dispose()
        $g.Dispose()
        return $out
    } catch {
        if ($out) { try { $out.Dispose() } catch { } }
        return $null
    }
}

function Get-PetFrames {
    # 按缩放比例缓存:key = "动作@比例"。换大小只会重新解码当前动作,不影响别的
    param([string]$Anim, [double]$Scale = 1.0)

    if ($Scale -lt 0.5) { $Scale = 0.5 }
    if ($Scale -gt 2.0) { $Scale = 2.0 }
    $key = ('{0}@{1:N2}@{2}@{3}' -f $Anim, $Scale, $script:ModelId, $script:VariantId)
    if ($script:PetCache.ContainsKey($key)) { return $script:PetCache[$key] }
    if ($script:PetBuilding -eq $key) { return $null }   # 建帧时会跑 DoEvents,消息循环可能转回来要同一套帧

    $dir = Join-Path $script:PetDir $Anim
    if (-not (Test-Path $dir)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.png' | Sort-Object Name)
    if ($files.Count -eq 0) { return $null }

    $fps = Get-PetFps
    foreach ($a in (Get-PetAnimList)) {
        if ($a.id -eq $Anim -and $a.PSObject.Properties['fps'] -and [int]$a.fps -gt 0) { $fps = [int]$a.fps }
    }

    # 统一画布:每个动作的裁剪框大小不一样,不垫到同一块画布的话,
    # 切换动作时窗口会突然缩放/移位(看着就是「突兀的缩放」)。
    # canvas/ox/oy 由 build 脚本写进 pet.json;老素材没有这些字段就按每帧自己的尺寸走。
    $man = Get-PetManifest
    $canvasW = 0; $canvasH = 0; $oxS = 0; $oyS = 0
    if ($man -and $man.PSObject.Properties['canvas'] -and $man.canvas) {
        $canvasW = [int][Math]::Round([double]$man.canvas.w * $Scale)
        $canvasH = [int][Math]::Round([double]$man.canvas.h * $Scale)
        foreach ($a in (Get-PetAnimList)) {
            if ([string]$a.id -eq $Anim -and $a.PSObject.Properties['ox']) {
                $oxS = [int][Math]::Round([double]$a.ox * $Scale)
                $oyS = [int][Math]::Round([double]$a.oy * $Scale)
                break
            }
        }
        if ($canvasW -lt 1) { $canvasW = 0 }
    }

    $hbs = New-Object System.Collections.ArrayList
    $w = 0; $h = 0

    # 素材是 24fps;想要更高刷新率就插中间帧(线性混合),播放时长不变
    $targetFps = [int](Get-PetCfg).Fps
    if ($targetFps -lt 12) { $targetFps = 12 }
    $k = 1
    # 长动作(整段 10 秒、上百帧)也插帧,否则 12fps 素材看着一顿一顿的;
    # 但 idle/sleep/walk 是慢速循环,不插(省内存)
    $interpOk = (($fps -lt 20) -and (($files.Count -le 90) -or ($Anim -notin @('idle', 'sleep', 'walk'))))
    if ($targetFps -gt [int]($fps * 1.2) -and $interpOk) { $k = 2 }
    # 内存闸门:一个动作最多 300 帧(约 80MB),再高就不插了
    if (($files.Count * $k) -gt 300) {
        Write-Log ('帧插值跳过:' + $Anim + ' 帧数偏多(' + $files.Count + ' × ' + $k + ')') 'WARN'
        $k = 1
    }

    $prev = $null
    $script:PetBuilding = $key
    $built = 0
    try {
    foreach ($f in $files) {
        $bmp = $null
        try {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $ms = New-Object System.IO.MemoryStream -ArgumentList (,$bytes)
            $img = [System.Drawing.Image]::FromStream($ms)
            $raw = New-Object System.Drawing.Bitmap -ArgumentList $img
            $img.Dispose(); $ms.Dispose()

            if ([Math]::Abs($Scale - 1.0) -lt 0.01) {
                $bmp = $raw
            } else {
                $dw = [Math]::Max(1, [int][Math]::Round($raw.Width * $Scale))
                $dh = [Math]::Max(1, [int][Math]::Round($raw.Height * $Scale))
                $scaled = New-Object System.Drawing.Bitmap -ArgumentList $dw, $dh, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $g = [System.Drawing.Graphics]::FromImage($scaled)
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $g.Clear([System.Drawing.Color]::Transparent)
                $g.DrawImage($raw, 0, 0, $dw, $dh)
                $g.Dispose()
                $raw.Dispose()
                $bmp = $scaled
            }
            # 配色变体:把颜色矩阵烘进帧,播放时零开销
            if ($script:PetTint) { $bmp = Apply-PetTint -Bitmap $bmp -Matrix $script:PetTint }
            # 垫进统一画布(不缩放,只改位置):切换动作时窗口尺寸和角色位置都不变
            if ($canvasW -gt 0 -and ($bmp.Width -ne $canvasW -or $bmp.Height -ne $canvasH)) {
                $pad = New-Object System.Drawing.Bitmap -ArgumentList $canvasW, $canvasH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $gp = [System.Drawing.Graphics]::FromImage($pad)
                $gp.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                $gp.Clear([System.Drawing.Color]::Transparent)
                $gp.DrawImage($bmp, $oxS, $oyS, $bmp.Width, $bmp.Height)
                $gp.Dispose()
                $bmp.Dispose()
                $bmp = $pad
            }
            if ($w -eq 0) { $w = $bmp.Width; $h = $bmp.Height }

            # 上一帧和这一帧之间插一张(顺序:帧0 → 混合 → 帧1 → …)
            if ($k -gt 1 -and $prev -and $prev.Width -eq $bmp.Width -and $prev.Height -eq $bmp.Height) {
                $mid = Merge-PetBitmap -A $prev -B $bmp -Alpha 0.5
                if ($mid) {
                    [void]$hbs.Add([DeskPet.Layered]::ToHBitmap($mid))
                    $mid.Dispose()
                }
            }
            [void]$hbs.Add([DeskPet.Layered]::ToHBitmap($bmp))

            if ($prev) { $prev.Dispose() }
            $prev = $bmp
            $built++
            if (($built % 8) -eq 0) { try { [System.Windows.Forms.Application]::DoEvents() } catch { } }
        } catch {
            if ($bmp) { try { $bmp.Dispose() } catch { } }
        }
    }
    if ($prev) { try { $prev.Dispose() } catch { } }
    } finally { $script:PetBuilding = $null }
    if ($hbs.Count -eq 0) { return $null }

    $entry = [pscustomobject]@{ Hbs = $hbs; W = $w; H = $h; Count = $hbs.Count; Fps = ($fps * $k) }
    $script:PetCache[$key] = $entry
    # 24fps 整段动作一帧要 250KB 上下,缓存只留「当前动作 + idle」两个,免得吃几百 MB
    if ($script:PetCache.Count -gt 2) {
        foreach ($k in @($script:PetCache.Keys)) {
            if ($k -eq $key -or $k -like 'idle@*') { continue }
            foreach ($hb in $script:PetCache[$k].Hbs) { [DeskPet.Layered]::FreeHBitmap($hb) }
            $script:PetCache.Remove($k)
        }
        $script:PetLastHb = [IntPtr]::Zero
$script:PetLastAnim = ''
$script:PetLastFrameIdx = 0
    }
    return $entry
}

function Get-IdleMilliseconds {
    # 用 GetLastInputInfo 拿「键鼠多久没动」,比读进程状态便宜得多
    if (-not ('DeskPet.Idle' -as [type])) {
        try {
            $cs = @'
using System;
using System.Runtime.InteropServices;
namespace DeskPet {
    public static class Idle {
        [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
        public static uint Milliseconds() {
            LASTINPUTINFO li = new LASTINPUTINFO();
            li.cbSize = (uint)Marshal.SizeOf(li);
            if (!GetLastInputInfo(ref li)) return 0;
            return (uint)(Environment.TickCount - (int)li.dwTime);
        }
    }
}
'@
            Add-Type -TypeDefinition $cs -Language CSharp
        } catch { }
    }
    try { return [int][DeskPet.Idle]::Milliseconds() } catch { return 0 }
}

function Test-PetShouldSleep {
    # 独立版没有「校园网在线状态」可看:改成「人多久没碰键鼠」。
    # 10 分钟没输入就打盹,动一下鼠标立刻醒;每 2 秒算一次就够(这个查询很便宜)。
    if (((Get-Date) - $script:PetSleepAt).TotalSeconds -lt 2) { return $script:PetSleepCache }
    $script:PetSleepAt = Get-Date
    $idleMs = Get-IdleMilliseconds
    $script:PetSleepCache = ($idleMs -ge ($script:PetIdleSleepMin * 60000))
    return $script:PetSleepCache
}

function Get-PetCfg {
    # 每帧都要用的几个设置:缓存 2 秒。之前每帧都 Get-Settings(读磁盘 + 解析 JSON),
    # 60 次/秒 —— 这是掉帧和移动发涩的主要来源。
    if ($script:PetCfg -and ((Get-Date) - $script:PetCfgAt).TotalSeconds -lt 2) { return $script:PetCfg }
    $s = $null
    try { $s = Get-Settings } catch { }
    $scale = 1.0
    if ($s -and $s.PSObject.Properties['petScale']) { $scale = [double]$s.petScale }
    if ($scale -lt 0.5) { $scale = 0.5 }
    if ($scale -gt 2.0) { $scale = 2.0 }
    $script:PetCfg = [pscustomobject]@{
        RandomMin = $(if ($s) { [int]$s.petRandomMin } else { 5 })
        Wander    = $(if ($s) { [bool]$s.petWander } else { $true })
        Weather   = $(if ($s) { [bool]$s.petWeather } else { $true })
        Scale     = $scale
        OverlayFont    = $(if ($s -and $s.PSObject.Properties['petOverlayFont'] -and [double]$s.petOverlayFont -gt 0) { [double]$s.petOverlayFont } else { 9.5 })
        OverlayOpacity = $(if ($s -and $s.PSObject.Properties['petOverlayOpacity'] -and [double]$s.petOverlayOpacity -gt 0) { [double]$s.petOverlayOpacity } else { 0.94 })
        OverlayW       = $(if ($s -and $s.PSObject.Properties['petOverlayW'] -and [int]$s.petOverlayW -gt 0) { [int]$s.petOverlayW } else { 0 })
        Fps            = $(if ($s -and $s.PSObject.Properties['petFps'] -and [int]$s.petFps -ge 12) { [int]$s.petFps } else { 60 })
        SayEvery       = $(if ($s -and $s.PSObject.Properties['petSayEvery']) { [int]$s.petSayEvery } else { 6 })
        SayDur         = $(if ($s -and $s.PSObject.Properties['petSayDur']) { [double]$s.petSayDur } else { 0 })
        OverlayH       = $(if ($s -and $s.PSObject.Properties['petOverlayH'] -and [int]$s.petOverlayH -gt 0) { [int]$s.petOverlayH } else { 0 })
        Gravity        = $(if ($s -and $s.PSObject.Properties['petGravity'] -and [int]$s.petGravity -gt 0) { [double]$s.petGravity } else { 1400 })
        Restitution    = $(if ($s -and $s.PSObject.Properties['petRestitution']) { [double]$s.petRestitution } else { 0.78 })
        Friction       = $(if ($s -and $s.PSObject.Properties['petGroundFriction']) { [double]$s.petGroundFriction } else { 2.5 })
        ThrowPower     = $(if ($s -and $s.PSObject.Properties['petThrowPower'] -and [double]$s.petThrowPower -gt 0) { [double]$s.petThrowPower } else { 1.0 })
        CeilingBounce  = $(if ($s -and $s.PSObject.Properties['petCeilingBounce']) { [bool]$s.petCeilingBounce } else { $true })
        Say            = $(if ($s -and $s.PSObject.Properties['petSay']) { [bool]$s.petSay } else { $true })
        WeatherCity    = $(if ($s -and $s.PSObject.Properties['petWeatherCity']) { [string]$s.petWeatherCity } else { '' })
    }
    $script:PetCfgAt = Get-Date
    return $script:PetCfg
}

function Set-PetSize {
    param([double]$Scale)
    if ($Scale -lt 0.5) { $Scale = 0.5 }
    if ($Scale -gt 2.0) { $Scale = 2.0 }
    try {
        $s = Get-Settings
        $s | Add-Member -NotePropertyName petScale -NotePropertyValue $Scale -Force
        Save-Settings -Settings $s
    } catch { }
    $script:PetCfg = $null
    $script:PetCfgAt = [datetime]::MinValue
    Write-Log ('宠物大小调整为 ' + [int][Math]::Round($Scale * 100) + '%')
}

function Set-PetOverlaySize {
    # 信息框尺寸:0 = 自动(按内容);宽固定就换行,高固定就截断
    param([int]$W, [int]$H)
    if ($W -lt 0) { $W = 0 }
    if ($H -lt 0) { $H = 0 }
    try {
        $s = Get-Settings
        $s.petOverlayW = $W
        $s.petOverlayH = $H
        Save-Settings -Settings $s
    } catch { }
    $script:PetCfg = $null
    $script:PetCfgAt = [datetime]::MinValue
    Write-Log ('信息框尺寸: ' + $(if ($W -gt 0) { [string]$W } else { '自动' }) + ' × ' + $(if ($H -gt 0) { [string]$H } else { '自动' }))
    # 面板正开着就按新尺寸重画一次
    if ($script:PetOverlayKind -eq 'info' -and $script:PetOverlay -and $script:PetOverlay.Visible) {
        Set-PetOverlayContent -Kind 'info'
    }
}

function Get-PetSetting {
    param([string]$Name, $Default)
    try {
        $s = Get-Settings
        $p = $s.PSObject.Properties[$Name]
        if ($p -and $null -ne $p.Value) { return $p.Value }
    } catch { }
    return $Default
}

function Set-PetSettingValue {
    param([string]$Name, $Value)
    try {
        $s = Get-Settings
        $s | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
        Save-Settings -Settings $s
    } catch { }
}
# ---------------- 天气(联网识别位置) ----------------
function Get-WeatherText {
    param([int]$Code)
    if ($Code -eq 0) { return '晴' }
    if ($Code -in 1, 2) { return '多云' }
    if ($Code -eq 3) { return '阴' }
    if ($Code -in 45, 48) { return '雾' }
    if ($Code -ge 51 -and $Code -le 57) { return '毛毛雨' }
    if ($Code -ge 61 -and $Code -le 67) { return '雨' }
    if ($Code -ge 71 -and $Code -le 77) { return '雪' }
    if ($Code -ge 80 -and $Code -le 82) { return '阵雨' }
    if ($Code -ge 85 -and $Code -le 86) { return '阵雪' }
    if ($Code -ge 95) { return '雷雨' }
    return '—'
}

function Get-CaiyunSkyText {
    # 彩云天气的 skycon 枚举 → 中文
    param([string]$Skycon)
    switch ([string]$Skycon) {
        'CLEAR_DAY' { return '晴' }
        'CLEAR_NIGHT' { return '晴' }
        'PARTLY_CLOUDY_DAY' { return '多云' }
        'PARTLY_CLOUDY_NIGHT' { return '多云' }
        'CLOUDY' { return '阴' }
        'LIGHT_HAZE' { return '轻度霾' }
        'MODERATE_HAZE' { return '中度霾' }
        'HEAVY_HAZE' { return '重度霾' }
        'LIGHT_RAIN' { return '小雨' }
        'MODERATE_RAIN' { return '中雨' }
        'HEAVY_RAIN' { return '大雨' }
        'STORM_RAIN' { return '暴雨' }
        'FOG' { return '雾' }
        'LIGHT_SNOW' { return '小雪' }
        'MODERATE_SNOW' { return '中雪' }
        'HEAVY_SNOW' { return '大雪' }
        'STORM_SNOW' { return '暴雪' }
        'DUST' { return '浮尘' }
        'SAND' { return '扬沙' }
        'WIND' { return '大风' }
        default { return '—' }
    }
}

function Get-DressingAdvice {
    # 穿衣提醒:按体感温度分档,再按天气加一句提醒
    param([double]$Temp, [string]$Text = '', [double]$WindSpeed = 0)

    $t = [int][Math]::Round($Temp)
    $adv = ''
    if ($t -ge 30) { $adv = '短袖短裤就行' }
    elseif ($t -ge 26) { $adv = '短袖 T 恤' }
    elseif ($t -ge 22) { $adv = '薄长袖,或短袖加件薄外套' }
    elseif ($t -ge 18) { $adv = '长袖衬衫 / 薄卫衣' }
    elseif ($t -ge 14) { $adv = '卫衣 / 夹克' }
    elseif ($t -ge 10) { $adv = '外套加长裤' }
    elseif ($t -ge 5) { $adv = '厚外套 / 毛衣' }
    elseif ($t -ge 0) { $adv = '棉服 / 羽绒服' }
    else { $adv = '羽绒服,帽子围巾戴上' }

    $extra = @()
    if ($Text -match '雨') { $extra += '带伞' }
    if ($Text -match '雪') { $extra += '带伞,路滑' }
    if ($Text -match '霾|浮尘|扬沙') { $extra += '戴口罩' }
    if ($WindSpeed -ge 5.5) { $extra += '风大' }
    if ($t -ge 30) { $extra += '多喝水' }

    if ($extra.Count -gt 0) { return ($adv + ',' + ($extra -join ',')) }
    return $adv
}

function Get-CnPlaceCandidates {
    # 「吉林省长春市南关区」这种整串,地理编码基本都不认;拆成几级逐个试
    param([string]$Text)
    $t = ([string]$Text).Trim()
    $list = @()
    if (-not $t) { return $list }
    $list += $t
    if ($t -match '([^省]+省)?(.+)$') { }
    # 去掉末尾的 省/市/区/县
    $a = $t -replace '(特别行政区|自治区|省|市|区|县)$', ''
    if ($a -and $a -ne $t) { $list += $a }
    # 「省」后面的部分(市 + 区县)
    if ($t -match '省(.+)$') {
        $b = $Matches[1]
        if ($b) { $list += $b }
        $b2 = $b -replace '(市|区|县)$', ''
        if ($b2 -and $b2 -ne $b) { $list += $b2 }
    }
    # 「市」后面的部分(区县)
    if ($t -match '市(.+)$') {
        $c = $Matches[1]
        if ($c) { $list += $c }
    }
    return @($list | Where-Object { $_ } | Select-Object -Unique)
}

function Get-CnPlaceParts {
    # 从 Nominatim 的 address 字段 / display_name 里按后缀归类成 省 / 市 / 区县
    # (display_name 的层级顺序不固定,不能直接按顺序取)
    param([string[]]$Texts)
    $prov = ''; $city = ''; $dist = ''
    foreach ($t in $Texts) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        foreach ($seg in ([string]$t -split ',')) {
            $s = $seg.Trim()
            if (-not $s) { continue }
            if ($s -match '^(中国|China|中华人民共和国|People.s Republic of China)$') { continue }
            if ($s -match '^\d+$') { continue }
            if ((-not $prov) -and $s -match '(省|自治区|特别行政区)$') { $prov = $s; continue }
            if ((-not $city) -and $s -match '(市|自治州|地区|盟)$') { $city = $s; continue }
            if ((-not $dist) -and $s -match '(区|县|旗)$') { $dist = $s; continue }
        }
    }
    return [pscustomobject]@{ Province = $prov; City = $city; District = $dist }
}

function Add-CnAdminSuffix {
    param([string]$Name, [string]$Kind)
    $n = ([string]$Name).Trim()
    if (-not $n) { return '' }
    if ($Kind -eq 'province') {
        if ($n -match '(省|自治区|特别行政区)$') { return $n }
        if (@('北京', '上海', '天津', '重庆') -contains $n) { return $n }
        return ($n + '省')
    }
    if ($Kind -eq 'city') {
        if ($n -match '(市|州|盟|地区|自治州|自治县)$') { return $n }
        return ($n + '市')
    }
    return $n
}

function Get-WeatherPlace {
    # 省 / 市 / 区县 —— 既用来显示,也给天气接口经纬度
    # 顺序:Nominatim(能到区县)→ Open-Meteo(只到市)→ IP 定位(只到市)
    param([string]$WantCity = '')

    $r = [pscustomobject]@{ Label = ''; Province = ''; City = ''; District = ''; Lat = $null; Lon = $null; Ok = $false }

    if ($WantCity) {
        # 1) Nominatim:地址层级全,能拿到区县
        foreach ($cand in (Get-CnPlaceCandidates $WantCity)) {
            if ($r.Ok) { break }
            try {
                $u = 'https://nominatim.openstreetmap.org/search?q={0}&format=json&addressdetails=1&limit=1&accept-language=zh-CN' -f [uri]::EscapeDataString($cand)
                $nr = Invoke-RestMethod -Uri $u -TimeoutSec 12 -UseBasicParsing -Headers @{ 'User-Agent' = ('campus-net/' + $script:AppVersion + ' (personal use)') }
                if ($nr -and @($nr).Count -gt 0) {
                    $one = @($nr)[0]
                    $r.Lat = [double]$one.lat
                    $r.Lon = [double]$one.lon
                    $ad = $one.address
                    $segs = @()
                    if ($ad) {
                        foreach ($fld in @($ad.state, $ad.city, $ad.town, $ad.municipality, $ad.district, $ad.county, $ad.city_district, $ad.suburb, $ad.village)) {
                            if ($fld) { $segs += [string]$fld }
                        }
                    }
                    $segs += [string]$one.display_name
                    $pp = Get-CnPlaceParts -Texts $segs
                    $r.Province = Add-CnAdminSuffix ([string]$pp.Province) 'province'
                    $r.City = [string]$pp.City
                    $r.District = [string]$pp.District
                    $lbl = @()
                    foreach ($x in @($r.Province, $r.City, $r.District)) {
                        $x = ([string]$x).Trim()
                        if ($x -and ($lbl -notcontains $x)) { $lbl += $x }
                    }
                    if ($lbl.Count -gt 0) { $r.Label = ($lbl -join ' ') }
                    $r.Ok = $true
                }
            } catch {
                Write-Log ('Nominatim 定位失败(' + $cand + '):' + $_.Exception.Message) 'WARN'
            }
        }

        # 2) Open-Meteo 兜底(没有区县)
        if (-not $r.Ok) {
            foreach ($cand in (Get-CnPlaceCandidates $WantCity)) {
                if ($r.Ok) { break }
                try {
                    $u = 'https://geocoding-api.open-meteo.com/v1/search?name={0}&count=1&language=zh&format=json' -f [uri]::EscapeDataString($cand)
                    $g = Invoke-RestMethod -Uri $u -TimeoutSec 12 -UseBasicParsing
                    if ($g.results -and @($g.results).Count -gt 0) {
                        $one = @($g.results)[0]
                        $r.Lat = [double]$one.latitude
                        $r.Lon = [double]$one.longitude
                        $r.Province = Add-CnAdminSuffix ([string]$one.admin1) 'province'
                        $r.City = Add-CnAdminSuffix ([string]$one.admin2) 'city'
                        if (-not $one.admin2) { $r.City = [string]$one.name }
                        $r.District = [string]$one.admin3
                        $r.Ok = $true
                    }
                } catch {
                    Write-Log ('天气地理编码失败(' + $cand + '):' + $_.Exception.Message) 'WARN'
                }
            }
        }
    }

    if (-not $r.Ok) {
        # 3) IP 定位只能到市,没有区县
        try {
            $loc = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,country,regionName,city,lat,lon' -TimeoutSec 12 -UseBasicParsing
            if ($loc.status -eq 'success') {
                $r.Lat = [double]$loc.lat
                $r.Lon = [double]$loc.lon
                $r.Province = [string]$loc.regionName
                $r.City = [string]$loc.city
                $r.Ok = $true
            }
        } catch {
            Write-Log ('IP 定位失败:' + $_.Exception.Message) 'WARN'
        }
    }

    # 没有现成标签就按 省/市/区 拼(同名只留一个)
    if (-not $r.Label) {
        $parts = @()
        foreach ($p in @($r.Province, $r.City, $r.District)) {
            $p = ([string]$p).Trim()
            if (-not $p) { continue }
            $dup = $false
            foreach ($q in $parts) {
                if ($q -eq $p -or $q -like ('*' + $p + '*') -or $p -like ('*' + $q + '*')) { $dup = $true; break }
            }
            if (-not $dup) { $parts += $p }
        }
        $r.Label = ($parts -join ' ')
    }
    return $r
}

function Get-CaiyunWeather {
    # 彩云天气 v2.6:一次 weather.json 拿实时 + 穿衣指数 + 预警
    param([string]$Token, [double]$Lat, [double]$Lon)

    $r = [pscustomobject]@{ Ok = $false; Temp = $null; Text = ''; Feels = $null; Wind = 0; Dressing = ''; Alert = '' }
    if ([string]::IsNullOrWhiteSpace($Token) -or $null -eq $Lat) { return $r }

    $coord = ('{0},{1}' -f [Math]::Round($Lat, 4), [Math]::Round($Lon, 4))
    $u = '{0}/v2.6/{1}/{2}/weather.json?alert=true&dailysteps=1' -f $script:CaiyunApiBase, $Token, $coord
    try { $w = Invoke-RestMethod -Uri $u -TimeoutSec 15 -UseBasicParsing } catch { return $r }
    if ([string]$w.status -ne 'ok') { return $r }

    $rt = $w.result.realtime
    if (-not $rt) { return $r }

    $r.Temp = [double]$rt.temperature
    $r.Text = Get-CaiyunSkyText -Skycon ([string]$rt.skycon)
    if ($null -ne $rt.apparent_temperature) { $r.Feels = [double]$rt.apparent_temperature }
    if ($rt.wind -and $null -ne $rt.wind.speed) { $r.Wind = [double]$rt.wind.speed }

    # 彩云自带的穿衣指数(desc 是"较冷 / 舒适"这种等级),拿来做补充
    try {
        $d = $w.result.daily.life_index.dressing
        if ($d) {
            if (@($d).Count -gt 0) { $r.Dressing = [string](@($d)[0].desc) }
            else { $r.Dressing = [string]$d.desc }
        }
    } catch { }

    try {
        $al = $w.result.alert.content
        if ($al -and @($al).Count -gt 0) {
            $first = @($al)[0]
            if ($first -and $first.title) { $r.Alert = [string]$first.title }
        }
    } catch { }

    $r.Ok = $true
    return $r
}

function Update-PetWeather {
    # 位置:设置里填的城市(能拿到省/市/区)→ 没填就 IP 定位(只有市)
    # 天气:彩云天气(要 token)→ 失败或没 token 用 Open-Meteo 兜底
    $out = [ordered]@{
        ts = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); ok = $false
        city = ''; place = ''; province = ''; district = ''
        temp = $null; feels = $null; code = -1; text = ''
        dressing = ''; wind = 0; alert = ''; source = ''
    }

    $wantCity = ''
    $token = ''
    try {
        $st = Get-Settings
        $wantCity = [string]$st.petWeatherCity
        $token = [string]$st.caiyunToken
    } catch { }
    $wantCity = $wantCity.Trim()
    $token = $token.Trim()

    $p = Get-WeatherPlace -WantCity $wantCity
    $out.city = [string]$p.City
    $out.place = [string]$p.Label
    $out.province = [string]$p.Province
    $out.district = [string]$p.District

    # 1) 彩云天气
    if ($token -and $p.Ok) {
        $cy = Get-CaiyunWeather -Token $token -Lat $p.Lat -Lon $p.Lon
        if ($cy.Ok) {
            $out.temp = [int][Math]::Round([double]$cy.Temp)
            $out.feels = $(if ($null -ne $cy.Feels) { [int][Math]::Round([double]$cy.Feels) } else { $out.temp })
            $out.text = [string]$cy.Text
            $out.wind = [double]$cy.Wind
            $out.alert = [string]$cy.Alert
            $base = Get-DressingAdvice -Temp $out.feels -Text $out.text -WindSpeed $out.wind
            $out.dressing = $(if ($cy.Dressing) { $base + '(' + $cy.Dressing + ')' } else { $base })
            $out.source = '彩云天气'
            $out.ok = $true
        } else {
            Write-Log '彩云天气取数失败(检查 token / 城市),回退 Open-Meteo' 'WARN'
        }
    }

    # 2) Open-Meteo 兜底
    if (-not $out.ok -and $p.Ok) {
        try {
            $u = 'https://api.open-meteo.com/v1/forecast?latitude={0}&longitude={1}&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m' -f $p.Lat, $p.Lon
            $w = Invoke-RestMethod -Uri $u -TimeoutSec 12 -UseBasicParsing
            $out.temp = [int][math]::Round([double]$w.current.temperature_2m)
            $out.code = [int]$w.current.weather_code
            $out.text = Get-WeatherText -Code $out.code
            if ($null -ne $w.current.apparent_temperature) { $out.feels = [int][Math]::Round([double]$w.current.apparent_temperature) }
            if ($null -ne $w.current.wind_speed_10m) { $out.wind = [double]$w.current.wind_speed_10m / 3.6 }
            if ($null -eq $out.feels) { $out.feels = $out.temp }
            $out.dressing = Get-DressingAdvice -Temp $out.feels -Text $out.text -WindSpeed $out.wind
            $out.source = 'Open-Meteo'
            $out.ok = $true
        } catch {
            Write-Log ('Open-Meteo 取数失败:' + $_.Exception.Message) 'WARN'
        }
    }

    try { ($out | ConvertTo-Json -Compress) | Set-Content -Path $script:PetWeatherFile -Encoding UTF8 } catch { }
    return $out
}

function Get-PetWeather {
    # 30 分钟内复用缓存
    if ($script:PetWeather -and ((Get-Date) - $script:PetWeatherAt).TotalMinutes -lt 30) { return $script:PetWeather }
    if (-not (Test-Path $script:PetWeatherFile)) { return $null }
    try {
        $w = Get-Content $script:PetWeatherFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:PetWeather = $w
        $script:PetWeatherAt = Get-Date
        if ($w.ts) {
            try {
                $age = ((Get-Date) - [datetime]::ParseExact($w.ts, 'yyyy-MM-dd HH:mm:ss', $null)).TotalMinutes
                if ($age -gt 30) { $script:PetWeatherAt = (Get-Date).AddMinutes(-31) }
            } catch { }
        }
        return $w
    } catch { return $null }
}

function Format-PetWeather {
    $w = Get-PetWeather
    if (-not $w -or -not $w.ok) { return '' }
    $line = [string]$w.text + ' ' + [string]$w.temp + '°C'
    if ($w.place) { $line += ' · ' + [string]$w.place }
    elseif ($w.city) { $line += ' · ' + [string]$w.city }
    if ($w.dressing) { $line += ' · ' + [string]$w.dressing }
    return $line
}
# ---------------- 媒体(GSMTC) ----------------
function Initialize-WinRtAsync {
    if ($script:PetMediaActions) { return $true }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $methods = [System.WindowsRuntimeSystemExtensions].GetMethods()
        $script:PetMediaActions = @($methods | Where-Object {
                $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            })[0]
        return [bool]$script:PetMediaActions
    } catch { return $false }
}

function Await-WinRt {
    param($Op, [Type]$ResultType, [int]$TimeoutMs = 1500)
    if (-not (Initialize-WinRtAsync)) { return $null }
    try {
        $m = $script:PetMediaActions.MakeGenericMethod($ResultType)
        $task = $m.Invoke($null, @($Op))
        if (-not $task.Wait($TimeoutMs)) { return $null }
        return $task.Result
    } catch { return $null }
}

function Get-PetMedia {
    # 返回 @{ Ok; Title; Artist; Playing; App } ;没有播放器时 Ok=$false
    if (((Get-Date) - $script:PetMediaAt).TotalSeconds -lt 1) { return $script:PetMedia }
    $script:PetMediaAt = Get-Date

    $res = [pscustomobject]@{ Ok = $false; Title = ''; Artist = ''; Playing = $false; App = '' }
    try {
        $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
        $op = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()
        $mgr = Await-WinRt -Op $op -ResultType ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        if ($mgr) {
            $sess = $mgr.GetCurrentSession()
            if ($sess) {
                $props = Await-WinRt -Op $sess.TryGetMediaPropertiesAsync() -ResultType ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                if ($props) {
                    $res.Ok = $true
                    $res.Title = [string]$props.Title
                    $res.Artist = [string]$props.Artist
                    $res.App = [string]$props.SourceAppUserModelId
                    $info = $sess.GetPlaybackInfo()
                    $res.Playing = ([int]$info.PlaybackStatus -eq 4)   # Playing
                }
            }
        }
    } catch { }
    $script:PetMedia = $res
    return $res
}

function Send-PetMediaCommand {
    param([ValidateSet('playpause', 'next', 'prev')][string]$Action)
    try {
        $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
        $op = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()
        $mgr = Await-WinRt -Op $op -ResultType ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        if (-not $mgr) { return $false }
        $sess = $mgr.GetCurrentSession()
        if (-not $sess) { return $false }
        switch ($Action) {
            'playpause' { $null = $sess.TryTogglePlayPauseAsync() }
            'next' { $null = $sess.TrySkipNextAsync() }
            'prev' { $null = $sess.TrySkipPreviousAsync() }
        }
        $script:PetMediaAt = [datetime]::MinValue
        return $true
    } catch { return $false }
}

function Format-PetMediaLine {
    $m = Get-PetMedia
    if (-not $m -or -not $m.Ok) { return '' }
    $t = $m.Title
    if ($m.Artist) { $t = $t + ' - ' + $m.Artist }
    return $t
}
# ---------------- 悬停面板 / 表情包 ----------------
function Get-PetMemeImage {
    param([string]$Id)
    if ($script:PetMemeCache.ContainsKey($Id)) { return $script:PetMemeCache[$Id] }
    $f = Join-Path (Join-Path $script:PetDir 'memes') ($Id + '.png')
    if (-not (Test-Path $f)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($f)
        $ms = New-Object System.IO.MemoryStream -ArgumentList (,$bytes)
        $img = [System.Drawing.Image]::FromStream($ms)
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList $img
        $img.Dispose(); $ms.Dispose()
        $script:PetMemeCache[$Id] = $bmp
        return $bmp
    } catch { return $null }
}

function Show-PetMeme {
    param([string]$Id)
    $bmp = Get-PetMemeImage -Id $Id
    if (-not $bmp) { return }
    $script:PetMemeUntil = (Get-Date).AddSeconds(8)
    Set-PetOverlayContent -Kind 'meme' -Meme $bmp
}

function New-PetOverlayWindow {
    if ($script:PetOverlay -and -not $script:PetOverlay.IsDisposed) { return }
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.Text = '桌宠信息'
    $f.ClientSize = New-Object System.Drawing.Size -ArgumentList 10, 10
    # 用普通窗口自绘 + 整体不透明度,而不是 UpdateLayeredWindow:
    # 半透明面板用 ULW 在跨窗口场景下容易失败(实测返回 0),普通绘制更稳。
    $f.AllowTransparency = $true
    $f.Opacity = 0.94
    $f.BackColor = [System.Drawing.Color]::FromArgb(18, 20, 30)
    $f.add_Paint({
            param($sender, $e)
            $c = $script:PetOverlayContent
            if (-not $c) { return }
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            if ($c.Kind -eq 'meme' -and $c.Meme) {
                $g.DrawImage($c.Meme, 0, 0, $sender.ClientSize.Width, $sender.ClientSize.Height)
                return
            }
            $fs = $(if ($script:PetOverlayFontSize) { $script:PetOverlayFontSize } else { 9.5 })
            $lh = $(if ($script:PetOverlayLineH) { $script:PetOverlayLineH } else { 22 })
            $pd = $(if ($script:PetOverlayPad) { $script:PetOverlayPad } else { 10 })
            # 换行/截断在 Set-PetOverlayContent 里已经算好,这里照着逐行画就行
            $font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', $fs
            $y = $pd
            foreach ($ln in $c.Lines) {
                $g.DrawString([string]$ln, $font, [System.Drawing.Brushes]::White, $pd, $y)
                $y += $lh
            }
            foreach ($b in $c.Buttons) {
                $br = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(70, 90, 140, 230))
                $g.FillRectangle($br, $b.X, $b.Y, $b.W, $b.H)
                $br.Dispose()
                $cx = $b.X + $b.W / 2
                $cy = $b.Y + $b.H / 2
                $wb = [System.Drawing.Brushes]::White
                switch ($b.Glyph) {
                    'play' {
                        $pts = @(
                            (New-Object System.Drawing.PointF -ArgumentList ($cx - 5), ($cy - 7)),
                            (New-Object System.Drawing.PointF -ArgumentList ($cx + 7), $cy),
                            (New-Object System.Drawing.PointF -ArgumentList ($cx - 5), ($cy + 7))
                        )
                        $g.FillPolygon($wb, $pts)
                    }
                    'pause' {
                        $g.FillRectangle($wb, [int]($cx - 6), [int]($cy - 7), 4, 14)
                        $g.FillRectangle($wb, [int]($cx + 2), [int]($cy - 7), 4, 14)
                    }
                    'next' {
                        $g.FillRectangle($wb, [int]($cx + 5), [int]($cy - 7), 3, 14)
                        $pts = @(
                            (New-Object System.Drawing.PointF -ArgumentList ($cx - 6), ($cy - 7)),
                            (New-Object System.Drawing.PointF -ArgumentList ($cx - 6), ($cy + 7)),
                            (New-Object System.Drawing.PointF -ArgumentList ($cx + 4), $cy)
                        )
                        $g.FillPolygon($wb, $pts)
                    }
                    default {
                        $g.FillRectangle($wb, [int]($cx - 8), [int]($cy - 7), 3, 14)
                        $pts = @(
                            (New-Object System.Drawing.PointF -ArgumentList ($cx + 7), ($cy - 7)),
                            (New-Object System.Drawing.PointF -ArgumentList ($cx + 7), ($cy + 7)),
                            (New-Object System.Drawing.PointF -ArgumentList ($cx - 4), $cy)
                        )
                        $g.FillPolygon($wb, $pts)
                    }
                }
            }
            $font.Dispose()
        })
    $f.add_MouseEnter({ $script:PetOverlayHover = $true; $script:PetHoverOffAt = [datetime]::MinValue })
    $f.add_MouseLeave({ $script:PetOverlayHover = $false; $script:PetHoverOffAt = (Get-Date) })
    $f.add_MouseClick({
            param($s, $e)
            $c = $script:PetOverlayContent
            if (-not $c) { return }
            foreach ($b in $c.Buttons) {
                if ($e.X -ge $b.X -and $e.X -le ($b.X + $b.W) -and $e.Y -ge $b.Y -and $e.Y -le ($b.Y + $b.H)) {
                    if ($b.Action -eq 'meme') { Hide-PetOverlay }
                    else { [void](Send-PetMediaCommand -Action $b.Action) }
                    return
                }
            }
            if ($c.Kind -eq 'meme') { Hide-PetOverlay }
        })
    $script:PetOverlay = $f
    $f.Show()
    [DeskPet.Layered]::Enable($f.Handle)
    $f.Visible = $false
}

function Get-WrappedText {
    # 按像素宽度把一行拆成多行(中文逐字拆,够用且简单)
    param([string]$Text, $Font, [int]$MaxWidth, $Graphics)
    $out = @()
    if ([string]::IsNullOrEmpty($Text)) { return $out }
    if ($MaxWidth -le 20 -or -not $Graphics) { return @($Text) }
    $cur = ''
    foreach ($ch in $Text.ToCharArray()) {
        $try = $cur + $ch
        if ($cur -and ($Graphics.MeasureString($try, $Font)).Width -gt $MaxWidth) {
            # 别把英文/数字词从中间劈开:能退到最近的空格就退
            if ($ch -match '[0-9A-Za-z]') {
                $sp = $cur.LastIndexOf(' ')
                if ($sp -gt 0) {
                    $out += $cur.Substring(0, $sp)
                    $cur = $cur.Substring($sp + 1) + $ch
                    continue
                }
            }
            $out += $cur
            $cur = [string]$ch
        } else {
            $cur = $try
        }
    }
    if ($cur) { $out += $cur }
    return $out
}

function Set-PetOverlayContent {
    # Kind: info(网速+天气+音乐) / meme(表情包) / say(碎碎念气泡)
    # 尺寸:settings 里 petOverlayW / petOverlayH 给了就固定(文本自动换行 + 超长截断),给 0 就按内容自适应
    param([string]$Kind, $Meme = $null, [string]$Text = '')

    if (-not $script:PetOverlay) { return }
    if ($script:PetOverlayKind -eq 'meme' -and $Kind -eq 'meme') { return }

    $rawLines = New-Object System.Collections.ArrayList
    $buttons = @()
    $w = 250
    $h = 0
    $cfg = Get-PetCfg
    $fontSize = [double]$cfg.OverlayFont
    $pad = [int][Math]::Round($fontSize * 1.15)
    $lineH = [int][Math]::Ceiling($fontSize * 2.3)
    $fixedW = [int]$cfg.OverlayW
    $fixedH = [int]$cfg.OverlayH

    if ($Kind -eq 'meme' -and $Meme) {
        $w = [Math]::Min(300, $Meme.Width)
        $h = [int]([Math]::Round($Meme.Height * $w / $Meme.Width))
        $buttons = @(@{ X = 0; Y = 0; W = $w; H = $h; Action = 'meme'; Glyph = '' })
        $script:PetOverlay.Opacity = 1.0
    } else {
        $media = $null
        if ($Kind -eq 'say') {
            [void]$rawLines.Add($Text)
        } else {
            $sp = Get-NetSpeed
            if (-not $sp) { $sp = [pscustomobject]@{ DownText = '—'; UpText = '—' } }
            [void]$rawLines.Add('↓ ' + $sp.DownText + '   ↑ ' + $sp.UpText)
            $wx = Format-PetWeather
            if ($wx) { [void]$rawLines.Add('☁ ' + $wx) }
            $media = Get-PetMedia
            if ($media -and $media.Ok) { [void]$rawLines.Add('♪ ' + (Format-PetMediaLine)) }
        }

        # 量一遍:固定宽度就换行,固定高度就截断
        $measureFont = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', $fontSize
        $mb = New-Object System.Drawing.Bitmap -ArgumentList 1, 1
        $mg = [System.Drawing.Graphics]::FromImage($mb)

        $lines = New-Object System.Collections.ArrayList
        $textW = 0
        if ($fixedW -gt 0) {
            $maxText = $fixedW - $pad * 2 - 4
            foreach ($ln in $rawLines) {
                foreach ($seg in (Get-WrappedText -Text ([string]$ln) -Font $measureFont -MaxWidth $maxText -Graphics $mg)) {
                    [void]$lines.Add($seg)
                    $sw = ($mg.MeasureString($seg, $measureFont)).Width
                    if ($sw -gt $textW) { $textW = $sw }
                }
            }
        } else {
            foreach ($ln in $rawLines) {
                [void]$lines.Add([string]$ln)
                $sw = ($mg.MeasureString([string]$ln, $measureFont)).Width
                if ($sw -gt $textW) { $textW = $sw }
            }
        }
        $mg.Dispose(); $mb.Dispose(); $measureFont.Dispose()

        # 媒体按钮占的高度
        $btnH = 0
        if ($media -and $media.Ok -and $Kind -ne 'say') { $btnH = 36 }

        if ($fixedH -gt 0) {
            # 高度固定:能放几行放几行,放不下的截断并加省略号
            $avail = $fixedH - $pad * 2 - $btnH
            $maxLines = [Math]::Max(1, [int][Math]::Floor($avail / $lineH))
            if ($lines.Count -gt $maxLines) {
                $keep = @()
                for ($i = 0; $i -lt $maxLines; $i++) { $keep += [string]$lines[$i] }
                $last = $keep[$maxLines - 1]
                if ($last.Length -gt 1) { $keep[$maxLines - 1] = $last.Substring(0, $last.Length - 1) + '…' }
                $lines = New-Object System.Collections.ArrayList
                foreach ($k in $keep) { [void]$lines.Add($k) }
            }
        }

        if ($fixedW -gt 0) {
            $w = $fixedW
        } else {
            $w = [int][Math]::Ceiling($textW) + $pad * 2 + 6
            if ($media -and $media.Ok -and $Kind -ne 'say') {
                $need = $pad * 2 + 54 * 3 + 10 * 2
                if ($w -lt $need) { $w = $need }
            }
            $minW = $(if ($Kind -eq 'say') { 90 } else { 150 })
            if ($w -lt $minW) { $w = $minW }
        }

        if ($fixedH -gt 0) {
            $h = $fixedH
        } else {
            $h = $pad * 2 + $lines.Count * $lineH + $btnH
            if ($Kind -eq 'say') { $h = $pad * 2 + $lineH }
        }

        $script:PetOverlayFontSize = $fontSize
        $script:PetOverlayLineH = $lineH
        $script:PetOverlayPad = $pad
        $script:PetOverlayText = $Text

        if ($Kind -eq 'say') {
            $buttons = @(@{ X = 0; Y = 0; W = $w; H = $h; Action = 'meme'; Glyph = '' })
        } elseif ($media -and $media.Ok) {
            $bw = 54; $bh = 26; $gap = 10; $bx = [int]$pad
            $by = $h - $pad - $bh
            if ($by -lt 0) { $by = 0 }
            foreach ($it in @(
                    @{ Action = 'prev'; Glyph = 'prev' },
                    @{ Action = 'playpause'; Glyph = $(if ($media.Playing) { 'pause' } else { 'play' }) },
                    @{ Action = 'next'; Glyph = 'next' }
                )) {
                $buttons += @{ X = $bx; Y = $by; W = $bw; H = $bh; Action = $it.Action; Glyph = $it.Glyph }
                $bx += $bw + $gap
            }
        }
        $script:PetOverlay.Opacity = [double]$cfg.OverlayOpacity
        $rawLines = $lines
    }

    $script:PetOverlayContent = [pscustomobject]@{
        Kind    = $Kind
        Lines   = @($rawLines)
        Buttons = $buttons
        Meme    = $Meme
        Text    = $Text
    }
    $script:PetOverlayKind = $Kind
    $script:PetOverlay.ClientSize = New-Object System.Drawing.Size -ArgumentList $w, $h
    # 圆角:用 Region 裁窗口(直角会被切掉),信息框和碎碎念都适用
    if ($Kind -ne 'meme') {
        try {
            $r = 12
            $rp = New-Object System.Drawing.Drawing2D.GraphicsPath
            $rp.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
            $rp.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
            $rp.AddArc($w - $r * 2, $h - $r * 2, $r * 2, $r * 2, 0, 90)
            $rp.AddArc(0, $h - $r * 2, $r * 2, $r * 2, 90, 90)
            $rp.CloseFigure()
            $script:PetOverlay.Region = New-Object System.Drawing.Region -ArgumentList $rp
            $rp.Dispose()
        } catch { }
    } else {
        $script:PetOverlay.Region = $null
    }
    $script:PetOverlay.Visible = $true
    $script:PetOverlay.Invalidate()
    Update-PetOverlayPosition
}

function Update-PetOverlayPosition {
    if (-not $script:PetOverlay -or -not $script:PetOverlay.Visible) { return }
    $w = $script:PetOverlay.ClientSize.Width
    $h = $script:PetOverlay.ClientSize.Height
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:ScreenW = $wa.Right; $script:ScreenH = $wa.Bottom
    $x = $script:PetX + 10
    $y = $script:PetY - $h - 6
    if ($y -lt $wa.Top) { $y = $script:PetY + 210 + 6 }
    if ($x + $w -gt $wa.Right) { $x = $wa.Right - $w - 4 }
    if ($x -lt $wa.Left) { $x = $wa.Left + 4 }
    $script:PetOverlay.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
}

function Hide-PetOverlay {
    if ($script:PetOverlay -and -not $script:PetOverlay.IsDisposed) { $script:PetOverlay.Visible = $false }
    $script:PetOverlayKind = ''
    $script:PetOverlayContent = $null
}
# ---------------- 动作 / 走动 ----------------
function Get-PetAnimMeta {
    param([string]$Id)
    foreach ($a in (Get-PetAnimList)) { if ([string]$a.id -eq $Id) { return $a } }
    return $null
}

function Get-PetActionMs {
    # 原项目每段动作都是 10 秒(assets/preview 里的 GIF 全是 120 帧 × 83ms = 10.00 秒),
    # 而我们抠帧时只截了其中 1.4 秒一段 —— 所以要按 pet.json 里的 ms 循环播放撑满,
    # 而不是播一遍就回待机。想改时长就改 pet.json 的 ms。
    param([string]$Id)
    $m = Get-PetAnimMeta -Id $Id
    if ($m -and $m.PSObject.Properties['ms'] -and [int]$m.ms -gt 0) { return [int]$m.ms }
    return 0
}

function Get-PetCurrentAnim {
    if ($script:PetAction -and (Get-Date) -lt $script:PetActionEnd) { return $script:PetAction }
    if ($script:PetAction) {
        try {
            $spent = ((Get-Date) - $script:PetActionStart).TotalSeconds
            Write-Log ('宠物动作结束:' + (Get-PetLabel $script:PetAction) + ' 实际 ' + [Math]::Round($spent, 1) + ' 秒')
        } catch { }
        $script:PetAction = ''
        $script:PetActionStart = [datetime]::MinValue
    }
    if ($script:PetTarget) { return 'walk' }
    if (Test-PetShouldSleep) { return 'sleep' }
    return 'idle'
}

function Play-PetAction {
    param([string]$Id, [int]$HoldSec = 0)
    $dir = Join-Path $script:PetDir $Id
    if (-not (Test-Path $dir)) { return }
    $entry = Get-PetFrames -Anim $Id -Scale (Get-PetCfg).Scale
    if (-not $entry) { if ($fadeSrc) { try { $fadeSrc.Dispose() } catch { } }; return }
    $fps = $entry.Fps
    $meta = Get-PetAnimMeta -Id $Id
    $ms = Get-PetActionMs -Id $Id
    $dur = 0.0
    if ($HoldSec -gt 0) { $dur = [double]$HoldSec }
    elseif ($ms -gt 0) { $dur = $ms / 1000.0 }
    else { $dur = ($entry.Count / $fps) }
    # 素材只有一段,来回播(0→末→0)接缝最自然;pet.json 里写 "pingpong": false 可以关掉
    # 整段素材(没有 ms)就直着播一遍;只有老素材(短片段 + ms)才循环
    $pingpong = ($ms -gt 0)
    if ($meta -and $meta.PSObject.Properties['pingpong']) { $pingpong = [bool]$meta.pingpong }
    $script:PetAction = $Id
    $script:PetActionStart = Get-Date
    $script:PetActionPingPong = $pingpong
    $script:PetActionDurSec = $dur
    $script:PetActionEnd = (Get-Date).AddSeconds($dur + 0.15)
    $script:PetAnim = $Id
    $script:PetLastIdx = -1
    if ($script:PetSw) { $script:PetSw.Restart() }
    $script:PetStillSince = (Get-Date).AddSeconds($dur)
    Write-Log ('宠物动作:' + (Get-PetLabel $Id) + ' ' + [Math]::Round($dur, 1) + ' 秒' + $(if ($pingpong) { '(往返循环)' } elseif ($ms -gt 0) { '(循环)' } else { '(整段 ' + [Math]::Round($dur, 1) + ' 秒)' }))
}

function Start-PetWander {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:ScreenW = $wa.Right; $script:ScreenH = $wa.Bottom
    $tx = $script:PetXf + (Get-Random -Minimum -260 -Maximum 260)
    $ty = $script:PetYf + (Get-Random -Minimum -140 -Maximum 140)
    $tx = [Math]::Max($wa.Left + 10, [Math]::Min($wa.Right - 190, $tx))
    $ty = [Math]::Max($wa.Top + 10, [Math]::Min($wa.Bottom - 210, $ty))
    $script:PetTarget = @{ X = [double]$tx; Y = [double]$ty }
}

function Step-PetWander {
    if (-not $script:PetTarget) { return }
    $dx = $script:PetTarget.X - $script:PetXf
    $dy = $script:PetTarget.Y - $script:PetYf
    $d = [Math]::Sqrt($dx * $dx + $dy * $dy)
    if ($d -le 2) {
        $script:PetXf = $script:PetTarget.X
        $script:PetYf = $script:PetTarget.Y
        $script:PetTarget = $null
        $script:PetStillSince = Get-Date
        try { [void](Invoke-IconEventNearPet -Source 'wander' -Chance 25) } catch { }
        return
    }
    # 浮点累加,每秒约 96px;取整只在绘制时做,不会有整数截断造成的抖动
    $step = 1.6
    $script:PetXf = $script:PetXf + $dx / $d * $step
    $script:PetYf = $script:PetYf + $dy / $d * $step
}

# ---------------- 物理(拖拽抛掷) ----------------
function Start-PetPhysics {
    param([double]$Vx, [double]$Vy)
    $cfg = Get-PetCfg
    $script:PetVx = $Vx * $cfg.ThrowPower
    $script:PetVy = $Vy * $cfg.ThrowPower
    # 限制一下,免得一甩就飞出屏幕外找不回来
    if ([Math]::Abs($script:PetVx) -gt 4000) { $script:PetVx = 4000 * [Math]::Sign($script:PetVx) }
    if ([Math]::Abs($script:PetVy) -gt 4000) { $script:PetVy = 4000 * [Math]::Sign($script:PetVy) }
    $script:PetTarget = $null
    $script:PetPhys = ($script:PetVx -ne 0 -or $script:PetVy -ne 0)
    $script:PetLastPhysAt = Get-Date
    Write-Log ('宠物被甩出去: vx=' + [int]$script:PetVx + ' vy=' + [int]$script:PetVy)
}

function Step-PetPhysics {
    param([double]$Dt)
    if (-not $script:PetPhys) { return }
    if ($Dt -le 0) { $Dt = 0.016 }
    if ($Dt -gt 0.1) { $Dt = 0.1 }

    $cfg = Get-PetCfg
    $g = [double]$cfg.Gravity
    $e = [double]$cfg.Restitution
    $f = [double]$cfg.Friction

    $script:PetVy = $script:PetVy + $g * $Dt
    $script:PetXf = $script:PetXf + $script:PetVx * $Dt
    $script:PetYf = $script:PetYf + $script:PetVy * $Dt

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:ScreenW = $wa.Right; $script:ScreenH = $wa.Bottom
    $pw = $script:PetForm.ClientSize.Width
    $ph = $script:PetForm.ClientSize.Height
    $minX = $wa.Left
    $maxX = $wa.Right - $pw
    $minY = $wa.Top
    $maxY = $wa.Bottom - $ph

    $onGround = $false
    if ($script:PetYf -ge $maxY) {
        $script:PetYf = $maxY
        $onGround = $true
        if ([Math]::Abs($script:PetVy) -gt 60) { $script:PetVy = -$script:PetVy * $e }
        else { $script:PetVy = 0 }
        # 地面摩擦
        $script:PetVx = $script:PetVx * [Math]::Max(0, 1 - $f * $Dt)
        if ([Math]::Abs($script:PetVx) -lt 8) { $script:PetVx = 0 }
    }
    if ($cfg.CeilingBounce -and $script:PetYf -le $minY) {
        $script:PetYf = $minY
        if ([Math]::Abs($script:PetVy) -gt 60) { $script:PetVy = -$script:PetVy * $e } else { $script:PetVy = 0 }
    }
    if ($script:PetXf -le $minX) { $script:PetXf = $minX; $script:PetVx = -$script:PetVx * $e }
    if ($script:PetXf -ge $maxX) { $script:PetXf = $maxX; $script:PetVx = -$script:PetVx * $e }

    if ($onGround -and $script:PetVx -eq 0 -and $script:PetVy -eq 0) {
        $script:PetPhys = $false
        $script:PetStillSince = Get-Date
    }
}

# ---------------- 碎碎念 ----------------
function Get-PetSayings {
    if ($script:PetSayings) { return $script:PetSayings }
    $f = Join-Path $script:PetDir 'sayings.txt'
    $list = @()
    if (Test-Path $f) {
        try {
            $list = @(Get-Content $f -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } catch { }
    }
    if ($list.Count -eq 0) { $list = @('……', '在的', '嗯?') }
    $script:PetSayings = $list
    return $list
}

function Show-PetSaying {
    param([string]$Text)
    $list = Get-PetSayings
    if (-not $Text) { $Text = [string]$list[(Get-Random -Maximum $list.Count)] }

    # 气泡时长:设了固定秒数就用它,设 0 就每次随机 2~6 秒
    $dur = 0.0
    try { $dur = [double](Get-PetCfg).SayDur } catch { }
    if ($dur -le 0) { $dur = [Math]::Round((Get-Random -Minimum 2.0 -Maximum 6.0), 1) }
    $script:PetSayUntil = (Get-Date).AddSeconds($dur)
    Set-PetOverlayContent -Kind 'say' -Meme $null -Text $Text
}

# ---------------- 主循环 ----------------
function Update-Pet {
    if (-not $script:PetForm -or $script:PetForm.IsDisposed) { return }
    if (-not $script:PetSw) { return }
    $script:PetTickAll++
    $now = Get-Date
    $cfg = Get-PetCfg

    # 缩放变了:强制重画一帧(缓存 key 变了,尺寸也会跟着变)
    if ([Math]::Abs($cfg.Scale - $script:PetLastScale) -gt 0.001) {
        $script:PetLastScale = $cfg.Scale
        $script:PetLastIdx = -1
        $script:PetLastDrawX = -99999
    }

    # 物理(拖拽甩出去之后的自由运动)
    if ($script:PetPhys) {
        $dtPhys = $(if ($script:PetLastPhysAt -ne [datetime]::MinValue) { ($now - $script:PetLastPhysAt).TotalSeconds } else { 0.016 })
        $script:PetLastPhysAt = $now
        Step-PetPhysics -Dt $dtPhys
    }

    # 碎碎念气泡到点收掉
    if ($script:PetSayUntil -ne [datetime]::MinValue -and $now -gt $script:PetSayUntil) {
        $script:PetSayUntil = [datetime]::MinValue
        if ($script:PetOverlayKind -eq 'say') { Hide-PetOverlay }
    }

    # 走动
    if ($script:PetTarget) { Step-PetWander }

    $anim = Get-PetCurrentAnim
    if ($anim -ne $script:PetAnim) {
        $script:PetAnim = $anim
        $script:PetLastIdx = -1
        $script:PetSw.Restart()
    }

    # 帧率变了(菜单切换 / 手改 settings.json)就重建帧缓存;不依赖菜单回调,自己会纠正
    if ([int]$cfg.Fps -ne $script:PetFpsApplied) {
        $script:PetFpsApplied = [int]$cfg.Fps
        foreach ($k in @($script:PetCache.Keys)) {
            foreach ($hb in $script:PetCache[$k].Hbs) { [DeskPet.Layered]::FreeHBitmap($hb) }
        }
        $script:PetLastHb = [IntPtr]::Zero
$script:PetLastAnim = ''
$script:PetLastFrameIdx = 0
        $script:PetCache = @{}
        $script:PetLastIdx = -1
        # 位图刚释放,催一下 GC,免得托管包装攒着(重建两次能涨几十 MB)
        [GC]::Collect()
        Write-Log ('宠物帧率:' + $script:PetFpsApplied + 'Hz(已重建帧缓存)')
    }

    $entry = Get-PetFrames -Anim $anim -Scale $cfg.Scale
    if (-not $entry) { return }
    $fps = $entry.Fps
    $idx = [int]([Math]::Floor($script:PetSw.Elapsed.TotalSeconds * $fps))
    if ($script:PetAction) {
        # 动作要循环撑满整段时长:往返播(0→末→0),接缝处不会硬跳
        $total = [int]$entry.Count
        if ($total -le 1) {
            $idx = 0
        } elseif ($script:PetActionPingPong) {
            $cycle = ($total * 2) - 2
            $i2 = $idx % $cycle
            if ($i2 -ge $total) { $i2 = $cycle - $i2 }
            $idx = [Math]::Min($i2, $total - 1)
        } else {
            $idx = $idx % $total
        }
    } else {
        $idx = $idx % $entry.Count
    }

    $px = [int][Math]::Round($script:PetXf)
    $py = [int][Math]::Round($script:PetYf)
    $moved = ($px -ne $script:PetLastDrawX -or $py -ne $script:PetLastDrawY)

    # 位置变化也要重画:否则移动只能按动画帧率跳,看着就是"卡顿"
    if ($idx -ne $script:PetLastIdx -or $moved) {
        $script:PetLastIdx = $idx
        if ($script:PetForm.ClientSize.Width -ne $entry.W -or $script:PetForm.ClientSize.Height -ne $entry.H) {
            $script:PetForm.ClientSize = New-Object System.Drawing.Size -ArgumentList $entry.W, $entry.H
        }
        $null = [DeskPet.Layered]::Draw($script:PetForm.Handle, $entry.Hbs[$idx], $entry.W, $entry.H, $px, $py, [byte]255)
        $script:PetX = $px
        $script:PetY = $py
        $script:PetLastDrawX = $px
        $script:PetLastDrawY = $py
        $script:PetTicks++
    }

    # 面板跟着宠物走 / 内容刷新
    if ($script:PetOverlay -and $script:PetOverlay.Visible) { Update-PetOverlayPosition }

    if ($script:PetHover -and -not $script:PetAction) {
        if (($now - $script:PetOverlayRefreshAt).TotalMilliseconds -ge 500) {
            $script:PetOverlayRefreshAt = $now
            Set-PetOverlayContent -Kind 'info'
        }
    }

    # 悬停移出判定:宠物和面板都没在鼠标下才收
    if ($script:PetHoverOffAt -ne [datetime]::MinValue -and -not $script:PetHover -and -not $script:PetOverlayHover) {
        if (($now - $script:PetHoverOffAt).TotalMilliseconds -ge 350) {
            $script:PetHoverOffAt = [datetime]::MinValue
            Hide-PetOverlay
        }
    }

    # 表情包到点自动收
    if ($script:PetMemeUntil -ne [datetime]::MinValue -and $now -gt $script:PetMemeUntil) {
        $script:PetMemeUntil = [datetime]::MinValue
        Hide-PetOverlay
    }

    # 随机走动
    if (-not $script:PetTarget -and -not $script:PetAction) {
        $wanderOn = [bool]$cfg.Wander
        if ($wanderOn -and $script:PetStillSince -ne [datetime]::MinValue -and ($now - $script:PetStillSince).TotalSeconds -ge 45) {
            Start-PetWander
        }
    }

    # 随机自动碎碎念(和「随机动作间隔」分开:这个是随机时长随机触发)
    $sayEvery = [int]$cfg.SayEvery
    if ($cfg.Say -and $sayEvery -gt 0 -and -not $script:PetAction -and -not $script:PetTarget -and $now -gt $script:PetNextSay) {
        $lo = [Math]::Max(1, [int]($sayEvery * 0.5))
        $hi = [Math]::Max($lo + 1, [int]($sayEvery * 1.5))
        $script:PetNextSay = $now.AddMinutes((Get-Random -Minimum $lo -Maximum ($hi + 1)))
        if (-not ($script:PetOverlay -and $script:PetOverlay.Visible)) { Show-PetSaying }
    }

    # 随机动作 / 表情包
    $randMin = [int]$cfg.RandomMin
    if ($randMin -gt 0 -and $now -gt $script:PetNextRandom -and -not $script:PetAction -and -not $script:PetTarget) {
        $script:PetNextRandom = $now.AddMinutes($randMin)
        $pool = @(Get-PetAnimList | Where-Object { $_.id -ne 'idle' -and $_.id -ne 'sleep' -and $_.id -ne 'walk' })
        $memes = @(Get-PetMemeList)
        $roll = Get-Random -Minimum 0 -Maximum 100
        if ($memes.Count -gt 0 -and $roll -lt 30) {
            Show-PetMeme -Id ([string]$memes[(Get-Random -Maximum $memes.Count)].id)
        } elseif ([bool]$cfg.Say -and $roll -lt 55) {
            Show-PetSaying
        } elseif ($pool.Count -gt 0) {
            Play-PetAction -Id ([string]$pool[(Get-Random -Maximum $pool.Count)].id)
        }
    }

    # 帧率采样
    if ($script:PetTickStart -ne [datetime]::MinValue) {
        $el = ($now - $script:PetTickStart).TotalSeconds
        if (-not $script:PetFpsLog -and $el -ge 5) {
            $script:PetFpsLog = $true
            $script:PetTicksWarm = $script:PetTicks
            $script:PetWarmAt = $now
            Write-Log ('宠物渲染实测 ' + [Math]::Round($script:PetTicks / $el, 1) + ' fps / 计时器 ' + [Math]::Round($script:PetTickAll / $el, 1) + ' Hz(目标 ' + $fps + ')')
        } elseif ($script:PetFpsLog -and -not $script:PetFpsLog2 -and $script:PetWarmAt -ne [datetime]::MinValue -and ($now - $script:PetWarmAt).TotalSeconds -ge 10) {
            $script:PetFpsLog2 = $true
            $el2 = ($now - $script:PetWarmAt).TotalSeconds
            Write-Log ('宠物渲染稳态 ' + [Math]::Round(($script:PetTicks - $script:PetTicksWarm) / $el2, 1) + ' fps(目标 ' + $fps + ')')
        }
    }
}

function Save-PetPos {
    try {
        $s = Get-Settings
        $s.petX = [int]$script:PetX
        $s.petY = [int]$script:PetY
        Save-Settings -Settings $s
    } catch { }
}
# ---------- 宠物菜单的勾选:菜单只建一次,勾必须能跟着设置重算 ----------
# 以前是「建菜单时算一次」,所以把帧率改成 48Hz 再打开菜单,勾还停在 60Hz 上。
function Set-PetMenuCheck {
    # Name = 设置名,Value = 这一项的取值;petOverlayWH 是「宽,高」的组合项
    param($Item, [string]$Name, $Value, [double]$Tol = 0.01, $Snapshot)
    $Item | Add-Member -NotePropertyName PetCheckName -NotePropertyValue $Name -Force
    $Item | Add-Member -NotePropertyName PetCheckValue -NotePropertyValue $Value -Force
    $Item | Add-Member -NotePropertyName PetCheckTol -NotePropertyValue $Tol -Force
    Sync-PetMenuChecks -Items @($Item) -Snapshot $Snapshot
}

function Sync-PetMenuChecks {
    param($Items, $Snapshot)
    if ($null -eq $Snapshot) { try { $Snapshot = Get-Settings } catch { $Snapshot = $null } }
    foreach ($it in @($Items)) {
        $was = $false
        try { $was = [bool]$it.Checked } catch { }
        try {
            if ($Snapshot -and $it.PSObject.Properties['PetCheckName']) {
                $nm = [string]$it.PetCheckName
                if ($nm -eq 'petOverlayWH') {
                    $p2 = @(([string]$it.PetCheckValue) -split ',')
                    $it.Checked = ([int]$Snapshot.petOverlayW -eq [int]$p2[0] -and [int]$Snapshot.petOverlayH -eq [int]$p2[1])
                } elseif ($nm -eq 'petModelPair') {
                    # 模型是「包 id|配色 id」两段值
                    $it.Checked = ([string]$it.PetCheckValue -eq ([string]$Snapshot.model + '|' + [string]$Snapshot.variant))
                } else {
                    $cur = $it.PetCheckValue
                    if ($Snapshot.PSObject.Properties[$nm]) { $cur = $Snapshot.PSObject.Properties[$nm].Value }
                    # Tol < 0 表示开关类(直接按真假)
                    if ([double]$it.PetCheckTol -lt 0) { $it.Checked = [bool]$cur }
                    else { $it.Checked = ([Math]::Abs([double]$cur - [double]$it.PetCheckValue) -le [double]$it.PetCheckTol) }
                }
            }
        } catch { }
        try { if ([bool]$it.Checked -ne $was) { $script:PetCheckChanged = [int]$script:PetCheckChanged + 1 } } catch { }
        if ($it -is [System.Windows.Forms.ToolStripMenuItem] -and $it.DropDownItems.Count -gt 0) {
            Sync-PetMenuChecks -Items $it.DropDownItems -Snapshot $Snapshot
        }
    }
}

function Test-PetMenuPoint {
    # 鼠标点是不是落在菜单里(含所有还开着的二级 / 三级菜单)
    param($Menu, [System.Drawing.Point]$P)
    if (-not $Menu.Visible) { return $false }
    if ($Menu.Bounds.Contains($P)) { return $true }
    foreach ($it in @($Menu.Items)) {
        if ($it -is [System.Windows.Forms.ToolStripDropDownItem] -and $it.DropDown.Visible) {
            if (Test-PetMenuPoint -Menu $it.DropDown -P $P) { return $true }
        }
    }
    return $false
}

function New-PetMenu {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    # 勾选状态统一用这一份快照,免得每个选项都去读一遍 settings.json
    $snap = $null
    try { $snap = Get-Settings } catch { }

    # 模型(放最上面:这是最想点的东西)
    $miModel = New-Object System.Windows.Forms.ToolStripMenuItem
    $miModel.Text = '模型'
    Add-PetModelItems -Parent $miModel -Snapshot $snap
    [void]$menu.Items.Add($miModel)
    $miIcons = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIcons.Text = '桌面图标互动'
    $miIconEat = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconEat.Text = '吃掉一个图标(3 分钟后回原位)'
    $miIconEat.add_Click({ try { [void](Invoke-IconManual -Kind 'eat') } catch { } })
    [void]$miIcons.DropDownItems.Add($miIconEat)
    $miIconCarry = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconCarry.Text = '搬运一个图标(随机位置)'
    $miIconCarry.add_Click({ try { [void](Invoke-IconManual -Kind 'carry') } catch { } })
    [void]$miIcons.DropDownItems.Add($miIconCarry)
    $miIconTidy = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconTidy.Text = '整理图标(随机一种排法)'
    $miIconTidy.add_Click({ try { [void](Invoke-IconManual -Kind 'tidy') } catch { } })
    [void]$miIcons.DropDownItems.Add($miIconTidy)
    [void]$miIcons.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miIconAll = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconAll.Text = '立即还回被吃掉的图标'
    $miIconAll.add_Click({ try { [void](Restore-EatenIcons -All) } catch { } })
    [void]$miIcons.DropDownItems.Add($miIconAll)
    $miIconLayout = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconLayout.Text = '恢复上次记下的图标布局'
    $miIconLayout.add_Click({ try { [void](Restore-DesktopIconLayout) } catch { } })
    [void]$miIcons.DropDownItems.Add($miIconLayout)
    [void]$miIcons.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miIconAuto = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconAuto.Text = '拖到图标上自动触发'
    $miIconAuto.CheckOnClick = $true
    Set-PetMenuCheck -Item $miIconAuto -Name 'iconAuto' -Value $true -Tol -1 -Snapshot $snap
    $miIconAuto.add_Click({
            param($sender, $e)
            Set-PetSettingValue -Name 'iconAuto' -Value ([bool]$sender.Checked)
            Write-Log ('图标互动:拖放触发 ' + $(if ($sender.Checked) { '开' } else { '关' }))
        })
    [void]$miIcons.DropDownItems.Add($miIconAuto)
    $miIconWander2 = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconWander2.Text = '溜达到图标上也触发'
    $miIconWander2.CheckOnClick = $true
    Set-PetMenuCheck -Item $miIconWander2 -Name 'iconWander' -Value $true -Tol -1 -Snapshot $snap
    $miIconWander2.add_Click({
            param($sender, $e)
            Set-PetSettingValue -Name 'iconWander' -Value ([bool]$sender.Checked)
            $script:IconAutoWander = [bool]$sender.Checked
            Write-Log ('图标互动:溜达触发 ' + $(if ($sender.Checked) { '开' } else { '关' }))
        })
    [void]$miIcons.DropDownItems.Add($miIconWander2)
    [void]$menu.Items.Add($miIcons)

    $miActions = New-Object System.Windows.Forms.ToolStripMenuItem
    $miActions.Text = '动作'
    foreach ($a in (Get-PetAnimList)) {
        if ($a.id -in @('idle', 'sleep', 'walk')) { continue }
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$a.label
        $mi.Tag = [string]$a.id
        $mi.add_Click({ param($sender, $e) Play-PetAction -Id ([string]$sender.Tag) })
        [void]$miActions.DropDownItems.Add($mi)
    }
    $miRandomNow = New-Object System.Windows.Forms.ToolStripMenuItem
    $miRandomNow.Text = '随机来一个'
    $miRandomNow.add_Click({
            $pool = @(Get-PetAnimList | Where-Object { $_.id -notin @('idle', 'sleep', 'walk') })
            if ($pool.Count -gt 0) { Play-PetAction -Id ([string]$pool[(Get-Random -Maximum $pool.Count)].id) }
        })
    $miMeme = New-Object System.Windows.Forms.ToolStripMenuItem
    $miMeme.Text = '随机表情包'
    $miMeme.add_Click({
            $memes = @(Get-PetMemeList)
            if ($memes.Count -gt 0) { Show-PetMeme -Id ([string]$memes[(Get-Random -Maximum $memes.Count)].id) }
        })
    [void]$miActions.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$miActions.DropDownItems.Add($miRandomNow)
    [void]$miActions.DropDownItems.Add($miMeme)
    [void]$miActions.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miInterval = New-Object System.Windows.Forms.ToolStripMenuItem
    $miInterval.Text = '随机间隔'
    $cur = [int](Get-PetSetting -Name 'petRandomMin' -Default 5)
    foreach ($opt in @(@{ m = 0; t = '关' }, @{ m = 1; t = '每 1 分钟' }, @{ m = 5; t = '每 5 分钟' }, @{ m = 15; t = '每 15 分钟' }, @{ m = 30; t = '每 30 分钟' })) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$opt.t
        Set-PetMenuCheck -Item $mi -Name 'petRandomMin' -Value ([int]$opt.m) -Tol 0 -Snapshot $snap
        $mi.Tag = [int]$opt.m
        $mi.add_Click({
                param($sender, $e)
                Set-PetSettingValue -Name 'petRandomMin' -Value ([int]$sender.Tag)
                $script:PetCfg = $null; $script:PetCfgAt = [datetime]::MinValue
                $script:PetNextRandom = (Get-Date).AddMinutes([int]$sender.Tag)
                Write-Log ('宠物随机动作间隔改为: ' + $sender.Text)
            })
        [void]$miInterval.DropDownItems.Add($mi)
    }
    [void]$miActions.DropDownItems.Add($miInterval)
    [void]$menu.Items.Add($miActions)


    $miWander = New-Object System.Windows.Forms.ToolStripMenuItem
    $miWander.Text = '随机走动'
    $miWander.CheckOnClick = $true
    Set-PetMenuCheck -Item $miWander -Name 'petWander' -Value $true -Tol -1 -Snapshot $snap
    $miWander.add_Click({
            param($sender, $e)
            Set-PetSettingValue -Name 'petWander' -Value ([bool]$sender.Checked)
            if (-not $sender.Checked) { $script:PetTarget = $null }
        })
    [void]$menu.Items.Add($miWander)

    $miWeather = New-Object System.Windows.Forms.ToolStripMenuItem
    $miWeather.Text = '悬停显示天气(联网定位)'
    $miWeather.CheckOnClick = $true
    Set-PetMenuCheck -Item $miWeather -Name 'petWeather' -Value $true -Tol -1 -Snapshot $snap
    $miWeather.add_Click({
            param($sender, $e)
            Set-PetSettingValue -Name 'petWeather' -Value ([bool]$sender.Checked)
            if ($sender.Checked) { Start-PetWeatherRefresh -Force }
        })
    [void]$menu.Items.Add($miWeather)

    $miSize = New-Object System.Windows.Forms.ToolStripMenuItem
    $miSize.Text = '大小'
    $curSize = [double](Get-PetSetting -Name 'petScale' -Default 1.0)
    foreach ($opt in @(0.6, 0.8, 1.0, 1.25, 1.5, 2.0)) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = ('{0}%' -f [int][Math]::Round($opt * 100))
        Set-PetMenuCheck -Item $mi -Name 'petScale' -Value ([double]$opt) -Tol 0.01 -Snapshot $snap
        $mi.Tag = [double]$opt
        $mi.add_Click({
                param($sender, $e)
                Set-PetSize -Scale ([double]$sender.Tag)
            })
        [void]$miSize.DropDownItems.Add($mi)
    }
    [void]$menu.Items.Add($miSize)

    $miBox = New-Object System.Windows.Forms.ToolStripMenuItem
    $miBox.Text = '信息框'
    $curFont = [double](Get-PetSetting -Name 'petOverlayFont' -Default 9.5)
    $miFont = New-Object System.Windows.Forms.ToolStripMenuItem
    $miFont.Text = '字号'
    foreach ($opt in @(@{ v = 8; t = '小' }, @{ v = 9.5; t = '中' }, @{ v = 11; t = '大' }, @{ v = 13; t = '特大' })) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$opt.t
        Set-PetMenuCheck -Item $mi -Name 'petOverlayFont' -Value ([double]$opt.v) -Tol 0.01 -Snapshot $snap
        $mi.Tag = [double]$opt.v
        $mi.add_Click({
                param($sender, $e)
                Set-PetSettingValue -Name 'petOverlayFont' -Value ([double]$sender.Tag)
                $script:PetCfg = $null
                $script:PetCfgAt = [datetime]::MinValue
                if ($script:PetHover) { Set-PetOverlayContent -Kind 'info' }
            })
        [void]$miFont.DropDownItems.Add($mi)
    }
    [void]$miBox.DropDownItems.Add($miFont)

    $miAlpha = New-Object System.Windows.Forms.ToolStripMenuItem
    $miAlpha.Text = '透明度'
    $curAlpha = [double](Get-PetSetting -Name 'petOverlayOpacity' -Default 0.94)
    foreach ($opt in @(@{ v = 0.7; t = '70%' }, @{ v = 0.85; t = '85%' }, @{ v = 1.0; t = '不透明' })) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$opt.t
        Set-PetMenuCheck -Item $mi -Name 'petOverlayOpacity' -Value ([double]$opt.v) -Tol 0.02 -Snapshot $snap
        $mi.Tag = [double]$opt.v
        $mi.add_Click({
                param($sender, $e)
                Set-PetSettingValue -Name 'petOverlayOpacity' -Value ([double]$sender.Tag)
                $script:PetCfg = $null
                $script:PetCfgAt = [datetime]::MinValue
                if ($script:PetHover) { Set-PetOverlayContent -Kind 'info' }
            })
        [void]$miAlpha.DropDownItems.Add($mi)
    }
    [void]$miBox.DropDownItems.Add($miAlpha)
    # 尺寸档位(0 = 自动)
    $curOW = [int](Get-PetSetting -Name 'petOverlayW' -Default 0)
    $curOH = [int](Get-PetSetting -Name 'petOverlayH' -Default 0)
    $miBoxSize = New-Object System.Windows.Forms.ToolStripMenuItem
    $miBoxSize.Text = '尺寸'
    foreach ($opt in @(
            @{ t = '自动(按内容)'; w = 0; h = 0 },
            @{ t = '紧凑 240 × 自动'; w = 240; h = 0 },
            @{ t = '标准 320 × 自动'; w = 320; h = 0 },
            @{ t = '宽版 420 × 自动'; w = 420; h = 0 },
            @{ t = '方框 300 × 120'; w = 300; h = 120 },
            @{ t = '大框 380 × 160'; w = 380; h = 160 }
        )) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$opt.t
        Set-PetMenuCheck -Item $mi -Name 'petOverlayWH' -Value ([string]$opt.w + ',' + [string]$opt.h) -Tol 0 -Snapshot $snap
        $mi.Tag = ([string]$opt.w + ',' + [string]$opt.h)
        $mi.add_Click({
                param($sender, $e)
                $parts = @(([string]$sender.Tag) -split ',')
                Set-PetOverlaySize -W ([int]$parts[0]) -H ([int]$parts[1])
            })
        [void]$miBoxSize.DropDownItems.Add($mi)
    }
    [void]$miBoxSize.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miBoxCustom = New-Object System.Windows.Forms.ToolStripMenuItem
    $miBoxCustom.Text = '自定义尺寸…'
    $miBoxCustom.add_Click({
            try {
                Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
                $cw = [int](Get-PetSetting -Name 'petOverlayW' -Default 0)
                $ch = [int](Get-PetSetting -Name 'petOverlayH' -Default 0)
                $ans = [Microsoft.VisualBasic.Interaction]::InputBox('宽,高(像素;0 = 自动)。例:320,0 或 320,120', '信息框尺寸', ($cw.ToString() + ',' + $ch.ToString()))
                if ($null -ne $ans -and $ans.Trim()) {
                    $parts = @($ans -split '[,，xX* ]+' | Where-Object { $_ -ne '' })
                    $nw = 0; $nh = 0
                    if ($parts.Count -ge 1) { [void][int]::TryParse([string]$parts[0], [ref]$nw) }
                    if ($parts.Count -ge 2) { [void][int]::TryParse([string]$parts[1], [ref]$nh) }
                    Set-PetOverlaySize -W $nw -H $nh
                }
            } catch { }
        })
    [void]$miBoxSize.DropDownItems.Add($miBoxCustom)
    [void]$miBox.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$miBox.DropDownItems.Add($miBoxSize)
    [void]$menu.Items.Add($miBox)

    # 帧率(24 = 素材原生;48/60 = 插中间帧,动作时长不变)
    $miFps = New-Object System.Windows.Forms.ToolStripMenuItem
    $miFps.Text = '帧率'
    $curFps = [int](Get-PetSetting -Name 'petFps' -Default 60)
    foreach ($opt in @(
            @{ v = 24; t = '24Hz(原生,最省内存)' },
            @{ v = 48; t = '48Hz(插一帧)' },
            @{ v = 60; t = '60Hz(插一帧 + 60Hz 计时器)' }
        )) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$opt.t
        Set-PetMenuCheck -Item $mi -Name 'petFps' -Value ([int]$opt.v) -Tol 0 -Snapshot $snap
        $mi.Tag = [int]$opt.v
        $mi.add_Click({
                param($sender, $e)
                $v = [int]$sender.Tag
                Set-PetSettingValue -Name 'petFps' -Value $v
                # 帧缓存是按旧帧率插值的,得清掉重来
                foreach ($k in @($script:PetCache.Keys)) {
                    foreach ($hb in $script:PetCache[$k].Hbs) { [DeskPet.Layered]::FreeHBitmap($hb) }
                }
                $script:PetCache = @{}
                $script:PetLastIdx = -1
                if ($script:PetTimer) { $script:PetTimer.Interval = 4 }
                Write-Log ('宠物帧率: ' + $v + 'Hz')
            })
        [void]$miFps.DropDownItems.Add($mi)
    }
    [void]$menu.Items.Add($miFps)
    # 物理(拖拽抛掷手感)
    $miPhys = New-Object System.Windows.Forms.ToolStripMenuItem
    $miPhys.Text = '物理'
    $cfgNow = Get-PetCfg
    $miFeel = New-Object System.Windows.Forms.ToolStripMenuItem
    $miFeel.Text = '手感'
    foreach ($opt in @(@{ g = 900; t = '轻盈' }, @{ g = 1400; t = '标准' }, @{ g = 2200; t = '厚重' })) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$opt.t
        Set-PetMenuCheck -Item $mi -Name 'petGravity' -Value ([int]$opt.g) -Tol 1 -Snapshot $snap
        $mi.Tag = [int]$opt.g
        $mi.add_Click({
                param($sender, $e)
                Set-PetSettingValue -Name 'petGravity' -Value ([int]$sender.Tag)
                $script:PetCfg = $null; $script:PetCfgAt = [datetime]::MinValue
                Write-Log ('宠物物理手感: ' + $sender.Text)
            })
        [void]$miFeel.DropDownItems.Add($mi)
    }
    [void]$miPhys.DropDownItems.Add($miFeel)

    $miRest = New-Object System.Windows.Forms.ToolStripMenuItem
    $miRest.Text = '弹性'
    foreach ($opt in @(@{ v = 0.5; t = '低' }, @{ v = 0.78; t = '标准' }, @{ v = 0.95; t = '高' })) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$opt.t
        Set-PetMenuCheck -Item $mi -Name 'petRestitution' -Value ([double]$opt.v) -Tol 0.02 -Snapshot $snap
        $mi.Tag = [double]$opt.v
        $mi.add_Click({
                param($sender, $e)
                Set-PetSettingValue -Name 'petRestitution' -Value ([double]$sender.Tag)
                $script:PetCfg = $null; $script:PetCfgAt = [datetime]::MinValue
            })
        [void]$miRest.DropDownItems.Add($mi)
    }
    [void]$miPhys.DropDownItems.Add($miRest)

    $miFric = New-Object System.Windows.Forms.ToolStripMenuItem
    $miFric.Text = '地面摩擦'
    foreach ($opt in @(@{ v = 1.0; t = '小' }, @{ v = 2.5; t = '标准' }, @{ v = 5.0; t = '大' })) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$opt.t
        Set-PetMenuCheck -Item $mi -Name 'petGroundFriction' -Value ([double]$opt.v) -Tol 0.05 -Snapshot $snap
        $mi.Tag = [double]$opt.v
        $mi.add_Click({
                param($sender, $e)
                Set-PetSettingValue -Name 'petGroundFriction' -Value ([double]$sender.Tag)
                $script:PetCfg = $null; $script:PetCfgAt = [datetime]::MinValue
            })
        [void]$miFric.DropDownItems.Add($mi)
    }
    [void]$miPhys.DropDownItems.Add($miFric)

    $miCeil = New-Object System.Windows.Forms.ToolStripMenuItem
    $miCeil.Text = '顶部反弹'
    $miCeil.CheckOnClick = $true
    Set-PetMenuCheck -Item $miCeil -Name 'petCeilingBounce' -Value $true -Tol -1 -Snapshot $snap
    $miCeil.add_Click({
            param($sender, $e)
            Set-PetSettingValue -Name 'petCeilingBounce' -Value ([bool]$sender.Checked)
            $script:PetCfg = $null; $script:PetCfgAt = [datetime]::MinValue
        })
    [void]$miPhys.DropDownItems.Add($miCeil)
    [void]$menu.Items.Add($miPhys)

    # 碎碎念(开关 + 随机触发间隔 + 气泡时长)
    $miSay = New-Object System.Windows.Forms.ToolStripMenuItem
    $miSay.Text = '碎碎念'

    $miSayOn = New-Object System.Windows.Forms.ToolStripMenuItem
    $miSayOn.Text = '自动碎碎念'
    $miSayOn.CheckOnClick = $true
    Set-PetMenuCheck -Item $miSayOn -Name 'petSay' -Value $true -Tol -1 -Snapshot $snap
    $miSayOn.add_Click({
            param($sender, $e)
            Set-PetSettingValue -Name 'petSay' -Value ([bool]$sender.Checked)
            $script:PetCfg = $null; $script:PetCfgAt = [datetime]::MinValue
            $script:PetNextSay = (Get-Date)
        })
    [void]$miSay.DropDownItems.Add($miSayOn)

    $miSayEvery = New-Object System.Windows.Forms.ToolStripMenuItem
    $miSayEvery.Text = '随机触发'
    $curEvery = [int](Get-PetSetting -Name 'petSayEvery' -Default 6)
    foreach ($opt in @(
            @{ m = 0; t = '关(只跟随机动作一起)' },
            @{ m = 6; t = '频繁:每 3~10 分钟' },
            @{ m = 20; t = '一般:每 10~30 分钟' },
            @{ m = 60; t = '偶尔:每 30~90 分钟' }
        )) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$opt.t
        Set-PetMenuCheck -Item $mi -Name 'petSayEvery' -Value ([int]$opt.m) -Tol 0 -Snapshot $snap
        $mi.Tag = [int]$opt.m
        $mi.add_Click({
                param($sender, $e)
                $v = [int]$sender.Tag
                Set-PetSettingValue -Name 'petSayEvery' -Value $v
                $script:PetCfg = $null; $script:PetCfgAt = [datetime]::MinValue
                $script:PetNextSay = (Get-Date)
                Write-Log ('碎碎念随机触发: ' + $sender.Text)
            })
        [void]$miSayEvery.DropDownItems.Add($mi)
    }
    [void]$miSay.DropDownItems.Add($miSayEvery)

    $miSayDur = New-Object System.Windows.Forms.ToolStripMenuItem
    $miSayDur.Text = '气泡时长'
    $curDur = [double](Get-PetSetting -Name 'petSayDur' -Default 0)
    foreach ($opt in @(
            @{ s = 0; t = '随机 2~6 秒' },
            @{ s = 3; t = '3 秒' },
            @{ s = 5; t = '5 秒' },
            @{ s = 8; t = '8 秒' }
        )) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = [string]$opt.t
        Set-PetMenuCheck -Item $mi -Name 'petSayDur' -Value ([double]$opt.s) -Tol 0.01 -Snapshot $snap
        $mi.Tag = [double]$opt.s
        $mi.add_Click({
                param($sender, $e)
                Set-PetSettingValue -Name 'petSayDur' -Value ([double]$sender.Tag)
                $script:PetCfg = $null; $script:PetCfgAt = [datetime]::MinValue
                Write-Log ('碎碎念气泡时长: ' + $sender.Text)
            })
        [void]$miSayDur.DropDownItems.Add($mi)
    }
    [void]$miSay.DropDownItems.Add($miSayDur)

    [void]$miSay.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miSayNow = New-Object System.Windows.Forms.ToolStripMenuItem
    $miSayNow.Text = '说一句'
    $miSayNow.add_Click({ Show-PetSaying })
    [void]$miSay.DropDownItems.Add($miSayNow)
    [void]$menu.Items.Add($miSay)

    # 天气城市
    $miCity = New-Object System.Windows.Forms.ToolStripMenuItem
    $miCity.Text = '天气城市…'
    $miCity.add_Click({
            try {
                Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
                $cur = [string](Get-PetSetting -Name 'petWeatherCity' -Default '')
                $ans = [Microsoft.VisualBasic.Interaction]::InputBox('输入城市名(留空=按 IP 自动定位)', '天气城市', $cur)
                if ($null -ne $ans) {
                    Set-PetSettingValue -Name 'petWeatherCity' -Value ([string]$ans).Trim()
                    $script:PetWeather = $null
                    $script:PetWeatherAt = [datetime]::MinValue
                    Start-PetWeatherRefresh -Force
                    Write-Log ('天气城市: ' + $(if ($ans.Trim()) { $ans.Trim() } else { '(按 IP 定位)' }))
                }
            } catch { }
        })
    [void]$menu.Items.Add($miCity)


    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $miMenu.Text = '打开应用目录…'
    $miMenu.add_Click({ Start-Process $script:AppDir })
    [void]$menu.Items.Add($miMenu)

    $miAbout = New-Object System.Windows.Forms.ToolStripMenuItem
    $miAbout.Text = '关于 / 素材来源'
    $miAbout.add_Click({
            $src = $(if ($script:PetUrl) { $script:PetUrl } else { 'https://github.com/PC2005-cloud/dsh-pet' })
            Start-Process $src
        })
    [void]$menu.Items.Add($miAbout)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miHide = New-Object System.Windows.Forms.ToolStripMenuItem
    $miHide.Text = '隐藏宠物(托盘里可再打开)'
    $miHide.add_Click({ Stop-Pet -Remember })
    [void]$menu.Items.Add($miHide)

    return $menu
}
function Start-PetWeatherRefresh {
    param([switch]$Force)
    if (-not [bool](Get-PetSetting -Name 'petWeather' -Default $true)) { return }
    $fresh = $false
    if (Test-Path $script:PetWeatherFile) {
        try {
            $age = ((Get-Date) - (Get-Item $script:PetWeatherFile).LastWriteTime).TotalMinutes
            $fresh = ($age -lt 30)
        } catch { }
    }
    if ($fresh -and -not $Force) { return }
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList (
            '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode weather -Background' -f $SelfScript)
    } catch { }
}

function Start-Pet {
    param([switch]$Quiet)

    if ($script:PetForm -and -not $script:PetForm.IsDisposed) { return $true }
    if (-not (Test-PetAssets)) {
        Write-Log ('没有宠物素材(缺 ' + (Join-Path $script:PetDir 'idle') + '),跳过') 'WARN'
        return $false
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [void](Set-PetDpiAware)
    # 图标互动:读设置 + 把上次没还回去的图标先还了
    try {
        $sI = Get-Settings
        $script:IconPlay = [bool]$sI.iconPlay
        $script:IconAutoWander = [bool]$sI.iconWander
        $script:IconEatSeconds = [int]$sI.iconEatSec
        $script:IconReady = [bool]$sI.iconReady
        Import-IconState
        [void](Restore-EatenIcons)
    } catch { }
    if (-not ('DeskPet.Layered' -as [type])) {
        Add-Type -TypeDefinition $script:LayeredCs -Language CSharp -ReferencedAssemblies System.Drawing
    }

    $frames = Get-PetFrames -Anim 'idle' -Scale ([double](Get-PetSetting -Name 'petScale' -Default 1.0))
    if (-not $frames) { Write-Log '宠物帧读不出来(pet/idle/*.png)', 'WARN'; return $false }
    $w = $frames.W
    $h = $frames.H

    $set = Get-Settings
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:ScreenW = $wa.Right; $script:ScreenH = $wa.Bottom
    if ([int]$set.petX -gt 0 -and [int]$set.petY -gt 0) {
        $script:PetX = [int]$set.petX
        $script:PetY = [int]$set.petY
    } else {
        $script:PetX = $wa.Left + 40
        $script:PetY = $wa.Bottom - $h - 60
    }
    if ($script:PetX -gt ($wa.Right - 40)) { $script:PetX = $wa.Right - $w - 30 }
    if ($script:PetX -lt $wa.Left) { $script:PetX = $wa.Left + 10 }
    if ($script:PetY -gt ($wa.Bottom - 40)) { $script:PetY = $wa.Bottom - $h - 40 }
    if ($script:PetY -lt $wa.Top) { $script:PetY = $wa.Top + 10 }

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.BackColor = [System.Drawing.Color]::FromArgb(1, 1, 1)
    $form.Text = '桌面宠物'
    $form.ClientSize = New-Object System.Drawing.Size -ArgumentList $w, $h
    $form.Location = New-Object System.Drawing.Point -ArgumentList $script:PetX, $script:PetY
    $script:PetMenu = New-PetMenu
    $form.ContextMenuStrip = $script:PetMenu
    # 菜单只在宠物启动时建一次 —— 每次弹出前按最新设置重算勾选,
    # 否则改成 48Hz 再打开菜单,勾还留在 60Hz 上。
    $script:PetMenu.add_Opening({
            try {
                $script:PetCheckChanged = 0
                Sync-PetMenuChecks -Items $script:PetMenu.Items
                if ([int]$script:PetCheckChanged -gt 0) {
                    Write-Log ('宠物菜单勾选已按最新设置重算(' + [int]$script:PetCheckChanged + ' 项变化)')
                }
            } catch { }
        })
    # 点菜单外面自动关闭(窗口 TopMost 且没有焦点时,默认行为常常不收起)
    # 关键:必须等「松手」再判断。按下就收会把二级菜单里的点击吃掉 ——
    # 帧率 / 大小 / 信息框 / 动作 / 随机间隔 / 碎碎念 全在二级菜单里,
    # 以前这些项点了完全没反应(日志里连一行「宠物帧率:48Hz」都没有)就是这个原因。
    $script:PetMenuGuard = New-Object System.Windows.Forms.Timer
    $script:PetMenuGuard.Interval = 40
    $script:PetMenuGuard.add_Tick({
            if (-not $script:PetMenu -or -not $script:PetMenu.Visible) { $script:PetMenuGuard.Stop(); $script:PetMenuDown = $false; return }
            $btn = [System.Windows.Forms.Control]::MouseButtons
            if ($btn -ne [System.Windows.Forms.MouseButtons]::None) { $script:PetMenuDown = $true; return }
            if (-not $script:PetMenuDown) { return }
            $script:PetMenuDown = $false
            $cp = [System.Windows.Forms.Cursor]::Position
            if (-not (Test-PetMenuPoint -Menu $script:PetMenu -P $cp)) {
                $script:PetMenu.Close()
                $script:PetMenuGuard.Stop()
            }
        })
    $script:PetMenu.add_Opened({ $script:PetMenuDown = $false; $script:PetMenuGuard.Start() })
    $script:PetMenu.add_Closed({ $script:PetMenuGuard.Stop() })
    $form.add_MouseEnter({
            $script:PetHover = $true
            $script:PetHoverOffAt = [datetime]::MinValue
            Set-PetOverlayContent -Kind 'info'
        })
    $form.add_MouseLeave({ $script:PetHover = $false; $script:PetHoverOffAt = (Get-Date) })
    $form.add_MouseDown({
            param($s, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                $script:PetDrag = @{ X = $e.X; Y = $e.Y; Moved = $false; VX = 0.0; VY = 0.0; At = (Get-Date); LastX = $script:PetXf; LastY = $script:PetYf }
                $script:PetTarget = $null
                $script:PetPhys = $false
                $script:PetVx = 0; $script:PetVy = 0
            }
        })
    $form.add_MouseMove({
            param($s, $e)
            if ($script:PetDrag) {
                $p = [System.Windows.Forms.Cursor]::Position
                $nx = [double]($p.X - $script:PetDrag.X)
                $ny = [double]($p.Y - $script:PetDrag.Y)
                $now = Get-Date
                $dt = ($now - $script:PetDrag.At).TotalSeconds
                if ($dt -gt 0.008) {
                    # 记录拖动速度(px/s),松手时当抛掷初速
                    $script:PetDrag.VX = ($nx - $script:PetDrag.LastX) / $dt
                    $script:PetDrag.VY = ($ny - $script:PetDrag.LastY) / $dt
                    $script:PetDrag.LastX = $nx
                    $script:PetDrag.LastY = $ny
                    $script:PetDrag.At = $now
                }
                $script:PetXf = $nx
                $script:PetYf = $ny
                $script:PetX = [int][Math]::Round($script:PetXf)
                $script:PetY = [int][Math]::Round($script:PetYf)
                $script:PetDrag.Moved = $true
                Update-Pet
            }
        })
    $form.add_MouseUp({
            param($s, $e)
            if ($script:PetDrag) {
                if ($script:PetDrag.Moved) {
                    Save-PetPos
                    # 甩出去:按松手瞬间的速度给一个初速,之后交给重力
                    $speed = [Math]::Sqrt($script:PetDrag.VX * $script:PetDrag.VX + $script:PetDrag.VY * $script:PetDrag.VY)
                    if ($speed -gt 120) { Start-PetPhysics -Vx $script:PetDrag.VX -Vy $script:PetDrag.VY }
                    try { [void](Invoke-IconEventNearPet -Source 'drop' -Chance 45) } catch { }
                }
                else {
                    # 点一下 / 摸头:随机挑一个动作(上半部分算摸头)
                    $head = ($e.Y -lt ($s.ClientSize.Height * 0.4))
                    $pool = @(Get-PetAnimList | Where-Object { $_.id -notin @('idle', 'sleep', 'walk') })
                    $pick = 'wave'
                    if ($pool.Count -gt 0) { $pick = [string]$pool[(Get-Random -Maximum $pool.Count)].id }
                    Play-PetAction -Id $pick
                    Write-Log ('宠物被' + $(if ($head) { '摸头' } else { '点了一下' }) + ' → ' + (Get-PetLabel $pick))
                    if ([bool](Get-PetCfg).Say -and (Get-Random -Maximum 100) -lt 30) { Show-PetSaying }
                }
                $script:PetDrag = $null
            }
        })

    $script:PetForm = $form
    $script:PetAnim = ''
    $script:PetLastIdx = -1
    $script:PetAction = ''
    $script:PetTarget = $null
    $script:PetStillSince = Get-Date
    $script:PetXf = [double]$script:PetX
    $script:PetYf = [double]$script:PetY
    $script:PetLastDrawX = -99999
    $script:PetLastDrawY = -99999
    $script:PetCfg = $null
    $script:PetCfgAt = [datetime]::MinValue
    $script:PetNextRandom = (Get-Date).AddMinutes([int](Get-PetSetting -Name 'petRandomMin' -Default 5))
    $script:PetNextSay = (Get-Date)
    $script:PetSw = New-Object System.Diagnostics.Stopwatch
    $script:PetSw.Start()
    $script:PetTickStart = Get-Date
    $script:PetTicks = 0
    $script:PetTickAll = 0
    $script:PetFpsLog = $false
    $script:PetFpsLog2 = $false
    $script:PetTicksWarm = 0
    $script:PetWarmAt = [datetime]::MinValue

    $form.Show()
    [DeskPet.Layered]::Enable($form.Handle)
    [DeskPet.Layered]::BeginHighRes()
    $noThrottle = [DeskPet.Layered]::DisablePowerThrottling()
    Write-Log ('宠物计时器: 1ms 精度, 已' + $(if ($noThrottle) { '退出' } else { '未退出(可能被系统强制)' }) + '电源节流')

    New-PetOverlayWindow

    $timer = New-Object System.Windows.Forms.Timer
    $fpsWant = [int](Get-PetSetting -Name 'petFps' -Default 60)
    if ($fpsWant -lt 12) { $fpsWant = 24 }
    # WinForms 的 Timer 分辨率约 15.6ms,用 4ms 间隔让它跑满;实际节拍由每帧工作量决定
    $timer.Interval = 4
    $timer.add_Tick({ try { Update-Pet } catch { } })
    $timer.Start()
    $script:PetTimer = $timer

    Update-Pet
    Start-PetWeatherRefresh
    if (-not $Quiet) {
        $anims = @(Get-PetAnimList | Where-Object { $_.id -notin @('idle', 'sleep', 'walk') }).Count
        $memes = @(Get-PetMemeList).Count
        Write-Log ('桌面宠物已启动(' + $w + 'x' + $h + ',' + $fpsWant + 'Hz(素材 ' + (Get-PetFps) + 'fps),' + $anims + ' 个动作,' + $memes + ' 张表情包,素材:' + $script:PetUrl + ')') 'OK'
    }
    return $true
}

function Stop-Pet {
    param([switch]$Remember)

    $had = [bool]($script:PetForm -or $script:PetTimer)
    if ($script:PetTimer) { try { $script:PetTimer.Stop(); $script:PetTimer.Dispose() } catch { }; $script:PetTimer = $null }
    if ($script:PetOverlay -and -not $script:PetOverlay.IsDisposed) {
        try { $script:PetOverlay.Hide(); $script:PetOverlay.Dispose() } catch { }
    }
    $script:PetOverlay = $null
    if ($script:PetForm -and -not $script:PetForm.IsDisposed) {
        try { $script:PetForm.Hide(); $script:PetForm.Dispose() } catch { }
    }
    if ('DeskPet.Layered' -as [type]) { try { [DeskPet.Layered]::EndHighRes() } catch { } }
    $script:PetForm = $null
    if ($script:PetSw) { $script:PetSw.Stop(); $script:PetSw = $null }
    foreach ($k in @($script:PetCache.Keys)) {
        foreach ($hb in $script:PetCache[$k].Hbs) { [DeskPet.Layered]::FreeHBitmap($hb) }
    }
    $script:PetCache = @{}
    foreach ($k in @($script:PetMemeCache.Keys)) { try { $script:PetMemeCache[$k].Dispose() } catch { } }
    $script:PetMemeCache = @{}
    $script:PetAnim = ''
    $script:PetAction = ''
    $script:PetTarget = $null
    $script:PetLastIdx = -1

    if ($Remember) {
        try {
            $s = Get-Settings
            $s.pet = $false
            Save-Settings -Settings $s
        } catch { }
    }
    if ($had) { Write-Log '桌面宠物已关闭' }
}

function Set-PetEnabled {
    param([bool]$On)
    try {
        $s = Get-Settings
        $s.pet = $On
        Save-Settings -Settings $s
    } catch { }
    if ($On) { [void](Start-Pet) } else { Stop-Pet }
}

function Sync-PetWithSettings {
    $stamp = 0
    try { if (Test-Path $script:SettingsFn) { $stamp = (Get-Item $script:SettingsFn).LastWriteTimeUtc.Ticks } } catch { }
    if ($stamp -eq $script:PetSettingsStamp) { return }
    $script:PetSettingsStamp = $stamp

    $want = $false
    try { $want = [bool](Get-Settings).pet } catch { }
    $on = [bool]($script:PetForm -and -not $script:PetForm.IsDisposed)
    if ($want -and -not $on) { [void](Start-Pet) }
    elseif (-not $want -and $on) { Stop-Pet }
}


# ================= 托盘 =================
function Test-Elevated {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-TaskInstalled {
    try { return [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) } catch { return $false }
}

function Update-TrayText {
    if (-not $script:TrayNotify) { return }
    $all = @(Get-PetModels)
    $pick = @($all | Where-Object { $_.Id -eq $script:ModelId -and $_.Variant -eq $script:VariantId })[0]
    $name = $(if ($pick) { $pick.Label } else { '没有模型' })
    $txt = '桌面宠物 · ' + $name
    if ($txt.Length -gt 62) { $txt = $txt.Substring(0, 62) }
    try { $script:TrayNotify.Text = $txt } catch { }
}

function Add-PetModelItems {
    # 模型子菜单:每个包的每套配色一项,当前那套打勾
    param($Parent, $Snapshot)
    $models = @(Get-PetModels)
    if ($models.Count -eq 0) {
        $miNone = New-Object System.Windows.Forms.ToolStripMenuItem
        $miNone.Text = '(models 里没有模型包)'
        $miNone.Enabled = $false
        [void]$Parent.DropDownItems.Add($miNone)
    } else {
        foreach ($m in $models) {
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem
            $mi.Text = [string]$m.Label
            $mi.Tag = ([string]$m.Id + '|' + [string]$m.Variant)
            Set-PetMenuCheck -Item $mi -Name 'petModelPair' -Value ([string]$mi.Tag) -Tol 0 -Snapshot $Snapshot
            $mi.add_Click({
                    param($sender, $e)
                    $parts = @(([string]$sender.Tag) -split '\|')
                    [void](Set-PetModel -Id $parts[0] -Variant $parts[1])
                })
            [void]$Parent.DropDownItems.Add($mi)
        }
    }
    [void]$Parent.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miDir = New-Object System.Windows.Forms.ToolStripMenuItem
    $miDir.Text = '打开模型目录…'
    $miDir.add_Click({ Start-Process $script:ModelsDir })
    [void]$Parent.DropDownItems.Add($miDir)
    $miReload = New-Object System.Windows.Forms.ToolStripMenuItem
    $miReload.Text = '重新扫描模型'
    $miReload.add_Click({
            $n = @(Get-PetModels).Count
            Write-Log ('重新扫描模型:' + $n + ' 套配色') 'OK'
        })
    [void]$Parent.DropDownItems.Add($miReload)
}

function Show-PetMenuFromTray {
    try {
        if (-not $script:PetMenu) { $script:PetMenu = New-PetMenu }
        $script:PetMenu.Show([System.Windows.Forms.Cursor]::Position)
    } catch {
        Write-Log ('打开宠物菜单失败:' + $_.Exception.Message) 'WARN'
    }
}

function New-TrayMenu {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $snap = $null
    try { $snap = Get-Settings } catch { }

    $miModel = New-Object System.Windows.Forms.ToolStripMenuItem
    $miModel.Text = '模型'
    Add-PetModelItems -Parent $miModel -Snapshot $snap
    [void]$menu.Items.Add($miModel)
    $miIcons = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIcons.Text = '桌面图标互动'
    $miIconEat = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconEat.Text = '吃掉一个图标(3 分钟后回原位)'
    $miIconEat.add_Click({ try { [void](Invoke-IconManual -Kind 'eat') } catch { } })
    [void]$miIcons.DropDownItems.Add($miIconEat)
    $miIconCarry = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconCarry.Text = '搬运一个图标(随机位置)'
    $miIconCarry.add_Click({ try { [void](Invoke-IconManual -Kind 'carry') } catch { } })
    [void]$miIcons.DropDownItems.Add($miIconCarry)
    $miIconTidy = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconTidy.Text = '整理图标(随机一种排法)'
    $miIconTidy.add_Click({ try { [void](Invoke-IconManual -Kind 'tidy') } catch { } })
    [void]$miIcons.DropDownItems.Add($miIconTidy)
    [void]$miIcons.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miIconAll = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconAll.Text = '立即还回被吃掉的图标'
    $miIconAll.add_Click({ try { [void](Restore-EatenIcons -All) } catch { } })
    [void]$miIcons.DropDownItems.Add($miIconAll)
    $miIconLayout = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconLayout.Text = '恢复上次记下的图标布局'
    $miIconLayout.add_Click({ try { [void](Restore-DesktopIconLayout) } catch { } })
    [void]$miIcons.DropDownItems.Add($miIconLayout)
    [void]$miIcons.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miIconAuto = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconAuto.Text = '拖到图标上自动触发'
    $miIconAuto.CheckOnClick = $true
    Set-PetMenuCheck -Item $miIconAuto -Name 'iconAuto' -Value $true -Tol -1 -Snapshot $snap
    $miIconAuto.add_Click({
            param($sender, $e)
            Set-PetSettingValue -Name 'iconAuto' -Value ([bool]$sender.Checked)
            Write-Log ('图标互动:拖放触发 ' + $(if ($sender.Checked) { '开' } else { '关' }))
        })
    [void]$miIcons.DropDownItems.Add($miIconAuto)
    $miIconWander2 = New-Object System.Windows.Forms.ToolStripMenuItem
    $miIconWander2.Text = '溜达到图标上也触发'
    $miIconWander2.CheckOnClick = $true
    Set-PetMenuCheck -Item $miIconWander2 -Name 'iconWander' -Value $true -Tol -1 -Snapshot $snap
    $miIconWander2.add_Click({
            param($sender, $e)
            Set-PetSettingValue -Name 'iconWander' -Value ([bool]$sender.Checked)
            $script:IconAutoWander = [bool]$sender.Checked
            Write-Log ('图标互动:溜达触发 ' + $(if ($sender.Checked) { '开' } else { '关' }))
        })
    [void]$miIcons.DropDownItems.Add($miIconWander2)
    [void]$menu.Items.Add($miIcons)

    $miShow = New-Object System.Windows.Forms.ToolStripMenuItem
    $miShow.Text = '显示宠物'
    $miShow.add_Click({
            Set-PetEnabled -On $true
            Update-TrayText
        })
    [void]$menu.Items.Add($miShow)

    $miHide = New-Object System.Windows.Forms.ToolStripMenuItem
    $miHide.Text = '隐藏宠物'
    $miHide.add_Click({
            Stop-Pet -Remember
            Update-TrayText
        })
    [void]$menu.Items.Add($miHide)

    $miPetMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $miPetMenu.Text = '打开宠物菜单…(和右键宠物一样)'
    $miPetMenu.add_Click({ Show-PetMenuFromTray })
    [void]$menu.Items.Add($miPetMenu)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miAuto = New-Object System.Windows.Forms.ToolStripMenuItem
    $miAuto.Text = '开机自启:' + $(if (Get-TaskInstalled) { ' 已安装' } else { ' 未安装' })
    $miAuto.add_Click({
            if (Get-TaskInstalled) {
                [void](Invoke-Uninstall)
                $miAuto.Text = '开机自启: 未安装'
            } else {
                [void](Invoke-Install)
                $miAuto.Text = '开机自启:' + $(if (Get-TaskInstalled) { ' 已安装' } else { ' 未安装' })
            }
        })
    [void]$menu.Items.Add($miAuto)

    $miLog = New-Object System.Windows.Forms.ToolStripMenuItem
    $miLog.Text = '查看日志'
    $miLog.add_Click({ if (Test-Path $script:LogFile) { Start-Process notepad.exe ('"{0}"' -f $script:LogFile) } })
    [void]$menu.Items.Add($miLog)

    $miDir = New-Object System.Windows.Forms.ToolStripMenuItem
    $miDir.Text = '打开应用目录'
    $miDir.add_Click({ Start-Process $script:AppDir })
    [void]$menu.Items.Add($miDir)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $miExit = New-Object System.Windows.Forms.ToolStripMenuItem
    $miExit.Text = '退出(关掉托盘和桌宠)'
    $miExit.add_Click({
            try { [void](Restore-EatenIcons -All) } catch { }
            try { Stop-Pet -Remember:$false } catch { }
            if ($script:TrayNotify) { $script:TrayNotify.Visible = $false; $script:TrayNotify.Dispose() }
            [System.Windows.Forms.Application]::Exit()
        })
    [void]$menu.Items.Add($miExit)

    return $menu
}

function New-StatusIcon {
    # 托盘图标:圆底 + 一个「宠」字(不依赖外部 ico,省得再塞二进制)
    param([string]$Kind)
    Add-Type -AssemblyName System.Drawing
    $c = switch ($Kind) {
        'pet' { [System.Drawing.Color]::FromArgb(70, 120, 220) }
        default { [System.Drawing.Color]::FromArgb(120, 120, 120) }
    }
    $bmp = [System.Drawing.Bitmap]::new(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse([System.Drawing.SolidBrush]::new($c), 2, 2, 28, 28)
    $g.DrawEllipse([System.Drawing.Pen]::new([System.Drawing.Color]::White, 2), 3, 3, 26, 26)
    try {
        $fnt = [System.Drawing.Font]::new('Microsoft YaHei', 13, [System.Drawing.FontStyle]::Bold)
    } catch {
        $fnt = [System.Drawing.Font]::new('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    }
    $g.DrawString('宠', $fnt, [System.Drawing.Brushes]::White, 4, 3)
    $g.Dispose()
    $fnt.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Invoke-Tray {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [void](Set-PetDpiAware)
    # 图标互动:读设置 + 把上次没还回去的图标先还了
    try {
        $sI = Get-Settings
        $script:IconPlay = [bool]$sI.iconPlay
        $script:IconAutoWander = [bool]$sI.iconWander
        $script:IconEatSeconds = [int]$sI.iconEatSec
        $script:IconReady = [bool]$sI.iconReady
        Import-IconState
        [void](Restore-EatenIcons)
    } catch { }

    # UI 回调抛异常只记日志,不要整个托盘退出
    try {
        [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
        [System.Windows.Forms.Application]::add_ThreadException({
                param($sender, $e)
                try { Write-Log ('托盘异常(已忽略,继续运行):' + $e.Exception.Message) 'WARN' } catch { }
            })
    } catch { }

    $mutex = New-Object System.Threading.Mutex($false, 'Local\DesktopPetTray')
    if (-not $mutex.WaitOne(0)) {
        Write-Log '托盘已经在运行了(单实例)' 'WARN'
        return
    }

    $script:Icons = @{ pet = New-StatusIcon 'pet'; gray = New-StatusIcon 'gray' }
    $script:TrayNotify = New-Object System.Windows.Forms.NotifyIcon
    $script:TrayNotify.Icon = $script:Icons['pet']
    $script:TrayNotify.Text = '桌面宠物'
    $script:TrayNotify.Visible = $true
    $script:TrayNotify.ContextMenuStrip = New-TrayMenu
    $script:TrayNotify.add_DoubleClick({ Show-PetMenuFromTray })

    $s = Get-Settings
    if ([bool]$s.pet -or $Force) { [void](Start-Pet) }
    Update-TrayText

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000
    $timer.add_Tick({ try { Sync-PetWithSettings; Update-TrayText; Restore-EatenIcons } catch { } })
    $timer.Start()

    Write-Log ('托盘已启动 v' + $script:AppVersion + '(模型 ' + $script:ModelId + '/' + $script:VariantId + ')') 'OK'
    [System.Windows.Forms.Application]::Run()

    try { $script:TrayNotify.Visible = $false; $script:TrayNotify.Dispose() } catch { }
}

# ================= 开机自启 =================
function Invoke-Install {
    if ([bool](Get-Settings).pet -eq $false) {
        $s = Get-Settings
        $s.pet = $true
        Save-Settings -Settings $s
    }
    $vbsLines = @(
        "' Auto-generated by DesktopPet.ps1 - launch hidden",
        'Set sh = CreateObject("WScript.Shell")',
        ('sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""' + $script:SelfScript + '"" -Mode run -Background", 0, True')
    )
    Set-Content -Path $script:VbsFile -Value $vbsLines -Encoding ASCII

    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//nologo "{0}"' -f $script:VbsFile)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    }
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Settings $taskSettings -Principal $principal -Description '桌面宠物(登录时自动启动)' | Out-Null

    Write-Log ('已安装开机自启(计划任务 ' + $script:TaskName + ')') 'OK'
    Write-Log ('  启动器:' + $script:VbsFile) 'OK'
    return $true
}

function Invoke-Uninstall {
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        try {
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
            Write-Log ('已卸载开机自启(计划任务 ' + $script:TaskName + ')') 'OK'
        } catch {
            Write-Log ('卸载计划任务失败:' + $_.Exception.Message) 'WARN'
        }
    } else {
        Write-Log '没有安装开机自启' 'WARN'
    }
    if (Test-Path $script:VbsFile) { Remove-Item $script:VbsFile -Force -ErrorAction SilentlyContinue }
    return $true
}

# ================= 桌面图标互动(吃掉 / 搬运 / 整理) =================
# 直接读写桌面 SysListView32 的图标位置(LVM_GETITEMPOSITION / LVM_SETITEMPOSITION),
# 跨进程要用 VirtualAllocEx + Read/WriteProcessMemory。
# 「自动排列图标」开着时位置会被 shell 弹回,所以动手前先测一下能不能挪:
# 挪不动就写注册表关掉它(FFlags bit0)并重启一次资源管理器 —— Windows 只认这一条路。
$script:DeskIconsCs = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace DeskPet {
    public static class DeskIcons {
        const int LVM_FIRST = 0x1000;
        const int LVM_GETITEMCOUNT = LVM_FIRST + 4;
        const int LVM_SETITEMPOSITION = LVM_FIRST + 15;
        const int LVM_GETITEMPOSITION = LVM_FIRST + 16;
        const int LVM_GETITEMSPACING = LVM_FIRST + 51;
        const int LVM_GETITEMTEXTW = LVM_FIRST + 115;
        const uint LVIF_TEXT = 0x1;
        const int PROCESS_VM_OPERATION = 0x8, PROCESS_VM_READ = 0x10, PROCESS_VM_WRITE = 0x20, PROCESS_QUERY_INFORMATION = 0x400;

        [StructLayout(LayoutKind.Sequential)]
        struct LVITEM {
            public uint mask; public int iItem; public int iSubItem; public uint state; public uint stateMask;
            public IntPtr pszText; public int cchTextMax; public int iImage; public IntPtr lParam;
            public int iIndent; public int iGroupId; public uint cColumns; public IntPtr puColumns; public IntPtr piColFmt; public int iGroup;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, uint pid);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, IntPtr size, int type, int protect);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool VirtualFreeEx(IntPtr h, IntPtr addr, IntPtr size, int type);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        public static IntPtr DefView = IntPtr.Zero;
        public static IntPtr ListView = IntPtr.Zero;

        public static IntPtr Find() {
            IntPtr progman = FindWindow("Progman", null);
            IntPtr dv = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (dv == IntPtr.Zero) {
                IntPtr w = IntPtr.Zero;
                while ((w = FindWindowEx(IntPtr.Zero, w, "WorkerW", null)) != IntPtr.Zero) {
                    dv = FindWindowEx(w, IntPtr.Zero, "SHELLDLL_DefView", null);
                    if (dv != IntPtr.Zero) break;
                }
            }
            DefView = dv;
            ListView = dv == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(dv, IntPtr.Zero, "SysListView32", null);
            return ListView;
        }

        public static int Count(IntPtr lv) { return (int)SendMessage(lv, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero); }

        public static int[] Spacing(IntPtr lv) {
            long v = SendMessage(lv, LVM_GETITEMSPACING, IntPtr.Zero, IntPtr.Zero).ToInt64();
            return new int[] { (int)(v & 0xFFFF), (int)((v >> 16) & 0xFFFF) };
        }

        static IntPtr OpenFor(IntPtr hwnd, out IntPtr proc) {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            proc = OpenProcess(PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_QUERY_INFORMATION, false, pid);
            return proc;
        }

        public static int[] Pos(IntPtr lv, int index) {
            IntPtr proc; OpenFor(lv, out proc);
            if (proc == IntPtr.Zero) return null;
            IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, (IntPtr)16, 0x3000, 0x04);
            if (mem == IntPtr.Zero) { CloseHandle(proc); return null; }
            try {
                SendMessage(lv, LVM_GETITEMPOSITION, (IntPtr)index, mem);
                byte[] buf = new byte[8]; IntPtr read;
                if (!ReadProcessMemory(proc, mem, buf, (IntPtr)8, out read)) return null;
                return new int[] { BitConverter.ToInt32(buf, 0), BitConverter.ToInt32(buf, 4) };
            } finally { VirtualFreeEx(proc, mem, IntPtr.Zero, 0x8000); CloseHandle(proc); }
        }

        public static void SetPos(IntPtr lv, int index, int x, int y) {
            // 不夹到屏幕内:吃掉图标要挪到可视区外;但 16 位消息只能表示 0..65535
            if (x < 0) x = 0;
            if (y < 0) y = 0;
            if (x > 30000) x = 30000;
            if (y > 30000) y = 30000;
            SendMessage(lv, LVM_SETITEMPOSITION, (IntPtr)index, (IntPtr)((y << 16) | (x & 0xFFFF)));
        }

        public static string Text(IntPtr lv, int index) {
            IntPtr proc; OpenFor(lv, out proc);
            if (proc == IntPtr.Zero) return "";
            IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, (IntPtr)4096, 0x3000, 0x04);
            if (mem == IntPtr.Zero) { CloseHandle(proc); return ""; }
            try {
                IntPtr itemPtr = mem;
                IntPtr textPtr = (IntPtr)(mem.ToInt64() + 1024);
                LVITEM it = new LVITEM();
                it.mask = LVIF_TEXT; it.iItem = index; it.iSubItem = 0;
                it.pszText = textPtr; it.cchTextMax = 512;
                int size = Marshal.SizeOf(typeof(LVITEM));
                IntPtr tmp = Marshal.AllocHGlobal(size);
                byte[] raw;
                try { Marshal.StructureToPtr(it, tmp, false); raw = new byte[size]; Marshal.Copy(tmp, raw, 0, size); }
                finally { Marshal.FreeHGlobal(tmp); }
                IntPtr written;
                WriteProcessMemory(proc, itemPtr, raw, (IntPtr)raw.Length, out written);
                SendMessage(lv, LVM_GETITEMTEXTW, (IntPtr)index, itemPtr);
                byte[] buf = new byte[1024]; IntPtr read;
                ReadProcessMemory(proc, textPtr, buf, (IntPtr)1024, out read);
                string s = Encoding.Unicode.GetString(buf);
                int z = s.IndexOf('\0');
                return z >= 0 ? s.Substring(0, z) : s;
            } finally { VirtualFreeEx(proc, mem, IntPtr.Zero, 0x8000); CloseHandle(proc); }
        }
    }
}
'@

function Initialize-DeskIcons {
    if (-not ('DeskPet.DeskIcons' -as [type])) {
        Add-Type -TypeDefinition $script:DeskIconsCs -Language CSharp
    }
    $lv = [DeskPet.DeskIcons]::ListView
    # 资源管理器重启过之后句柄会失效,得重新找
    if ($lv -eq [IntPtr]::Zero -or -not [DeskPet.DeskIcons]::IsWindow($lv)) { $lv = [DeskPet.DeskIcons]::Find() }
    $script:IconLv = $lv
    return $lv
}

function Get-DesktopIconList {
    # 返回 @{ Lv; Spacing; Icons = @(@{Index;Name;X;Y;W;H}) };拿不到桌面就返回 $null
    $lv = Initialize-DeskIcons
    if (-not $lv -or $lv -eq [IntPtr]::Zero) { return $null }
    $sp = [DeskPet.DeskIcons]::Spacing($lv)
    if (-not $sp -or $sp[0] -le 0 -or $sp[1] -le 0) { $sp = @(90, 100) }
    $n = [DeskPet.DeskIcons]::Count($lv)
    if ($n -le 0) { return $null }
    $list = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $n; $i++) {
        $pos = [DeskPet.DeskIcons]::Pos($lv, $i)
        if (-not $pos) { continue }
        $name = ''
        try { $name = [DeskPet.DeskIcons]::Text($lv, $i) } catch { }
        [void]$list.Add([pscustomobject]@{
                Index = $i; Name = $name; X = [int]$pos[0]; Y = [int]$pos[1]
                W = [int]$sp[0]; H = [int]$sp[1]
            })
    }
    if ($list.Count -eq 0) { return $null }
    return [pscustomobject]@{ Lv = $lv; Spacing = $sp; Icons = @($list) }
}

function Get-DesktopIconAt {
    param([int]$X, [int]$Y)
    $d = Get-DesktopIconList
    if (-not $d) { return $null }
    foreach ($ic in $d.Icons) {
        if ($X -ge $ic.X -and $X -lt ($ic.X + $ic.W) -and $Y -ge $ic.Y -and $Y -lt ($ic.Y + $ic.H)) {
            return [pscustomobject]@{ Icon = $ic; Data = $d }
        }
    }
    return $null
}

function Get-DesktopIconNearPet {
    # 宠物盖住的图标:先看中心点,再看矩形重叠
    $px = [int]($script:PetX + ($script:PetFrameW / 2))
    $py = [int]($script:PetY + ($script:PetFrameH / 2))
    $hit = Get-DesktopIconAt -X $px -Y $py
    if ($hit) { return $hit }
    $d = Get-DesktopIconList
    if (-not $d) { return $null }
    $x0 = [int]$script:PetX; $y0 = [int]$script:PetY
    $x1 = $x0 + [int]$script:PetFrameW; $y1 = $y0 + [int]$script:PetFrameH
    foreach ($ic in $d.Icons) {
        $ox = [Math]::Max($x0, $ic.X); $oy = [Math]::Max($y0, $ic.Y)
        $ex = [Math]::Min($x1, $ic.X + $ic.W); $ey = [Math]::Min($y1, $ic.Y + $ic.H)
        if ($ex - $ox -gt 12 -and $ey - $oy -gt 12) { return [pscustomobject]@{ Icon = $ic; Data = $d } }
    }
    return $null
}

function Test-IconMovable {
    # 试挪一个图标:只要位置变了就算能挪(桌面开着「对齐到网格」时坐标会被吸附,
    # 所以不能按精确坐标比,不然会误判成「挪不动」,白白重启一次资源管理器)
    param($Data)
    if (-not $Data -or $Data.Icons.Count -eq 0) { return $false }
    $p = $Data.Icons[0]
    $bx = [int]$p.X; $by = [int]$p.Y
    $tx = $bx + [Math]::Max(40, [int]$Data.Spacing[0])
    $ty = $by + [int]$Data.Spacing[1]
    [DeskPet.DeskIcons]::SetPos($Data.Lv, $p.Index, $tx, $ty)
    Start-Sleep -Milliseconds 300
    $after = [DeskPet.DeskIcons]::Pos($Data.Lv, $p.Index)
    $moved = ($after -and ([Math]::Abs($after[0] - $bx) -gt 12 -or [Math]::Abs($after[1] - $by) -gt 12))
    [DeskPet.DeskIcons]::SetPos($Data.Lv, $p.Index, $bx, $by)
    Start-Sleep -Milliseconds 150
    return $moved
}

function ConvertTo-IconGrid {
    # 把坐标吸附到图标网格(桌面开着「对齐到网格」时,不吸附就落不到你给的点上)
    param([int]$X, [int]$Y, [int]$Cw, [int]$Ch)
    if ($Cw -lt 20) { $Cw = 90 }
    if ($Ch -lt 20) { $Ch = 100 }
    $gx = [int][Math]::Round($X / $Cw) * $Cw
    $gy = [int][Math]::Round($Y / $Ch) * $Ch
    if ($gx -lt 0) { $gx = 0 }
    if ($gy -lt 0) { $gy = 0 }
    return @($gx, $gy)
}
function Enable-DesktopAutoArrangeOff {
    # 关掉「自动排列图标」:Windows 只认注册表里的 FFlags bit0,而且**必须重启一次资源管理器**才生效
    # (正在跑的 explorer 不会重读这个键,所以哪怕键里已经是关的,也得重启)。
    # 第一次问一句(任务栏会闪一下),之后记住不再问。
    param([switch]$Force, [switch]$NoDialog)
    $key = 'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
    $flags = 0x40200225
    try { $flags = [int](Get-ItemProperty -Path $key -ErrorAction Stop).FFlags } catch { }
    if (-not [bool]$script:IconReady -and -not $NoDialog) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $ans = [System.Windows.Forms.MessageBox]::Show(
                '桌面的「自动排列图标」现在是开着的,吃掉/搬运/整理图标都动不了。' + "`r`n`r`n" +
                '要关掉它吗?会重启一次资源管理器(任务栏闪一下,打开的文件夹窗口会关掉),图标位置保留。',
                '桌面宠物', 'YesNo', 'Question')
            if ($ans -ne 'Yes') { Write-Log '没关自动排列:图标互动这次跳过' 'WARN'; return $false }
        } catch { }
    }
    if (($flags -band 1) -ne 0) {
        try {
            Set-ItemProperty -Path $key -Name FFlags -Value ([int]($flags -band (-bnot 1))) -Type DWord
            Write-Log ('已把「自动排列图标」写为关闭(FFlags 0x{0:X8} → 0x{1:X8})' -f $flags, ($flags -band (-bnot 1))) 'WARN'
        } catch {
            Write-Log ('改注册表失败:' + $_.Exception.Message) 'WARN'
            return $false
        }
    } else {
        Write-Log '注册表里「自动排列图标」已经是关的,重启一次资源管理器让它生效' 'WARN'
    }
    try {
        if (Get-Process explorer -ErrorAction SilentlyContinue) { Stop-Process -Name explorer -Force -ErrorAction Stop }
        else { Start-Process explorer.exe }
    } catch { Write-Log ('重启资源管理器失败:' + $_.Exception.Message) 'WARN' }
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Milliseconds 500
        [DeskPet.DeskIcons]::ListView = [IntPtr]::Zero
        $lv = [DeskPet.DeskIcons]::Find()
        if ($lv -ne [IntPtr]::Zero) {
            $d2 = Get-DesktopIconList
            if ($d2 -and (Test-IconMovable -Data $d2)) {
                $script:IconReady = $true
                try { $sI = Get-Settings; $sI.iconReady = $true; [void](Save-Settings -Settings $sI) } catch { }
                Write-Log '「自动排列图标」已关闭,图标互动生效' 'OK'
                return $true
            }
        }
    }
    Write-Log '资源管理器重启了,但图标还是挪不动(可能被别的桌面工具接管了)' 'WARN'
    return $false
}
function Set-DesktopAutoArrangeOff {
    # 能挪动 → 自动排列本来就关着;挪不动 → 走注册表 + 重启资源管理器
    # (刚操作完桌面时 shell 可能还没排完,测两次再下结论,免得白重启一次 explorer)
    param($Data)
    if (-not $Data -or $Data.Icons.Count -eq 0) { return $false }
    for ($i = 0; $i -lt 3; $i++) {
        if (Test-IconMovable -Data $Data) { return $true }
        Start-Sleep -Milliseconds 250
        $Data = Get-DesktopIconList
        if (-not $Data) { return $false }
    }
    return (Enable-DesktopAutoArrangeOff)
}
function Get-DesktopFileMap {
    # 图标名 → 文件对象(拿时间和大小用);扩展名可能被隐藏,基名也进表
    $map = @{}
    $roots = @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:PUBLIC 'Desktop'))
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
            if (-not $map.ContainsKey($f.Name)) { $map[$f.Name] = $f }
            if ($f.BaseName -and -not $map.ContainsKey($f.BaseName)) { $map[$f.BaseName] = $f }
        }
    }
    return $map
}

function Save-DesktopIconLayout {
    param($Data, [string]$Tag = 'backup')
    if (-not $Data) { return }
    try {
        $rows = @($Data.Icons | ForEach-Object { [pscustomobject]@{ Name = $_.Name; X = $_.X; Y = $_.Y } })
        [System.IO.File]::WriteAllText($script:IconLayoutFn, ($rows | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
        Write-Log ('已记下桌面图标布局(' + $rows.Count + ' 个,' + $Tag + ')')
    } catch { }
}

function Read-IconLayoutFile {
    $rows = @()
    if (-not (Test-Path $script:IconLayoutFn)) { return $rows }
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($script:IconLayoutFn, [System.Text.Encoding]::UTF8) } catch { return $rows }
    $parsed = $null
    try { if ($raw) { $parsed = $raw | ConvertFrom-Json } } catch { }
    if ($null -eq $parsed) { return $rows }
    if ($parsed -is [System.Array]) { return @($parsed) }
    return @($parsed)
}

function Restore-DesktopIconLayout {
    $d = Get-DesktopIconList
    if (-not $d) { Write-Log '读不到桌面图标,没法恢复布局' 'WARN'; return $false }
    $rows = @(Read-IconLayoutFile)
    if ($rows.Count -eq 0) { Write-Log '没有可恢复的布局记录' 'WARN'; return $false }
    [void](Set-DesktopAutoArrangeOff -Data $d)
    $d = Get-DesktopIconList
    if (-not $d) { return $false }
    $apply = {
        param($Data)
        $n = 0
        foreach ($r in $rows) {
            $t = @($Data.Icons | Where-Object { [string]$_.Name -eq [string]$r.Name })[0]
            if ($t) { [DeskPet.DeskIcons]::SetPos($Data.Lv, $t.Index, [int]$r.X, [int]$r.Y); $n++ }
        }
        return $n
    }
    $n = & $apply $d
    Start-Sleep -Milliseconds 400
    # 校验一遍:没对齐的再补一次(shell 偶尔会把刚设的位置弹回去)
    $d2 = Get-DesktopIconList
    if ($d2) {
        $bad = 0
        foreach ($r in $rows) {
            $t = @($d2.Icons | Where-Object { [string]$_.Name -eq [string]$r.Name })[0]
            if ($t -and ([Math]::Abs($t.X - [int]$r.X) -gt 3 -or [Math]::Abs($t.Y - [int]$r.Y) -gt 3)) { $bad++ }
        }
        if ($bad -gt 0) {
            Write-Log ('有 ' + $bad + ' 个图标没对齐,再补一次') 'WARN'
            [void](& $apply $d2)
        }
    }
    Write-Log ('已恢复桌面图标布局(' + $n + ' / ' + $rows.Count + ' 个)') 'OK'
    return ($n -gt 0)
}
function Save-IconState {
    try {
        $obj = [pscustomobject]@{
            eaten = @($script:IconEaten | ForEach-Object { [pscustomobject]@{ Name = $_.Name; X = $_.X; Y = $_.Y; Due = $_.Due } })
        }
        [System.IO.File]::WriteAllText($script:IconStateFn, ($obj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Import-IconState {
    $script:IconEaten = @()
    if (-not (Test-Path $script:IconStateFn)) { return }
    try {
        $j = [System.IO.File]::ReadAllText($script:IconStateFn, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($j -and $j.eaten) { $script:IconEaten = @($j.eaten) }
    } catch { }
}

function Restore-EatenIcons {
    # 到点的(或被要求全部)把图标搬回原位;按名字找,图标索引可能变了
    param([switch]$All)
    if (-not $script:IconEaten -or $script:IconEaten.Count -eq 0) { return 0 }
    $d = Get-DesktopIconList
    if (-not $d) { return 0 }
    $now = Get-Date
    $keep = New-Object System.Collections.ArrayList
    $restored = 0
    foreach ($e in $script:IconEaten) {
        $due = [datetime]::MinValue
        try { $due = [datetime]::ParseExact([string]$e.Due, 'yyyy-MM-dd HH:mm:ss', $null) } catch { }
        if ($All -or ($due -ne [datetime]::MinValue -and $now -ge $due)) {
            $t = @($d.Icons | Where-Object { [string]$_.Name -eq [string]$e.Name })[0]
            if ($t) {
                [DeskPet.DeskIcons]::SetPos($d.Lv, $t.Index, [int]$e.X, [int]$e.Y)
                $restored++
                Write-Log ('图标已恢复:' + $e.Name) 'OK'
            }
        } else {
            [void]$keep.Add($e)
        }
    }
    $script:IconEaten = @($keep)
    Save-IconState
    return $restored
}

function Invoke-IconEat {
    # 吃掉 = 挪到屏幕外,到点(默认 180 秒)自己搬回来
    param($Icon, $Data)
    if (-not $Icon) { return $false }
    if ($script:IconEaten -and $script:IconEaten.Count -ge 1) {
        Write-Log '已经吃掉一个图标了,等它回原位再吃下一个'
        return $false
    }
    $d = Get-DesktopIconList
    if (-not $d) { return $false }
    if (-not (Set-DesktopAutoArrangeOff -Data $d)) { return $false }
    $d = Get-DesktopIconList
    if (-not $d) { return $false }
    $t = @($d.Icons | Where-Object { [string]$_.Name -eq [string]$Icon.Name })[0]
    if (-not $t) { return $false }
    $due = (Get-Date).AddSeconds([int]$script:IconEatSeconds)
    $script:IconEaten += [pscustomobject]@{ Name = $t.Name; X = [int]$t.X; Y = [int]$t.Y; Due = $due.ToString('yyyy-MM-dd HH:mm:ss'); Index = [int]$t.Index }
    Save-IconState
    # 屏幕外:先按网格推到右下角外面,ListView 一刷新就看不见了,但还在列表里
    $off = ConvertTo-IconGrid -X ($script:ScreenW + 4000) -Y ($script:ScreenH + 4000) -Cw ([int]$d.Spacing[0]) -Ch ([int]$d.Spacing[1])
    [DeskPet.DeskIcons]::SetPos($d.Lv, $t.Index, $off[0], $off[1])
    Write-Log ('图标互动:吃掉「' + $t.Name + '」,' + [int]$script:IconEatSeconds + ' 秒后回原位') 'OK'
    try { Show-PetSaying } catch { }
    return $true
}
function Invoke-IconCarry {
    # 搬运 = 关掉自动排列,把图标丢到一个随机位置(吸附到网格)
    param($Icon, $Data)
    if (-not $Icon) { return $false }
    $d = Get-DesktopIconList
    if (-not $d) { return $false }
    if (-not (Set-DesktopAutoArrangeOff -Data $d)) { return $false }
    $d = Get-DesktopIconList
    if (-not $d) { return $false }
    $t = @($d.Icons | Where-Object { [string]$_.Name -eq [string]$Icon.Name })[0]
    if (-not $t) { return $false }
    $cw = [int]$d.Spacing[0]; $ch = [int]$d.Spacing[1]
    $cols = [Math]::Max(1, [int][Math]::Floor($script:ScreenW / $cw))
    $rows = [Math]::Max(1, [int][Math]::Floor($script:ScreenH / $ch))
    $gx = (Get-Random -Minimum 0 -Maximum $cols) * $cw
    $gy = (Get-Random -Minimum 0 -Maximum $rows) * $ch
    [DeskPet.DeskIcons]::SetPos($d.Lv, $t.Index, $gx, $gy)
    Write-Log ('图标互动:把「' + $t.Name + '」搬到 (' + $gx + ',' + $gy + ')') 'OK'
    try { Show-PetSaying } catch { }
    return $true
}
function Invoke-IconTidy {
    # 整理 = 随机挑一种排法,按格子重排所有图标
    param($Data)
    $d = Get-DesktopIconList
    if (-not $d -or $d.Icons.Count -lt 2) { return $false }
    if (-not (Set-DesktopAutoArrangeOff -Data $d)) { return $false }
    $d = Get-DesktopIconList
    if (-not $d) { return $false }
    $fileMap = Get-DesktopFileMap
    $rows = foreach ($ic in $d.Icons) {
        $f = $fileMap[[string]$ic.Name]
        if (-not $f) { $base = [System.IO.Path]::GetFileNameWithoutExtension([string]$ic.Name); if ($base) { $f = $fileMap[$base] } }
        [pscustomobject]@{
            Index = $ic.Index; Name = $ic.Name
            Time  = $(if ($f) { $f.LastWriteTime } else { [datetime]::MinValue })
            Size  = $(if ($f) { $f.Length } else { 0 })
        }
    }
    $rows = @($rows)
    $methods = @('名称正序', '名称倒序', '时间正序', '时间倒序', '大小正序', '大小倒序')
    $method = $methods[(Get-Random -Maximum $methods.Count)]
    switch ($method) {
        '名称正序' { $rows = @($rows | Sort-Object Name) }
        '名称倒序' { $rows = @($rows | Sort-Object Name -Descending) }
        '时间正序' { $rows = @($rows | Sort-Object Time, Name) }
        '时间倒序' { $rows = @($rows | Sort-Object Time -Descending) }
        '大小正序' { $rows = @($rows | Sort-Object Size, Name) }
        '大小倒序' { $rows = @($rows | Sort-Object Size -Descending) }
    }
    $cw = [int]$d.Spacing[0]; $ch = [int]$d.Spacing[1]
    $margin = 8
    # 竖向排:先往下排满一列,再排右边一列
    $cols = [Math]::Max(1, [int][Math]::Floor(($script:ScreenW - $margin) / $cw))
    $rowsMax = [Math]::Max(1, [int][Math]::Floor(($script:ScreenH - $margin) / $ch))
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = $i % $rowsMax
        $col = [int][Math]::Floor($i / $rowsMax)
        if ($col -ge $cols) { break }
        $x = $margin + $col * $cw
        $y = $margin + $row * $ch
        [DeskPet.DeskIcons]::SetPos($d.Lv, $rows[$i].Index, $x, $y)
    }
    Write-Log ('图标互动:整理 ' + $rows.Count + ' 个图标,排法「' + $method + '」') 'OK'
    try { Show-PetSaying } catch { }
    return $true
}

function Invoke-IconManual {
    # 菜单里手动触发:默认对「宠物下面那个图标」动手;整理则对全部图标
    param([string]$Kind)
    $hit = Get-DesktopIconNearPet
    if (-not $hit -and $Kind -ne 'tidy') {
        Write-Log '宠物下面没有图标 —— 先把它拖到桌面图标上再点' 'WARN'
        return $false
    }
    if (-not $hit) {
        $d = Get-DesktopIconList
        if (-not $d) { Write-Log '读不到桌面图标列表' 'WARN'; return $false }
        $hit = [pscustomobject]@{ Icon = $d.Icons[0]; Data = $d }
    }
    [void](Save-DesktopIconLayout -Data $hit.Data -Tag 'manual')
    switch ($Kind) {
        'eat' { return (Invoke-IconEat -Icon $hit.Icon -Data $hit.Data) }
        'carry' { return (Invoke-IconCarry -Icon $hit.Icon -Data $hit.Data) }
        'tidy' { return (Invoke-IconTidy -Data $hit.Data) }
        'restore' { return ([bool](Restore-DesktopIconLayout)) }
        'all' { return ((Restore-EatenIcons -All) -gt 0) }
    }
    return $false
}

function Invoke-IconEventNearPet {
    # 宠物停在图标上时随机来一个事件;带冷却,避免一直折腾桌面
    param([string]$Source = 'drop', [int]$Chance = 100)
    if (-not [bool]$script:IconPlay) { return $false }
    $now = Get-Date
    if ($script:IconEventAt -ne [datetime]::MinValue -and ($now - $script:IconEventAt).TotalSeconds -lt 45) { return $false }
    if ($Source -eq 'wander' -and -not [bool]$script:IconAutoWander) { return $false }
    if ((Get-Random -Maximum 100) -ge $Chance) { return $false }
    $hit = Get-DesktopIconNearPet
    if (-not $hit) { return $false }
    [void](Save-DesktopIconLayout -Data $hit.Data -Tag 'touch')
    $script:IconEventAt = $now
    $pick = @('eat', 'carry', 'tidy')[(Get-Random -Maximum 3)]
    $ok = $false
    switch ($pick) {
        'eat' { $ok = Invoke-IconEat -Icon $hit.Icon -Data $hit.Data }
        'carry' { $ok = Invoke-IconCarry -Icon $hit.Icon -Data $hit.Data }
        'tidy' { $ok = Invoke-IconTidy -Data $hit.Data }
    }
    return $ok
}

# ================= 控制台 / 后台进程探测 =================
function Get-ConsoleWindowHandle {
    # 有没有一个「看得见的」控制台窗口(隐藏进程里也挂着控制台,所以必须看可见性)
    if (-not ('DeskPet.Win32' -as [type])) {
        try {
            $cs = @'
using System;
using System.Runtime.InteropServices;
namespace DeskPet {
    public static class Win32 {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    }
}
'@
            Add-Type -TypeDefinition $cs -Language CSharp
        } catch { }
    }
    try {
        $h = [DeskPet.Win32]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        if (-not [DeskPet.Win32]::IsWindowVisible($h)) { return [IntPtr]::Zero }
        return $h
    } catch { return [IntPtr]::Zero }
}

function Get-PetAppProcess {
    # 已经在跑的「托盘 + 桌宠」本体(-Mode run,隐藏进程)
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.ProcessId -ne $PID -and $p.CommandLine -match 'DesktopPet\.ps1' -and $p.CommandLine -match '\-Mode\s+run\b') {
            return $p
        }
    }
    return $null
}

function Start-DetachedPet {
    # 起一个隐藏的后台本体;控制台只是启动器,关掉不影响它
    return (Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList (
            '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode run -Background' -f $script:SelfScript))
}

# ================= 主流程 =================
[void](Set-PetDpiAware)
    # 图标互动:读设置 + 把上次没还回去的图标先还了
    try {
        $sI = Get-Settings
        $script:IconPlay = [bool]$sI.iconPlay
        $script:IconAutoWander = [bool]$sI.iconWander
        $script:IconEatSeconds = [int]$sI.iconEatSec
        $script:IconReady = [bool]$sI.iconReady
        Import-IconState
        [void](Restore-EatenIcons)
    } catch { }

$s0 = Get-Settings
if (-not $Model -and $s0.model) { $Model = [string]$s0.model }
if (-not $Variant -and $s0.variant) { $Variant = [string]$s0.variant }
if ($Model) { $script:ModelId = $Model }
if ($Variant) { $script:VariantId = $Variant }
$current = Resolve-PetModel
# 第一次跑(models 里只有一个包)也要把选择写进 settings,否则菜单里的勾对不上
if ($current -and ([string]$s0.model -ne $script:ModelId -or [string]$s0.variant -ne $script:VariantId)) {
    $s0.model = $script:ModelId
    $s0.variant = $script:VariantId
    [void](Save-Settings -Settings $s0)
}

switch ($Mode) {
    'selftest' {
        # 自检:不用真开窗口也能验证「模型能列出来 / 菜单勾对 / 配色矩阵真的上色了 / 切换能落盘」
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $fail = 0
        Write-Log '--- selftest ---'
        if (-not ('DeskPet.Layered' -as [type])) {
            Add-Type -TypeDefinition $script:LayeredCs -Language CSharp -ReferencedAssemblies System.Drawing
        }

        $models = @(Get-PetModels)
        Write-Log ('模型: ' + $models.Count + ' 套配色')
        if ($models.Count -eq 0) { $fail++ }

        $menu = New-PetMenu
        Write-Log ('菜单顶层: ' + ((@($menu.Items | Where-Object { $_.Text } | ForEach-Object { $_.Text })) -join ' | '))
        $miModel = @($menu.Items | Where-Object { $_.Text -eq '模型' })[0]
        if (-not $miModel) {
            $fail++
            Write-Log '菜单里没有「模型」' 'WARN'
        } else {
            $items = @($miModel.DropDownItems | Where-Object { $_.Text } | ForEach-Object { $_.Text + $(if ($_.Checked) { '[√]' } else { '' }) })
            Write-Log ('模型子菜单: ' + ($items -join ' | '))
            $checked = @($miModel.DropDownItems | Where-Object { $_.Checked }).Count
            Write-Log ('  打勾项数: ' + $checked + ' (应为 1)')
            if ($checked -ne 1) { $fail++ }
        }

        # 每套配色解一帧,算不透明像素的平均色 —— 配色矩阵生效的话数字应该各不相同
        $seen = @{}
        foreach ($m in $models) {
            $script:ModelId = $m.Id
            $script:VariantId = $m.Variant
            $script:PetManifest = $null
            $null = Resolve-PetModel
            $fr = Get-PetFrames -Anim 'idle' -Scale 1.0
            if (-not $fr) { Write-Log ('  ' + $m.Label + ': 帧读不出来') 'WARN'; $fail++; continue }
            $avg = '?'
            try {
                # 用真正要贴到屏幕的那张 HBITMAP,拷进 32bpp 位图后按 LockBits 采样
                # (GetHbitmap 出来的位图不能直接 GetPixel,会抛 GDI+ 通用错误)
                $src = [System.Drawing.Image]::FromHbitmap($fr.Hbs[0])
                $b32 = New-Object System.Drawing.Bitmap -ArgumentList $fr.W, $fr.H, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $g = [System.Drawing.Graphics]::FromImage($b32)
                $g.DrawImage($src, 0, 0, $fr.W, $fr.H)
                $g.Dispose(); $src.Dispose()
                $rect = New-Object System.Drawing.Rectangle -ArgumentList 0, 0, $fr.W, $fr.H
                $data = $b32.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                try {
                    $bytes = New-Object byte[] ($data.Stride * $data.Height)
                    [void][System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
                    $rr = 0L; $gg = 0L; $bb = 0L; $n = 0L
                    for ($i = 0; $i -lt $bytes.Length; $i += 16) {
                        if ($bytes[$i + 3] -lt 128) { continue }
                        $bb += $bytes[$i]; $gg += $bytes[$i + 1]; $rr += $bytes[$i + 2]; $n++
                    }
                    if ($n -gt 0) { $avg = ('R{0} G{1} B{2}' -f [int]($rr / $n), [int]($gg / $n), [int]($bb / $n)) }
                } finally { $b32.UnlockBits($data) }
                $b32.Dispose()
            } catch { Write-Log ('  平均色取样失败:' + $_.Exception.Message) 'WARN' }
            Write-Log ('  ' + $m.Label.PadRight(24) + ' ' + $fr.W + 'x' + $fr.H + ' ' + $fr.Count + ' 帧  平均色 ' + $avg)
            if ($avg -eq '?') { $fail++ }
            elseif ($seen.ContainsKey($avg)) { Write-Log ('  ⚠ ' + $m.Label + ' 和 ' + $seen[$avg] + ' 平均色一样,配色可能没生效') 'WARN'; $fail++ }
            else { $seen[$avg] = $m.Label }
        }

        # 切到第二套配色,确认写盘 + 目录跟着换
        if ($models.Count -gt 1) {
            $target = $models[1]
            $ok = Set-PetModel -Id $target.Id -Variant $target.Variant
            $saved = Get-Settings
            Write-Log ('切换测试: ' + $target.Label + ' → 返回 ' + $ok + ' , settings 里 model=' + $saved.model + ' variant=' + $saved.variant)
            if (-not $ok -or [string]$saved.model -ne $target.Id -or [string]$saved.variant -ne $target.Variant) { $fail++ }
            # 切回原样,别把用户的选择改掉
            $null = Set-PetModel -Id $models[0].Id -Variant $models[0].Variant
        }

        if ($fail -eq 0) { Write-Log 'selftest: 全部通过' 'OK'; exit 0 }
        Write-Log ('selftest: ' + $fail + ' 项失败') 'ERROR'
        exit 1
    }

    'list' {
        $models = @(Get-PetModels)
        if ($models.Count -eq 0) {
            Write-Log ('models 目录里没有模型包:' + $script:ModelsDir) 'ERROR'
            exit 2
        }
        Write-Log ('模型包目录:' + $script:ModelsDir)
        foreach ($m in $models) {
            $mark = $(if ($m.Id -eq $script:ModelId -and $m.Variant -eq $script:VariantId) { '  ← 当前' } else { '' })
            $frames = @(Get-ChildItem -LiteralPath $m.Dir -Directory | Where-Object { $_.Name -ne 'memes' })
            Write-Log ('  ' + $m.Id + ' / ' + $m.Variant + '  ' + $m.Label + '  (' + $frames.Count + ' 个动作)' + $mark)
        }
        exit 0
    }

    'install' {
        if (-not $script:PetDir) { Write-Log '没有模型包,先放一个到 models/' 'ERROR'; exit 2 }
        [void](Invoke-Install)
        if (-not $NoTray) {
            try { Start-ScheduledTask -TaskName $script:TaskName; Write-Log '已启动' 'OK' } catch { }
        }
        exit 0
    }

    'uninstall' {
        [void](Invoke-Uninstall)
        foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
            if ($p.ProcessId -ne $PID -and $p.CommandLine -match 'DesktopPet\.ps1' -and $p.CommandLine -match '\-Mode\s+run') {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Log ('已停止托盘 pid=' + $p.ProcessId) 'OK' } catch { }
            }
        }
        exit 0
    }

    'weather' {
        $w = Update-PetWeather
        if ($w -and $w.ok) {
            $line = [string]$w.text + ' ' + [string]$w.temp + '°C'
            if ($w.place) { $line += ' · ' + [string]$w.place }
            if ($w.dressing) { $line += ' · ' + [string]$w.dressing }
            Write-Log ($line + '  [' + [string]$w.source + ']') 'OK'
            exit 0
        }
        Write-Log '拿不到天气(没网或被拦)' 'WARN'
        exit 1
    }

    'launch' {
        # 双击 start.bat 用的入口:本体起成一个隐藏进程,这个窗口只是「启动器」,
        # 关掉它不会连带关掉宠物(Windows 关控制台 = 直接杀进程,拦不住,所以只能分进程)
        if (Get-PetAppProcess) {
            Write-Log ('桌面宠物已经在托盘里运行了(右下角「宠」图标),不用重复启动') 'OK'
        } else {
            $null = Start-DetachedPet
            Start-Sleep -Milliseconds 1600
            Write-Log ('已启动:托盘图标 + 桌宠   日志:' + $script:LogFile) 'OK'
        }
        Write-Log ''
        Write-Log '  右键右下角「宠」图标:切换模型 / 显示或隐藏宠物 / 开机自启 / 退出'
        Write-Log '  关掉这个窗口不影响宠物运行(本体在后台,由托盘图标控制)'
        Write-Log ''
        exit 0
    }

    'pet' {
        if (-not (Start-Pet)) { exit 1 }
        $s = Get-Settings
        $s.pet = $true
        [void](Save-Settings -Settings $s)
        Write-Log ('宠物素材来自 ' + $(if ($script:PetUrl) { $script:PetUrl } else { 'models/' + $script:ModelId })) 'OK'
        Write-Log '右键小宠物有菜单;这个窗口关掉就退出' 'OK'
        [System.Windows.Forms.Application]::Run()
        exit 0
    }

    default {
        # 直接运行脚本(控制台里)时:先把自己转成一个隐藏的后台进程,再退出控制台。
        # 否则用户点控制台右上角 ✕,Windows 直接把进程杀掉,宠物和托盘一起没 ——
        # 关控制台这个事件是拦不住的(控制台窗口归 conhost/终端所有,进程里收不到可取消的通知)。
        if (-not $Background -and -not $NoTray -and (Get-ConsoleWindowHandle) -ne [IntPtr]::Zero) {
            if (Get-PetAppProcess) {
                Write-Log '桌面宠物已经在托盘里运行了(右下角「宠」图标)' 'OK'
            } else {
                $null = Start-DetachedPet
                Start-Sleep -Milliseconds 1400
                Write-Log '桌面宠物已转到托盘运行(右下角「宠」图标),这个窗口可以关掉' 'OK'
            }
            exit 0
        }
        if ($NoTray) {
            if (-not (Start-Pet)) { exit 1 }
            [System.Windows.Forms.Application]::Run()
            exit 0
        }
        Invoke-Tray
    }
}
