# Norma de nombres

Cómo se llama **todo** lo que crea la plataforma. Es de obligado cumplimiento para cualquier pieza nueva: aplicaciones, roles, variables, secretos, redes y copias. La norma sale de las decisiones R48, R49 y R50 ([`DECISIONS.md`](DECISIONS.md)). La política de Quadlet del CI hace cumplir una parte: prefijo de entorno, nombres explícitos y etiquetas.

## 1. Las cinco reglas

1. **Un identificador por instancia**: `<corto>-<instancia>`, por ejemplo `ff-laptop` o `pg-laptop`. Todo lo de esa instancia empieza por él.
2. **Dos alfabetos, nunca mezclados:**
   - **fuera de Postgres**, minúsculas, cifras y `-`. Es la regla de los nombres DNS (RFC 1123), la de Podman y Kubernetes;
   - **dentro de Postgres** (bases, esquemas, usuarios, grupos), minúsculas, cifras y `_`, porque Postgres no admite `-` sin comillas. Se pasa de uno a otro cambiando `-` por `_`: `ff-laptop` es `ff_laptop`.
3. **En las máquinas, el entorno va delante:** `dev-` o `prod-`. Así nunca hay duda de qué es cada cosa.
4. **En KeePassXC, nunca hay entorno** en un título. Lo separa el fichero: `infra-dev.kdbx` e `infra-pro.kdbx` tienen los mismos títulos.
5. **El operador solo escribe nombres cortos** (la instancia: `laptop`), sin guiones. El código compone el resto y rechaza un nombre entero, para que no pueda salir `prod-ff-prod-ff-laptop`.

## 2. Nombres cortos de las aplicaciones

Cada aplicación tiene un nombre **de código**, que se usa en el repositorio y el inventario, y un nombre **corto**, que se usa en todo lo que existe en la máquina.

| Aplicación | De código | Corto | Variable del nombre corto |
| --- | --- | --- | --- |
| PostgreSQL | `postgres` | `pg` | fijo en el rol |
| Firefly III | `firefly` | **`ff`** | `firefly_short` |
| Backup local y servidor de copias | `backup`, `backup_server` | `backup`, `backup-server` | fijos en sus roles (no van por instancias) |

**Una aplicación nueva** escoge su nombre corto con dos condiciones: que no esté ya en esta tabla y que sea de 2 a 6 letras. Se añade aquí **en el mismo PR** que la aplicación.

## 3. Lo que eliges tú

| Qué | Dónde | Formato | Ejemplo |
| --- | --- | --- | --- |
| Instancia de Postgres | `name:` de `postgres_instances` | `^[a-z0-9]+$` | `laptop` |
| Instancia de una aplicación | `name:` de `<app>_instances` | `^[a-z0-9]{1,14}$` | `laptop`, `casa`, `canary` |
| Superusuario de Postgres | `superuser:` | `^[a-z_][a-z0-9_]{0,62}$`; ni `backup`, ni `public`, ni `pg_*`. Mejor uno tuyo que `postgres` | el tuyo |
| Base y usuario de otra cosa que no es una aplicación de aquí | `databases:` | `^[a-z][a-z0-9_]*$` | `ai_reader` |
| Puerto de una instancia | `port:` | desde 18100, uno por instancia | `18100` |
| Instalación | `infra_site` | `^[a-z][a-z0-9-]{1,30}$`, igual en dev y prod | tu nombre de instalación |

## 4. Lo que compone el código

Ejemplo: Firefly `laptop` en la Postgres `laptop`, en producción.

| Objeto | Patrón | Ejemplo |
| --- | --- | --- |
| Contenedor y su servicio | `<entorno>-<corto>-<instancia>` | `prod-ff-laptop`, `prod-pg-laptop` |
| Fichero Quadlet | el nombre del objeto y su tipo | `prod-ff-laptop.container` |
| Volumen | `<entorno>-<corto>-<instancia>-<contenido>` | `prod-ff-laptop-uploads`, `prod-pg-laptop-data` |
| Red hacia Postgres | `<entorno>-<consumidor>-pg-<instancia>-net` | `prod-ff-laptop-pg-laptop-net` |
| `consumer:` en Postgres | el identificador de la aplicación | `ff-laptop` |
| Base, esquema y usuario de una aplicación | `<corto>_<instancia>` | `ff_laptop` |
| Grupos de una base | `<base>_owner`, `_writer`, `_reader` | `ff_laptop_owner` |
| Tareas programadas | `<entorno>-<corto>-<instancia>-<tarea>` | `prod-ff-laptop-cron.timer` |
| Lanzador del menú | `infra-podman-<entorno>-<corto>-<instancia>.desktop` | «Firefly III (laptop)» |
| Configuración en la máquina | `~/.config/infra-podman/<entorno>-<corto>-<instancia>` | `…/prod-pg-laptop` |
| Etiqueta `infra.app` | `<corto>-<instancia>` | `ff-laptop`, `pg-laptop` |

