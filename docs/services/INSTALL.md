# Instalar Postgres y una aplicación, paso a paso

La guía para montar desde cero una instancia de Postgres y una aplicación encima. El ejemplo completo es **Firefly III en el portátil, en producción**. Las reglas (por qué cada instancia es independiente y cómo se forman los nombres) están en [`README.md`](README.md); aquí solo el procedimiento.

**Para DEV** es igual, con tres cambios:
- `inventory/dev/` en vez de `inventory/prod/`;
- `infra-dev.kdbx` en vez de `infra-pro.kdbx`;
- `--env dev --limit <tu VM>` en las órdenes, y desde la rama del PR, no desde un tag.

Primero DEV, luego producción ([`WORKFLOW.md`](../WORKFLOW.md)).

## 1. Qué vas a tener al final

| Pieza | Nombre | Qué es |
| --- | --- | --- |
| Postgres | `prod-pg-laptop` | El servidor de bases de datos. Puede alojar las bases de muchas aplicaciones |
| Base de Firefly | `ff_laptop` (base, esquema y usuario) | Los datos de esta instancia de Firefly. Solo suya |
| Firefly | `prod-ff-laptop` | La aplicación. **`ff` es Firefly III** |
| Red | `prod-fflaptop-pg-laptop-net` | El único camino de Firefly: a su Postgres, sin internet |
| Puerto | `127.0.0.1:18100` | Por donde entras tú con el navegador, solo desde el portátil |
| Justificantes | volumen `prod-ff-laptop-uploads` | Los ficheros que adjuntas en Firefly |
| Tareas diarias | `prod-ff-laptop-cron.timer`, a las 05:30 | Movimientos recurrentes, presupuestos y avisos de Firefly |
| Lanzador | «Firefly III (laptop)» en el menú | Abre Firefly en tu navegador |

## 2. Los nombres que eliges tú

Solo eliges **dos nombres cortos**, en minúsculas y cifras, sin guiones. Todo lo demás lo pone el código:

| Qué eliges | Dónde se escribe | Ejemplo | De él sale |
| --- | --- | --- | --- |
| La instancia de Postgres | `name:` en `postgres_hosts.yml` | `laptop` | `prod-pg-laptop` y los secretos `pg-laptop-…` |
| La instancia de la aplicación | `name:` en `firefly_hosts.yml` | `laptop` | `prod-ff-laptop`, `ff_laptop`, `fflaptop`, `ff-laptop-app-key` |

**Escribe solo el nombre corto.** Con `name: laptop` sale `prod-ff-laptop`. Si escribieras `name: prod-ff-laptop`, el despliegue se para: no admite guiones. Así no puede salir `prod-ff-prod-ff-laptop`.

**Cambiar un nombre después** no es renombrar: es crear algo nuevo, vacío. Elígelos bien antes del primer despliegue.

## 3. El superusuario y las contraseñas

**El superusuario** es el administrador de esa Postgres.
- **Su nombre** lo eliges tú (el tuyo, por ejemplo; nunca `postgres`) y se escribe en `superuser:` de `postgres_hosts.yml`. No es secreto.
- **Su contraseña** sí es secreta y va en KeePassXC.
- Lo usan Ansible, para crear bases y usuarios, y tú, para la consola. Ninguna aplicación entra con él.

**Las contraseñas** viven solo en KeePassXC. Están en `infra-pro.kdbx`, dentro del grupo con el nombre de tu instalación (`infra_site` de `group_vars/all.yml`), y en el inventario solo va su nombre. `./deploy.sh secrets` las copia a la máquina como secretos de Podman, con el entorno delante (`prod-…`), y de ahí las leen los servicios. **Nunca las escribes en ningún otro sitio.**

| Entrada en KeePassXC | Qué es | Quién la usa | ¿Tiene que coincidir con otra cosa? |
| --- | --- | --- | --- |
| `pg-laptop-superuser-password` | Contraseña del superusuario de `prod-pg-laptop` | Ansible y la consola | No |
| `pg-laptop-ff_laptop-password` | Contraseña del usuario de Postgres `ff_laptop` | **Dos lados:** Postgres (Ansible se la pone al usuario) y Firefly (la lee para entrar en su base) | Sí, y por eso es **una sola entrada**: los dos leen el mismo secreto y siempre coinciden |
| `ff-laptop-app-key` | La clave interna de Firefly (`APP_KEY`): cifra sus sesiones y las claves de su API. No es un usuario | Solo Firefly | No. Exactamente **32 letras y números**, y no se cambia nunca con Firefly en uso |
| `backup-restic-password`, `backup-server-password` (ya las tienes) | Las de los backups ([`SECRETS_INVENTORY.md`](../SECRETS_INVENTORY.md)) | Los backups | Ya están puestas |

**Tu usuario de Firefly**, el que usas en la web, no es nada de esto. Lo creas tú en Firefly la primera vez (paso 8) y guardas su contraseña donde quieras, por ejemplo en KeePassXC. Ansible no lo conoce.

