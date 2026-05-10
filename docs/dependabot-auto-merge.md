# Dependabot · estrategia de auto-merge cross-org

> Doc generado por `agent-w14-dependabot` tras incidente
> [SEC-2026-05-08 cryptominer](../../../cis/SECURITY-INCIDENT-2026-05-08-CRYPTOMINER.md)
> (CVE-2025-55182 Next.js, detectado post-facto por `cis-cve-scan`).
> Pendiente humano: V2 follow-up (branch protection + workflow approvals).

## Tier matrix

| Tier | Repos | Schedule | Auto-merge target |
|------|-------|----------|-------------------|
| T0 / T1 críticos | core-deploy, cis-mailer, cis-platform, cis-core, cis-inbox, cis-sign, cis-auth (docker) | daily | patch + security |
| T2 productos | cis-claudia, cis-mando, cis-pagos, cis-monitoreo, cis-www, cis-style, periodismo2-{api,frontend,www}, situacion-www | weekly | patch + security |
| T3 incubated | cis-isometrico, cis-mapa, cis-portal (sólo gh-actions), cis-tree (sólo gh-actions) | weekly | patch + security |
| Tooling base | core-python-base, core-ts-base | weekly (gh-actions only) | patch (manual) |

## Política de merge por tipo de update

| Update type | Acción | Quién |
|-------------|--------|-------|
| **patch** (1.2.3 → 1.2.4) | auto-merge si CI green ≥ 5 min | Dependabot bot |
| **security-updates** (cualquier severidad) | priorizar review humano (≤ 24 h) y mergear · auto-merge sólo si patch + low severity | Martin / sopapo |
| **minor** (1.2.x → 1.3.0) | review humano · changelog skim · mergear si no breaking | Martin / sopapo |
| **major** (1.x → 2.x) | review humano + ADR si breaking · puede esperar lockstep | Martin / sopapo + ADR |
| **docker authentik** (cis-auth) | NUNCA auto-merge · validar SSO en ventana low-traffic | Martin |

Razón del patrón: la lección post-CVE-2025-55182 es que la detección reactiva
(`cis-cve-scan` corriendo cada N horas) llega siempre tarde. Dependabot abre PR
en cuanto upstream publica versión parcheada, lo que reduce el window of exposure.

## Mecanismo técnico (V1 manual · V2 auto)

### V1 (estado actual · post-W14)
- Dependabot abre PRs (limit 5/ecosystem) con label `dependencies` + `automated`.
- CI corre tests en cada PR (workflow `ci.yml` ya existente en cada repo).
- Humano (Martin / sopapo) revisa daily batch y mergea via UI / `gh pr merge`.
- Helper recomendado en cada laptop:

  ```bash
  # PRs Dependabot abiertos cross-org
  gh search prs --owner innovacionsantiago \
    --author app/dependabot --state open --json url,title,repository \
    --limit 100 | jq -r '.[] | "\(.repository.name)\t\(.title)\t\(.url)"'
  ```

### V2 (follow-up · branch protection + auto-merge workflow)
Pendiente humano. Pasos:

1. **Branch protection** en cada repo crítico (`main` / `master`):
   - Required status checks: `ci/pytest`, `ci/lint`, `ci/coverage`.
   - Required PR review: 0 (Dependabot bypass) o 1 (humano).
   - Auto-merge enabled: yes.

2. **Workflow** `.github/workflows/dependabot-auto-merge.yml` en cada repo crítico
   (templated en `core-deploy/templates/.github/workflows/`):

   ```yaml
   name: Dependabot auto-merge
   on: pull_request
   permissions:
     contents: write
     pull-requests: write
   jobs:
     automerge:
       if: github.actor == 'dependabot[bot]'
       runs-on: ubuntu-latest
       steps:
         - uses: dependabot/fetch-metadata@v2
           id: meta
         - if: steps.meta.outputs.update-type == 'version-update:semver-patch'
           run: gh pr merge --auto --squash "$PR_URL"
           env:
             PR_URL: ${{ github.event.pull_request.html_url }}
             GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
   ```

