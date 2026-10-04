<#
.SYNOPSIS
  WSL Bootstrap: WSL 预发行版 + virtiofs/mirrored 配置 + Ubuntu + VLESS 出口/黑洞 kill-switch + Firefox。

.DESCRIPTION
  在普通（非管理员）PowerShell 中运行；需要管理员权限的步骤会单独弹出 UAC。
  双击 install.cmd 即可。

.EXAMPLE
  .\install.ps1
  .\install.ps1 -Distro Ubuntu-26.04 -Name Ubuntu-Egress -Location D:\WSL\Ubuntu-Egress
#>
[CmdletBinding()]
param(
  [string]$Distro,
  [string]$Name,
  [string]$Location,
  [switch]$SkipUpdate,
  [switch]$SkipWslConfig,
  [switch]$Plain
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$LinuxDir = Join-Path $Here 'linux'
$MinWsl = [version]'2.9.0'
$Stage = '/opt/wsl-bootstrap'

$Catalog = @(
  @{ Id = 'Ubuntu-26.04'; Label = 'Ubuntu 26.04 LTS'; Hint = '推荐'; Disabled = $false }
  @{ Id = 'Ubuntu-24.04'; Label = 'Ubuntu 24.04 LTS'; Hint = '';             Disabled = $false }
  @{ Id = 'Debian';       Label = 'Debian';           Hint = '即将支持';     Disabled = $true }
)

# ------------------------------------------------------------------ console UI
$script:StepNo = 0
function Write-Step([string]$Text) {
  $script:StepNo++
  Write-Host ''
  Write-Host ("==> [{0}] {1}" -f $script:StepNo, $Text) -ForegroundColor Cyan
}
function Write-Ok([string]$Text)   { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "    $Text" -ForegroundColor Gray }
function Write-Warn([string]$Text) { Write-Host "    [!] $Text" -ForegroundColor Yellow }
function Fail([string]$Text) { throw $Text }

function Test-Interactive { -not $Plain -and -not [Console]::IsInputRedirected }

# Arrow-key menu (Up/Down/1-9, Enter, Esc). Items: @{ Label; Hint; Disabled }
function Select-Option([string]$Title, [object[]]$Items, [int]$Default = 0) {
  Write-Host ''
  Write-Host "  $Title" -ForegroundColor White
  if (-not (Test-Interactive)) {
    for ($i = 0; $i -lt $Items.Count; $i++) {
      $mark = if ($i -eq $Default) { ' (默认)' } else { '' }
      Write-Host ("    {0}) {1}  {2}{3}" -f ($i + 1), $Items[$i].Label, $Items[$i].Hint, $mark)
    }
    while ($true) {
      $ans = Read-Host '  选择'
      if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
      $n = 0
      if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count -and -not $Items[$n - 1].Disabled) { return $n - 1 }
    }
  }
  Write-Host '  (↑/↓ 选择，回车确认，Esc 取消)' -ForegroundColor DarkGray
  $idx = $Default
  $draw = {
    for ($i = 0; $i -lt $Items.Count; $i++) {
      $it = $Items[$i]
      $prefix = if ($i -eq $idx) { '  > ' } else { '    ' }
      $color = if ($it.Disabled) { 'DarkGray' } elseif ($i -eq $idx) { 'Cyan' } else { 'Gray' }
      $hint = if ($it.Hint) { "  ($($it.Hint))" } else { '' }
      Write-Host "$prefix$($it.Label)$hint" -ForegroundColor $color
    }
  }
  & $draw
  $top = [Console]::CursorTop - $Items.Count
  $cursor = [Console]::CursorVisible
  [Console]::CursorVisible = $false
  try {
    while ($true) {
      $k = [Console]::ReadKey($true)
      switch ($k.Key) {
        'UpArrow'   { $idx = ($idx - 1 + $Items.Count) % $Items.Count }
        'DownArrow' { $idx = ($idx + 1) % $Items.Count }
        'Escape'    { Fail '已取消' }
        'Enter'     { if (-not $Items[$idx].Disabled) { return $idx } }
        default {
          $n = [int]$k.KeyChar - [int][char]'0'
          if ($n -ge 1 -and $n -le $Items.Count) { $idx = $n - 1 }
        }
      }
      [Console]::SetCursorPosition(0, $top)
      & $draw
    }
  } finally {
    [Console]::CursorVisible = $cursor
  }
}

