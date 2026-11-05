# Manual de operaciones

Las tareas de cada día: ver y comprobar las copias, restaurar, actualizar imágenes y quitar servicios. Cómo se instala cada pieza está en [`SETUP.md`](SETUP.md); cómo se hace un cambio, en [`WORKFLOW.md`](WORKFLOW.md).

**Las órdenes de este manual están probadas.** El CI (workflow `lifecycle`, job `backup-copy`) ejecuta cada bloque marcado tal cual, en DEV (`env=dev`), con el portátil y el GX10 en la misma máquina, igual que la VM DEV. Lo que depende de SELinux, que el CI no tiene, está marcado **«por comprobar en el portátil»**.

## 0. Antes de empezar

### 0.1 En el portátil (y en la VM DEV)

Pega este bloque en cada terminal nueva. Solo crea variables y funciones **en esa terminal**: no cambia nada en la máquina ni en tus ficheros, y al cerrarla desaparece. Funciona desde cualquier carpeta. Pide la contraseña de sudo una vez.

Lee la imagen de restic y la dirección del GX10 de los contenedores ya instalados, así que necesita los playbooks `postgres` y `backup` desplegados.

<!-- test: laptop -->
```bash
env=prod        # en la VM DEV: env=dev
inst=main       # la instancia de Postgres (pg-main)
svc() { (cd / && sudo -u svc_runner env HOME="$(getent passwd svc_runner | cut -d: -f6)" \
  XDG_RUNTIME_DIR="/run/user/$(id -u svc_runner)" "$@"); }
units=$(getent passwd svc_runner | cut -d: -f6)/.config/containers/systemd
img=$(svc sed -n 's/^Image=//p' "$units/$env-backup.container")
url=$(svc sed -n 's/^Environment=BACKUP_REMOTE_URL=//p' "$units/$env-backup-copy.container")
repo=$(svc sed -n 's/^Environment=BACKUP_REMOTE_PATH=//p' "$units/$env-backup-copy.container")
net=$(svc sed -n 's/^Network=//p' "$units/$env-backup-copy.container")
su=$(svc podman exec "$env-pg-$inst" printenv POSTGRES_USER)

# restic sobre la copia local, en solo lectura
restic_local() { svc podman run --rm --network=none --security-opt label=disable -v "$env-backup-repo:/repo:ro" \
  --secret "$env-backup-restic-password,type=mount,target=/run/secrets/restic-password" \
  -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/run/secrets/restic-password "$img" --no-cache --no-lock "$@"; }
# restic sobre la copia del GX10, a través de su servidor
restic_gx10() { svc podman run --rm ${net:+--network="$net"} \
  --secret "$env-backup-restic-password,type=mount,target=/run/secrets/restic-password" \
  --secret "$env-backup-server-password,type=env,target=RESTIC_REST_PASSWORD" \
  -e RESTIC_PASSWORD_FILE=/run/secrets/restic-password -e RESTIC_REST_USERNAME="${repo%%/*}" \
  -e RESTIC_REPOSITORY="rest:$url/$repo/" "$img" --no-cache --no-lock "$@"; }
# psql como superusuario, por el socket
psql_pg() { svc podman exec -i "$env-pg-$inst" psql -X -v ON_ERROR_STOP=1 -U "$su" "$@"; }
# restore_into <base nueva>: crea la base (vacía, con el dueño de $db) y carga el volcado que le llega.
# Los dos psql leen de /dev/null: si no, se comerían el volcado antes de que llegue a pg_restore
restore_into() {
  local owner
  owner=$(psql_pg -d postgres -tAc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$db'" </dev/null)
  psql_pg -d postgres -qc "CREATE DATABASE \"$1\" OWNER \"${owner:-$su}\" TEMPLATE template0" </dev/null
  svc podman exec -i "$env-pg-$inst" pg_restore -U "$su" -d "$1" --single-transaction --exit-on-error
}
# row_counts <base>: cada tabla y su número exacto de filas
row_counts() {
  psql_pg -d "$1" -At <<'SQL'
SELECT format('SELECT %L, count(*) FROM %I.%I', n.nspname || '.' || c.relname, n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1 \gexec
SQL
}
# missing_on_gx10: las copias del portátil que el GX10 todavía no tiene (vacío = ninguna)
missing_on_gx10() {
  comm -23 <(restic_local snapshots --json | grep -o '"id":"[0-9a-f]*"' | cut -d'"' -f4 | sort) \
    <(restic_gx10 snapshots --json | grep -o '"original":"[0-9a-f]*"' | cut -d'"' -f4 | sort)
}
```

