# Build Flutter Web for production + deploy to Vercel (Windows PowerShell).
#
# Usage:
#   .\scripts\deploy-vercel.ps1
#   $env:DAEMON_URL = "https://api.digitorn.ai"; .\scripts\deploy-vercel.ps1
#
# Requires:
#   - Flutter SDK on PATH
#   - Vercel CLI (`npm i -g vercel`), logged in (`vercel login`)

$ErrorActionPreference = "Stop"

$DaemonUrl = if ($env:DAEMON_URL) { $env:DAEMON_URL } else { "https://api.digitorn.ai" }
$Renderer  = if ($env:RENDERER)   { $env:RENDERER }   else { "canvaskit" }

Write-Host "==> Cleaning previous build"
flutter clean | Out-Null
flutter pub get | Out-Null

Write-Host "==> Building Flutter Web (renderer=$Renderer, daemon=$DaemonUrl)"
flutter build web --release `
  --dart-define=DIGITORN_DAEMON_URL="$DaemonUrl" `
  --web-renderer="$Renderer"

Write-Host "==> Copying vercel.json into build artifact"
Copy-Item vercel.json build\web\vercel.json -Force

Write-Host "==> Deploying to Vercel"
Push-Location build\web
try {
  npx vercel --prod --yes
} finally {
  Pop-Location
}

Write-Host ""
Write-Host "Done. Production deploy published."
Write-Host "Verify DNS: digitorn.ai (or app.digitorn.ai) -> Vercel"
Write-Host "Verify CORS: daemon's cors_origins list includes the Vercel URL."
