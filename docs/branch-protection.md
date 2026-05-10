# Branch protection · setup + rationale

> Doc generado por `agent-w15-branch-protection` (2026-05-09) como parte del
> hardening post-CVE-2025-55182 (ver
> [SEC-2026-05-08 cryptominer](../../../cis/SECURITY-INCIDENT-2026-05-08-CRYPTOMINER.md))
> y siguiendo la promesa V2 de `dependabot-auto-merge.md` (branch protection +
> workflow approvals como pre-requisito real para auto-merge seguro).

## TL;DR

| Repo | Visibility | Estado | Notas |
|------|------------|--------|-------|
| `core-python-base` | PUBLIC | LIVE 2026-05-09 | reusable workflow only · sin required CI checks |
| `core-ts-base` | PUBLIC | LIVE 2026-05-09 | reusable workflow only · sin required CI checks |
| `core-deploy` | PUBLIC | LIVE 2026-05-09 | reusable workflow only · sin required CI checks |
| T0 privates (cis-mailer · cis-platform · cis-core · cis-auth) | PRIVATE | BLOCKED | requiere GitHub Pro (USD 4 / seat / mes) |

## Reglas aplicadas a los 3 core-* públicos

```json
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true,
  "required_conversation_resolution": true
}
```

Aplicado vía:

```bash
for repo in core-python-base core-ts-base core-deploy; do
  gh api -X PUT "/repos/innovacionsantiago/$repo/branches/main/protection" \
    --input branch-protection.json
done
```

### Por qué `required_status_checks: null`

Los 3 repos son **bibliotecas de workflows reusables** (`workflow_call:`
trigger, sin `push:` ni `pull_request:`). No tienen un job CI propio que se
dispare al abrir un PR contra `main`, así que requerir un status check `ci`
inexistente bloquearía PRs indefinidamente.

Cuando se decida agregar un CI propio (linting de la propia YAML, test del
workflow con `act`, etc.) este parámetro debe actualizarse a:

```json
"required_status_checks": {
  "strict": true,
  "contexts": ["<nombre-real-del-job>"]
}
```

Para descubrir el nombre real del check después de un primer run:

```bash
gh api /repos/innovacionsantiago/<repo>/commits/main/check-runs \
  --jq '.check_runs[].name'
```

### Por qué `enforce_admins: false`

Permite que owners (`illanes00`, `sopapo`) hagan push directo a `main` en
emergencia (rollback urgente, hotfix de incidente activo). Las protecciones
estructurales (`allow_force_pushes: false`, `allow_deletions: false`,
`required_linear_history: true`) **siguen aplicando incluso a admins** —
GitHub las trata como invariantes del repo, no como reglas de PR.

Verificado en test `2026-05-09`:

| Acción admin | Resultado |
|--------------|-----------|
| `git push origin main` (commit normal) | OK con warning "Bypassed rule violations" |
| `git push --force origin main` | RECHAZADO `Cannot force-push to this branch` |
| `git push origin :main` (delete) | RECHAZADO `refusing to delete the current branch` |

Para no-admins (colaboradores externos, agentes Claude con token scoped) las
reglas de PR sí aplican: deben abrir PR + obtener 1 review + resolver
conversaciones + mantener historia lineal.

### Por qué `required_linear_history: true`

Forzar `--ff-only` o squash/rebase al merge → `git log --oneline` legible,
revertibles puntuales, bisect funcional. Bloquea merge commits ruidosos.

### Por qué `dismiss_stale_reviews: true`

Si alguien aprueba una PR y luego se hace `git push` con cambios nuevos, la
aprobación se invalida. Evita "approve & sneak" — patrón visto en supply
chain attacks (Aeza Group ASN ya nos pegó una vez con CVE-2025-55182).

### Por qué `required_conversation_resolution: true`

Bloquea merge si hay comentarios unresolved en la PR. Forza explicitness:
todo nit/blocker que un reviewer escriba debe ser respondido o resuelto
antes de merge. Sin esto, un comment "este shell injection es bug?" se
mergea sin tocar.

## T0 privates · GitHub Pro decision pendiente

GitHub **Free tier no permite branch protection en private repos**. Verificado
con HTTP 403 al intentar:

```text
"Upgrade to GitHub Pro or make this repository public to enable this feature."
```

Esto afecta a los 4 repos T0 críticos:

- `cis-mailer` (Resend webhook + SMTP outbound · DKIM keys)
- `cis-platform` (forward_auth gateway · cookie session validation)
- `cis-core` (DB schema central · alembic migrations · service registry)
- `cis-auth` (Authentik docker compose · SSO root of trust)

### Opciones (no excluyentes)

1. **Upgrade org `innovacionsantiago` → GitHub Team** (USD 4 / seat / mes)
   - Habilita branch protection en privates **y** propagación de org secrets
     a reusable workflows en private repos (resuelve C4 + W9 simultáneamente).
   - Bundle más eficiente · ver `/srv/projects/cis/HUMAN-PENDING.md` C4 / W9
     para el otro side de la decisión.
   - 2 seats hoy (martin + sopapo) → USD 96 / año.
   - Recomendado.

2. **Volver T0 selectos PUBLIC** (visibility flip)
   - `cis-platform` es candidato menos riesgoso (config en env vars vía
     vault, código de routing forward_auth no contiene secretos hardcoded).
     Auditoría previa con `cis-cve-scan` + `gitleaks` requerida.
   - `cis-mailer` / `cis-core` / `cis-auth` NO son candidatos (DKIM keys en
     `cis-mailer` históricos · alembic migrations en `cis-core` filtraron
     schema interno · `cis-auth` docker compose tiene refs a outpost SSL).
   - Trade-off: rompe modelo "T0 internal de Innovación Santiago" (ADR-035).

3. **Org rulesets en lugar de branch protection** (GitHub feature gratuito
   incluso en Free para org owners)
   - **Sí está disponible en Free** para classic rulesets at org level.
   - Limitación: rulesets actúan a nivel commits/branches pero no exponen
     todas las opciones de classic branch protection (ej. `dismiss_stale_reviews`
     funciona via ruleset en plan Pro+, en Free sólo subset).
   - **Acción de seguimiento** (no cubierta en W15 por scope): probar
     `gh api orgs/innovacionsantiago/rulesets` con un ruleset minimal
     (no force push + no delete + linear history) y ver si Free lo acepta
     para repos privados. Si funciona, es free workaround parcial.

### Recomendación

Bundle "GitHub Team upgrade" como single decisión:
- Branch protection T0 (este doc).
- Org secret propagation a private callers (HUMAN-PENDING C4 + W9).
- 2 seats × USD 4 = USD 96/año, evaluable a 12 meses.

Si la decisión humana es "sin upgrade", aplicar opción 3 (rulesets minimal)
como mitigación parcial y dejar trazabilidad explícita en `HUMAN-PENDING C7`.

## Test plan

```bash
# Clone protected repo
git clone https://github.com/innovacionsantiago/core-python-base.git /tmp/test-bp
cd /tmp/test-bp

# Test 1: force push debe fallar
git commit --allow-empty -m "probe"
git push --force origin main
# Expected: "Cannot force-push to this branch"

# Test 2: branch deletion debe fallar
git push origin :main
# Expected: "refusing to delete the current branch"

# Test 3: merge sin review debe requerir PR
# (no se puede testear via CLI · validar manualmente vía PR + intento merge sin approval)
```

Resultados del test ejecutado 2026-05-09 documentados arriba.

## Mantenimiento

Si se agrega un CI nuevo a alguno de los 3 repos:

1. Push del workflow + un commit que dispare el CI.
2. Verificar nombre del check:
   ```bash
   gh api /repos/innovacionsantiago/<repo>/commits/main/check-runs \
     --jq '.check_runs[] | {name, conclusion}'
   ```
3. Update branch protection con el nombre real:
   ```bash
   gh api -X PUT /repos/innovacionsantiago/<repo>/branches/main/protection \
     --input - <<EOF
   {
     "required_status_checks": {
       "strict": true,
       "contexts": ["nombre-real-del-job"]
     },
     ...
   }
   EOF
   ```

Ver el body completo en este mismo doc (sección "Reglas aplicadas").

## Referencias

- ADR-018 (workflows reusables core-python-base / core-ts-base)
- ADR-034 (severity gates CI · CRITICAL bloquea merge)
- `dependabot-auto-merge.md` (V2 follow-up: branch protection + workflow approvals)
- HUMAN-PENDING C4 · CD secrets per-repo workaround Free tier
- HUMAN-PENDING C7 · este trabajo (link bidireccional)
- HUMAN-PENDING W9 · org secrets propagation Free tier
- SEC-2026-05-08-CRYPTOMINER · razón última de todo este hardening
