# ============================================================
#  LKM 统一开发服务器启动脚本 (单窗口并发实时日志)
#
#  用法 (由 dev.bat 转调, 也可直接运行):
#    powershell -NoProfile -ExecutionPolicy Bypass -File dev.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File dev.ps1 -Mode front   # 仅 SSR 前端
#    powershell -NoProfile -ExecutionPolicy Bypass -File dev.ps1 -Mode back    # 仅后端
#    powershell -NoProfile -ExecutionPolicy Bypass -File dev.ps1 -Mode back -NoRun # 仅安装后端依赖
#
#  注意: 本文件须以 UTF-8 带 BOM 保存, 否则 PS5.1 中文会乱码。
# ============================================================

param(
    [ValidateSet("all", "front", "back")]
    [string]$Mode = "all",
    [switch]$NoRun
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RootDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrontDir  = Join-Path $RootDir "LKM-official-website"
$BackDir   = Join-Path $RootDir "LKM-service"

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

function Write-Log {
    # 用 [Console] 直接写终端, 即使被管道/重定向捕获也可见(Write-Host 不会进管道)。
    param([string]$Msg)
    [Console]::WriteLine("[lkm] " + $Msg)
}

function Install-Front {
    # 只负责执行并保持 $LASTEXITCODE 有效, 不返回任何对象,
    # 避免 pnpm 的 stdout 被当作返回值污染上层判断。
    Write-Log "安装前端依赖 (pnpm install) ..."
    [Console]::WriteLine("")
    Push-Location $FrontDir
    try { & pnpm install } finally { Pop-Location }
}

function Install-Back {
    Write-Log "安装后端依赖 (uv sync) ..."
    [Console]::WriteLine("")
    Push-Location $BackDir
    try { & uv sync } finally { Pop-Location }
}

Write-Log ("项目根目录: " + $RootDir)
Write-Log ("模式       : " + $Mode)
[Console]::WriteLine()

# ---------- 依赖 ----------
# 只装本次真会启动的服务所需依赖。
if ($Mode -eq "all" -or $Mode -eq "front") {
    Require-Command "pnpm"
    if (-not (Test-Path -LiteralPath (Join-Path $FrontDir "package.json"))) {
        [Console]::Error.WriteLine("[lkm:error] 前端子模块未初始化: $FrontDir")
        exit 1
    }
    Install-Front
    if ($LASTEXITCODE -ne 0) { [Console]::WriteLine("[lkm:error] 前端依赖安装失败。"); exit 1 }
}
if ($Mode -eq "all" -or $Mode -eq "back") {
    Require-Command "uv"
    if (-not (Test-Path -LiteralPath (Join-Path $BackDir "pyproject.toml"))) {
        [Console]::Error.WriteLine("[lkm:error] 后端子模块未初始化: $BackDir")
        exit 1
    }
    Install-Back
    if ($LASTEXITCODE -ne 0) { [Console]::WriteLine("[lkm:error] 后端依赖安装失败。"); exit 1 }
}
[Console]::WriteLine()
Write-Log "依赖就绪。"
if ($NoRun) { exit 0 }

if ($Mode -ne "back") { $FrontPort = Get-Port "FRONT_PORT" 4321 }
if ($Mode -ne "front") { $BackPort = Get-Port "BACKEND_PORT" 8000 }

if ($Mode -ne "front") {
    Push-Location $BackDir
    try { & uv run python (Join-Path $RootDir "scripts\check_dev_db.py") } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
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

# 仅需后端时(back 或 all)才生成后端密钥; front 不起后端, 不生成。
if ($Mode -ne "front") {
    # RS256 密钥对(必填前置): 未在 env/.env 指定文件路径时, 用 openssl 生成到 deploy/jwt/keys。
    if ([string]::IsNullOrWhiteSpace($env:LKM_JWT_PRIVATE_KEY_FILE) -and
        [string]::IsNullOrWhiteSpace($env:LKM_JWT_PUBLIC_KEY_FILE) -and
        -not (Test-EnvFileHasKey "LKM_JWT_PRIVATE_KEY_FILE") -and
        -not (Test-EnvFileHasKey "LKM_JWT_PUBLIC_KEY_FILE")) {
        $KeyDir = Join-Path $RootDir "deploy\jwt\keys"
        $PrivFile = Join-Path $KeyDir "jwt-private.pem"
        $PubFile  = Join-Path $KeyDir "jwt-public.pem"
        $hasPrivate = Test-Path -LiteralPath $PrivFile
        $hasPublic = Test-Path -LiteralPath $PubFile
        if ($hasPrivate -xor $hasPublic) {
            [Console]::Error.WriteLine("[lkm:error] 开发密钥对只存在一半: $KeyDir。请检查后再重新生成，避免误轮换。")
            exit 1
        }
        if (-not $hasPrivate) {
            Require-Command "openssl"
            New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
            $tmpPrivate = Join-Path $KeyDir ("jwt-private." + [guid]::NewGuid().ToString("N") + ".tmp")
            $tmpPublic = Join-Path $KeyDir ("jwt-public." + [guid]::NewGuid().ToString("N") + ".tmp")
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
            Write-Log "已为开发环境生成 RS256 密钥对(deploy\jwt\keys)。"
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

# ---------- 仅前端 / 仅后端: 前台运行 ----------
if ($Mode -eq "front") {
    Write-Log "启动 SSR 前端: pnpm run dev --port $FrontPort"
    [Console]::WriteLine()
    Set-Location $FrontDir
    & pnpm run dev --port $FrontPort
    exit $LASTEXITCODE
}
if ($Mode -eq "back") {
    Write-Log "启动后端: uvicorn main:app --reload --port $BackPort"
    [Console]::WriteLine()
    Set-Location $BackDir
    & uv run uvicorn main:app --reload --port $BackPort
    exit $LASTEXITCODE
}

# ---------- 同时启动: 两个后台作业, 实时交错打印日志 ----------
Write-Log "同时启动 SSR 前端与后端(单窗口实时交错日志)。"
[Console]::WriteLine()
Write-Log "停止: 在本窗口按 Ctrl+C 即可同时结束全部服务。"

# 先声明为 $null: 作业创建也必须放进 try —— 若第 2 个 Start-Job 失败
# (Start-Job 报错、PSRemoting/WSMan 不可用等), 已启动的作业及其孙进程
# (pnpm/node、uv/uvicorn)就没人收尾, 4321/8000 端口会一直被占。
$frontJob = $null
$backJob  = $null
$exitCode = 0

try {
    $frontJob = Start-Job -Name "lkm-frontend" -ScriptBlock {
        param($dir, $port)
        Set-Location $dir
        # 2>&1 把 stderr 也并入输出流, 确保日志可被收到
        & pnpm run dev --port $port *>&1
        if ($LASTEXITCODE -ne 0) { throw "前端退出码: $LASTEXITCODE" }
    } -ArgumentList $FrontDir, $FrontPort -ErrorAction Stop

    $backJob = Start-Job -Name "lkm-backend" -ScriptBlock {
        param($dir, $port)
        Set-Location $dir
        & uv run uvicorn main:app --reload --port $port *>&1
        if ($LASTEXITCODE -ne 0) { throw "后端退出码: $LASTEXITCODE" }
    } -ArgumentList $BackDir, $BackPort -ErrorAction Stop

    # 简单取个别名便于在下面循环里打 tag
    $frontJobTag = "lkm-frontend"
    $backJobTag  = "lkm-backend"

    # 失败只播报一次: 状态不会回到 Running, 每 200ms 重打一遍会把窗口刷爆
    $reportedFailed = @{}

    # 持续消费两个任务的输出并实时打印; 消费式(不带 -Keep)天然去重
    while ($true) {
        foreach ($job in @($frontJob, $backJob)) {
            $tag = switch ($job.Name) {
                $frontJobTag { "前端" }
                $backJobTag  { "后端" }
            }
            # 任务的 stderr 已在脚本块里用 *>&1 并入输出流, 这里只消费 stdout 即可。
            # 原来那段 -ErrorVariable err + $err 循环是死代码(Receive-Job 几乎不会写错误流),
            # 留着只会让人以为错误另有出口。
            Receive-Job $job | ForEach-Object {
                [Console]::WriteLine("[" + $tag + "] " + $_)
            }
            if ($job.State -eq "Failed" -and -not $reportedFailed[$tag]) {
                $reportedFailed[$tag] = $true
                # 连失败原因一起打: 只报作业名等于没说
                $reason = $job.ChildJobs[0].JobStateInfo.Reason
                [Console]::WriteLine("[" + $tag + "][failed] " + $job.Name + ": " + $reason)
            }
        }
        # 任一服务结束就停止另一服务，避免留下半套环境。
        if (($frontJob.State -in @("Completed", "Failed", "Stopped")) -or
            ($backJob.State -in @("Completed", "Failed", "Stopped"))) {
            if ($frontJob.State -eq "Failed" -or $backJob.State -eq "Failed") { $exitCode = 1 }
            break
        }
        Start-Sleep -Milliseconds 200
    }
}
catch {
    [Console]::Error.WriteLine("[lkm:error] 启动失败: " + $_)
    $exitCode = 1
}
finally {
    [Console]::WriteLine()
    Write-Log "退出中, 正在停止全部服务(前端/后端)..."
    # 只收尾真正起来了的作业($null 的跳过): 作业创建失败时 finally 同样可达
    $jobs = @($frontJob, $backJob) | Where-Object { $_ }
    if ($jobs) {
        Stop-Job $jobs -ErrorAction SilentlyContinue
        Remove-Job $jobs -Force -ErrorAction SilentlyContinue
    }
    Write-Log "已停止。"
}
exit $exitCode
