# ApelinPlus -> GitHub 一键开通
#
#   1. 建仓库   POST /user/repos
#   2. 推代码   git push https://x-access-token:<token>@github.com/...
#
# 用法（PowerShell 5.1 或 7 均可）：
#
#   .\provision.ps1 -Token "ghp_xxxxxxxx"
#
#   # 想建私有仓库（默认公开，因为公开仓库的 macOS CI 不计费）：
#   .\provision.ps1 -Token "ghp_xxxxxxxx" -Visibility private
#
#   # 仓库已经在网页上建好了，只推代码：
#   .\provision.ps1 -Token "ghp_xxxxxxxx" -SkipCreate
#
# token 需要什么权限见 PROVISION.md。这个脚本不会把 token 写进
# .git/config，也不会写进任何文件。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Token,

    [string]$Repo = 'ApelinPlus',

    [ValidateSet('public', 'private')]
    [string]$Visibility = 'public',

    [string]$Owner = '',

    [switch]$SkipCreate
)

$ErrorActionPreference = 'Stop'

# ---- 人话的失败 ------------------------------------------------

function Fail($message, $hint) {
    Write-Host ""
    Write-Host "失败：$message" -ForegroundColor Red
    if ($hint) { Write-Host "怎么办：$hint" -ForegroundColor Yellow }
    Write-Host ""
    exit 1
}

# ---- 前置：git 在哪 --------------------------------------------

$git = (Get-Command git -ErrorAction SilentlyContinue).Source

if (-not $git) {
    # WorkBuddy 自带了一份 portable git，PATH 里没有就用它
    $bundled = Join-Path $env:USERPROFILE '.workbuddy\binaries\PortableGit\versions'
    if (Test-Path $bundled) {
        $candidate = Get-ChildItem -Path $bundled -Directory |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\git.exe' } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if ($candidate) { $git = $candidate }
    }
}

if (-not $git) {
    Fail "找不到 git。" "装一个：winget install --id Git.Git -e，或者直接去 https://git-scm.com/download/win"
}

Write-Host "git: $git" -ForegroundColor DarkGray

$repoDir = $PSScriptRoot
if (-not (Test-Path (Join-Path $repoDir '.git'))) {
    Fail "这个脚本必须在仓库根目录里跑（找不到 .git）。" "确认 apelin-plus 目录里有 .git"
}

# ---- 前置：token 有没有效 --------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'ApelinPlus-Provision'
}

try {
    $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -Method Get
} catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    if ($status -eq 401) {
        Fail "token 无效或已过期（401）。" "重新生成一个，注意 fine-grained token 必须以 github_pat_ 开头，classic 以 ghp_ 开头"
    }
    Fail "连不上 GitHub API：$($_.Exception.Message)" "检查代理/网络。公司网络常拦 api.github.com"
}

if (-not $Owner) { $Owner = $me.login }
Write-Host "账号: $($me.login)  仓库: $Owner/$Repo  可见性: $Visibility" -ForegroundColor DarkGray

# ---- 1. 建仓库 -------------------------------------------------

if (-not $SkipCreate) {
    $body = @{
        name        = $Repo
        private     = ($Visibility -eq 'private')
        description = 'Apelin 多实例服务商 + 余额查询（独立 SPM 包，CI 在 macOS runner 上验证）'
        has_issues  = $true
        has_wiki    = $false
        auto_init   = $false
    } | ConvertTo-Json

    try {
        $created = Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Headers $headers `
            -Method Post -Body $body -ContentType 'application/json; charset=utf-8'
        Write-Host "仓库已建好: $($created.html_url)" -ForegroundColor Green
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }

        if ($status -eq 422) {
            Write-Host "仓库已经存在，跳过创建，直接推。" -ForegroundColor Yellow
        } elseif ($status -eq 403) {
            Fail "token 没有建仓库的权限（403）。" "fine-grained token 建不了仓库，这是 GitHub 的限制。两条路：①先用 -SkipCreate，去网页手动建一个空仓库再推；②换 classic token，勾上 repo + workflow"
        } else {
            Fail "建仓库失败：$($_.Exception.Message)" "换成 -SkipCreate，手动在 https://github.com/new 建一个空仓库（不要勾 README/gitignore）再跑"
        }
    }
}

# ---- 2. 推代码 -------------------------------------------------

$remoteUrl = "https://x-access-token:$Token@github.com/$Owner/$Repo.git"
$remoteHttps = "https://github.com/$Owner/$Repo.git"

Push-Location $repoDir
try {
    $branch = (& $git rev-parse --abbrev-ref HEAD).Trim()
    if (-not $branch -or $branch -eq 'HEAD') { $branch = 'main' }

    # 有未提交改动就先提交，别让 CI 跑的是旧代码
    $dirty = (& $git status --porcelain)
    if ($dirty) {
        Write-Host "有未提交的改动，先提交..." -ForegroundColor Yellow
        & $git add -A
        & $git -c core.autocrlf=false commit -q -m "Update before first CI run"
    }

    Write-Host "推送 $branch ..." -ForegroundColor DarkGray
    & $git push $remoteUrl "HEAD:refs/heads/$branch" 2>&1 | ForEach-Object { Write-Host "  $_" }

    if ($LASTEXITCODE -ne 0) {
        Fail "git push 被拒（exit $LASTEXITCODE）。" "最常见的原因是 token 缺 workflow 权限 —— 推 .github/workflows/ 必须有它。报错里出现 'without workflow scope' 就是它。"
    }

    Write-Host ""
    Write-Host "推完了。" -ForegroundColor Green
    Write-Host "  Actions: $remoteHttps/actions" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "打开上面那个链接，等 'swift test' 那个 job 跑完（约 2 分钟）。" -ForegroundColor Gray
    Write-Host "绿的就行；红的把日志整段贴给我。" -ForegroundColor Gray
    Write-Host ""
} finally {
    Pop-Location
}
