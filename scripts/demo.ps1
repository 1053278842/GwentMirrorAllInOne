# 一条命令跑完整演示（Windows PowerShell 版）：
#   启动容器 -> 等健康 -> 爬官网卡组 -> 回放对局 -> 打印数据库落库情况
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\demo.ps1
#   $env:IMAGE="<镜像地址>"; .\scripts\demo.ps1
param(
  [string]$Image = $(if ($env:IMAGE) { $env:IMAGE } else { "gwentmirror-all-in-one:1.4.0" }),
  [string]$Name  = "gwent-mirror",
  [int]$WebPort  = 8080,
  [int]$ApiPort  = 8081
)

$ErrorActionPreference = "Stop"
$base = "http://localhost:$WebPort/gmapi"

Write-Host "==> 清理旧容器" -ForegroundColor Cyan
docker rm -f $Name 2>$null | Out-Null

Write-Host "==> 启动 $Image" -ForegroundColor Cyan
docker run -d --name $Name -p "${WebPort}:80" -p "${ApiPort}:8081" $Image | Out-Null

Write-Host "==> 等待就绪（首次启动要初始化 MySQL，最多 180s）" -ForegroundColor Cyan
$ready = $false
foreach ($i in 1..90) {
  try {
    $h = Invoke-WebRequest -Uri "http://localhost:$WebPort/healthz" -TimeoutSec 3 -UseBasicParsing
    $m = Invoke-WebRequest -Uri "$base/deck/api/maxid" -TimeoutSec 3 -UseBasicParsing
    if ($h.StatusCode -eq 200 -and $m.StatusCode -eq 200) { $ready = $true; Write-Host "    就绪（第 $i 次探测）"; break }
  } catch { }
  Start-Sleep -Seconds 2
}
if (-not $ready) { Write-Host "启动超时，请查看: docker logs $Name" -ForegroundColor Red; exit 1 }

Write-Host "`n==> 1/2 抓取官网最新卡组" -ForegroundColor Cyan
python scripts/fetch_decks.py --base-url $base --since-days 30 --limit 20
if ($LASTEXITCODE -ne 0) { Write-Host "    (抓取失败，跳过；容器自带样例卡组仍可演示)" -ForegroundColor Yellow }

Write-Host "`n==> 2/2 回放对局（模拟记牌器上报）" -ForegroundColor Cyan
python scripts/simulate_battle.py --base-url $base --matches 5

Write-Host "`n==> 数据库落库情况" -ForegroundColor Cyan
docker exec $Name mysql -ugwent -pgwent123 GwentMirror -e "SELECT 'deck' AS tbl, COUNT(*) AS rows_cnt FROM deck UNION ALL SELECT 'battle', COUNT(*) FROM battle UNION ALL SELECT 'player', COUNT(*) FROM player UNION ALL SELECT 'player_battle_info', COUNT(*) FROM player_battle_info;"

Write-Host "`n==> 打开 http://localhost:$WebPort  查看卡组站" -ForegroundColor Green
Write-Host "==> 查看日志: docker logs -f $Name"
