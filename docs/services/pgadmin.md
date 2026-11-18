# pgAdmin 4 (`pgadmin`): requisitos (fase 2)

**`pgadmin` es pgAdmin 4:** su nombre corto en todo lo que se crea en la máquina, y también su nombre de código (`roles/pgadmin`, `pgadmin_instances`). La instancia `laptop` es `prod-pgadmin-laptop`. Instalarla, paso a paso: [`INSTALL.md`](INSTALL.md); lo que es propio de pgAdmin está en el apartado 7.

Qué tiene que cumplir pgAdmin antes de escribir su código. Es una propuesta: lo que esté aquí y no en SPEC, sección 3, se aprueba con este PR. Lo marcado 🔍 no está verificado en la documentación oficial o en una máquina: se comprueba en `lifecycle` o en DEV, y el PR que lo verifique lo deja escrito.

**Para qué:** administrar a mano las instancias de Postgres de la plataforma desde el navegador del portátil (R37). Postgres no publica puertos (SPEC 4.4), así que pgAdmin tiene que vivir dentro, como una aplicación más de `svc_runner`.

**Por instancias (R48),** como cualquier aplicación ([`README.md`](README.md)), aunque lo normal es tener una sola, que puede administrar **una o varias** Postgres de la misma máquina. Abajo, `<instancia>` es el `name:` de la tuya.

