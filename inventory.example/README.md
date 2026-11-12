# Ejemplo de inventario

Esta carpeta es un **ejemplo con nombres inventados**. La usan el CI y las pruebas, y sirve de plantilla. Tu inventario real vive en tu **repo de datos** (SPEC 4.13, R38), con esta misma estructura dentro de una carpeta `inventory/`:

```text
infra-podman/                      # tu repo de datos (solo en el portátil, commits firmados)
  inventory/
    dev/                           # --env dev
      hosts.yml                    # máquinas y grupos
      group_vars/
        all.yml                    # variables de todas las máquinas del entorno
        postgres_hosts.yml         # instancias de Postgres, con las bases y los usuarios de las aplicaciones
        firefly_hosts.yml          # instancias de Firefly III (fase 2)
      host_vars/                   # variables de una sola máquina: <alias>.yml
    prod/                          # --env prod, igual
      ...
```

`deploy.sh` lee `inventory/<entorno>/hosts.yml` de la ruta `data_repo` de `~/.config/infra-podman/deploy.conf`. Ansible carga solo `group_vars/` y `host_vars/` que estén junto a ese `hosts.yml`.

## Qué va en cada fichero

| Fichero | Qué contiene | Ejemplo |
| --- | --- | --- |
| `hosts.yml` | Las máquinas, por su alias de `~/.ssh/config`, y a qué grupo pertenecen. La dirección y el usuario de SSH **no** van aquí | [`prod/hosts.yml`](prod/hosts.yml) |
| `group_vars/all.yml` | Entorno (`infra_env`), usuario de servicio, **nombres** de los secretos que hay en KeePassXC (`infra_secrets`), tope del servidor de copias y opciones de SSH | [`prod/group_vars/all.yml`](prod/group_vars/all.yml) |
| `group_vars/postgres_hosts.yml` | Las instancias de Postgres de cada máquina del grupo. Desde la fase 2, también las bases y los usuarios de cada aplicación ([`POSTGRES.md`](../docs/POSTGRES.md), sección 6) | [`prod/group_vars/postgres_hosts.yml`](prod/group_vars/postgres_hosts.yml) |
| `group_vars/firefly_hosts.yml` | Las instancias de Firefly III de cada máquina del grupo: nombre, puerto, idioma, navegador del lanzador… Paso a paso en [`docs/services/INSTALL.md`](../docs/services/INSTALL.md) | [`prod/group_vars/firefly_hosts.yml`](prod/group_vars/firefly_hosts.yml) |
| `host_vars/<alias>.yml` | Lo que cambie solo en una máquina. Hoy, en el portátil: que su backup copie también el repo de datos, el aviso de escritorio y adónde va la copia externa (`backup_remote_url`). En la VM DEV, que no tiene Tailscale: servidor de copias sin exponer y copia en la misma VM | [`prod/host_vars/example-laptop.yml`](prod/host_vars/example-laptop.yml), [`dev/host_vars/example-vm.yml`](dev/host_vars/example-vm.yml) |

Lo que llegue en fases siguientes (pgAdmin, qué guarda cada aplicación en los backups) también son datos: cada PR dice qué añadir y dónde, y actualiza este ejemplo.

## Límites de recursos

Todo contenedor tiene tope de memoria, de procesador y de procesos (R46). Cada uno trae un valor por defecto; para cambiarlo, escribe la variable en el fichero indicado y haz `plan` y `apply` del playbook.

| Contenedor | Variables y valor por defecto | Dónde se cambian |
| --- | --- | --- |
| Postgres (todas las instancias de la máquina) | `postgres_memory` (`1g`), `postgres_cpus` (`"2"`), `postgres_pids_limit` (`500`) | `group_vars/postgres_hosts.yml` |
| Firefly III (cada instancia) | `memory` (`512m`), `cpus` (`"1"`), `pids_limit` (`200`), dentro de la instancia | `group_vars/firefly_hosts.yml` |
| Backup local y copia al servidor (`<entorno>-backup`, `<entorno>-backup-copy`) | `backup_memory` (`1g`), `backup_cpus` (`"2"`), `backup_pids_limit` (`500`) | `host_vars/<alias>.yml` de la máquina que hace copias |
| Servidor de copias (`<entorno>-backup-server`) | `backup_server_memory` (`512m`), `backup_server_cpus` (`"1"`), `backup_server_pids_limit` (`200`) | `host_vars/<alias>.yml` de la máquina que las guarda |

Los procesadores van entre comillas, para que YAML no los cambie (`"0.5"`). Si un contenedor se queda sin memoria, Podman lo anota: `podman inspect --format '{{.State.OOMKilled}}' <contenedor>`.

## Qué nunca va en el repo de datos

- **Contraseñas ni claves**: viven en KeePassXC (SPEC 4.5). En el inventario solo sus nombres.
- Direcciones IP y usuarios de SSH: en tu `~/.ssh/config`.
- Código: roles, plantillas y playbooks están en el repo de código.

## Cómo se cambian los datos

En `docs/WORKFLOW.md`, «Cambiar datos»: editar, commit firmado y `deploy.sh plan`.
