#!/usr/bin/env bash
# core-deploy · post_deploy template para servicios TS/Node (Next, Vite, Express).
#
# Variables exportadas por el workflow:
#   SERVICE_NAME   systemd unit (ej cis-www, periodismo2-api)
#   HEALTH_URL     URL post-restart (ej http://127.0.0.1:3000/api/health)
#
# Para sitios estáticos servidos por Caddy (sin systemd unit) este script
# igual hace el build · skip restart si la unit no existe.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> [post_deploy] $SERVICE_NAME · $(date -u +%FT%TZ)"

# 0. Drift check post-rsync · ver post_deploy.python.sh para detalle.
# Detecta archivos creados durante el post_deploy (build outputs, etc) que el
# próximo rsync --delete borraría. V1 warn-only.
if command -v git >/dev/null 2>&1 && [ -d .git ]; then
  UNTRACKED_TOTAL=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l)
  if [ "$UNTRACKED_TOTAL" -gt 0 ]; then
    echo "WARNING: [$SERVICE_NAME] $UNTRACKED_TOTAL archivo(s) untracked en prod"
    echo "WARNING: el próximo rsync --delete los va a borrar"
    echo "WARNING: sample (top 10):"
    git ls-files --others --exclude-standard 2>/dev/null | head -10 | sed 's/^/WARNING:   /'
  fi
fi

# 1. dependencias (production-only)
if [ -f package-lock.json ]; then
  npm ci --omit=dev
elif [ -f pnpm-lock.yaml ]; then
  pnpm install --frozen-lockfile --prod
elif [ -f yarn.lock ]; then
  yarn install --frozen-lockfile --production
fi

# devDependencies necesarias para build (si build script existe)
if grep -q '"build"' package.json 2>/dev/null; then
  if [ -f package-lock.json ]; then
    npm ci
  fi
  echo "==> npm run build"
  npm run build
fi

# 2. restart systemd unit (si aplica)
if systemctl list-unit-files "${SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q "${SERVICE_NAME}.service"; then
  echo "==> sudo systemctl restart $SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"
else
  echo "WARNING: systemd unit ${SERVICE_NAME}.service not found"
  echo "         (esto es OK para sitios estáticos servidos por Caddy)"
fi

# 3. health check
sleep 3
if [ -n "${HEALTH_URL:-}" ]; then
  echo "==> health check $HEALTH_URL"
  for i in 1 2 3 4 5; do
    if curl -fsS --max-time 5 "$HEALTH_URL"; then
      echo
      echo "==> health OK on attempt $i"
      exit 0
    fi
    echo "==> health attempt $i failed, retry in 2s"
    sleep 2
  done
  echo "ERROR: health check failed after 5 attempts"
  exit 1
fi

echo "==> [post_deploy] done"
