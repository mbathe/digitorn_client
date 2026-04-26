#!/usr/bin/env bash
#
# Build Flutter Web for production + deploy to Vercel.
#
# Usage:
#   ./scripts/deploy-vercel.sh                # uses DAEMON_URL env or default
#   DAEMON_URL=https://api.digitorn.ai ./scripts/deploy-vercel.sh
#
# Requires:
#   - Flutter SDK on PATH
#   - Vercel CLI (`npm i -g vercel`), logged in (`vercel login`)

set -euo pipefail

DAEMON_URL="${DAEMON_URL:-https://api.digitorn.ai}"
RENDERER="${RENDERER:-canvaskit}"

echo "==> Cleaning previous build"
flutter clean > /dev/null
flutter pub get > /dev/null

echo "==> Building Flutter Web (renderer=$RENDERER, daemon=$DAEMON_URL)"
flutter build web --release \
  --dart-define=DIGITORN_DAEMON_URL="$DAEMON_URL" \
  --web-renderer="$RENDERER"

echo "==> Copying vercel.json into build artifact"
cp vercel.json build/web/vercel.json

echo "==> Deploying to Vercel"
cd build/web
npx vercel --prod --yes

echo
echo "Done. Production deploy published."
echo "Verify DNS: digitorn.ai (or app.digitorn.ai) → Vercel"
echo "Verify CORS: daemon's cors_origins list includes the Vercel URL."
