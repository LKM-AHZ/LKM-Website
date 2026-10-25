# ============================================================
#  LKM 统一开发服务器启动脚本 (单窗口并发实时日志)
#
#  同一份脚本适用于 Windows PowerShell 5.1 与 PowerShell 7+ (pwsh, Linux/macOS)。
#  原 dev.bat 的参数解析已并入本文件, 不再需要 .bat 包装。
#
#  用法:
#    pwsh ./dev.ps1                 # 启动全部: SSR 前端 + 后端
#    pwsh ./dev.ps1 front           # 仅 SSR 前端 (Astro, :4321)
#    pwsh ./dev.ps1 back            # 仅后端 (uvicorn, :8000)
#    pwsh ./dev.ps1 --no-run        # 仅安装全部依赖
#    pwsh ./dev.ps1 back --no-run   # 仅安装后端依赖
#    pwsh ./dev.ps1 --help          # 显示用法
#
#  Windows 上受执行策略限制时:
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\dev.ps1 front
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

# PS6+ 才有 $IsLinux/$IsWindows; PS5.1 上取不到, 视作 Windows。
$OnLinux = [bool](Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue)
$OnWindows = $true
$platformVar = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
if ($null -ne $platformVar) { $OnWindows = [bool]$platformVar }

$RootDir    = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RootDir)) { $RootDir = (Get-Location).Path }
$FrontDir   = Join-Path $RootDir "LKM-official-website"
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
    [Console]::WriteLine("  模式: all (默认) | front | back, 也可写 前端 / 后端")
    [Console]::WriteLine("")
    [Console]::WriteLine("  dev.ps1                 # 启动全部: SSR 前端 + 后端")
    [Console]::WriteLine("  dev.ps1 front           # 仅 SSR 前端 (Astro, :4321)")
    [Console]::WriteLine("  dev.ps1 back            # 仅后端 (uvicorn, :8000)")
    [Console]::WriteLine("  dev.ps1 --no-run        # 仅安装全部依赖")
    [Console]::WriteLine("  dev.ps1 back --no-run   # 仅安装后端依赖")
    [Console]::WriteLine("")
    [Console]::WriteLine("  旧写法 -Mode front -NoRun 仍然可用。")
}

function Exit-UsageError {
    param([string]$Message)
    [Console]::Error.WriteLine("[lkm:error] " + $Message)
    [Console]::Error.WriteLine("用法: dev.ps1 [all|front|back|前端|后端] [--no-run] [--help]")
    exit 2
}