function Read-Value([string]$Prompt, [string]$Default) {
  $ans = Read-Host ("  {0} [{1}]" -f $Prompt, $Default)
  if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
  return $ans.Trim()
}

function Confirm-Choice([string]$Prompt, [bool]$DefaultYes = $true) {
  $hint = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
  $ans = Read-Host "  $Prompt [$hint]"
  if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultYes }
  return $ans -match '^[Yy]'
}

# ------------------------------------------------------------------ wsl.exe
# Native stderr must not become a terminating error under PS 5.1.
function Invoke-WslCapture([string[]]$WslArgs) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & wsl.exe @WslArgs 2>&1 | ForEach-Object { "$_" }
    $script:WslExit = $LASTEXITCODE
    return (($out -join "`n") -replace "`0", '')
  } finally {
    $ErrorActionPreference = $old
  }
}

# Windows argv quoting (CommandLineToArgvW rules).
function ConvertTo-ArgString([string[]]$ArgList) {
  ($ArgList | ForEach-Object {
    if ($_ -eq '') { '""' }
    elseif ($_ -notmatch '[\s"]') { $_ }
    else { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
  }) -join ' '
}

# Interactive passthrough: wsl.exe inherits this console, so the Linux TUI
# (whiptail) gets a real terminal. Calling it with & inside a function whose
# result is captured would turn its stdout into a pipe.
function Invoke-Wsl([string[]]$WslArgs) {
  $p = Start-Process -FilePath 'wsl.exe' -ArgumentList (ConvertTo-ArgString $WslArgs) -NoNewWindow -Wait -PassThru
  return $p.ExitCode
}

function Get-WslVersion {
  $out = Invoke-WslCapture @('--version')
  if ($script:WslExit -ne 0) { return $null }
  if ($out -match '(\d+\.\d+\.\d+(\.\d+)?)') { return [version]$Matches[1] }
  return $null
}

function Get-Distros {
  $out = Invoke-WslCapture @('--list', '--quiet')
  if ($script:WslExit -ne 0) { return @() }
  return @($out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-RunningDistros {
  $out = Invoke-WslCapture @('--list', '--running', '--quiet')
  if ($script:WslExit -ne 0) { return @() }
  return @($out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Start-Elevated([string]$File, [string]$Arguments) {
  $p = Start-Process -FilePath $File -ArgumentList $Arguments -Verb RunAs -Wait -PassThru
  return $p.ExitCode
}

# ------------------------------------------------------------------ .wslconfig
# Merge keys into an INI file, keeping everything else (comments, other keys).
function Merge-Ini([string[]]$Lines, [hashtable]$Wanted) {
  $out = New-Object System.Collections.Generic.List[string]
  $section = ''
  $done = @{}
  $flush = {
    param($sec)
    if ($Wanted.ContainsKey($sec)) {
      # Insert before the section's trailing blank lines.
      $blank = 0
      while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1); $blank++ }
      foreach ($k in $Wanted[$sec].Keys) {
        if (-not $done.ContainsKey("$sec.$k")) { $out.Add("$k=$($Wanted[$sec][$k])"); $done["$sec.$k"] = 1 }
      }
      for ($b = 0; $b -lt $blank; $b++) { $out.Add('') }
    }
  }
  foreach ($line in $Lines) {
    if ($line -match '^\s*\[(.+?)\]\s*$') {
      & $flush $section
      $section = $Matches[1].ToLower()
      $out.Add($line)
      continue
    }
    if ($line -match '^\s*([A-Za-z0-9_.]+)\s*=' -and $Wanted.ContainsKey($section)) {
      $key = $Matches[1]
      $hit = $Wanted[$section].Keys | Where-Object { $_ -ieq $key } | Select-Object -First 1
      if ($hit) {
        if (-not $done.ContainsKey("$section.$hit")) { $out.Add("$hit=$($Wanted[$section][$hit])"); $done["$section.$hit"] = 1 }
        continue
      }
    }
    $out.Add($line)
  }
  & $flush $section
  foreach ($sec in $Wanted.Keys) {
    $missing = @($Wanted[$sec].Keys | Where-Object { -not $done.ContainsKey("$sec.$_") })
    if ($missing.Count -gt 0) {
      $hasSection = $Lines | Where-Object { $_ -match "^\s*\[$sec\]\s*$" }
      if (-not $hasSection) {
        if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '') { $out.Add('') }
        $out.Add("[$sec]")
        foreach ($k in $missing) { $out.Add("$k=$($Wanted[$sec][$k])") }
      }
    }
  }
  return $out.ToArray()
}

function Set-WslConfig([bool]$Mirrored) {
  $path = Join-Path $env:USERPROFILE '.wslconfig'
  $lines = @()
  if (Test-Path $path) { $lines = @(Get-Content -LiteralPath $path -Encoding UTF8) }

  $ramGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  $cpus = [Environment]::ProcessorCount
  Write-Note "本机内存 ${ramGB}GB，逻辑处理器 $cpus 个"
  $mem = Read-Value 'WSL 内存上限' ("{0}GB" -f [math]::Max(2, [math]::Floor($ramGB / 2)))
  $cpu = Read-Value 'WSL 处理器数' "$cpus"
  $swap = Read-Value 'swap 大小' '8GB'

  # virtio/hostFileSystemAccess/virtiofs: /mnt/* over virtiofs instead of 9p
  # (much faster Windows-drive I/O; needs a recent pre-release WSL).
  $wsl2 = [ordered]@{
    virtio               = 'true'
    hostFileSystemAccess = 'true'
    virtiofs             = 'true'
    memory               = $mem
    processors           = $cpu
    swap                 = $swap
    ipv6                 = 'false'
  }
  if ($Mirrored) {
    $wsl2['networkingMode'] = 'mirrored'
    # dnsTunneling 绕过 TUN 把查询交给 Windows  autoProxy 把 Windows 代理注入环境变量
    $wsl2['dnsTunneling'] = 'false'
    $wsl2['autoProxy'] = 'false'
  }
  $wanted = @{ 'wsl2' = $wsl2; 'experimental' = [ordered]@{ autoMemoryReclaim = 'gradual' } }
  $new = Merge-Ini $lines $wanted

  Write-Host ''
  Write-Host "  将写入 $path :" -ForegroundColor White
  $new | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkCyan }
  if (-not (Confirm-Choice '确认写入？' $true)) { Write-Warn '跳过 .wslconfig'; return $false }
  if (Test-Path $path) {
    $bak = "$path.bak-{0:yyyyMMdd-HHmmss}" -f (Get-Date)
    Copy-Item -LiteralPath $path -Destination $bak
    Write-Note "原文件已备份: $bak"
  }
  # No BOM: WSL would not recognize the first [section] header.
  [IO.File]::WriteAllText($path, (($new -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
  Write-Ok '.wslconfig 已更新'
  return $true
}

function Get-GpuHint {
  try {
    $names = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name } | Where-Object { $_ })
  } catch { $names = @() }
  $vendor = 'auto'
  foreach ($v in 'NVIDIA', 'AMD', 'Intel') {
    if ($names | Where-Object { $_ -match $v -or ($v -eq 'AMD' -and $_ -match 'Radeon') }) { $vendor = $v; break }
  }
  return @{ Names = ($names -join ', '); Vendor = $vendor }
}

# ------------------------------------------------------------------ main
function Main {
  Clear-Host
  Write-Host ''
  Write-Host '  ╔══════════════════════════════════════════════════════╗' -ForegroundColor Cyan
  Write-Host '  ║  WSL Bootstrap                                       ║' -ForegroundColor Cyan
  Write-Host '  ║  WSL 预发行版 · virtiofs · VLESS 出口 · 黑洞防泄露   ║' -ForegroundColor Cyan
  Write-Host '  ╚══════════════════════════════════════════════════════╝' -ForegroundColor Cyan

  if (-not (Test-Path (Join-Path $LinuxDir 'setup.sh'))) { Fail "找不到 $LinuxDir\setup.sh，请在完整的项目目录中运行" }
  if (-not (Test-Path (Join-Path $LinuxDir 'bin\wsl-egress'))) { Fail "缺少 linux\bin\wsl-egress。先在 WSL 中于项目根目录运行: zig build -Drelease=true -p linux" }

  $build = [Environment]::OSVersion.Version.Build
  $mirrored = $build -ge 22621
  if ($build -lt 19041) { Fail "Windows 版本过旧 (build $build)，WSL2 需要 Windows 10 2004 (19041) 以上" }
  if (-not $mirrored) { Write-Warn "Windows build $build 不支持 mirrored 网络（需 Windows 11 22H2+），将使用 NAT 模式" }

  # 1. WSL itself
  Write-Step '检查 WSL'
  $ver = Get-WslVersion
  if (-not $ver) {
    Write-Warn '未安装 WSL（或仍是系统内置的旧版存根）'
    if (-not (Confirm-Choice '现在启用 WSL？（需要管理员权限，完成后需重启）' $true)) { Fail '已取消' }
    $rc = Start-Elevated 'wsl.exe' '--install --no-distribution'
    if ($rc -ne 0) { Fail "wsl --install 失败 (exit $rc)" }
    $runOnce = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    Set-ItemProperty -Path $runOnce -Name 'WslBootstrap' -Value ('cmd.exe /c "{0}"' -f (Join-Path $Here 'install.cmd'))
    Write-Ok 'WSL 已启用。重启后会自动继续安装。'
    if (Confirm-Choice '立即重启？' $false) { Restart-Computer }
    return
  }
  Write-Ok "当前 WSL $ver"

  if (-not $SkipUpdate) {
    Write-Step '更新到 WSL 预发行版 (wsl --update --pre-release)'
    Write-Note '需要管理员权限，请在 UAC 弹窗中确认'
    $rc = Start-Elevated 'wsl.exe' '--update --pre-release'
    if ($rc -ne 0) { Write-Warn "更新返回 $rc（可能已是最新）" }
    $ver = Get-WslVersion
    Write-Ok "WSL $ver"
  }
  if (-not $ver) { Fail '无法读取 WSL 版本（wsl --version 失败）' }
  if ($ver -lt $MinWsl) { Write-Warn "WSL $ver 低于已验证版本 $MinWsl，virtiofs 可能不可用" }

  # 2. .wslconfig
  $needShutdown = $false
  if (-not $SkipWslConfig) {
    Write-Step '配置 .wslconfig（virtiofs 磁盘访问、mirrored 网络、资源上限）'
    $needShutdown = Set-WslConfig $mirrored
  }

  # 3. distro choice
  Write-Step '选择发行版'
  if (-not $Distro) {
    $i = Select-Option '要安装的 Linux 发行版' $Catalog 0
    $Distro = $Catalog[$i].Id
  }
  $entry = $Catalog | Where-Object { $_.Id -eq $Distro }
  if ($entry -and $entry.Disabled) { Fail "$Distro 暂未支持" }

  $existing = Get-Distros
  if (-not $Name) {
    $Name = $Distro
    $n = 2
    while ($existing -contains $Name) { $Name = "$Distro-$n"; $n++ }
    $Name = Read-Value '实例名称' $Name
  }
  if ($existing -contains $Name) { Fail "已存在名为 $Name 的发行版。换个名字，或先 wsl --unregister $Name" }
  if (-not $Location) {
    $defRoot = if (Test-Path 'D:\') { 'D:\WSL' } else { Join-Path $env:LOCALAPPDATA 'WSL' }
    $Location = Read-Value '虚拟磁盘存放位置' (Join-Path $defRoot $Name)
  }

  # 4. apply .wslconfig before the new distro boots
  if ($needShutdown) {
    $running = Get-RunningDistros
    if ($running.Count -gt 0) {
      Write-Warn ("以下发行版正在运行，应用 .wslconfig 需要 wsl --shutdown: {0}" -f ($running -join ', '))
      if (Confirm-Choice '现在关闭所有 WSL 发行版？' $true) { Invoke-WslCapture @('--shutdown') | Out-Null; Write-Ok '已关闭' }
      else { Write-Warn '.wslconfig 将在下次 wsl --shutdown 后生效（网络探测可能与最终环境不同）' }
    } else {
      Invoke-WslCapture @('--shutdown') | Out-Null
    }
  }

  Write-Step "安装 $Distro → $Name"
  Write-Note "位置: $Location"
  New-Item -ItemType Directory -Force -Path $Location | Out-Null
  $rc = Invoke-Wsl @('--install', $Distro, '--name', $Name, '--location', $Location, '--no-launch')
  if ($rc -ne 0) {
    Write-Warn "安装失败 (exit $rc)，改用 --web-download 重试"
    $rc = Invoke-Wsl @('--install', $Distro, '--name', $Name, '--location', $Location, '--no-launch', '--web-download')
    if ($rc -ne 0) { Fail "发行版安装失败 (exit $rc)" }
  }
  if (-not ((Get-Distros) -contains $Name)) { Fail "安装后未找到发行版 $Name" }
  Write-Ok "$Name 已安装"

  # 5. stage the Linux side (strip CRs in case of a CRLF checkout)
  Write-Step '复制安装脚本到发行版'
  $null = Invoke-WslCapture @('-d', $Name, '-u', 'root', '--exec', 'rm', '-rf', $Stage)
  $null = Invoke-WslCapture @('-d', $Name, '-u', 'root', '--exec', 'mkdir', '-p', $Stage)
  $out = Invoke-WslCapture @('-d', $Name, '-u', 'root', '--cd', $LinuxDir, '--exec', 'cp', '-r', '.', $Stage)
  if ($script:WslExit -ne 0) { Fail "复制失败: $out" }
  # bin/ 和离线包是二进制 去 CR 会损坏
  $null = Invoke-WslCapture @('-d', $Name, '-u', 'root', '--exec', 'find', $Stage, '-type', 'f', '-not', '-path', "$Stage/bin/*", '-not', '-name', '*.tar.gz', '-exec', 'sed', '-i', 's/\r$//', '{}', '+')
  Write-Ok "$Stage"

  # 6. Linux configure (interactive TUI)
  Write-Step 'Linux 端配置（交互界面）'
  $gpu = Get-GpuHint
  $setupArgs = @('-d', $Name, '-u', 'root', '--exec', 'bash', "$Stage/setup.sh", 'configure',
    '--win-user', $env:USERNAME, '--gpu-vendor', $gpu.Vendor)
  if ($gpu.Names) { $setupArgs += @('--gpu-hint', $gpu.Names) }
  if ($Plain) { $setupArgs += '--plain' }
  $rc = Invoke-Wsl $setupArgs
  if ($rc -eq 3) { Fail "$Distro 暂未支持" }
  if ($rc -ne 0) { Fail "Linux 配置阶段失败 (exit $rc)。发行版已保留，可删除后重试: wsl --unregister $Name" }

  # 7. restart so wsl.conf (systemd, default user, resolv.conf) takes effect
  Write-Step "重启 $Name 以启用 systemd / wsl.conf"
  $null = Invoke-WslCapture @('--terminate', $Name)
  $state = Invoke-WslCapture @('-d', $Name, '-u', 'root', '--exec', 'systemctl', 'is-system-running', '--wait')
  Write-Ok "systemd: $($state.Trim())"

  # 8. finalize: tunnel up, then everything else goes through it
  Write-Step '建立出口隧道并完成安装'
  $finalArgs = @('-d', $Name, '-u', 'root', '--exec', 'bash', "$Stage/setup.sh", 'finalize')
  if ($Plain) { $finalArgs += '--plain' }
  $rc = Invoke-Wsl $finalArgs
  if ($rc -ne 0) { Fail "完成阶段失败 (exit $rc)。修复后可重跑: wsl -d $Name -u root bash $Stage/setup.sh finalize" }

  Write-Host ''
  if (Confirm-Choice "把 $Name 设为默认发行版？" $true) {
    $null = Invoke-WslCapture @('--set-default', $Name)
    Write-Ok "默认发行版: $Name"
  }
  Write-Host ''
  Write-Host "  全部完成。进入: wsl -d $Name" -ForegroundColor Green
  Write-Host '  注意: kill-switch 作用于整个 WSL VM（所有发行版与 docker-desktop 共享网络栈）。' -ForegroundColor Yellow
}

try {
  Main
} catch {
  Write-Host ''
  Write-Host "  ✘ $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