Nombres explícitos siempre: `ContainerName=`, `NetworkName=` y `VolumeName=`. Sin ellos, Podman antepone `systemd-` (comprobado con el generador de 4.9).

## 5. Secretos

| Qué | Entrada de KeePassXC (grupo `<instalación>`) | Secreto de Podman |
| --- | --- | --- |
| Secreto de una instancia | `<corto>-<instancia>-<qué>` | `<entorno>-` + lo mismo |
| Contraseña de cualquier usuario de base | `<usuario>-db-password`, con `-` en lugar de `_` | `prod-ff-laptop-db-password` |
| Superusuario de Postgres | `pg-<instancia>-superuser-password` | `prod-pg-laptop-superuser-password` |
| Backups | `backup-<qué>` | `prod-backup-restic-password` |
| Prueba de lectura | `test-dummy` | no se instala |

Ejemplos: `ff-laptop-app-key`, `ff-laptop-db-password`, `pg-laptop-superuser-password`.

- **`<qué>` dice qué es:** `-password`, `-key` o `-token`.
- **Un nombre de usuario de base no se repite** en dos instancias de Postgres de la misma máquina: su contraseña sería la misma, y el `apply` se para.
- **Lo que no es de la plataforma** no lleva esta norma, porque no está en `infra_secrets`. Por ejemplo, el token del registro de imágenes que usa `deploy.sh`.

## 6. Etiquetas

Todo contenedor, red y volumen lleva:

| Etiqueta | Valor | Ejemplo |
| --- | --- | --- |
| `infra.env` | el entorno | `prod` |
| `infra.app` | el identificador | `ff-laptop` |
| `infra.component` | qué es | `db`, `app`, `data`, `net`, `backup` |
| `infra.managed-by` | quién lo gestiona | `infra-podman` |

Sirven para filtrar: `podman ps --filter label=infra.app=ff-laptop`. Es la idea de las etiquetas recomendadas de Kubernetes (`app.kubernetes.io/…`), sin Kubernetes.

## 7. Copias de seguridad

| Qué | Patrón | Ejemplo |
| --- | --- | --- |
| Carpeta en la copia | `/backup/<app>/<tipo>/<nombre>` | `/backup/pg-laptop/pgdump/ff_laptop` |
| Etiquetas de restic | `site=`, `env=`, `app=`, `type=`, `reason=` | `app=pg-laptop`, `type=pgdump` |
| Repositorio en el servidor de copias | `/data/<instalación>/<entorno>-<máquina>` | `/data/<instalación>/prod-laptop` |

## 8. En el código

| Qué | Formato | Ejemplo |
| --- | --- | --- |
| Rol, playbook, grupo del inventario | nombre de código | `roles/firefly`, `playbooks/firefly.yml`, `firefly_hosts` |
| Lista de instancias | `<app>_instances` | `firefly_instances` |
| Variables de un rol | `<rol>_<cosa>`, en `snake_case` | `firefly_memory`, `postgres_confirm_drop` |
| Imágenes, en `images.yml` | `<app>[_<variante>]_image`, con `# track: <etiqueta>` | `firefly_image`, `firefly_canary_image` |
| Opción de `deploy.sh` | `--<verbo>` | `--retire`, `--confirm-drop` |
| Rama | `<tipo>/<tema>` | `feat/ff-names` |
| Commit | prefijo convencional | `feat:`, `fix:`, `docs:` |

Documentación y mensajes, en español; código, variables y commits, en inglés (`CLAUDE.md`).

## 9. Lista para una pieza nueva

- [ ] Nombre corto nuevo en la tabla del apartado 2.
- [ ] El operador solo escribe la instancia; el rol compone los nombres a partir del identificador.
- [ ] Nombres explícitos y las cuatro etiquetas en cada `.container`, `.network` y `.volume`.
- [ ] Secretos `<corto>-<instancia>-<qué>`, en `infra_secrets` y en [`SECRETS_INVENTORY.md`](SECRETS_INVENTORY.md).
- [ ] Si usa Postgres: base y usuario `<corto>_<instancia>`, y `consumer: <corto>-<instancia>`.
- [ ] Ningún entorno en un título de KeePassXC.