Fuente de todo lo que dice este documento de la imagen, salvo que se diga otra cosa: [Container Deployment, pgAdmin 4 9.19](https://www.pgadmin.org/docs/pgadmin4/9.19/container_deployment.html). Todas las opciones de configuración: [The config.py File](https://www.pgadmin.org/docs/pgadmin4/9.19/config_py.html).

## 1. Ficha

| Dato | Valor |
| --- | --- |
| Nombres | De código `pgadmin`; corto `pgadmin` (7 letras, su nombre real, R52) |
| Imagen | `docker.io/dpage/pgadmin4`, la oficial, en Docker Hub; sin suscripción. Se sigue la versión exacta: `# track: 9.19`, que corrige 15 vulnerabilidades del modo servidor. Digest del índice calculado por el operador el 2026-11-18 con `skopeo inspect --raw \| sha256sum`, con `linux/amd64` y `linux/arm64` |
| Usuario del contenedor | `pgadmin`, UID y GID 5050. Sin `User=` ni `UserNS=`: como Firefly con su UID 33, el 5050 de dentro es un UID subordinado de `svc_runner` en el host |
| Endurecimiento | `DropCapability=all` y `NoNewPrivileges=true`, sin excepción: la imagen lo contempla y entonces escucha en el 8080. `ReadOnly=true` 🔍 (apartado 3) |
| Contrato | `database: none` (sus datos propios van en SQLite, en su volumen), `providers: [postgres]` (al menos una en `connects_to`), `egress: false`. Además, está en `infra_postgres_admins` (apartado 3) |
| Entrada | HTTP en el 8080, publicado en `127.0.0.1:<puerto>`. Salud: `GET /misc/ping` responde 200 y `PING` (dicho por sus desarrolladores en la lista oficial `pgadmin-support`, no en la documentación). 🔍 Qué herramienta trae la imagen para pedirlo (`wget` o `python3`) |
| Datos | `/var/lib/pgadmin` (sesiones, ficheros de usuario, configuración y su base SQLite): volumen `prod-pgadmin-<instancia>-data`. `/tmp` en `tmpfs` |
| Secretos | Uno: la contraseña de entrada (apartado 4) |
| Copias | Opcional, apagada por defecto: `backup: [data]`, el volumen entero (apartado 6) |
| Primer arranque | Crea su base de configuración con el usuario inicial (email y contraseña). Sin tareas programadas |
| Recursos | Para empezar, 512 MB, 1 CPU y 256 procesos; se miden en DEV 🔍. Gunicorn usa 25 hilos por defecto |
| Lanzador | «pgAdmin 4 (<instancia>)» en el menú de Sway (rofi `drun`, R47) |
| Lo que no encaja | Nada |

## 2. Red: sin salida a internet

- **Sin `egress`:** solo está en redes internas, una por cada Postgres de su `connects_to`, sin ruta a fuera. No necesita salir para nada.
- **Varias Postgres a la vez:** `connects_to: [pg-main, pg-test]`. Cada pareja tiene su red aislada ([`NETWORK.md`](../NETWORK.md)); pgAdmin está en todas, pero las Postgres no se ven entre sí. Añadir o quitar una reinicia pgAdmin y esa Postgres. El orden de los `apply` es el de cualquier tubo hacia Postgres: **primero `apply postgres`**, después `apply pgadmin`.
- **Se llega solo desde el portátil**, por un puerto en `127.0.0.1` publicado desde esas redes internas, como Firefly.
- **Lo que pediría tu navegador:** `egress` limita al contenedor, no a tu navegador. La interfaz de pgAdmin pide por defecto la foto de Gravatar del usuario, y para ello manda a gravatar.com una huella de tu email. Se apaga (apartado 5). 🔍 Que no quede ninguna otra petición externa: prueba del apartado 7.

## 3. Acceso a Postgres: el superusuario, solo desde pgAdmin

R37 decidió que el superusuario solo pueda entrar por TCP desde la red de pgAdmin. Hoy el inventario no puede decirlo: `pg_hba` va por bases y abre a todos los usuarios de una, y el superusuario no pertenece a ninguna. La forma, aprobada por el operador el 2026-11-18:

- **Una lista fija, `infra_postgres_admins: [pgadmin]`**, en `playbooks/group_vars/all/apps.yml`, junto a la de nombres cortos: las aplicaciones que administran Postgres. Es una excepción fija en el código: un test impide que tenga otra cosa. Va ahí y no en el contrato del rol porque es el rol `postgres` quien la lee.
- **El rol `postgres` escribe la línea.** En cada `apply postgres`, para cada instancia de esas aplicaciones que lo nombra en `connects_to` (filtro `admins_of`), añade antes del rechazo del superusuario: `host all <su superusuario> <subred de esa pareja> scram-sha-256`. El superusuario es el `superuser:` de esa instancia en `postgres_hosts.yml`; la subred, la que eligió Podman al crear la red, que el rol ya lee para las demás aplicaciones. Si cambia, la recarga sin reiniciar ([`POSTGRES.md`](../POSTGRES.md), apartado 3).
- **En la instancia de pgAdmin no se escribe `pg_hba`:** solo `connects_to`, y el `plan` rechaza un `pg_hba`.
- **Sin pgAdmin, `pg_hba.conf` no cambia:** las instancias que ya existen no se recargan.
- **Toca otro rol** (`postgres`) y el filtro `pg_hba_problems`, aunque el criterio de la fase 2b dice «sin tocar los demás roles»: lo exige R37.
- **Para trabajar como una aplicación,** el superusuario usa `SET ROLE <base>_owner` ([`POSTGRES.md`](../POSTGRES.md), apartado 2): no hace falta abrir a pgAdmin los usuarios de las bases.

## 4. Seguridad

- **Un solo usuario, el tuyo,** en modo servidor (pide entrar). Su email va en la instancia (`email:`), en tu repo de datos: nunca en este repo, que es público (SPEC 5.2).
- **La contraseña de entrada:**
  - la escribes tú en KeePassXC, en `pgadmin-<instancia>-login-password` (sin entorno, [`NAMING.md`](../NAMING.md), apartado 5);
  - `deploy.sh secrets` la instala como secreto de Podman, `<entorno>-pgadmin-<instancia>-login-password`, y llega al contenedor como fichero, legible solo por el UID 5050 (`PGADMIN_DEFAULT_PASSWORD_FILE`);
  - **solo se usa en el primer arranque**, para crear tu usuario. La imagen exige una contraseña al arrancar, así que el secreto se queda instalado. 🔍 La documentación describe `PGADMIN_DEFAULT_PASSWORD_FILE` para Swarm y Compose; con un secreto de Podman se prueba en `lifecycle`;
  - para cambiarla después, dentro de pgAdmin, y lo apuntas en KeePassXC. El secreto de Podman ya no cuenta.
- **Sin recuperación por correo:** Postfix apagado (`PGADMIN_DISABLE_POSTFIX`). Con `NoNewPrivileges` no podría arrancar, y no hay salida.
- **Las contraseñas de Postgres no se guardan en pgAdmin** (`ALLOW_SAVE_PASSWORD` a `False`): se copian de KeePassXC al conectar ([`POSTGRES.md`](../POSTGRES.md), apartado 5). Sin `.pgpass` ni `servers.json`.
- **Contenedor endurecido**, como el resto: sin capacidades, sin privilegios nuevos y con límites (R46, R51).
  - **`ReadOnly=true`** 🔍: en el primer arranque la imagen escribe `config_distro.py` con las opciones `PGADMIN_CONFIG_*`. Se apunta a su volumen con `PGADMIN_CUSTOM_CONFIG_DISTRO_FILE`, la variable que la documentación da para un sistema de ficheros de solo lectura, y `/tmp` va en `tmpfs`. Si `lifecycle` no lo consigue, se para y se pide la excepción al operador.

## 5. Configuración

Todas las opciones: [The config.py File](https://www.pgadmin.org/docs/pgadmin4/9.19/config_py.html). Cualquier opción de `config.py` se fija con una variable `PGADMIN_CONFIG_<opción>`, que la imagen escribe en `config_distro.py` **solo en el primer arranque**: cambiarla después no se aplica sola.

| Opción | Valor | Por qué |
| --- | --- | --- |
| `PGADMIN_LISTEN_PORT` | `8080` | Puerto sin privilegios; es el que usa la imagen sin capacidades |
| `PGADMIN_LISTEN_ADDRESS` | `0.0.0.0` | Por defecto escucha en `[::]`; las redes de la plataforma son solo IPv4 |
| `PGADMIN_DISABLE_POSTFIX` | activada | Sin correo y sin salida |
| `PGADMIN_CUSTOM_CONFIG_DISTRO_FILE` | en el volumen | Para `ReadOnly=true` (apartado 4) 🔍 |
| `PGADMIN_CONFIG_ALLOW_SAVE_PASSWORD` | `False` | Las contraseñas viven en KeePassXC |
| `PGADMIN_CONFIG_SHOW_GRAVATAR_IMAGE` | `False` | Tu navegador no manda una huella de tu email a gravatar.com. Sin el prefijo `PGADMIN_CONFIG_` no se lee (Dave Page, lista `pgadmin-support`, 2018) |
| `PGADMIN_CONFIG_UPGRADE_CHECK_ENABLED` | `False` | No intenta buscar versiones: de eso avisa `image-updates` |
| `PGADMIN_CONFIG_ENHANCED_COOKIE_PROTECTION` | `True` | Está en los ejemplos oficiales |
| `PGADMIN_CONFIG_CONSOLE_LOG_LEVEL` | por defecto | Se cambia por instancia (`log_level`) para depurar |

🔍 Que `ALLOW_SAVE_PASSWORD`, `SHOW_GRAVATAR_IMAGE` y `UPGRADE_CHECK_ENABLED` siguen existiendo en la 9.19, en su `config.py`.

**`SERVER_PASSEXEC_COMMANDS`** (nueva en la 9.19): la lista de órdenes que pueden dar una contraseña en modo servidor, sustituyendo las de texto libre. Su aviso de «configúrala antes del primer arranque» es para quien ya las usaba al actualizar. Aquí no se usan: las contraseñas se copian de KeePassXC.

## 6. Actualizaciones y copias

- **Actualizaciones**, como las demás imágenes: digest fijo, aviso semanal de `image-updates`, PR, DEV y producción. pgAdmin pone al día su base SQLite al arrancar 🔍.
- **Copias:** apagadas por defecto. `backup: [data]` copia el volumen entero ([`README.md`](README.md), apartado 8): tu usuario, los servidores registrados y tus preferencias. Ninguna contraseña de Postgres. Perderlo cuesta poco: crear el usuario otra vez y registrar los servidores.
- **Retirar y purgar**, como cualquier instancia ([`README.md`](README.md), apartado 7). Al retirar la última pgAdmin que nombra a una Postgres, desaparece su línea del superusuario en el siguiente `apply postgres`.

## 7. Instalación: lo propio de pgAdmin

El orden general está en [`INSTALL.md`](INSTALL.md). Lo de pgAdmin, cuando llegue el momento:

1. **KeePassXC:** crea `pgadmin-<instancia>-login-password` y escribe tu contraseña.
2. **Repo de datos**, `group_vars/all.yml`, en `infra_secrets`:
   ```yaml
   - name: pgadmin-laptop-login-password
     group: pgadmin_hosts
     readers: [pgadmin-laptop]
   ```
3. **Repo de datos**, `group_vars/pgadmin_hosts.yml` (y la máquina en el grupo `pgadmin_hosts` de `hosts.yml`):
   ```yaml
   pgadmin_instances:
     - name: laptop
       email: admin@example.com        # el tuyo, solo aquí
       networking:
         inbound:
           publish: ["127.0.0.1:18101:8080"]
         connects_to: [pg-main]        # una o varias Postgres de esta máquina
       # backup: [data]
   ```
4. `./deploy.sh secrets`, después `./deploy.sh plan postgres` y `apply postgres`, y por último `plan pgadmin` y `apply pgadmin`.
5. **Primer acceso**, desde el lanzador: entra con tu email y la contraseña de KeePassXC.
6. **Registra cada Postgres una vez** (*Register → Server*): host `prod-pg-<instancia de Postgres>`, puerto `5432`, base de mantenimiento `postgres`, tu superusuario, y la contraseña sin guardar (`pg-<instancia>-superuser-password` de KeePassXC, cada vez que conectes).
7. **Prueba de que nada sale (DEV, dos minutos):** abre las herramientas del navegador, pestaña «Red», recarga pgAdmin y navega un poco. Ninguna petición puede ir a un dominio que no sea `127.0.0.1`.
