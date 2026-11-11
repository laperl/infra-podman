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
- **Usuarios LOGIN a demanda:** en cada base, miembros de **un** grupo, con `search_path = <app>` en esa base. Altas, cambios y bajas, en la sección 7.

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
  - name: main                  # un nombre distinto en cada máquina; no se cambia después
    superuser: tu_usuario       # el administrador; obligatorio desde la fase 1d
    databases:
      - name: app1              # base y esquema app1; ^[a-z][a-z0-9_]{0,30}$
        # Grupos, siempre estos tres: app1_owner, app1_writer y app1_reader (sección 2).
        users:
          - name: app1          # ^[a-z][a-z0-9_]{0,62}$
            group: owner        # owner | writer | reader: entra en app1_owner
            consumer: app1      # la aplicación que entra con él: su red, y solo desde ella; ^[a-z][a-z0-9]{0,20}$, sin guiones
          - name: app1_ia
            group: reader       # entra en app1_reader
            consumer: ia
```

- **`group:`** es siempre `owner`, `writer` o `reader`. El grupo real es `<base>_<grupo>`, y lo que puede hacer cada uno está en la sección 2.
- **`users:`** es opcional. Sin usuarios, la base existe pero nadie entra salvo el administrador.
- **Una base por instancia de aplicación** (R48): dos Firefly son dos bases (`ff_casa`, `ff_canary`), cada una con su usuario y su consumidor (`ffcasa`, `ffcanary`). Nunca dos instancias en la misma base. Detalle en [`services/README.md`](services/README.md).
- **Una instancia en otra máquina** va en `host_vars/<máquina>.yml` del repo de datos, con su propio nombre (por ejemplo `gx10`). Cada aplicación tiene que estar en la misma máquina que su Postgres: las redes de Podman no salen de la máquina.

## 7. Altas, cambios y bajas

Todo se hace editando el fichero de la sección 6 y aplicando. Primero en DEV:

```
./deploy.sh plan  postgres --limit <máquina>
./deploy.sh apply postgres --limit <máquina>
```

El `plan` enseña lo que va a cambiar sin tocar nada, y las bajas en un bloque aparte. Al final de cada `plan` y `apply` sale un resumen por base, con sus grupos y sus usuarios.

**Ansible solo borra lo que creó él.** Lo marca dentro de Postgres con el comentario `managed by infra-podman`. Nunca toca el superusuario, `backup`, los roles `pg_*` ni nada creado a mano: si encuentra una base o un usuario que no está en el fichero y no lleva esa marca, solo avisa.

### Altas

**Una base.** Añades su bloque:
```yaml
      - name: app2