`--security-opt label=disable` hace falta en Fedora: el backup marca su volumen como privado para SELinux y, sin esa opción, otro contenedor no puede leerlo. No cambia la marca del volumen.

### 0.2 En el GX10

Para leer las copias **directamente del volumen**, sin el servidor de copias (2.2). Solo hace falta la clave de restic.

<!-- test: gx10 -->
```bash
env=prod
inst=main
repo=<instalación>/<entorno>-<máquina>    # la carpeta del portátil, por ejemplo laperl/prod-laptop
img=<restic_image de images.yml>         # cópiala de playbooks/group_vars/all/images.yml, en GitHub
svc() { (cd / && sudo -u svc_runner env HOME="$(getent passwd svc_runner | cut -d: -f6)" \
  XDG_RUNTIME_DIR="/run/user/$(id -u svc_runner)" "$@"); }
IFS= read -rs -p 'Clave de restic (KeePassXC, backup-restic-password): ' key; echo
# restic sobre el volumen del servidor, en solo lectura. La clave le llega por la entrada estándar
restic_volume() { printf '%s' "$key" | svc podman run --rm -i --network=none -v "$env-backup-server-data:/data:ro" \
  -e RESTIC_REPOSITORY="/data/$repo" -e RESTIC_PASSWORD_FILE=/dev/stdin "$img" --no-cache --no-lock "$@"; }
```

La clave solo vive en esa terminal. Cuando termines: `unset key`, o cierra la terminal.

## 1. Copias de seguridad

### 1.1 Ver las copias

<!-- test: view -->
```bash
restic_local snapshots --latest 1     # la última copia de cada cosa, en el portátil
restic_gx10 snapshots --latest 1      # lo mismo en el GX10
```

Sin `--latest 1`, todas. Cada copia lleva las etiquetas `site=` (tu instalación), `env=`, `app=`, `type=` (`pgdump` o `files`) y `reason=` (`daily`, o `pre-upgrade` si se hizo antes de cambiar la imagen de Postgres). La ruta dice qué es: `/backup/pg-main/pgdump/<base>`, `/backup/pg-main/pgdump/_roles` (los roles, sin contraseñas) o `/backup/infra-podman/files/data-repo` (tu repo de datos).

- **Estado** de la última copia y del último envío al GX10:
  ```bash
  cat /var/lib/infra-podman/backup-status/$env-backup.status /var/lib/infra-podman/backup-status/$env-backup-copy.status
  ```
- **Logs:** `sudo journalctl _SYSTEMD_USER_UNIT=$env-backup.service -n 100` (y `$env-backup-copy.service`). Nunca muestran la clave.
- **Próximas ejecuciones:** `svc systemctl --user list-timers "$env-backup*"`.

### 1.2 ¿Tiene el GX10 todas las copias?

<!-- test: in-sync -->
```bash
missing=$(missing_on_gx10)
if [[ -z $missing ]]; then echo "BIEN: el GX10 tiene todas las copias del portátil"
else echo "Faltan $(wc -l <<<"$missing") copias en el GX10"; fi
```

- Una copia nueva llega al GX10 en menos de una hora (cada hora, a y media). Para no esperar: 1.3.
- El GX10 puede tener **más** copias que el portátil: en el portátil se borran las antiguas (7 diarias, 12 mensuales, 5 anuales) y en el GX10 no se borra nada (R26).
- Si sale un error de conexión, el GX10 no responde: [`SETUP.md`](SETUP.md), 18.6.

### 1.3 Hacer una copia ahora

<!-- test: copy-now -->
```bash
svc systemctl --user start "$env-backup.service"         # la copia local; tarda segundos o minutos
svc systemctl --user start "$env-backup-copy.service"    # y su envío al GX10
grep -H '^result=' /var/lib/infra-podman/backup-status/$env-backup{,-copy}.status
```

Las dos líneas tienen que decir `result=ok`. `result=unreachable` en la segunda es que el GX10 no responde: no es un fallo, lo reintenta cada hora.

### 1.4 Simulacro completo (una vez al mes)

La prueba de extremo a extremo: copia, envío al GX10, comprobación de que llegó y restauración **desde el GX10** de una base con otro nombre, que se compara con la original y se borra. No toca la base original.