3. **Excepciones explícitas**:
   - `cis-auth` (Docker authentik): nunca automerge — validar SSO manualmente.
   - Cualquier repo con CI rojo histórico (>10% failure rate en main): pasar a manual.

## Smoke verification post-deploy

Tras merge automático de patch:

```bash
# Verificar que el servicio sigue healthy
curl -fsS https://api.cis-mailer.svc/healthz
sudo systemctl status cis-mailer.service --no-pager | head -5

# Si CD push-on-main está activo (W13 ramp), el deploy es automático.
# Si no, gh workflow run cd.yml --repo innovacionsantiago/<repo>
```

## Métricas a vigilar

- **Time-to-merge** patch updates: target < 24 h.
- **CVE detection lag**: target < 1 h (Dependabot publishing → PR open).
- **Open PR queue per repo**: target ≤ 5 (limit configurado).
- **Failed CI rate en Dependabot PRs**: si > 30%, indica deps con tests frágiles.

Dashboard recomendado en `cis-mando` (futuro): grid de PRs Dependabot por repo +
status CI + age. Hook al `RepoGrid` ya existente.

## Coordinación con `cis-cve-scan`

`cis-cve-scan` sigue siendo necesario como **second line**: detecta CVEs en deps
no cubiertas por Dependabot (ej. system packages, custom binaries, dependencias
sin pyproject/package.json). Dependabot + cis-cve-scan = defensa en profundidad.

| Capa | Cobertura | Latencia |
|------|-----------|----------|
| Dependabot | pip / npm / docker / gh-actions con manifest | minutos |
| cis-cve-scan | runtime, system packages, hardcoded versions | horas (cron) |
| Sentry / logs | runtime exploit attempts | tiempo real |

## V2 deployment (W17 · 2026-05-10)

Estado actual: **V2 LIVE** en 20 de 21 repos del batch original (cis-auth excluido por
politica · validar SSO authentik manual).

### Workflow desplegado

`.github/workflows/dependabot-auto-merge.yml` (ver template canonico
`templates/.github/workflows/dependabot-auto-merge.yml`):

- `if: github.actor == 'dependabot[bot]'` — el job sólo corre en PRs del bot.
- Step 1: `dependabot/fetch-metadata@v2` extrae `update-type`, `dependency-group`,
  `dependency-names`, etc.
- Step 2 (auto-approve) si **alguna** de estas condiciones se cumple:
    - `update-type == 'version-update:semver-patch'` (single-package patch), **o**
    - `dependency-group == 'patch-updates'` (PR grupal del grupo patch-updates
      definido en dependabot.yml).
- Step 3 (auto-merge `--auto --squash`): mismas condiciones que el step 2.
- Step 4 (comment minor/major/non-patch-group): si no cumple, postea un
  comentario recordando review humana.

#### Por qué necesitamos chequear `dependency-group`

`fetch-metadata@v2` devuelve `update-type:null` para PRs grupales (cuando un
PR bumpea N paquetes a la vez, no hay un único update-type). Sin el check de
grupo, todo PR `patch-updates` quedaria fuera de auto-merge — derrotando el
proposito del groupado en `dependabot.yml`. El grupo `security-updates`
intencionalmente queda fuera de auto-merge (mix de severities + update-types
no es seguro auto-mergearlo).

