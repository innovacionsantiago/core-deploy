# Rollback playbook · CD vps-cis

Procedimiento manual para revertir un deploy roto del workflow reusable
[`cd-vps-cis.yml`](.github/workflows/cd-vps-cis.yml).

> **Cuándo usar**: el smoke W9.5 (cis-mailer, 2026-05-09) reveló que un escenario
> realista — archivos sólo-en-prod (no commiteados) → `rsync --delete` los borra
> → service no arranca. ROLLBACK.md cubre ese caso y los típicos.

## Cuándo rollback?

Disparar rollback si **alguna** de las siguientes ocurre dentro de los 5 min
post-deploy:

- `Health check (remote curl)` falla en el workflow (paso final de cd-vps-cis).
- `systemctl status <service>` queda en `activating (auto-restart)` loop o
  `failed`.
- `journalctl -u <service> -n 50` muestra `ImportError`/`ModuleNotFoundError`/
  `OperationalError`/`ConnectionRefused` post-restart.
- 500s visibles en prod (Caddy access logs, Authentik, frontend).
- KPIs de negocio caen (envíos mailer = 0, healthz timeout, etc.).

## Pre-rollback: estabilizar prod (≤1 min)

Antes de tocar git, **detener el restart loop** si systemd está reintentando:

```bash
ssh illanes00@vps-cis
sudo systemctl stop <service>           # corta el loop
sudo systemctl status <service>         # confirma stopped
```

Esto evita que el log se llene mientras debuggeás y deja prod "down clean"
(mejor que "flapping").

## Camino rápido (deploy reciente, source en git OK)

Si el problema es código + no hay archivos huérfanos en prod:

```bash
ssh illanes00@vps-cis
cd /srv/projects/<service-path>

# 1. Identificar último commit good
git log --oneline -10
# elegir el commit anterior al deploy roto (busca el commit ANTES del deploy)

# 2. Revert filesystem al commit good
git stash                                # save WIP si lo hubiera
git reset --hard <last-good-commit>      # ahora árbol = commit good

# 3. Re-run post_deploy (idempotente)
bash deploy/post_deploy.sh

# 4. Verify
curl -fsS http://127.0.0.1:<port>/healthz
sudo journalctl -u <service> -n 30 --no-pager
```

Si el `post_deploy.sh` no quedó tras el rollback (raro), usar el del repo en
`/srv/projects/core/core-deploy/templates/`.

## Camino con archivos huérfanos (caso W9.5)

Si el deploy `--delete`ó archivos que sólo vivían en prod (no estaban en git):

```bash
ssh illanes00@vps-cis
cd /srv/projects/<service-path>

# 1. Confirmar el daño
ls __pycache__/                          # los .pyc suelen sobrevivir
git status                               # ver qué quedó / qué falta

# 2. Restaurar desde .pyc (si existen)
# Python puede importar .pyc directamente si está en la ruta del módulo,
# fuera de __pycache__:
for sub in '' routers services; do
  base="app/$sub"; cache="$base/__pycache__"
  [ -d "$cache" ] || continue
  for f in "$cache"/*.cpython-312.pyc; do
    [ -e "$f" ] || continue
    mod=$(basename "$f" .cpython-312.pyc)
    [ -f "$base/$mod.py" ] || cp "$f" "$base/$mod.pyc"
  done
done

sudo systemctl restart <service>
curl -fsS http://127.0.0.1:<port>/healthz   # debería pasar

# 3. Reconstruir source limpia (en una segunda pasada, sin urgencia)
#    a) introspección del runtime con venv/bin/python -c "..."
#       (saca model_fields, columns, routes, signatures)
#    b) decompiler (pycdc): build de https://github.com/zrax/pycdc · `cmake . && make`
#    c) commit los .py reconstruidos · push · re-deploy via workflow

# 4. Limpiar los .pyc fallback una vez que .py estén en git+prod
rm -f app/*.pyc app/routers/*.pyc app/services/*.pyc
sudo systemctl restart <service>
curl -fsS http://127.0.0.1:<port>/healthz
```

## Camino sistémico (DB / migraciones / Alembic head fallido)

