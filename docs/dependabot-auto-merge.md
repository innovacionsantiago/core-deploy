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

## Histórico

- **2026-05-08**: incidente cryptominer via Next.js CVE-2025-55182. Detección post-facto.
- **2026-05-09 W14**: Dependabot config rolled out cross-org (18 repos · agent-w14-dependabot).
- **2026-05-09 V2 pendiente**: branch protection + workflow auto-merge (humano).