```
Se crean la base `app2`, su esquema `app2` con `vector` y sus tres grupos, `app2_owner`, `app2_writer` y `app2_reader`.

**Un usuario.** Antes de aplicar:
1. En KeePassXC, la entrada `<instalación>/pg-<instancia>-<usuario>-password`, por ejemplo `laperl/pg-main-app2-password`.
2. En `group_vars/all.yml` del repo de datos, dentro de `infra_secrets`:
   ```yaml
     - name: pg-main-app2-password
       group: postgres_hosts
   ```
3. Su línea dentro de la base:
   ```yaml
      - name: app2
        users:
          - {name: app2, group: owner, consumer: app2}
   ```
4. `./deploy.sh secrets --limit <máquina>`, y después `plan` y `apply postgres`.

Se crea el usuario con la contraseña de su secreto, en `app2_owner`, y solo puede entrar en `app2` desde la red de `app2`. Si `app2` es una aplicación nueva, se crea su red y Postgres se reinicia una vez: Podman no añade redes a un contenedor en marcha.

**Un usuario en varias bases.** Se puede: el mismo nombre en cada base, con su grupo y su aplicación en cada una, y una sola contraseña. Lo recomendable es un usuario por aplicación, para que cada una vea solo lo suyo.

### Cambios

| Cambias | Qué pasa | Después |
| --- | --- | --- |
| `group:` de un usuario | Sale de su grupo y entra en el nuevo | Reinicia la aplicación: el cambio vale para las conexiones nuevas |
| `consumer:` de un usuario | Solo puede entrar desde la red de la aplicación nueva. Si esa red no existía, Postgres se reinicia una vez | Reinicia las dos aplicaciones |
| Su contraseña | `./deploy.sh secrets --rotate pg-<instancia>-<usuario>-password --limit <máquina>` y `apply postgres` (sección 4) | Reinicia la aplicación |

**No se renombra nada en el fichero:** ni bases, ni usuarios, ni instancias. Cambiar un nombre es borrar lo viejo y crear algo nuevo, vacío. Con una base, eso son sus datos. Si de verdad hace falta, es una mudanza a mano: base nueva, restaurar la copia en ella (OPERATIONS, apartado 5) y borrar la vieja.

### Bajas

**Un usuario.** Quitas su línea (o todas, si la base se queda sin `users:`) y aplicas:
1. Si el usuario está conectado, **se para** sin borrar nada y te dice que pares antes la aplicación que lo usa.
2. Borra el usuario. Su grupo se queda. Si el usuario sigue en otra base, solo deja de estar en esta.
3. Borra su secreto de Podman. La aplicación que lo usaba no tiene que borrar nada.
4. Al final te recuerda dos cosas que haces tú: borrar su entrada de KeePassXC y su línea de `infra_secrets`. Si esa línea sigue ahí, `deploy.sh secrets` volvería a crear el secreto.

**Una base.** Quitas su bloque entero y aplicas:
1. Si hay alguien conectado a ella, **se para** sin borrar nada.
2. Hace una **copia completa antes de borrar**, igual que antes de cambiar la imagen de Postgres (sección 1). Esa copia llega también al GX10. Si la copia falla, o la máquina no tiene copias configuradas, **no borra**.
3. Borra la base y sus tres grupos.
4. Borra sus usuarios que ya no estén en ninguna otra base, como en el caso anterior.

**Todas las bases.** Si falta `databases:` o está vacío (`databases: []`) y hay bases que borrar, **se para** y te enseña la lista. Para confirmarlo, repites la orden así:
```
./deploy.sh apply postgres --limit <máquina> --confirm-drop <instancia>
```

**La red de una aplicación** que se queda sin usuarios se quita, y Postgres se reinicia una vez.

**Recuperar una base borrada:** la vuelves a declarar, aplicas (nace vacía) y restauras la copia hecha antes de borrarla (OPERATIONS, apartado 5).

### Instancias

Quitar una instancia del fichero **no la borra ni la para**: cada `apply` avisa de que en esa máquina hay una instancia que no está declarada. Para retirarla, **mientras aún está en el fichero**:
```
./deploy.sh apply postgres --limit <máquina> --retire <instancia>
```
Para ese contenedor y quita su servicio, pero **conserva el volumen con los datos** (SPEC, sección 8). Las demás instancias de la máquina siguen igual. Después la quitas del fichero; si no, el siguiente `apply` la vuelve a arrancar con los mismos datos. Borrar también los datos es un paso aparte, a mano (abajo).

**Después de retirarla, en el mismo momento:** quítala del fichero y aplica el backup:
```
./deploy.sh apply backup --limit <máquina>
```
La copia diaria vuelca todas las instancias declaradas. Hasta este `apply`, sigue intentando volcar la retirada y falla con `prod-pg-<instancia> no está en marcha`.

#### Borrar del todo una instancia retirada

Solo cuando estés seguro: **no tiene vuelta atrás**, salvo restaurar una copia (OPERATIONS, apartado 5). Ejemplo con la instancia `main` en el portátil; cambia `main` por la tuya.

1. **En el repo de datos:** quita su línea `pg-main-superuser-password` de `infra_secrets` (`group_vars/all.yml`). Si no, `deploy.sh secrets` vuelve a crear su secreto. Haz un commit firmado.
2. **En KeePassXC:** borra la entrada `<instalación>/pg-main-superuser-password`.
3. **En la máquina**, como `svc_runner` (la función `svc` de [`SETUP.md`](SETUP.md), paso 12). Cada orden borra una cosa:
   ```bash
   sudo rm ~svc_runner/.config/containers/systemd/prod-pg-main-data.volume   # la unidad del volumen
   sudo rm -f ~svc_runner/.config/containers/systemd/*-pg-main-net.network    # las redes de sus aplicaciones, si quedó alguna
   svc systemctl --user daemon-reload
   svc podman volume rm prod-pg-main-data                                     # LOS DATOS
   sudo rm -r ~svc_runner/.config/infra-podman/prod-pg-main                   # su pg_hba.conf
   svc podman secret rm prod-pg-main-superuser-password                       # el secreto de su administrador
   ```
   Si ya no existe alguna de estas cosas, la orden lo dice y no pasa nada.
4. **Sus copias, si también las quieres borrar** (opcional). Son las que llevan la etiqueta `app=pg-main`. Se quedan para siempre: la limpieza diaria siempre guarda las últimas de cada cosa. Primero, en el portátil, mira qué se borraría (`--dry-run` no borra nada):
   ```bash
   img=$(sudo sed -n 's/^Image=//p' ~svc_runner/.config/containers/systemd/prod-backup.container)
   svc podman run --rm --network=none --security-opt label=disable -v prod-backup-repo:/repo \
     --secret prod-backup-restic-password,type=env,target=RESTIC_PASSWORD -e RESTIC_REPOSITORY=/repo \
     "$img" forget --tag app=pg-main --unsafe-allow-remove-all --prune --dry-run
   ```
   - Si la lista es la que esperas, repite la orden sin `--dry-run`.
   - `--tag app=pg-main` limita el borrado a las copias de esa instancia; sin ese filtro, restic no permite `--unsafe-allow-remove-all` (restic 0.17 o más nuevo).
   - `--prune` libera el espacio.
   - Esta orden escribe en el repositorio: hazlo cuando no esté corriendo el backup (`svc systemctl --user is-active prod-backup.service` dice `inactive`).

   **En el GX10**, la copia externa no se puede borrar desde el portátil: su servidor solo deja añadir (R44). Se borra en el GX10, directamente sobre su volumen, con la clave de restic, que se pega cuando la pide. Es el mismo acceso que para restaurar desde el GX10 (OPERATIONS, apartado 5.2); `<imagen_de_restic>` e `<instalación>` son los de ese apartado:
   ```bash
   img=<imagen_de_restic>
   read -rs -p 'Clave de restic: ' key; echo
   printf '%s' "$key" | svc podman run --rm -i --network=none -v prod-backup-server-data:/data \
     -e RESTIC_REPOSITORY=/data/<instalación>/prod-laptop -e RESTIC_PASSWORD_FILE=/dev/stdin \
     "$img" forget --tag app=pg-main --unsafe-allow-remove-all --prune --dry-run
   unset key
   ```
   Igual: primero con `--dry-run` y, si es lo esperado, sin él. Mejor cuando no esté llegando ninguna copia (por ejemplo, justo después de que el portátil haya enviado la suya).
