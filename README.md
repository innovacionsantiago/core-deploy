# core-deploy · reusable CD workflows + deploy templates

**Propósito**: workflows de deploy reusables para todo servicio del ecosistema CIS/CDS, más templates de scripts post-deploy idempotentes.

ADR: **ADR-018** (Python project standard) extendido a deploy.
Plan: `delightful-hopping-avalanche.md` Phase 3 / W7.

## Workflows disponibles

### `cd-vps-cis.yml`

Deploy a vps-cis (108.175.4.190) via rsync + SSH + systemd.

**Inputs**:

| Input | Required | Default | Descripción |
|---|---|---|---|
| `target_path` | sí | — | Path absoluto en vps-cis (debe empezar con `/srv/`) |
| `service_name` | sí | — | Nombre del systemd unit (sin `.service`) |
| `post_deploy_script` | no | `deploy/post_deploy.sh` | Script idempotente post-rsync |
| `health_url` | no | `http://127.0.0.1/healthz` | curl post-deploy desde el host |
| `rsync_excludes` | no | `""` | Patrones extra `--exclude` (separados por espacio) |
| `notify_on_failure` | no | `false` | Mail via Resend a hola@innovacionsantiago.cl |
| `working_directory` | no | `.` | Subdir del repo a sincronizar |

**Org secrets requeridos** (ya seteados en innovacionsantiago):
- `CIS_VPS_HOST` = `108.175.4.190`
- `CIS_VPS_USER` = `illanes00`
- `CIS_VPS_SSH_KEY` = ed25519 private key con write access en `/srv/projects/`
- `RESEND_API_KEY_CIS` (opcional, para `notify_on_failure`)

## Cómo usarlo desde un repo consumidor

`.github/workflows/deploy.yml`:

```yaml
name: Deploy
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    uses: innovacionsantiago/core-deploy/.github/workflows/cd-vps-cis.yml@main
    with:
      target_path: /srv/projects/cds/cis/cis-mailer
      service_name: cis-mailer
      health_url: http://127.0.0.1:8080/healthz
    secrets: inherit
```

`secrets: inherit` propaga los org-level secrets (`CIS_VPS_*`, `RESEND_API_KEY_CIS`) al workflow callable.

## Templates `post_deploy.sh`

Copiar al repo en `deploy/post_deploy.sh` y adaptar:

- **Python**: `templates/post_deploy.python.sh` — venv + pip + alembic + systemctl restart + healthz.
- **TS/Node**: `templates/post_deploy.ts.sh` — npm ci + build + systemctl restart + healthz.

```bash
# en el repo consumidor
mkdir -p deploy
cp /srv/projects/core/core-deploy/templates/post_deploy.python.sh deploy/post_deploy.sh
chmod +x deploy/post_deploy.sh
git add deploy/post_deploy.sh
```

Variables que el workflow exporta al script:
- `SERVICE_NAME` — systemd unit
- `HEALTH_URL` — curl target post-restart

Los scripts son **idempotentes**: pueden correr N veces sin efectos colaterales.

## Convenciones de seguridad

- **SSH key inyectada via env**, no en `run:` literal (evita leak en logs).
- **`target_path` validado**: debe empezar con `/srv/`. Evita typos catastróficos tipo `/etc` o `/`.
- **rsync `--delete`** activado. Lo que no esté en el repo se borra del target. Excludes default protegen `.env`, `.git`, `node_modules`, `.venv`, etc.
- **Concurrency group** por `service_name`: dos deploys del mismo servicio no corren en paralelo.
- **SSH key cleanup** en step `if: always()` post-deploy.

## TODO

- [ ] Hardcodear `known_hosts` del vps-cis tras primera deploy validada (evitar TOFU permanente).
- [ ] Migrar a OIDC GitHub si vps-cis suporta `github-actions-runner` self-hosted.
- [ ] Rollback automático si healthz falla (tag previous deploy + git revert + redeploy).
- [ ] cis-mailer call directo en vez de Resend para uniformidad.

## Referencias

- `vps-cis(1)` manual: `cat /srv/projects/a`
- `STRUCTURE.md` — layout `/srv/projects/`
- `core-python-base/.github/workflows/ci-python.yml` — sibling CI workflow
- `core-ts-base/.github/workflows/ci-typescript.yml` — sibling CI workflow
