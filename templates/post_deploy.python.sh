#!/usr/bin/env bash
# core-deploy · post_deploy template para servicios Python (FastAPI/Flask/etc).
#
# Variables exportadas por el workflow:
#   SERVICE_NAME   nombre del systemd unit (ej cis-mailer)
#   HEALTH_URL     URL para curl post-restart (ej http://127.0.0.1/healthz)
#
# Convenciones:
#   - venv en .venv (creado on-demand si no existe)
#   - python3.12 explícito (ADR-018 servicios nuevos)
#   - alembic upgrade idempotente · NO falla si no hay migrations/
#   - sudo systemctl restart vía sudoers NOPASSWD (grupo infra ya configurado)
#
# Idempotente: este script puede correr N veces sin efectos colaterales.

set -euo pipefail

cd "$(dirname "$0")/.."

PYTHON_BIN="${PYTHON_BIN:-python3.12}"
VENV_DIR="${VENV_DIR:-.venv}"

echo "==> [post_deploy] $SERVICE_NAME · $(date -u +%FT%TZ)"

# 0. Drift check post-rsync: detecta archivos creados por el post_deploy mismo
# (e.g. caches, alembic-generated, etc) que NO están en git. Si aparecen acá
# es porque se generaron dentro del checkout productivo y al PRÓXIMO CD el
# `rsync --delete` los va a borrar. La pre-flight check del workflow corre
# antes del rsync, este check captura drift introducido en este mismo deploy.
# V1: warn-only · V2 (Wave 12+, todos los repos limpios) → abort.
# Ver: core-deploy/ROLLBACK.md, cis-validators structure.untracked_on_prod,
# /srv/projects/cis/scripts/audit-untracked-on-prod.sh
if command -v git >/dev/null 2>&1 && [ -d .git ]; then
  UNTRACKED_TOTAL=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l)
  if [ "$UNTRACKED_TOTAL" -gt 0 ]; then
    echo "WARNING: [$SERVICE_NAME] $UNTRACKED_TOTAL archivo(s) untracked en prod"
    echo "WARNING: el próximo rsync --delete los va a borrar"
    echo "WARNING: sample (top 10):"
    git ls-files --others --exclude-standard 2>/dev/null | head -10 | sed 's/^/WARNING:   /'
  fi
fi

# 1. venv (idempotente)
if [ ! -d "$VENV_DIR" ]; then
  echo "==> Creating venv at $VENV_DIR"
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

# 2. dependencias
python -m pip install --upgrade pip
if [ -f requirements.lock ]; then
  pip install -r requirements.lock
elif [ -f requirements.txt ]; then
  pip install -r requirements.txt
fi
# install editable si pyproject define [project]
if [ -f pyproject.toml ] && grep -q '^\[project\]' pyproject.toml; then
  pip install -e . || true
fi

# 3. migraciones (idempotente · no falla si no hay alembic)
if [ -f alembic.ini ]; then
  echo "==> alembic upgrade head"
  alembic upgrade head || {
    echo "WARNING: alembic upgrade failed (continuing anyway)"
  }
fi

# 4. restart systemd unit
if systemctl list-unit-files "${SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q "${SERVICE_NAME}.service"; then
  echo "==> sudo systemctl restart $SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"
else
  echo "WARNING: systemd unit ${SERVICE_NAME}.service not found, skipping restart"
fi

# 5. wait for healthz
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
