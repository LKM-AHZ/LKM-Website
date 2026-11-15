# ============================================================
#  LKM 后端开发服务器启动脚本
#
#  同一份脚本适用于 Windows PowerShell 5.1 与 PowerShell 7+ (pwsh, Linux/macOS)。
#  原 dev.bat 的参数解析已并入本文件, 不再需要 .bat 包装。
#
#  用法:
#    pwsh ./dev.ps1                 # 启动 AUTH 进程 (:8001) 与业务后端 (:8000)
#    pwsh ./dev.ps1 back            # 同上; back/all 保留为等价写法
#    pwsh ./dev.ps1 --no-run        # 仅安装后端依赖
#    pwsh ./dev.ps1 back --no-run   # 仅安装后端依赖
#    pwsh ./dev.ps1 --help          # 显示用法
#
#  Windows 上受执行策略限制时:
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\dev.ps1 back
#
#  兼容性约定:
#    - 只用 PS5.1 也能解析的语法 (不用 ?: / ?? / -Parallel), 否则 Windows 自带的 5.1 跑不起来;
#    - 路径一律用 Join-Path/Split-Path 组合, 不硬编码 \ 或 /, 以适配 Linux/macOS;
#    - 本文件须以 UTF-8 带 BOM 保存, 否则 PS5.1 下中文会乱码。
# ============================================================

try {
    # 输出被重定向(管道/CI)时设置控制台编码可能失败, 不应因此挡住启动
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
}

$RootDir    = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RootDir)) { $RootDir = (Get-Location).Path }
$BackDir    = Join-Path $RootDir "LKM-service"
$ScriptsDir = Join-Path $RootDir "scripts"

function Write-Log {
    # 用 [Console] 直接写终端, 即使被管道/重定向捕获也可见(Write-Host 不会进管道)。
    param([string]$Msg)
    [Console]::WriteLine("[lkm] " + $Msg)
}

function Show-Usage {
    [Console]::WriteLine("用法: dev.ps1 [模式] [--no-run]")
    [Console]::WriteLine("")
    [Console]::WriteLine("  模式: back (默认) | all, 也可写 后端")
    [Console]::WriteLine("")
    [Console]::WriteLine("  dev.ps1                 # 启动 AUTH (:8001) 与后端 (:8000)")
    [Console]::WriteLine("  dev.ps1 back            # 同上; back/all 等价")
    [Console]::WriteLine("  dev.ps1 --no-run        # 仅安装后端依赖")
    [Console]::WriteLine("  dev.ps1 back --no-run   # 仅安装后端依赖")
    [Console]::WriteLine("")
    [Console]::WriteLine("  旧写法 -Mode back -NoRun 仍然可用。")
}

function Exit-UsageError {
    param([string]$Message)
    [Console]::Error.WriteLine("[lkm:error] " + $Message)
    [Console]::Error.WriteLine("用法: dev.ps1 [all|back|后端] [--no-run] [--help]")
    exit 2
}

function ConvertTo-Mode {
    # 位置参数与 -Mode 取值共用; 未知取值返回 $null。
    param([string]$Value)
    switch ($Value.ToLowerInvariant()) {
        "all"   { return "all" }
        "back"  { return "back" }
        "后端"  { return "back" }
        default { return $null }
    }
}

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine("[lkm:error] 未找到命令 '$Name'，请先安装。")
        exit 1
    }
}

