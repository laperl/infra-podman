# Plataforma de despliegue con Podman y Ansible

Infraestructura de un operador único: servicios en contenedores Podman gestionados por systemd (Quadlet) y desplegados con Ansible.

## Empieza aquí

| Quiero… | Documento |
| --- | --- |
| Hacer un cambio y desplegarlo: PR, DEV, merge, tag, `plan` y `apply` | [`docs/WORKFLOW.md`](docs/WORKFLOW.md) |
| Desplegar en producción paso a paso | [`docs/WORKFLOW.md`, pasos 5 y 6](docs/WORKFLOW.md#5-crear-el-tag-firmado) |
| Preparar el portátil (se hace una vez) | [`docs/SETUP.md`](docs/SETUP.md) |
| Configurar la firma de tags y commits (una vez) | [`docs/SIGNING.md`](docs/SIGNING.md) |
| Saber en qué fase estamos y qué queda pendiente | [`docs/ROADMAP.md`](docs/ROADMAP.md) |
| Ver qué secretos existen (sin valores) | [`docs/SECRETS_INVENTORY.md`](docs/SECRETS_INVENTORY.md) |
| Cómo se monta Postgres: instancias, bases, grupos, usuarios y acceso | [`docs/POSTGRES.md`](docs/POSTGRES.md) |
| Cambiar el inventario (máquinas, instancias, bases…): vive en tu repo de datos | [`docs/WORKFLOW.md`, «Cambiar datos»](docs/WORKFLOW.md#cambiar-datos) y [`inventory.example/`](inventory.example/README.md) |

## Referencia

- Especificación completa, la fuente de verdad: [`docs/SPEC.md`](docs/SPEC.md)
- Por qué se decidió cada cosa: [`docs/DECISIONS.md`](docs/DECISIONS.md)
- Compatibilidad con Podman 4.9: [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md)
- Reglas para agentes de IA: [`CLAUDE.md`](CLAUDE.md)

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
