# Ejemplo de inventario

Esta carpeta es un **ejemplo con nombres inventados**. La usan el CI y las pruebas, y sirve de plantilla. Tu inventario real vive en tu **repo de datos** (SPEC 4.13, R38), con esta misma estructura dentro de una carpeta `inventory/`:

```text
infra-podman/                      # tu repo de datos (solo en el portátil, commits firmados)
  inventory/
    dev/                           # --env dev
      hosts.yml                    # máquinas y grupos
      group_vars/
        all.yml                    # variables de todas las máquinas del entorno
        postgres_hosts.yml         # instancias de Postgres (y, en la fase 2, bases y usuarios)
      host_vars/                   # variables de una sola máquina: <alias>.yml
    prod/                          # --env prod, igual
      ...
```

`deploy.sh` lee `inventory/<entorno>/hosts.yml` de la ruta `data_repo` de `~/.config/infra-podman/deploy.conf`. Ansible carga solo `group_vars/` y `host_vars/` que estén junto a ese `hosts.yml`.

## Qué va en cada fichero

| Fichero | Qué contiene | Ejemplo |
| --- | --- | --- |
| `hosts.yml` | Las máquinas, por su alias de `~/.ssh/config`, y a qué grupo pertenecen. La dirección y el usuario de SSH **no** van aquí | [`prod/hosts.yml`](prod/hosts.yml) |
| `group_vars/all.yml` | Entorno (`infra_env`), usuario de servicio, **nombres** de los secretos que hay en KeePassXC (`infra_secrets`) y opciones de SSH | [`prod/group_vars/all.yml`](prod/group_vars/all.yml) |
| `group_vars/postgres_hosts.yml` | Las instancias de Postgres de cada máquina del grupo. Desde la fase 2, también las bases y los usuarios de cada aplicación ([`POSTGRES.md`](../docs/POSTGRES.md), sección 6) | [`prod/group_vars/postgres_hosts.yml`](prod/group_vars/postgres_hosts.yml) |
| `host_vars/<alias>.yml` | Lo que cambie solo en una máquina. Hoy, en el portátil: que su backup copie también el repo de datos y el aviso de escritorio | [`prod/host_vars/example-laptop.yml`](prod/host_vars/example-laptop.yml) |

Lo que llegue en fases siguientes (aplicaciones como Firefly o pgAdmin, qué guarda cada una en los backups) también son datos: cada PR dice qué añadir y dónde, y actualiza este ejemplo.

## Qué nunca va en el repo de datos

- **Contraseñas ni claves**: viven en KeePassXC (SPEC 4.5). En el inventario solo sus nombres.
- Direcciones IP y usuarios de SSH: en tu `~/.ssh/config`.
- Código: roles, plantillas y playbooks están en el repo de código.

## Cómo se cambian los datos

En `docs/WORKFLOW.md`, «Cambiar datos»: editar, commit firmado y `deploy.sh plan`.