<!-- test: drill -->
```bash
db=postgres     # desde la fase 2, mejor la base de una aplicación
svc systemctl --user start "$env-backup.service"
svc systemctl --user start "$env-backup-copy.service"
if [[ -z $(missing_on_gx10) ]]; then echo "BIEN: el GX10 tiene todas las copias"; else echo "MAL: faltan copias en el GX10 (1.2)"; fi
restic_gx10 dump --path "/backup/pg-$inst/pgdump/$db" latest "/backup/pg-$inst/pgdump/$db/$db.dump" | restore_into "${db}_simulacro"
if diff <(row_counts "$db") <(row_counts "${db}_simulacro"); then
  echo "BIEN: la base restaurada desde el GX10 es igual ($(row_counts "$db" | wc -l) tablas)"
else echo "MAL: la base restaurada no es igual (arriba, las diferencias)"; fi
psql_pg -d postgres -qc "DROP DATABASE \"${db}_simulacro\""
```

Tienen que salir dos `BIEN`. En la fase 1 la base `postgres` no tiene tablas («0 tablas»): aun así prueba que la copia del GX10 se descifra y se carga. Si una aplicación escribe entre la copia y la comparación, puede salir alguna diferencia pequeña en sus tablas; repite con la aplicación parada.

## 2. Restaurar

Reglas, en todos los casos:

- **Nunca encima de la base que hay.** Se restaura con otro nombre, se comprueba y después se cambia. Si la copia resulta mala, no has perdido nada.
- **El volcado sin cifrar no toca el disco:** va de restic directo a Postgres. La única excepción es 2.2, donde pasa por la memoria del GX10 (`/dev/shm`), nunca por su disco, que no está cifrado.
- **No para la base `postgres`**, que es la de mantenimiento.

### 2.1 Una base estropeada

Para un borrado por error, una migración rota o datos que no cuadran: vuelves al estado de una copia.

**Paso 1. Restaurar con otro nombre.** No para nada: la base buena sigue funcionando.

<!-- test: restore-local -->
```bash
db=<la base que quieres recuperar>
restic_local snapshots --path "/backup/pg-$inst/pgdump/$db"    # las copias de esa base, la más nueva al final
snap=latest     # o el ID (primera columna) de una copia anterior
restic_local dump --path "/backup/pg-$inst/pgdump/$db" "$snap" "/backup/pg-$inst/pgdump/$db/$db.dump" \
  | restore_into "${db}_restaurada"
row_counts "${db}_restaurada"     # tablas y filas: ¿es lo que esperas?
```

Si la copia local no está o no sirve, la del GX10 es igual: cambia `restic_local` por `restic_gx10` en las dos órdenes. Si el `pg_restore` falla, la base `${db}_restaurada` queda vacía: bórrala (`psql_pg -d postgres -c "DROP DATABASE \"${db}_restaurada\""`) antes de repetir.

**Paso 2. Cambiarla por la estropeada.**

1. Para las aplicaciones que usan esa base (desde la fase 2): `svc systemctl --user stop $env-<aplicación>.service`.
2. Renombra, las dos a la vez:
   <!-- test: swap -->
   ```bash
   old="${db}_antigua_$(date +%Y%m%d_%H%M)"
   psql_pg -d postgres -1 -c "ALTER DATABASE \"$db\" RENAME TO \"$old\"" \
     -c "ALTER DATABASE \"${db}_restaurada\" RENAME TO \"$db\""
   echo "La base estropeada queda como $old"
   ```
3. Arranca las aplicaciones: `svc systemctl --user start $env-<aplicación>.service`.
4. **Para deshacerlo**, renombra al revés. Unos días después, cuando estés seguro, borra la antigua: `psql_pg -d postgres -c "DROP DATABASE \"<nombre de la antigua>\""`.

Los permisos sobre la propia base (quién puede conectarse) no van en la copia. Desde la fase 2 los pone Ansible: `apply postgres` después del cambio. Se comprueba en esa fase (ROADMAP).

### 2.2 Desde el GX10, sin su servidor

Para cuando el servidor de copias no arranca, has perdido su contraseña o quieres comprobar que las copias se leen solo con la clave de restic.

En el **GX10**, con el bloque 0.2:

<!-- test: volume-view -->
```bash
restic_volume snapshots --latest 1
```

Para restaurar una base, primero en el **GX10** (el volcado queda en memoria, no en el disco):

<!-- test: volume-dump -->
```bash
db=<la base que quieres recuperar>
(umask 077 && restic_volume dump --path "/backup/pg-$inst/pgdump/$db" latest "/backup/pg-$inst/pgdump/$db/$db.dump" \
  > /dev/shm/infra-restore.dump)
```

Después en el **portátil**, con el bloque 0.1, lo carga y lo borra del GX10:

<!-- test: volume-restore -->
```bash
db=<la misma base>
ssh gx10 cat /dev/shm/infra-restore.dump | restore_into "${db}_restaurada"
ssh gx10 rm -f /dev/shm/infra-restore.dump
row_counts "${db}_restaurada"
```