function ConvertTo-Mode {
    # 位置参数与 -Mode 取值共用; 未知取值返回 $null。
    param([string]$Value)
    switch ($Value.ToLowerInvariant()) {
        "all"   { return "all" }
        "front" { return "front" }
        "back"  { return "back" }
        "前端"  { return "front" }
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

function Initialize-FrontEnvironment {
    # 只影响前端进程, 但必须在子进程/作业创建前设置。
    if ([string]::IsNullOrWhiteSpace($env:ASTRO_DEV_BACKGROUND)) {
        # Astro 7 检测到 AI agent 环境会自动 fork 到后台, 脱离本脚本的收尾逻辑;
        # 显式置 0 可保持前台运行, 保证 Ctrl+C 能一起停掉(与 dev.sh 一致)。
        $env:ASTRO_DEV_BACKGROUND = "0"
    }
    if ($OnLinux -and [string]::IsNullOrWhiteSpace($env:CHOKIDAR_USEPOLLING)) {
        # Linux 桌面常由 IDE/浏览器占满 inotify 配额, Vite 随后以 ENOSPC 退出。
        # 只在 Linux 且用户未显式设置时改为轮询。
        $env:CHOKIDAR_USEPOLLING = "1"
        Write-Log "Linux 前端文件监视使用轮询（CHOKIDAR_USEPOLLING=1）。"
    }
}

# ---------- 收尾: 结束整棵进程树 ----------
# 为什么不用 Stop-Job / Remove-Job 收尾: 按 Ctrl+C 时父进程已进入「管道停止」状态,
# 这类要等作业状态事件的 cmdlet 会永久阻塞(pwsh 7.6/Linux 上实测 Stop-Job 与
# $job.StopJob() 都卡死, 而它等的作业宿主早就被终端信号结束了)。
# 因此这里只按 PID 结束进程树, 完全不依赖作业状态。
function Get-ProcessTreeIds {
    # 返回 root 及其全部后代 PID(root 在前, 后代在后)。
    param([int]$RootPid)
    $children = @{}
    foreach ($line in (& ps -Ao pid=,ppid= 2>$null)) {
        $fields = @($line.Trim() -split '\s+')
        if ($fields.Count -lt 2) { continue }
        $childPid = 0
        $parentPid = 0
        if (-not [int]::TryParse($fields[0], [ref]$childPid)) { continue }
        if (-not [int]::TryParse($fields[1], [ref]$parentPid)) { continue }
        if (-not $children.ContainsKey($parentPid)) { $children[$parentPid] = New-Object System.Collections.ArrayList }
        [void]$children[$parentPid].Add($childPid)
    }
    $ids = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        [void]$ids.Add($current)
        if ($children.ContainsKey($current)) {
            foreach ($child in $children[$current]) { $queue.Enqueue($child) }
        }
    }
    return $ids
}

function Stop-ServiceTree {
    # 先让子进程收到 TERM(倒序: 孙进程先走), 2 秒内没退干净再 KILL;
    # Windows 用 taskkill /T 一次结束整棵树。
    param([int]$RootPid)
    if (-not (Get-Process -Id $RootPid -ErrorAction SilentlyContinue)) { return }
    if ($OnWindows) {
        & taskkill /PID $RootPid /T /F 2>$null | Out-Null
        return
    }
    $ids = @(Get-ProcessTreeIds $RootPid)
    for ($i = $ids.Count - 1; $i -ge 0; $i--) { & kill -TERM $ids[$i] 2>$null }
    for ($i = 0; $i -lt 40; $i++) {
        if (-not (Get-Process -Id $RootPid -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 50
    }
    for ($i = $ids.Count - 1; $i -ge 0; $i--) { & kill -KILL $ids[$i] 2>$null }
}

function Get-JobHostPid {
    # 作业宿主在脚本块开头把 $PID 写进文件; 父进程据此直接结束进程树。
    # 等不到(启动失败/被中断)就返回 0, 后续跳过。
    param([string]$Path, [int]$TimeoutMs = 10000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $text = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $text -and $text.Trim() -match '^\d+$') { return [int]$text.Trim() }
        }
        Start-Sleep -Milliseconds 50
    }
    return 0
}

# ---------- 参数解析 ----------
# 不用 param() 块: 旧 dev.bat 是以位置参数转发的(`front`、`--no-run`), 而 param() 会把
# `--no-run` 当成未声明的命名参数直接报错退出。这里统一解析 $args, 同时兼容旧文档里的
# `-Mode front -NoRun` 写法。
$Mode     = "all"
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
        # 先判「是不是合法模式」: 否则 `front --bogus` 会报成「只能指定一个启动模式」,
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
# 先查命令和子模块, 再校验端口, 最后才装依赖: 配置写错时不必等 pnpm/uv 跑完。
if ($Mode -eq "all" -or $Mode -eq "front") {
    Require-Command "pnpm"
    if (-not (Test-Path -LiteralPath (Join-Path $FrontDir "package.json"))) {
        [Console]::Error.WriteLine("[lkm:error] 前端子模块未初始化: $FrontDir")
        exit 1
    }
}
if ($Mode -eq "all" -or $Mode -eq "back") {
    Require-Command "uv"
    if (-not (Test-Path -LiteralPath (Join-Path $BackDir "pyproject.toml"))) {
        [Console]::Error.WriteLine("[lkm:error] 后端子模块未初始化: $BackDir")
        exit 1
    }
}

# --no-run 不监听端口, 与 dev.sh 一致跳过端口校验。
if (-not $NoRun) {
    if ($Mode -ne "back") { $FrontPort = Get-Port "FRONT_PORT" 4321 }
    if ($Mode -ne "front") { $BackPort = Get-Port "BACKEND_PORT" 8000 }
}

# ---------- 依赖 ----------
if ($Mode -eq "all" -or $Mode -eq "front") {
    Install-Front
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("[lkm:error] 前端依赖安装失败。"); exit 1 }
}
if ($Mode -eq "all" -or $Mode -eq "back") {
    Install-Back
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("[lkm:error] 后端依赖安装失败。"); exit 1 }
}
[Console]::WriteLine()
Write-Log "依赖就绪。"
if ($NoRun) { exit 0 }

