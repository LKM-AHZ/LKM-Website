# ============================================================
#  LKM 后端开发服务器启动脚本
#
#  同一份脚本适用于 Windows PowerShell 5.1 与 PowerShell 7+ (pwsh, Linux/macOS)。
#  原 dev.bat 的参数解析已并入本文件, 不再需要 .bat 包装。
#
#  用法:
#    pwsh ./dev.ps1                 # 启动后端
#    pwsh ./dev.ps1 back            # 仅后端 (uvicorn, :8000)
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
    [Console]::WriteLine("  dev.ps1                 # 启动后端")
    [Console]::WriteLine("  dev.ps1 back            # 仅后端 (uvicorn, :8000)")
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

# ---------- 后端开发密钥 ----------
# 后端为 RS256-only(无 HS256 对称降级): 签发/验签需 RSA 密钥对, 另需 TOTP/pepper 两个对称密钥;
# 非测试环境还会强制校验密钥强且非默认。若未通过环境变量(或 .env)提供, 这里自动生成开发用值并注入,
# 让一键启动即可跑通; 已有配置时则不改动。
function New-RandomSecret {
    param([int]$Length = 64)
    $chars = 65..90 + 97..122 + 48..57   # A-Z a-z 0-9
    # 必须用 CSPRNG: Get-Random 是 System.Random(时间种子, 可预测); 而且 -Count 去重后
    # 字符池只有 62 个, 要 64 位根本凑不齐(会静默返回 62 位, 与 DEPLOYMENT.md 的
    # 「64 位以上随机串」不符)。
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { [char]$chars[$_ % $chars.Count] })
}

# 后端只读取 LKM-service/.env（工作目录为 LKM-service），进程环境变量优先级更高。
# 不应把根目录用于 Docker Compose 的 .env 误认为后端配置。
$BackEnv = Join-Path $BackDir ".env"

function Test-EnvFileHasKey {
    # 后端 .env 里存在未被注释的 `KEY=非空值` 行即返回 true
    param([string]$Key)
    if (-not (Test-Path -LiteralPath $BackEnv)) { return $false }
    if (Select-String -LiteralPath $BackEnv -Pattern ("^\s*" + [regex]::Escape($Key) + "\s*=\s*\S") -Quiet) {
        return $true
    }
    return $false
}

# 为后端生成开发密钥。
if ($Mode -eq "back" -or $Mode -eq "all") {
    # RS256 密钥对(必填前置): 未在 env/.env 指定文件路径时, 用 openssl 生成到 deploy/jwt/keys。
    if ([string]::IsNullOrWhiteSpace($env:LKM_JWT_PRIVATE_KEY_FILE) -and
        [string]::IsNullOrWhiteSpace($env:LKM_JWT_PUBLIC_KEY_FILE) -and
        -not (Test-EnvFileHasKey "LKM_JWT_PRIVATE_KEY_FILE") -and
        -not (Test-EnvFileHasKey "LKM_JWT_PUBLIC_KEY_FILE")) {
        $KeyDir   = Join-Path (Join-Path $RootDir "deploy") "jwt"
        $KeyDir   = Join-Path $KeyDir "keys"
        $PrivFile = Join-Path $KeyDir "jwt-private.pem"
        $PubFile  = Join-Path $KeyDir "jwt-public.pem"
        $hasPrivate = Test-Path -LiteralPath $PrivFile
        $hasPublic  = Test-Path -LiteralPath $PubFile
        if ($hasPrivate -xor $hasPublic) {
            [Console]::Error.WriteLine("[lkm:error] 开发密钥对只存在一半: $KeyDir。请检查后再重新生成，避免误轮换。")
            exit 1
        }
        if (-not $hasPrivate) {
            Require-Command "openssl"
            New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
            $tmpPrivate = Join-Path $KeyDir ("jwt-private." + [guid]::NewGuid().ToString("N") + ".tmp")
            $tmpPublic  = Join-Path $KeyDir ("jwt-public." + [guid]::NewGuid().ToString("N") + ".tmp")
            try {
                & openssl genrsa -out $tmpPrivate 2048 2>$null
                if ($LASTEXITCODE -ne 0) { throw "openssl genrsa 失败" }
                & openssl rsa -in $tmpPrivate -pubout -out $tmpPublic 2>$null
                if ($LASTEXITCODE -ne 0) { throw "openssl rsa -pubout 失败" }
                Move-Item -LiteralPath $tmpPrivate -Destination $PrivFile
                Move-Item -LiteralPath $tmpPublic -Destination $PubFile
            } catch {
                Remove-Item -LiteralPath $PrivFile, $PubFile -ErrorAction SilentlyContinue
                [Console]::Error.WriteLine("[lkm:error] 生成开发密钥对失败: " + $_)
                exit 1
            } finally {
                Remove-Item -LiteralPath $tmpPrivate, $tmpPublic -ErrorAction SilentlyContinue
            }
            Write-Log "已为开发环境生成 RS256 密钥对(deploy/jwt/keys)。"
        }
        # 绝对路径, 免 uvicorn 以 LKM-service 为 CWD 时相对路径解析到错处
        $env:LKM_JWT_PRIVATE_KEY_FILE = $PrivFile
        $env:LKM_JWT_PUBLIC_KEY_FILE  = $PubFile
    }
    if ([string]::IsNullOrWhiteSpace($env:LKM_TOTP_ENCRYPTION_KEY) -and
        -not (Test-EnvFileHasKey "LKM_TOTP_ENCRYPTION_KEY")) {
        $env:LKM_TOTP_ENCRYPTION_KEY = New-RandomSecret 64
        Write-Log "已为开发环境生成 LKM_TOTP_ENCRYPTION_KEY。"
    }
    if ([string]::IsNullOrWhiteSpace($env:LKM_VERIFICATION_CODE_PEPPER) -and
        -not (Test-EnvFileHasKey "LKM_VERIFICATION_CODE_PEPPER")) {
        $env:LKM_VERIFICATION_CODE_PEPPER = New-RandomSecret 64
        Write-Log "已为开发环境生成 LKM_VERIFICATION_CODE_PEPPER。"
    }
}

Write-Log "启动后端: uvicorn main:app --reload --port $BackPort"
[Console]::WriteLine()
Set-Location $BackDir
& uv run uvicorn main:app --reload --port $BackPort
exit $LASTEXITCODE