Y sigue con el paso 2 de 2.1. En DEV todo está en la misma VM: quita `ssh gx10`.

### 2.3 El repo de datos

Recupera tu repo de datos de la copia local en una carpeta nueva, sin tocar el que tienes:

<!-- test: data-repo -->
```bash
dest=~/infra-podman-datos-restaurados
(umask 077 && restic_local dump --path /backup/infra-podman/files/data-repo latest \
  /backup/infra-podman/files/data-repo/infra-podman-data.bundle > "$dest.bundle")
git clone -q "$dest.bundle" "$dest" && rm "$dest.bundle"
git -C "$dest" log -1 --format='%h %ad %s'
```

Es una copia hecha por `deploy.sh` tras su última ejecución correcta, con todos los commits y sus firmas.

### 2.4 Portátil perdido o máquina nueva

Lo que necesitas: la copia de `infra-pro.kdbx` (ROADMAP: la guardas tú a mano), tu cuenta de GitHub y el GX10 encendido. En la máquina nueva:

1. **Lo básico:** [`SETUP.md`](SETUP.md), pasos 0 a 10. El paso 14 no: el repo de datos sale de la copia.
2. **El repo de datos, del GX10.** Todavía no hay usuario de servicio: lo hace tu propio Podman. `--network=host` solo sirve para que ese contenedor llegue al GX10 por Tailscale. Pega las dos contraseñas cuando las pida; no se guardan.
   <!-- test: lost-laptop -->
   ```bash
   url=http://<nombre del GX10>.<tu red>.ts.net:18000
   repo=<instalación>/<entorno>-<máquina>    # por ejemplo laperl/prod-laptop
   img=<restic_image de images.yml>
   dest=~/Documents/SECURE_vc/ansible/infra-podman
   IFS= read -rs -p 'Contraseña del servidor (backup-server-password): ' spw; echo
   IFS= read -rs -p 'Clave de restic (backup-restic-password): ' key; echo
   mkdir -p "$(dirname "$dest")"
   (umask 077 && printf '%s' "$key" | RESTIC_REST_PASSWORD=$spw podman run --rm -i --network=host \
     -e RESTIC_REST_PASSWORD -e RESTIC_REST_USERNAME="${repo%%/*}" -e RESTIC_REPOSITORY="rest:$url/$repo/" \
     -e RESTIC_PASSWORD_FILE=/dev/stdin "$img" --no-cache --no-lock \
     dump --path /backup/infra-podman/files/data-repo latest \
     /backup/infra-podman/files/data-repo/infra-podman-data.bundle > "$dest.bundle")
   unset spw key
   git clone -q "$dest.bundle" "$dest" && rm "$dest.bundle"
   git -C "$dest" remote remove origin
   git -C "$dest" log -1 --format='%h %ad %s'
   ```
   Configura la firma en ese repo y dile a `deploy.sh` dónde está: [`SETUP.md`](SETUP.md), paso 14, puntos 2 y 5. Por comprobar en el portátil: que el contenedor resuelve el nombre de Tailscale del GX10 (si no, usa su IP: `tailscale ip -4 <nombre del GX10>`).
3. **Despliega**, desde tu copia del código, en este orden: `./deploy.sh secrets --limit laptop` y, para cada playbook, `plan` y `apply` con `--limit laptop`: `base`, `postgres`, `backup`.
4. **Las bases, del GX10.** Con el bloque 0.1, mira qué bases hay (`restic_gx10 snapshots --tag type=pgdump --latest 1`) y, para cada una:
   ```bash
   db=<la base>
   restic_gx10 dump --path "/backup/pg-$inst/pgdump/$db" latest "/backup/pg-$inst/pgdump/$db/$db.dump" | restore_into "$db"
   ```
   Aquí no hay nada que pisar: la instancia es nueva. Desde la fase 2, Ansible crea las bases de las aplicaciones; este paso se ajustará entonces.
5. **Un simulacro** (1.4) para comprobar que todo vuelve a funcionar.

La copia local de la máquina nueva empieza vacía; el GX10 sigue guardando todas las anteriores.

## 3. Servicios

### 3.1 Ver cómo va todo

```bash
svc podman ps --filter label=infra.managed-by=infra-podman   # los contenedores en marcha
svc systemctl --user list-timers                             # lo que se lanza solo (backups)
sudo journalctl _SYSTEMD_USER_UNIT=$env-pg-$inst.service -n 50   # los logs de un servicio
tail -5 ~/.local/state/infra-podman/deploy.log               # los últimos despliegues
```