Para generar valores, usa el generador de KeePassXC, o en una terminal:
```bash
head /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32; echo     # 32 letras y números
```

## 4. Crear las entradas en KeePassXC

En `infra-pro.kdbx`, grupo `<instalación>`, crea:

1. `pg-laptop-superuser-password`;
2. `pg-laptop-ff_laptop-password`;
3. `ff-laptop-app-key`, con exactamente 32 letras y números.

El nombre de cada entrada es el **título** y el valor va en el campo **contraseña**.

## 5. El repo de datos

En `~/Documents/SECURE_vc/ansible/infra-podman/inventory/prod/`. Son los ficheros enteros para un portátil `laptop` y un GX10 `gx10`: son los alias de tu `~/.ssh/config`, así que si los tuyos son otros, usa los tuyos. Lo que va entre `<…>` es tuyo. Si ya tienes alguno de estos ficheros con más cosas, conserva lo tuyo y añade solo lo que falta.

### `hosts.yml`

```yaml
---
all:
  children:
    control:
      hosts:
        localhost:
          ansible_connection: local
          ansible_python_interpreter: "{{ ansible_playbook_python }}"
    servers:
      hosts:
        laptop: {}
        gx10: {}
    backup_clients:
      hosts:
        laptop: {}
    backup_servers:
      hosts:
        gx10: {}
    postgres_hosts:
      hosts:
        laptop: {}
    firefly_hosts:          # máquinas con Firefly
      hosts:
        laptop: {}
```

### `group_vars/all.yml`

```yaml
---
infra_env: prod
infra_site: <instalación>
service_user: svc_runner

# Solo NOMBRES de las entradas de KeePassXC (grupo <instalación>), nunca valores.
infra_secrets:
  - name: pg-laptop-superuser-password
    group: postgres_hosts
  - name: pg-laptop-ff_laptop-password
    group: postgres_hosts
  - name: ff-laptop-app-key
    group: firefly_hosts
  - name: backup-restic-password
    group: backup_clients
  - name: backup-server-password
    group: [backup_clients, backup_servers]

backup_server_max_size_gb: <el tuyo>

ansible_ssh_common_args: "-o ForwardAgent=no"
```

### `group_vars/postgres_hosts.yml`

```yaml
---
postgres_instances:
  - name: laptop                    # → prod-pg-laptop
    superuser: <tu_admin>           # el nombre del administrador; su contraseña, pg-laptop-superuser-password
    databases:
      - name: ff_laptop             # la base de la instancia laptop de Firefly
        users:
          - name: ff_laptop         # el usuario con el que entra Firefly
            group: owner            # puede crear sus tablas (Firefly las crea al arrancar)
            consumer: fflaptop      # solo desde la red de esa instancia de Firefly
```

Los nombres `ff_laptop` y `fflaptop` salen de la instancia de Firefly ([`README.md`](README.md), apartado 3). Otra aplicación sería otro bloque `- name:` dentro de `databases:`.

### `group_vars/firefly_hosts.yml`

```yaml
---
firefly_instances:
  - name: laptop                    # → prod-ff-laptop
    port: 18100                     # 127.0.0.1:18100; desde 18100, uno distinto por instancia
    pg_instance: laptop             # su Postgres: prod-pg-laptop
    language: es_ES
    timezone: Europe/Madrid
    launcher_command: [flatpak, run, org.mozilla.firefox, --new-window]
```

`launcher_command` abre el lanzador con tu Firefox de Flatpak. Comprueba antes que se llama así: `flatpak list --app | grep -i firefox`, en la segunda columna. Sin esta línea, se abre tu navegador predeterminado.

Después, commit firmado:
```bash
cd ~/Documents/SECURE_vc/ansible/infra-podman
git diff
git add -A && git commit -m "prod: Postgres laptop and Firefly laptop"
git verify-commit HEAD
```

## 6. Todo lo que puedes ajustar

**Cada instancia de Firefly** (dentro de `firefly_instances`). Lo que no pongas toma el valor por defecto de `roles/firefly/defaults/main.yml`:

| Parámetro | Por defecto | Para qué |
| --- | --- | --- |
| `name` | obligatorio | La instancia, sin guiones |
| `port` | obligatorio | Su puerto en `127.0.0.1`, desde 18100 |
| `pg_instance` | `main` | En qué Postgres está su base |
| `image` | `firefly_image` | Qué imagen de `images.yml` usa (por ejemplo, una canary) |
| `language` | `en_US` | Idioma de la pantalla de entrada y de los usuarios nuevos |
| `timezone` | `UTC` | Zona horaria |
| `log_level` | `notice` | Cuánto escribe en el log |
| `memory`, `cpus`, `pids_limit` | `512m`, `1`, `200` | Límites. Medido en DEV: unos 70 MB y 12 procesos |
| `start_timeout` | `300` | Segundos que espera a que Postgres esté sano al arrancar |
| `cron_time` | `05:30` | Hora de sus tareas diarias |
| `launcher` | `true` | `false` para no poner lanzador |
| `launcher_name` | `Firefly III (<instancia>)` | Su nombre en el menú |
| `launcher_command` | `[xdg-open]` | El navegador, como lista de palabras y sin la dirección |

