#!/usr/bin/env bash
# Deploy Dependabot V2 auto-merge workflow a todos los repos del W14.5 batch.
#
# Estrategia: commit directo a la default branch via GitHub Contents API
# (gh api PUT /repos/.../contents/.github/workflows/dependabot-auto-merge.yml).
# No tocamos working trees locales · evita conflictos con cambios untracked
# en disco y con divergencias local/remote (ej. periodismo2-* tiene local=main
# y remote default=master).
#
# Uso:
#   ./deploy-dependabot-auto-merge.sh           # apply
#   DRY_RUN=1 ./deploy-dependabot-auto-merge.sh # preview
#   REPOS=cis-mailer,core-deploy ./deploy-dependabot-auto-merge.sh  # subset
#
# Requisitos:
#   - gh autenticado con scope `repo` y `workflow` (token vault _global GH_TOKEN).
#
# Excepciones (NO se les copia el workflow):
#   - cis-auth · Docker authentik · validar SSO manual.
#   - cis-portal/cis-tree · todavia sin dependabot.yml en main.
#
# Origen: agent-w17-dependabot-automerge (2026-05-10).
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
ORG="innovacionsantiago"
TEMPLATE="/srv/projects/core/core-deploy/templates/.github/workflows/dependabot-auto-merge.yml"
WORKFLOW_PATH=".github/workflows/dependabot-auto-merge.yml"
COMMIT_MSG="feat(security): Dependabot V2 auto-merge workflow

Auto-approve + auto-merge para semver-patch si CI green.
Minor/major postean comment recordando review humana.
Template canonico en core-deploy/templates/.github/workflows/.

Origen: agent-w17-dependabot-automerge (2026-05-10).
Lecccion post CVE-2025-55182 cryptominer (2026-05-08)."

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found at $TEMPLATE" >&2
  exit 1
fi

# Lista canonica · 20 repos (cis-auth excluido por politica).
ALL_REPOS=(
  cis-claudia
  cis-core
  cis-inbox
  cis-mailer
  cis-monitoreo
  cis-pagos
  cis-platform
  cis-sign
  cis-isometrico
  cis-mando
  cis-mapa
  cis-style
  cis-www
  periodismo2-api
  periodismo2-frontend
  periodismo2-www
  situacion-www
  core-deploy
  core-python-base
  core-ts-base
)

# Filtro REPOS=a,b,c
if [ -n "${REPOS:-}" ]; then
  IFS=',' read -ra ALL_REPOS <<<"$REPOS"
fi

CONTENT_B64=$(base64 -w0 <"$TEMPLATE")

# Step 0: enable allow_auto_merge en cada repo (no-op si ya esta on).
# Sin esto `gh pr merge --auto` falla con "auto-merge is not allowed".
enable_auto_merge() {
  local repo="$1"
  local cur
  cur=$(gh api "/repos/$ORG/$repo" --jq '.allow_auto_merge' 2>/dev/null || echo "false")
  if [ "$cur" = "true" ]; then
    echo "  allow_auto_merge: already on"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "  DRY: PATCH /repos/$ORG/$repo allow_auto_merge=true"
    return 0
  fi
  gh api -X PATCH "/repos/$ORG/$repo" -F allow_auto_merge=true >/dev/null 2>&1 \
    && echo "  allow_auto_merge: enabled" \
    || echo "  WARN: no se pudo habilitar allow_auto_merge"
}

ok=0
skipped=0
failed=()

for repo in "${ALL_REPOS[@]}"; do
  echo
  echo "=== $repo ==="

  default=$(gh repo view "$ORG/$repo" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo "")
  if [ -z "$default" ]; then
    echo "  FAIL: cannot resolve default branch"
    failed+=("$repo")
    continue
  fi
  echo "  default branch: $default"

  enable_auto_merge "$repo"

  # Existe ya?  (200 -> JSON con sha+content · 404 -> no existe)
  api_resp=$(gh api "/repos/$ORG/$repo/contents/$WORKFLOW_PATH?ref=$default" 2>/dev/null || true)
  existing=""
  remote_b64=""
  if echo "$api_resp" | jq -e 'has("sha")' >/dev/null 2>&1; then
    existing=$(echo "$api_resp" | jq -r '.sha')
    remote_b64=$(echo "$api_resp" | jq -r '.content' | tr -d '\n')
  fi

  if [ -n "$existing" ]; then
    if [ "$remote_b64" = "$CONTENT_B64" ]; then
      echo "  SKIP: ya existe e identico (sha=$existing)"
      skipped=$((skipped+1))
      continue
    else
      echo "  UPDATE: existe pero diferente (sha=$existing) · sera reemplazado"
    fi
  fi

  if [ "$DRY_RUN" = "1" ]; then
    if [ -n "$existing" ]; then
      echo "  DRY: PUT contents/$WORKFLOW_PATH (update sha=$existing) on $default"
    else
      echo "  DRY: PUT contents/$WORKFLOW_PATH (create) on $default"
    fi
    continue
  fi

  # Build payload
  if [ -n "$existing" ]; then
    payload=$(jq -n \
      --arg msg "$COMMIT_MSG" \
      --arg branch "$default" \
      --arg content "$CONTENT_B64" \
      --arg sha "$existing" \
      '{message:$msg, branch:$branch, content:$content, sha:$sha}')
  else
    payload=$(jq -n \
      --arg msg "$COMMIT_MSG" \
      --arg branch "$default" \
      --arg content "$CONTENT_B64" \
      '{message:$msg, branch:$branch, content:$content}')
  fi

  resp=$(echo "$payload" | gh api -X PUT \
    "/repos/$ORG/$repo/contents/$WORKFLOW_PATH" --input - 2>&1) || {
      echo "  FAIL: $resp"
      failed+=("$repo")
      continue
    }
  commit_sha=$(echo "$resp" | jq -r '.commit.sha // "?"')
  echo "  OK: commit $commit_sha on $default"
  ok=$((ok+1))
done

echo
echo "==================================="
echo "Done: $ok ok · $skipped skipped · ${#failed[@]} failed"
[ ${#failed[@]} -eq 0 ] || printf 'failed: %s\n' "${failed[@]}"