Los contenedores de backup no salen en `podman ps`: solo viven mientras copian.

### 3.2 Actualizar una imagen

1. **Pídelo** en una conversación con Claude, por ejemplo «actualiza restic a 0.19.2». Claude no llega a los registros de imágenes, así que te pedirá el digest. Desde cualquier carpeta del portátil:
   ```bash
   ref=docker.io/restic/restic:0.19.2     # la imagen y la versión nueva
   skopeo inspect --raw "docker://$ref" | sha256sum                                         # el digest
   skopeo inspect --raw "docker://$ref" | grep -o '"architecture": *"[a-z0-9]*"' | sort -u   # tiene que salir amd64 y arm64
   ```
2. **Como cualquier cambio** ([`WORKFLOW.md`](WORKFLOW.md)): el PR cambia `images.yml`, el CI lo prueba, lo pruebas en DEV, merge, tag y `apply` del playbook que usa esa imagen:

   | Imagen | Playbook | Máquina |
   | --- | --- | --- |
   | `postgres_image` | `postgres` | `laptop` |
   | `restic_image` | `backup` | `laptop` |
   | `rest_server_image` | `backup-server` | `gx10` |

3. **Postgres se protege solo:** antes de cambiar la imagen hace una copia (`reason=pre-upgrade`) y espera; si la copia falla, no cambia nada. Si la imagen nueva no arranca sana, se para y te avisa, sin volver atrás solo (D11). Para volver atrás: despliega el tag anterior (`git switch --detach <tag anterior>` y `apply postgres --limit laptop`).
4. **Solo versiones menores** (18.6 → 18.7). Una versión mayor de PostgreSQL (18 → 19) no se hace cambiando la imagen: necesita volcar y restaurar, con su propio PR.

### 3.3 Quitar un servicio

Se quita como dato, en tu repo de datos, nunca borrando a mano. **Los datos se quedan:** se para y se borra el contenedor, nunca su volumen (SPEC 4.2).

| Qué | En el repo de datos | Después | Qué se queda |
| --- | --- | --- | --- |
| Backup local | `backup_state: absent` en `inventory/prod/host_vars/laptop.yml` | `apply backup --limit laptop` | El repositorio local con todas las copias |
| Envío al GX10 | Quita `backup_remote_url` de `host_vars/laptop.yml` | `apply backup --limit laptop` | En el GX10 no se toca nada |
| Servidor de copias | `backup_server_state: absent` en `inventory/prod/host_vars/gx10.yml` | `apply backup-server --limit gx10` | El volumen con las copias, el hash de la contraseña y el puerto de `tailscale serve` (el mensaje final dice cómo quitarlo) |

- Commit firmado ([`WORKFLOW.md`](WORKFLOW.md), «Cambiar datos»), y `plan` antes del `apply`.
- **No saques la máquina del grupo** (`backup_clients`, `backup_servers`…) para quitar un servicio: Ansible dejaría de mirarla y el servicio seguiría en marcha. Primero `…_state: absent` y `apply`; después, si quieres, la sacas del grupo.
- **Postgres:** pídemelo. Tiene pasos propios, porque el backup diario cuenta con él.
- **Borrar también los datos** no se hace con `deploy.sh`: es irreversible y va en su propio PR.

### 3.4 Desplegar una aplicación nueva

Llega con la fase 2 (Firefly III y pgAdmin), y este apartado se completará entonces. El camino será:

1. Pides la aplicación. El PR trae su rol y sus plantillas, la actualiza en el documento de arquitectura y dice en «Cómo desplegarlo» qué entradas crear en KeePassXC (grupo de tu instalación) y qué añadir al repo de datos (su base, sus usuarios, la máquina).
2. Creas esas entradas en `infra-dev.kdbx` y en `infra-pro.kdbx`, y haces el commit firmado en el repo de datos.
3. DEV: `secrets`, `plan`, `apply` y un segundo `apply` con `changed=0`.
4. Merge, tag y lo mismo en producción con `--limit`.
5. Sus bases entran solas en el backup diario (se copian todas las de la instancia). Sus volúmenes, cuando la fase 2 lo resuelva (ROADMAP).

## 4. Pruebas automáticas

- **En cada PR**, el workflow `lifecycle` despliega todo en una máquina limpia de GitHub: Postgres, backups, servidor de copias, la restauración y los bloques de este manual. Si algo de este manual deja de funcionar, el PR sale en rojo.
- **En tus máquinas**, el simulacro (1.4). Es lo único que prueba tus datos reales y tu Tailscale.
