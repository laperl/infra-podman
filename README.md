# Plataforma de despliegue con Podman y Ansible

Infraestructura de un operador único: servicios en contenedores Podman gestionados por systemd (Quadlet) y desplegados con Ansible.

- Especificación completa: [`docs/SPEC.md`](docs/SPEC.md)
- Flujo de trabajo del operador: [`docs/WORKFLOW.md`](docs/WORKFLOW.md)
- Reglas para agentes de IA: [`CLAUDE.md`](CLAUDE.md)
- Estado y pendientes: [`docs/ROADMAP.md`](docs/ROADMAP.md) · Decisiones: [`docs/DECISIONS.md`](docs/DECISIONS.md)
- Compatibilidad con Podman 4.9: [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md)
- Inventario de secretos (sin valores): [`docs/SECRETS_INVENTORY.md`](docs/SECRETS_INVENTORY.md)
- Puesta en marcha del portátil: [`docs/SETUP.md`](docs/SETUP.md) · Firma SSH: [`docs/SIGNING.md`](docs/SIGNING.md)

## Comprobaciones en local

Lo mismo que ejecuta el workflow `lint`, en Ubuntu 24.04 con `podman` y `shellcheck` instalados:

```bash
python3 -m venv .venv && .venv/bin/pip install -r scripts/requirements-lint.txt
PATH="$PWD/.venv/bin:$PATH"
yamllint --strict . && ansible-lint && shellcheck deploy.sh scripts/*.sh tests/*/run.sh
tests/quadlet/run.sh
python3 -m unittest discover -s tests/unit
tests/deploy/run.sh
```