function Get-Port {
    param([string]$Name, [int]$Default)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    $port = 0
    if (-not [int]::TryParse($value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        [Console]::Error.WriteLine("[lkm:error] $Name 必须是 1–65535 之间的端口号（当前: $value）。")
        exit 2
    }
    return $port
}

function Install-Back {
    Write-Log "安装后端依赖 (uv sync) ..."
    [Console]::WriteLine("")
    Push-Location $BackDir
    try { & uv sync } finally { Pop-Location }
}

# ---------- 参数解析 ----------
# 不用 param() 块: 旧 dev.bat 是以位置参数转发的(`back`、`--no-run`), 而 param() 会把
# `--no-run` 当成未声明的命名参数直接报错退出。这里统一解析 $args, 同时兼容旧文档里的
# `-Mode back -NoRun` 写法。
$Mode     = "back"
$NoRun    = $false
$ShowHelp = $false
$ModeSeen = $false

$index = 0
while ($index -lt $args.Count) {
    $arg   = [string]$args[$index]
    $lower = $arg.ToLowerInvariant()
    $candidate = $null

    if ($lower -eq "--help" -or $lower -eq "-h" -or $lower -eq "-?" -or $lower -eq "help") {
        $ShowHelp = $true
        break
    }
    elseif ($lower -eq "--no-run" -or $lower -eq "-norun") {
        $NoRun = $true
    }
    elseif ($lower -eq "-mode" -or $lower -eq "--mode") {
        $index++
        if ($index -ge $args.Count) { Exit-UsageError "参数 -Mode 缺少取值。" }
        $candidate = [string]$args[$index]
    }
    elseif ($lower -like "-mode:*" -or $lower -like "--mode:*") {
        $candidate = $arg.Substring($arg.IndexOf(":") + 1)
    }
    else {
        $candidate = $arg
    }

    if ($null -ne $candidate) {
        # 先判「是不是合法模式」: 否则 `back --bogus` 会报成「只能指定一个启动模式」,
        # 真正的问题是 --bogus 写错了。
        $resolved = ConvertTo-Mode $candidate
        if ($null -eq $resolved) { Exit-UsageError ("未知参数: " + $candidate) }
        if ($ModeSeen) { Exit-UsageError "只能指定一个启动模式。" }
        $Mode = $resolved
        $ModeSeen = $true
    }
    $index++
}

if ($ShowHelp) { Show-Usage; exit 0 }

Write-Log ("项目根目录: " + $RootDir)
Write-Log ("模式       : " + $Mode)
[Console]::WriteLine()

# ---------- 前置检查 ----------
# 先查命令和子模块, 再校验端口, 最后才装依赖: 配置写错时不必等 uv 跑完。
if ($Mode -eq "all" -or $Mode -eq "back") {
    Require-Command "uv"
    if (-not (Test-Path -LiteralPath (Join-Path $BackDir "pyproject.toml"))) {
        [Console]::Error.WriteLine("[lkm:error] 后端子模块未初始化: $BackDir")
        exit 1
    }
}

# --no-run 不监听端口, 与 dev.sh 一致跳过端口校验。
if (-not $NoRun) {
    $BackPort = Get-Port "BACKEND_PORT" 8000
}

# ---------- 依赖 ----------
if ($Mode -eq "all" -or $Mode -eq "back") {
    Install-Back
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("[lkm:error] 后端依赖安装失败。"); exit 1 }
}
[Console]::WriteLine()
Write-Log "依赖就绪。"
if ($NoRun) { exit 0 }