Pon estos ajustes **dentro de cada instancia**. No escribas variables sueltas como `firefly_memory`: mandarían sobre todas las instancias.

**Cada instancia de Postgres** (dentro de `postgres_instances`): `name`, `superuser` y `databases`. Las bases y los usuarios se explican en [`POSTGRES.md`](../POSTGRES.md), apartado 6.

**Comunes a todas las Postgres de la máquina**, como variables sueltas en `postgres_hosts.yml`:
- `postgres_memory` (`1g`);
- `postgres_cpus` (`2`);
- `postgres_pids_limit` (`500`);
- `postgres_shm_size` (`256m`);
- `postgres_timezone` (`UTC`).

## 7. Las órdenes, en orden

Desde tu copia del código, en el tag firmado ([`WORKFLOW.md`](../WORKFLOW.md), apartados 5 y 6). Cada `apply` pide escribir `prod` y la contraseña de sudo del portátil. Repite cada `apply` una segunda vez: tiene que dar `changed=0`.

```bash
./deploy.sh secrets --env prod --limit laptop          # 1. KeePassXC → secretos de Podman en el portátil
./deploy.sh plan  postgres --env prod --limit laptop   # 2. lee qué va a crear
./deploy.sh apply postgres --env prod --limit laptop   #    prod-pg-laptop, la base ff_laptop, su usuario y su red
./deploy.sh apply backup   --env prod --limit laptop   # 3. que la copia diaria vuelque también prod-pg-laptop
./deploy.sh plan  firefly  --env prod --limit laptop   # 4. lee qué va a crear
./deploy.sh apply firefly  --env prod --limit laptop   #    prod-ff-laptop; el primer arranque crea las tablas y tarda
```

**El orden importa:**
- **Primero los secretos.** Sin ellos, Postgres y Firefly se paran diciendo cuál falta.
- **Después Postgres.** Crea la base, el usuario y la red que Firefly necesita; si faltan, Firefly se para y dice qué declarar.
- **El backup**, cada vez que añades o quitas una instancia de Postgres.

## 8. Comprobar y entrar

En el portátil:

```bash
svc podman ps --filter label=infra.component=app       # prod-ff-laptop … (healthy)
svc podman healthcheck run prod-pg-laptop && echo sano  # Postgres sano
svc podman port prod-ff-laptop                          # 8080/tcp -> 127.0.0.1:18100
curl -s http://127.0.0.1:18100/health; echo             # OK
svc systemctl --user list-timers 'prod-ff-*'            # sus tareas: mañana a las 05:30
```

La función `svc` está en [`SETUP.md`](../SETUP.md), paso 12. Comprobación completa: [`OPERATIONS.md`](../OPERATIONS.md), apartado 4.

Abre «Firefly III (laptop)» desde el menú y, **la primera vez**:

1. **Crea tu usuario.** El primero que se registra es el administrador.
2. **Activa el doble factor** (TOTP), con KeePassXC como autenticador.
3. En *Administration → Configuration*, deja **apagados** el registro de usuarios nuevos, los tipos de cambio externos, el mapa y los webhooks.
4. Cuando pregunte si buscar actualizaciones, di **No**: de las versiones nuevas ya avisa `image-updates`.

**Para mirar los datos de su base**, en modo solo lectura:

```bash
svc podman exec -it prod-pg-laptop psql -U <tu_admin> -d ff_laptop
```

Dentro, primero `SET default_transaction_read_only = on;` y `SET search_path = ff_laptop;`. Luego `\dt` para ver las tablas y `\q` para salir.

## 9. Si algo falla

Cada mensaje dice qué falta y qué hacer. Si no basta, búscalo en [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md): el apartado 5 es Postgres y el 11 es Firefly.

## 10. Si ya tenías otra Postgres vacía (por ejemplo `prod-pg-main`)

1. **Crea primero la nueva**, con los pasos 4 a 7.
2. **Retira la vieja** mientras aún está declarada en `postgres_hosts.yml`:
   ```bash
   ./deploy.sh apply postgres --env prod --limit laptop --retire main
   ```
3. **Quítala del fichero**, con su línea `pg-main-superuser-password` de `infra_secrets`. Haz un commit firmado y luego:
   ```bash
   ./deploy.sh apply backup --env prod --limit laptop
   ```
4. **Borra sus datos, su secreto y, si quieres, sus copias.** Está en [`POSTGRES.md`](../POSTGRES.md), apartado 7, «Borrar del todo una instancia retirada».