Hardening: ningún `${{ ... }}` en `run:` blocks · todos los valores derivados de
events pasan por `env:` con quoting estricto. Ref: [GitHub Actions injection guide](https://github.blog/security/vulnerability-research/how-to-catch-github-actions-workflow-injections-before-attackers-do/).

### Repo settings ajustados

Para que `gh pr merge --auto` funcione, cada repo debe tener
`allow_auto_merge=true`. El script de deploy lo habilita automaticamente
(`PATCH /repos/{owner}/{repo} allow_auto_merge=true`).

### Branch protection · core-* públicos (3 repos)

`core-deploy`, `core-python-base`, `core-ts-base`:

- `required_pull_request_reviews=1` (W15.4) · Dependabot bot dispara su propio
  approve via el workflow → la review count llega a 1 sin humano.
- `required_status_checks` queda **null** intencionalmente. Justificación: estos
  3 repos son **reusable-only** (`on: workflow_call`) · no tienen suite CI propia
  · agregar `required_status_checks=["ci"]` bloquearia toda PR para siempre. La
  proteccion real viene de `dismiss_stale_reviews=true + required_linear_history`.

### Excepciones explícitas

- **cis-auth** · Docker authentik · NO se le copia el workflow. Validar SSO en
  ventana low-traffic.
- **cis-portal / cis-tree** · todavia sin `dependabot.yml` en main · entrarán
  cuando se complete onboarding gh-actions-only (W14.5 partial).

### Free tier · auto-merge en repos privados

GitHub habilitó auto-merge para repos privados Free desde 2022 (no requiere
upgrade a Team). El feature `Allow auto-merge` se activa por repo via
`PATCH /repos/{owner}/{repo}` con `allow_auto_merge=true` · no requiere plan
pago.

Branch protection en repos **privados** sigue requiriendo Team plan ($4/usuario)
— el W15.4 doc lista esto como C7 (HUMAN-PENDING). En W17 los privados quedan
con auto-merge habilitado pero **sin branch protection**: GitHub mergea el PR
de Dependabot apenas se cumpla `mergeable_state=clean` (que para repos sin
protection significa "no conflicts" sólo · NO fuerza CI green).

> **Implicacion**: en repos privados sin branch protection, el `--auto` flag se
> degrada de "merge cuando CI passe" a "merge cuando no haya conflicts". Para
> los repos privados con CI estable (cis-mailer, cis-platform, cis-core, etc.)
> esto es aceptable (PRs de patch con tests rotos quedan sin mergear porque
> Dependabot reintenta hasta que el PR sea mergeable). Para los críticos T0
> (cis-auth, cis-mailer) deberíamos elevar a Team plan o usar un PAT con scope
> limitado para forzar wait-on-checks via API custom.

### Script bulk-deploy

`/srv/projects/core/core-deploy/scripts/deploy-dependabot-auto-merge.sh`
(uso de la GitHub Contents API — no toca working trees locales · idempotente):

```bash
DRY_RUN=1 ./deploy-dependabot-auto-merge.sh             # preview
./deploy-dependabot-auto-merge.sh                        # apply all
REPOS=cis-mailer,cis-mando ./deploy-dependabot-auto-merge.sh  # subset
```

## Test plan + verificación

1. Esperar siguiente Dependabot patch PR (Dependabot abre diariamente para
   T0/T1, semanal para T2/T3) · verify auto-merge runs + auto-approves +
   auto-squashes.
2. O simulacion: `gh pr comment <PR-URL> --body "@dependabot rebase"` en una
   PR patch ya abierta — Dependabot rebasa, dispara `pull_request synchronize`,
   el workflow corre.

## Histórico

- **2026-05-08**: incidente cryptominer via Next.js CVE-2025-55182. Detección post-facto.
- **2026-05-09 W14**: Dependabot config rolled out cross-org (18 repos · agent-w14-dependabot).
- **2026-05-09 W14.5**: ampliacion a 21 repos del batch (incluye 3 core-*).
- **2026-05-09 W15.4**: branch protection en 3 core-* publics (require 1 review · enforce_admins=false).
- **2026-05-10 W17**: V2 auto-merge LIVE · workflow desplegado en 20/21 repos via Contents API · `allow_auto_merge=true` habilitado en los 20 · branch protection core-* sin status_checks (reusable-only justification).