# ---------- 数据库 ----------
# 先确认能连上(错连/未启动时报错更直白), 再建 schema。
# 注意: 这两步不要包进函数里取值 —— 原生命令的 stdout 会变成函数返回值,
# 退出码判断就被日志行污染了(实测会让 $LASTEXITCODE 变成字符串数组)。
if ($Mode -eq "back" -or $Mode -eq "all") {
    $dbStatus = 0
    Push-Location $BackDir
    try {
        & uv run python (Join-Path $ScriptsDir "check_dev_db.py")
        $dbStatus = $LASTEXITCODE
        if ($dbStatus -eq 0) {
            Write-Log "准备业务库与认证库 schema ..."
            & uv run python (Join-Path $ScriptsDir "prepare_dev_db.py")
            $dbStatus = $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
    if ($dbStatus -ne 0) { exit $dbStatus }
}

# ---------- 开发密钥与内部缝 ----------
# 密钥补齐逻辑与 dev.sh 共用 scripts/prepare_dev_secrets.py: 已有环境变量或
# LKM-service/.env 配置时不改动, 只为缺失项生成值 (JWT 密钥对写入 deploy/jwt/keys)。
Write-Log "准备开发密钥（缺失时自动生成）..."
$secretJson = $null
Push-Location $BackDir
try {
    $secretJson = (& uv run python (Join-Path $ScriptsDir "prepare_dev_secrets.py") --json) -join "`n"
    $secretStatus = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($secretStatus -ne 0) {
    [Console]::Error.WriteLine("[lkm:error] 生成开发密钥失败。")
    exit 1
}
if (-not [string]::IsNullOrWhiteSpace($secretJson)) {
    $secrets = $secretJson | ConvertFrom-Json
    foreach ($name in $secrets.PSObject.Properties.Name) {
        [Environment]::SetEnvironmentVariable($name, [string]$secrets.$name)
    }
}

# 双形态退役后 auth 是后端的硬依赖: 注入内部缝地址/令牌 (与 dev.sh 默认值一致)。
if ([string]::IsNullOrWhiteSpace($env:LKM_AUTH_HTTP_URL)) {
    $env:LKM_AUTH_HTTP_URL = "http://127.0.0.1:8001"
}
if ([string]::IsNullOrWhiteSpace($env:LKM_AUTH_HTTP_TOKEN)) {
    $env:LKM_AUTH_HTTP_TOKEN = "dev-internal-auth-token-change-me-32chars"
}

# ---------- 启动两个进程 ----------
# 任一进程退出即整体退出并沿用其退出码, 与 dev.sh 一致。
# Windows 用 taskkill /T 杀进程树; Unix 递归 pgrep。uv 若先于 python 退出,
# 孙进程回收是尽力而为 (Ctrl+C 时同一控制台进程组已收到信号)。
function Stop-ProcessTree {
    param([int]$ProcessId)
    if ($env:OS -eq "Windows_NT") {
        & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
        return
    }
    $children = & pgrep -P $ProcessId 2>$null
    foreach ($child in $children) {
        if ($child) { Stop-ProcessTree -ProcessId ([int]$child) }
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

$Uv = (Get-Command "uv").Source
if ([string]::IsNullOrWhiteSpace($Uv)) { $Uv = "uv" }
$AuthProc = $null
$BackProc = $null
$ExitCode = 0
try {
    Write-Log "启动 AUTH 进程: python -m auth.main (8001)"
    $AuthProc = Start-Process -FilePath $Uv -ArgumentList @("run", "python", "-m", "auth.main") `
        -WorkingDirectory $BackDir -PassThru -NoNewWindow
    Write-Log "启动后端: uvicorn main:app --reload --port $BackPort"
    [Console]::WriteLine()
    $BackProc = Start-Process -FilePath $Uv `
        -ArgumentList @("run", "uvicorn", "main:app", "--reload", "--port", "$BackPort") `
        -WorkingDirectory $BackDir -PassThru -NoNewWindow

    while (-not $AuthProc.HasExited -and -not $BackProc.HasExited) {
        Start-Sleep -Milliseconds 500
    }
    if ($BackProc.HasExited) { $ExitCode = $BackProc.ExitCode } else { $ExitCode = $AuthProc.ExitCode }
}
finally {
    $running = @($AuthProc, $BackProc) | Where-Object { $null -ne $_ -and -not $_.HasExited }
    if ($running.Count -gt 0) { Write-Log "收到退出信号，正在停止..." }
    foreach ($proc in @($AuthProc, $BackProc)) {
        if ($null -eq $proc) { continue }
        if (-not $proc.HasExited) { Stop-ProcessTree -ProcessId $proc.Id }
        $proc.WaitForExit(5000) | Out-Null
    }
}
exit $ExitCode