Si el problema es schema y `alembic upgrade head` rompió la app:

```bash
cd /srv/projects/<service-path>
source venv/bin/activate

# 1. Ver historial alembic
alembic history --verbose | head -20

# 2. Downgrade al revision previo
alembic downgrade -1            # un step atrás
# o: alembic downgrade <rev_id>

# 3. Restart
sudo systemctl restart <service>
curl -fsS http://127.0.0.1:<port>/healthz
```

Si la migración drop-eó tablas con datos: levantar dump pre-deploy desde
`/srv/projects/cis/backups/db/` (rsnapshot diario · default 17:13 UTC).

```bash
# Ejemplo cis-mailer
gunzip -c /srv/projects/cis/backups/db/cis_mailer_<fecha>.sql.gz | \
  sudo -u postgres psql cis_mailer
```

## Post-rollback: notificar y abrir ticket

1. **Channel note** (`cis-note`):
   ```
   [rollback] <service> · root cause: <X> · prod restaurado vía <camino>
   · last good commit <hash> · ticket HUMAN-PENDING D-cd-rollback-<service>
   ```

2. **Push commit de rollback** si el git reset cambió el árbol vs origin:
   ```bash
   git push origin HEAD:rollback/<svc>-<fecha>      # rama, NO --force a main
   gh pr create --title "rollback: <service> revert <hash>" \
                --body "Rollback W9 smoke W<...> root cause: <X>"
   ```
   No `--force-with-lease` a main/master jamás sin ack humano.

3. **Disable workflow_dispatch** del CD (workflow_dispatch only V1 es justo
   esto: que ningún trigger automático corra mientras debuggeás).
   ```bash
   gh workflow disable cd.yml --repo innovacionsantiago/<service>
   # re-enable cuando esté el fix:
   gh workflow enable cd.yml  --repo innovacionsantiago/<service>
   ```

4. **Postmortem** breve: agregar entry a `cis/CHANNEL.md` + ticket HUMAN-PENDING.
   En W9.5 el postmortem reveló: "audit pre-deploy de archivos untracked-on-prod
   en cada repo target ANTES de habilitar push-on-main". Ese ticket vive en
   `cis/HUMAN-PENDING.md` C-cd-untracked-audit.

## Prevention · pre-flight untracked check (W11.5)

Después del incidente cis-mailer W9.5, el reusable `cd-vps-cis.yml` ganó un step
**Pre-flight · audit untracked-on-prod (warn-only V1)** que corre EN VPS antes
del `rsync --delete`:

```yaml
- name: Pre-flight · audit untracked-on-prod (warn-only V1)
  shell: bash
  continue-on-error: true
  run: |
    ssh vps-cis "
      cd '$TARGET_PATH' && [ -d .git ] || exit 0
      UNTRACKED=\$(git ls-files --others --exclude-standard)
      [ -n \"\$UNTRACKED\" ] && {
        echo \"::warning::archivos untracked serán BORRADOS por rsync --delete\"
        printf '%s\n' \"\$UNTRACKED\" | head -20 | sed 's/^/::warning::  /'
      }
    "
```

V1 = warn-only · queda en el log del run pero no aborta. V2 (cuando todos los
repos cierren HUMAN-PENDING C5) = ramp a abort hard.

Adicional: los templates `post_deploy.python.sh` y `post_deploy.ts.sh` también
hacen el check post-rsync para capturar drift introducido por el deploy mismo
(p.ej. build outputs no gitignored).

### Audit cross-repo (one-shot per ola)

```bash
ssh illanes00@vps-cis
bash /srv/projects/cis/scripts/audit-untracked-on-prod.sh
# → text en stderr · JSON en /var/log/cis-validators/untracked-audit-YYYYMMDD.json
# Exit codes: 0 clean · 1 hay source untracked · 2 posibles secretos
```

### Validator structurado · suite cis-validators

`structure.untracked_on_prod` (cis-validators) es la versión auditable:
emite findings por archivo (HIGH si source · CRITICAL si secret · MEDIUM si
doc) y se integra al gate de severidad del orchestrator:

```yaml
# cis-validators/config/targets.yaml — agregar a cualquier target prod:
- name: cis_<svc>
  layers: [structure]   # entre otros
  meta:
    repo_root: /srv/projects/cds/cis/cis-<svc>
```

Tracking: HUMAN-PENDING C5 (cerrado 2026-05-09 W11.5).

## Lecciones W9.5 (cis-mailer · 2026-05-09)

1. **`rsync --delete` es brutal**: borra todo lo que no esté en el repo, incluso
   si llevaba meses funcionando en prod. Pre-deploy obligatorio:
   ```bash
   ssh illanes00@vps-cis
   cd /srv/projects/<svc>
   git status                        # detecta untracked-on-prod
   git ls-files <pkg-principal>/ | wc -l
   find <pkg-principal>/ -name "*.py" | wc -l
   # si los counts no matchean → hay archivos no commiteados que se perderán.
   ```
   **Nota W11.5**: este check ya está automatizado en el reusable workflow
   (warn-only V1) + en los templates post_deploy + en el script
   `/srv/projects/cis/scripts/audit-untracked-on-prod.sh` + en el suite
   `cis-validators structure.untracked_on_prod`. Sección "Prevention" arriba.

2. **`secrets: inherit` cross-repo NO funciona en GitHub Free org → private repo**.
   Workaround: setear los secrets a nivel repo manualmente:
   ```bash
   echo -n "108.175.4.190" | gh secret set CIS_VPS_HOST --repo <repo>
   echo -n "illanes00"     | gh secret set CIS_VPS_USER --repo <repo>
   cat ~/.ssh/cis_ci_deploy_ed25519 | gh secret set CIS_VPS_SSH_KEY --repo <repo>
   ```
   Tracking en HUMAN-PENDING C-cd-secrets-per-repo (eventual: GitHub Pro upgrade
   o repos públicos).

3. **`.pyc` survive es oro**: Python carga `module.pyc` directamente si vive al
   lado del paquete (no en `__pycache__`). Vale como crash-cart por 5 minutos.

4. **post_deploy.sh idempotente importa**: el script de cis-mailer corrió 3
   veces seguidas durante el debug sin romper venv ni DB. El template
   `core-deploy/templates/post_deploy.python.sh` es la base correcta.

## Healthchecks rápidos por servicio (V1)

| Service        | Local URL                              | Public URL                                              |
|----------------|----------------------------------------|---------------------------------------------------------|
| cis-mailer     | `http://127.0.0.1:9180/healthz`        | `https://mail.innovacionsantiago.cl/healthz`            |
| cis-platform   | `http://127.0.0.1:8176/healthz`        | `https://api.innovacionsantiago.cl/healthz`             |
| cis-core       | `http://127.0.0.1:8200/healthz`        | `https://core.innovacionsantiago.cl/healthz`            |
| cis-auth       | `http://127.0.0.1:9000/-/health/ready/`| `https://auth.innovacionsantiago.cl/-/health/ready/`    |
| cis-claudia    | `http://127.0.0.1:8172/healthz`        | (loopback only)                                         |
| cis-inbox      | `http://127.0.0.1:8260/healthz`        | (loopback only)                                         |
| cis-sign       | `http://127.0.0.1:8190/healthz`        | `https://sign.innovacionsantiago.cl/healthz`            |
| cis-mando      | `http://127.0.0.1:8267/healthz`        | `https://mando.innovacionsantiago.cl/healthz`           |
| cis-www        | (build estático)                       | `https://innovacionsantiago.cl/`                        |
| cis-isometrico | (pipeline batch)                       | n/a                                                     |

## Referencias

- Reusable workflow: [`cd-vps-cis.yml`](.github/workflows/cd-vps-cis.yml)
- Templates post_deploy: [`templates/`](templates/)
- Manual vps-cis: `/srv/projects/a` (para SSH/sudo/systemd cheats)
- HUMAN-PENDING: `/srv/projects/cis/HUMAN-PENDING.md` sección C-cd-* y D-cd-*
- pycdc decompiler: <https://github.com/zrax/pycdc> (build con `cmake . && make`)