# ---------- 数据库 ----------
# 先确认能连上(错连/未启动时报错更直白), 再建 schema; 仅前端模式不碰数据库。
# 注意: 这两步不要包进函数里取值 —— 原生命令的 stdout 会变成函数返回值,
# 退出码判断就被日志行污染了(实测会让 $LASTEXITCODE 变成字符串数组)。
if ($Mode -ne "front") {
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

# 仅需后端时(back 或 all)才生成后端密钥; front 不起后端, 不生成。
if ($Mode -ne "front") {
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

# ---------- 仅前端 / 仅后端: 前台运行 ----------
if ($Mode -eq "front") {
    Initialize-FrontEnvironment
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
Initialize-FrontEnvironment
Write-Log "同时启动 SSR 前端与后端(单窗口实时交错日志)。"
[Console]::WriteLine()
Write-Log "停止: 在本窗口按 Ctrl+C 即可同时结束全部服务。"

# 作业宿主(Start-Job 另起的 pwsh 进程)把自己的 PID 写进这两个文件;
# 收尾时按 PID 结束整棵进程树, 不依赖作业状态。
$PidDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lkm-dev-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $PidDir | Out-Null
$FrontPidFile = Join-Path $PidDir "frontend.pid"
$BackPidFile  = Join-Path $PidDir "backend.pid"

# 先声明为 $null: 作业创建也必须放进 try —— 若第 2 个 Start-Job 失败
# (Start-Job 报错、PSRemoting/WSMan 不可用等), 已启动的作业及其孙进程
# (pnpm/node、uv/uvicorn)就没人收尾, 4321/8000 端口会一直被占。
$frontJob     = $null
$backJob      = $null
$frontHostPid = 0
$backHostPid  = 0
$exitCode     = 0

try {
    $frontJob = Start-Job -Name "lkm-frontend" -ScriptBlock {
        param($dir, $port, $pidFile)
        # 供父进程收尾用(见 Stop-ServiceTree): Ctrl+C 时不能再依赖作业状态。
        Set-Content -LiteralPath $pidFile -Value $PID -Encoding Ascii
        Set-Location $dir
        # 2>&1 把 stderr 也并入输出流, 确保日志可被收到
        & pnpm run dev --port $port *>&1
        if ($LASTEXITCODE -ne 0) { throw "前端退出码: $LASTEXITCODE" }
    } -ArgumentList $FrontDir, $FrontPort, $FrontPidFile -ErrorAction Stop
    $frontHostPid = Get-JobHostPid $FrontPidFile

    $backJob = Start-Job -Name "lkm-backend" -ScriptBlock {
        param($dir, $port, $pidFile)
        Set-Content -LiteralPath $pidFile -Value $PID -Encoding Ascii
        Set-Location $dir
        & uv run uvicorn main:app --reload --port $port *>&1
        if ($LASTEXITCODE -ne 0) { throw "后端退出码: $LASTEXITCODE" }
    } -ArgumentList $BackDir, $BackPort, $BackPidFile -ErrorAction Stop
    $backHostPid = Get-JobHostPid $BackPidFile

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
    # 只按 PID 结束进程树, 不调用 Stop-Job/Remove-Job: 按 Ctrl+C 时父进程处于
    # 「管道停止」状态, 那些等作业状态事件的 cmdlet 会永久阻塞(见 Stop-ServiceTree 注释)。
    foreach ($hostPid in @($frontHostPid, $backHostPid)) {
        if ($hostPid) { Stop-ServiceTree $hostPid }
    }
    Remove-Item -LiteralPath $PidDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "已停止。"
    # 用 [Environment]::Exit 而不是 exit, 而且必须在 finally 里调用:
    # 1) exit 会让引擎去收尾那些作业对象, 而它们的宿主刚被结束, 实测会无限等待;
    # 2) 按 Ctrl+C 时管道已在停止状态, finally 返回后引擎同样会卡在作业清理上,
    #    所以直接在这里终止进程(退出码照常返回)。
    [Console]::Out.Flush()
    [Environment]::Exit($exitCode)
}
