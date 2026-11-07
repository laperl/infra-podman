# Estándar de PostgreSQL

Cómo se monta cada instancia de PostgreSQL y cada base de datos de aplicación. Parte del estándar que el operador ya usaba en su proyecto anterior (`personal-data-platform`, ADR 0003 y 0004), adaptado a esta plataforma (R33 a R37 en [`DECISIONS.md`](DECISIONS.md)).

Todo se declara como **datos** en el inventario (ver [Datos fuera del código](#datos-fuera-del-código)): instancias, bases, usuarios y su grupo. En el código no hay ningún nombre de aplicación ni de usuario. Una base o un usuario nuevo es una entrada más, y Ansible lo crea.

Estado: **diseño aprobado el 2026-11-03.**
- El nivel de instancia está implementado desde la fase 1d (rol `postgres`) y comprobado con Podman 4.9 en el workflow `lifecycle`. `pg-main` se recrea con él ([`SETUP.md`](SETUP.md), paso 15).
- Las bases de las aplicaciones, desde la fase 2 (R45): se declaran en el repo de datos (sección 6) y `lifecycle` comprueba el modelo de permisos, el aislamiento de las redes y la vuelta atrás.

## 1. Instancia

Igual en todas las instancias, para que copias, restauraciones y migraciones entre instancias o versiones no den sorpresas (R34):

| Parámetro | Valor | Por qué |
| --- | --- | --- |
| Imagen | `pgvector/pgvector:pg18`, por digest (R27) | PostgreSQL 18 con la extensión `vector` |
| Superusuario | El que declares en el repo de datos (`superuser:` de cada instancia). Sin valor por defecto en el código (R41) | El administrador. Nunca lo usan las aplicaciones. No existe ningún rol `postgres` |
| Base principal | `postgres` (`POSTGRES_DB=postgres`) | Sin base extra con el nombre del superusuario |
| Codificación | `UTF8` | Cualquier idioma y cualquier emoji |
| Locale | `C.UTF-8` con proveedor `builtin`: el de PostgreSQL, no el de glibc | Mayúsculas y minúsculas correctas en cualquier idioma, y un orden que **no cambia nunca** al actualizar el sistema, porque no depende de glibc ni de ICU. Orden por código Unicode; si una consulta necesita orden de idioma, se pide en esa consulta. Comprobado en `lifecycle` |
| Zona horaria | `UTC` (`timezone` y `log_timezone`) | Lo estándar. Las aplicaciones guardan `timestamptz` y muestran la hora en su zona |
| Checksums de datos | Activados (por defecto en PostgreSQL 18, y además pedidos explícitamente) | Detectan corrupción en disco. Comprobado en `lifecycle` |
| Contraseñas | `scram-sha-256` | Por defecto en PostgreSQL 18 |

Estos parámetros solo se fijan al crear la base por primera vez. Cambiarlos después obliga a volcar y restaurar. Ansible los lee en cada `apply` y, si una instancia se creó de otra forma, **se para** con un mensaje y no toca nada (D11).

**La base `postgres`:**
- nadie puede conectar salvo el superusuario y `backup` (`REVOKE CONNECT … FROM PUBLIC`; aquí `PUBLIC` significa «todos los usuarios»);
- sin esquema `public` ni extensión `vector`: allí solo entran el administrador y los backups (R41).

**La plantilla `template1`:** sin esquema `public`, así que toda base nueva nace sin él.

**Rol `backup`:**
- LOGIN, miembro de `pg_read_all_data`;
- solo entra por el socket de dentro del contenedor y **no tiene contraseña**, porque por TCP se rechaza siempre;
- puede conectar a todas las bases, porque cada base nueva se lo concede;
- solo lee: no puede modificar ni borrar nada;
- los backups lo usan para volcar **todas** las bases de cada instancia, una a una, y los roles sin sus contraseñas (fase 1e1).

**Cambio de imagen:** antes de reiniciar una instancia con una imagen nueva, el `apply` hace un backup (`reason=pre-upgrade`) y se para si falla (D11).

**Contenedor endurecido** (el mismo que el operador ya usaba con Podman; comprobado con Podman 4.9 en `lifecycle`):
- `ReadOnly=true`, con `Tmpfs` para `/var/run/postgresql` y `/tmp`;
- `DropCapability=all` y `AddCapability=CHOWN SETUID SETGID FOWNER DAC_OVERRIDE`;
- `NoNewPrivileges=true`;
- límites de memoria, CPU y procesos;
- healthcheck por el socket: por TCP cada comprobación quedaría rechazada y apuntada en el log.

## 2. Bases de las aplicaciones (un solo modelo)

Para cada aplicación `<app>` (nombre elegido por el operador, `^[a-z][a-z0-9_]{0,30}$`):

- **Base** `<app>`, cuyo dueño es `<app>_owner`.
- **Tres grupos sin LOGIN:** `<app>_owner`, `<app>_writer` y `<app>_reader`.
- **Esquema** `<app>`, cuyo dueño es `<app>_owner`, con la extensión `vector`. No hay esquema `public`: la base nace sin él, porque `template1` no lo tiene. La aplicación solo ve el suyo.
- **Conexión:** nadie puede conectar por defecto (`REVOKE CONNECT … FROM PUBLIC`). Pueden los tres grupos, sus usuarios y `backup`.
- **Usuarios LOGIN a demanda,** cada uno miembro de **un** grupo, con `search_path = <app>` en su base.

### Permisos

| Rol | Puede | No puede |
| --- | --- | --- |
| `<app>_owner` | Todo dentro de su base: crear, cambiar y borrar objetos | Nada fuera de su base |
| `<app>_writer` | Usar el esquema; leer, insertar, modificar y borrar filas; usar secuencias; ejecutar las funciones del esquema | Cambiar la estructura (DDL), `TRUNCATE` |
| `<app>_reader` | Usar el esquema y **leer tablas** (`SELECT`) | **Nada más:** ni escribir, ni secuencias, ni ejecutar funciones de la aplicación (R36) |
| `backup` | Leer todo (`pg_read_all_data`) | Escribir, entrar por TCP |

- **Privilegios por defecto:** todo lo que cree `<app>_owner` en el futuro da automáticamente sus permisos a `_writer` y `_reader`. Solo funciona con lo que **crea `<app>_owner`**: por eso todo se crea como ese rol (ver «Quién crea las tablas»).
- **`_reader` no puede modificar datos de ninguna forma (R36).** Sin permiso de ejecución, ni siquiera una función con permisos especiales (`SECURITY DEFINER`) le sirve. Si un panel de solo lectura necesitara una función concreta, se le concede esa función, a mano. El CI comprueba que `_reader` no puede insertar, modificar, borrar ni ejecutar una función que escribe.

### Quién crea las tablas (R35)

El dueño de un objeto es el rol que lo crea, y los privilegios por defecto solo se aplican a lo que crea `<app>_owner`.

| Caso | Usuarios | Por qué |
| --- | --- | --- |
| **Aplicaciones propias** (por ejemplo `rag`) | Un usuario de migraciones en `_owner` y otro de uso diario en `_writer` | La práctica recomendada: la aplicación funciona sin poder cambiar su esquema |
| **Aplicaciones de terceros que migran solas** (por ejemplo Firefly) | Un único usuario en `_owner` | No se pueden separar. El riesgo queda limitado a su propia base |
| **Cambios a mano del operador** | El superusuario, con `SET ROLE <app>_owner` | Para que lo creado quede a nombre de `_owner` |

A los usuarios de `_owner` se les fija que, al conectar a su base, trabajen ya como `_owner` (`ALTER ROLE <usuario> IN DATABASE <app> SET role = <app>_owner`), así lo que crean queda a nombre del grupo sin cambiar nada en la aplicación. Comprobado con PostgreSQL 16 en local y en `lifecycle` con la imagen de la plataforma.

## 3. Acceso (`pg_hba.conf`)

Lo genera Ansible a partir del inventario y se monta en solo lectura. Si cambia, Ansible lo recarga sin reiniciar PostgreSQL y comprueba que no tiene errores. Gana la primera regla que encaja:

1. `local all all trust`: solo por el socket, dentro del contenedor. Quien llega ahí ya es `svc_runner`.
2. El superusuario por TCP: `reject`, **salvo desde la subred de pgAdmin** (R37), con `scram-sha-256`.
3. `backup` por TCP: `reject`.
4. Cada usuario LOGIN: `host <su base> <usuario> <subred de la red de su consumidor> scram-sha-256`. Una línea por usuario, limitada a su base y a la red de su consumidor (D9). La subred la elige Podman al crear la red y Ansible la lee; mientras la red no existe, el usuario no tiene línea y queda rechazado (R45).
5. Cualquier otro caso: `reject`.

No hay TLS: el tráfico nunca sale de la máquina, va por redes de Podman aisladas.

No hay red compartida entre consumidores: cada consumidor tiene su red, `<entorno>-<consumidor>-pg-<instancia>-net`, interna y con `isolate=true` (D9, R45), unida solo a su instancia. Sin consumidores, la instancia sigue con `Network=none`. Al añadir el primero (o uno nuevo), Postgres se reinicia una vez, porque Podman no añade redes a un contenedor en marcha.

## 4. Contraseñas

- **KeePassXC** es la copia maestra: `<instalación>/pg-<instancia>-<usuario>-password` (por ejemplo `laperl/…`; SETUP, paso 16). El superusuario es `pg-<instancia>-superuser-password`. `backup` no tiene.
- **Secretos de Podman** (`podman secret`): `<entorno>-pg-<instancia>-<usuario>-password`. Así llega cada contraseña a su aplicación, como fichero (SPEC 4.5). Se declaran en `infra_secrets` (grupo `postgres_hosts`) y se crean con `deploy.sh secrets`. Sin ellos, `apply postgres` se para y dice cuáles faltan.
- **En la base, desde el secreto:** en cada `apply`, Ansible compara la contraseña guardada con la del secreto y, si no coincide, la cambia. Envía el SCRAM ya calculado, nunca la contraseña en claro, que podría acabar en el log de PostgreSQL (R45). Solo letras, números y símbolos ASCII: es lo que genera KeePassXC por defecto.
- **No hay `.pgpass` ni ficheros de contraseñas.**
- **Cambiar una contraseña:** de un usuario de aplicación, `deploy.sh secrets --rotate pg-<instancia>-<usuario>-password`, después `apply postgres` y por último reiniciar la aplicación. Del superusuario, primero `ALTER ROLE` en la base y después `--rotate` (SPEC 4.5).

## 5. Cómo se conecta el operador

- **Consola:** `svc podman exec -it <entorno>-pg-<instancia> psql -U <superusuario> -d postgres`, con la función `svc` de [`SETUP.md`](SETUP.md), paso 12. Entra por el socket, sin contraseña.
- **pgAdmin (R37):**
  - es una aplicación más de `svc_runner`, desplegada con Ansible en la fase 2;
  - tiene su propia red aislada hacia la instancia;
  - publica solo en `127.0.0.1:<puerto>` del portátil: se abre en el navegador;
  - su contraseña de entrada está en KeePassXC;
  - para administrar, el superusuario solo puede entrar por TCP desde la subred de pgAdmin;
  - las contraseñas de las bases se copian de KeePassXC, sin guardarlas en pgAdmin.

## 6. Datos fuera del código

Los nombres de las bases, los usuarios, las aplicaciones y su configuración son **datos del operador** y no viven en este repo (R38). Ver [`SPEC.md`](SPEC.md), sección 4.13.

Se declaran en `group_vars/postgres_hosts.yml` del repo de datos (ejemplo comentado en [`inventory.example/prod/group_vars/postgres_hosts.yml`](../inventory.example/prod/group_vars/postgres_hosts.yml)):

```yaml
postgres_instances:
  - name: main
    superuser: tu_usuario       # el administrador; obligatorio desde la fase 1d
    databases:
      - name: app1              # base, esquema y grupos app1_*; ^[a-z][a-z0-9_]{0,30}$
        users:
          - name: app1          # único en la instancia; ^[a-z][a-z0-9_]{0,62}$
            group: owner        # owner | writer | reader
            consumer: app1      # la aplicación que entra con él: su red, y solo desde ella
          - name: app1_ia
            group: reader
            consumer: ia
```

Para añadir una base o un usuario:
1. su contraseña en KeePassXC, `<instalación>/pg-<instancia>-<usuario>-password`, y su nombre en `infra_secrets` con `group: postgres_hosts`;
2. la entrada de arriba en el repo de datos;
3. `./deploy.sh secrets --limit <máquina>` y después `./deploy.sh plan postgres --limit <máquina>` y `apply`, primero en DEV. Si llega un consumidor nuevo, Postgres se reinicia una vez.
