param(
    [string]$Token = ""
)

# 推送 ApelinPlus 到 GitHub。推送后 GitHub Actions 会自动开始编 .deb。
#
# 两种认证方式，任选其一：
#   1) 不带参数运行 —— 走 Git Credential Manager，会弹浏览器登录 GitHub
#   2) 带 -Token 运行 —— 用你生成好的 fine-grained PAT
#
# PAT 需要三项权限，全部 Read and write：Contents、Workflows、Actions。
# 缺 Workflows 时推 .github/workflows/ 里的文件必定被拒。

$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot
$remote = "https://github.com/jgomez2975-a/ApelinPlus.git"
$owner = "jgomez2975-a"
$name = "ApelinPlus"

Set-Location $repo

Write-Host ""
Write-Host "仓库: $repo" -ForegroundColor Cyan

if (-not (Test-Path (Join-Path $repo ".git"))) {
    Write-Host "这里不是 git 仓库，脚本必须放在 ApelinPlus 目录里。" -ForegroundColor Red
    exit 1
}

# 命令行里带的 token 优先；否则让 git 走 Credential Manager
if ($Token -ne "") {
    $pushUrl = "https://x-access-token:$Token@github.com/$owner/$name.git"
    Write-Host "认证: 使用传入的 token" -ForegroundColor Cyan
} else {
    $pushUrl = $remote
    Write-Host "认证: Git Credential Manager（会弹窗口让你登录 GitHub）" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "=== 待推送的提交 ===" -ForegroundColor Cyan
git log --oneline -5

Write-Host ""
Write-Host "=== 开始推送 ===" -ForegroundColor Cyan
$output = git push $pushUrl "HEAD:refs/heads/main" 2>&1
$code = $LASTEXITCODE
$output | ForEach-Object {
    # 不要把 token 打进日志
    ($_ -replace 'github_pat_[A-Za-z0-9_]+', '<TOKEN>') -replace 'x-access-token:[^@]+@', 'x-access-token:<TOKEN>@'
}

if ($code -ne 0) {
    Write-Host ""
    Write-Host "推送失败（exit $code）。" -ForegroundColor Red
    Write-Host "如果提示 Invalid username or token，说明 token 被撤销了；" -ForegroundColor Yellow
    Write-Host "不带参数重新运行本脚本，改走浏览器登录即可。" -ForegroundColor Yellow
    exit $code
}

Write-Host ""
Write-Host "推送成功。" -ForegroundColor Green
Write-Host ""
Write-Host "GitHub 已开始编译，打开这里看进度：" -ForegroundColor Cyan
Write-Host "  https://github.com/$owner/$name/actions" -ForegroundColor White
Write-Host ""
Write-Host "编译完成后，在那次运行的页面底部 Artifacts 里下载 .deb。" -ForegroundColor Cyan
Write-Host "文件应名为 wiki.qaq.apelin_0.4.8_iphoneos-arm64e.deb。" -ForegroundColor Cyan
Write-Host ""
