# GlitchTip — internal error tracking (anywaye's own use)

**Not part of the customer substrate.** This runs on anywaye's own boxes
(anywaye.com) for error tracking and agent-driven resolution. Customers do
not get this.

## Stand up on a new VPS

```sh
mkdir -p /opt/glitchtip
# copy compose.yml from kit/templates/internal/glitchtip/ (or fetch from git)
cd /opt/glitchtip
export SECRET_KEY="$(openssl rand -hex 32)"
export GLITCHTIP_DOMAIN="https://errors.anywaye.com"   # or http://<ip>:8095
export EMAIL_URL="smtp://..."                          # or consolemail:// for dev
docker compose up -d
```

First run creates the DB. Then create a superuser and project:

```sh
docker exec glitchtip-web-1 ./manage.py createsuperuser --noinput --email admin@anywaye.com
docker exec glitchtip-web-1 ./manage.py shell -c "
from django.contrib.auth import get_user_model
u = get_user_model().objects.get(email='admin@anywaye.com')
u.set_password('CHANGE_ME'); u.save()
from apps.organizations_ext.models import Organization
from apps.projects.models import Project, ProjectKey
org, _ = Organization.objects.get_or_create(name='anywaye', slug='anywaye')
proj, _ = Project.objects.get_or_create(organization=org, name='anywaye', slug='anywaye')
key = ProjectKey.objects.filter(project=proj).first() or ProjectKey.objects.create(project=proj)
print('DSN:', f'http://{key.public_key}@localhost:8095/{proj.id}')
"
```

## Wire services

Set the DSN as an env var in each service's deployment:

- Gateway: `GATEWAY_ERROR_REPORTING_DSN`
- Identity: `IDENTITY_ERROR_REPORTING_DSN`
- Ship: `SHIP_ERROR_REPORTING_DSN`

## MCP server

Enabled via `GLITCHTIP_ENABLE_MCP=True`. Agents connect to `/mcp/` with a
GlitchTip API token. See https://glitchtip.com/documentation/mcp.

## Ports

- 8095 (host) → 8000 (container). Avoids conflicts with identity (8080),
  ship (8090), ella (8000).
