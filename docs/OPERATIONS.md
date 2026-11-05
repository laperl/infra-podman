# Manual de operaciones

El día a día: qué hay en marcha, cómo van las copias, cómo lanzar algo a mano, cómo se ve un sistema sano y cómo restaurar. Cómo está montado: [`ARCHITECTURE.md`](ARCHITECTURE.md). Cómo se hace un cambio: [`WORKFLOW.md`](WORKFLOW.md).

**Cómo leer las órdenes:**

- Funcionan **desde cualquier carpeta**. Cada bloque dice en qué máquina va: el portátil o el GX10.
- Usan la función `svc` de [`SETUP.md`](SETUP.md), paso 12, que tienes en tu `~/.bashrc` del portátil y del GX10. Hace falta porque los contenedores son de `svc_runner`, no tuyos. Pide la contraseña de sudo de esa máquina.
- Lo que va entre `<…>` lo cambias tú. Por ejemplo, `<base>` por el nombre de una base de datos.
- **En DEV** (en `vmiadev`): cambia `prod` por `dev`. Lo del GX10 también se hace en `vmiadev`, y sobra el `ssh gx10`.
- Los bloques de este manual están **probados**: el CI (workflow `lifecycle`) los ejecuta tal cual en cada PR. Lo que depende de SELinux o Tailscale, que el CI no tiene, está marcado **«por comprobar en el portátil»**.

## 1. Qué hay desplegado

| Contenedor | Máquina | Cómo corre | Quién lo lanza |
| --- | --- | --- | --- |
| `prod-pg-main` (Postgres) | Portátil | **Siempre** | systemd, al encender |
| `prod-backup` (copia diaria) | Portátil | **Duerme** y despierta un rato | `prod-backup.timer`, cada día a las 13:00 |
| `prod-backup-copy` (envío al GX10) | Portátil | **Duerme** y despierta un rato | `prod-backup-copy.timer`, cada hora a y media |
| `prod-backup-server` (recibe las copias) | GX10 | **Siempre** | systemd, al encender |

Si el portátil estaba apagado a la hora de un temporizador, la tarea se hace al encenderlo. Además, en **tu** usuario del portátil, `infra-podman-backup-notify.timer` mira cada hora cómo van las copias y te avisa en el escritorio si algo falla. No es un contenedor.

En el portátil:

<!-- test: deployed -->
```bash
svc podman ps                          # los que corren siempre
svc systemctl --user list-timers       # los que duermen: cuándo despiertan (NEXT) y la última vez (LAST)
sudo ls ~svc_runner/.config/containers/systemd/ ~svc_runner/.config/systemd/user/   # todo lo desplegado
```

En el GX10, la primera orden muestra `prod-backup-server`.

## 2. Estado de los backups

En el portátil:

<!-- test: status -->
```bash
cat /var/lib/infra-podman/backup-status/prod-backup.status        # la copia diaria
cat /var/lib/infra-podman/backup-status/prod-backup-copy.status   # el envío al GX10
```

Lo que importa:

- `result=ok`: la última vez fue bien. En el envío, `result=unreachable` es que el GX10 no respondía; no es un fallo, lo reintenta cada hora.
- `last_ok=`: la fecha de la última copia buena.
- `usage=` (solo el envío): cuánto ocupan tus copias en el GX10, sobre el tope de 30 GB.
- `message=`: qué ha pasado, en español. Si algo falla, dice qué hacer.

**Logs**, con lo que se volcó, lo que se guardó y cualquier error (nunca las claves):

```bash
sudo journalctl _SYSTEMD_USER_UNIT=prod-backup.service -n 50
sudo journalctl _SYSTEMD_USER_UNIT=prod-backup-copy.service -n 50
```

**Las copias que hay en el portátil**, la última de cada cosa (quita `--latest 1` para verlas todas):

<!-- test: snapshots -->
```bash
img=$(sudo sed -n 's/^Image=//p' ~svc_runner/.config/containers/systemd/prod-backup.container)
svc podman run --rm --network=none --security-opt label=disable -v prod-backup-repo:/repo:ro \
  --secret prod-backup-restic-password,type=env,target=RESTIC_PASSWORD -e RESTIC_REPOSITORY=/repo \
  "$img" --no-lock snapshots --latest 1
```

- La primera línea lee qué imagen de restic está instalada.
- La ruta de cada copia dice qué es: `/backup/pg-main/pgdump/<base>` (una base), `/backup/pg-main/pgdump/_roles` (los roles, sin contraseñas) o `/backup/infra-podman/files/data-repo` (tu repo de datos).
- `--security-opt label=disable`: en Fedora, el volumen es privado del contenedor de backup para SELinux. Así otro contenedor puede leerlo sin cambiar esa marca. Con `:ro` y `--no-lock` solo lee: no toca nada. Por comprobar en el portátil.
- Para ver las copias del GX10, mira el apartado 5.2.

## 3. Lanzar a mano

En el portátil. Cada orden espera a que termine; sin salida es que ha ido bien.

<!-- test: run-now -->
```bash
svc systemctl --user start prod-backup.service        # una copia ahora (segundos o minutos)
svc systemctl --user start prod-backup-copy.service   # enviarla al GX10 ahora
grep -h '^result=' /var/lib/infra-podman/backup-status/prod-backup*.status   # dos result=ok
```

Otras:

| Qué | Orden | Dónde |
| --- | --- | --- |
| Reiniciar Postgres | `svc systemctl --user restart prod-pg-main.service` | Portátil |
| Reiniciar el servidor de copias | `svc systemctl --user restart prod-backup-server.service` | GX10 |
| Comprobar ahora el aviso de escritorio | `systemctl --user start infra-podman-backup-notify.service` (tu usuario, sin `svc`) | Portátil |
| Consola de Postgres | `svc podman exec -it prod-pg-main psql -U <superusuario> -d postgres` | Portátil |

## 4. Cómo se ve un sistema sano

Repásalo tras un reinicio, tras un `apply` o cuando quieras quedarte tranquilo.

**En el portátil:**

<!-- test: healthy -->
```bash
svc systemctl --user is-active prod-pg-main.service prod-backup.timer prod-backup-copy.timer
svc podman healthcheck run prod-pg-main && echo sano
svc podman port prod-pg-main
grep -h '^result=' /var/lib/infra-podman/backup-status/prod-backup*.status
```

| Orden | Lo que tiene que salir |
| --- | --- |
| `is-active` | Tres líneas `active`: Postgres en marcha y los dos temporizadores esperando su hora |
| `healthcheck` | `sano` |
| `podman port` | Nada: Postgres no publica ningún puerto |
| `grep` | Dos líneas `result=ok`. `result=unreachable` en la segunda solo si el GX10 está apagado o fuera de Tailscale |

Y el aviso de escritorio, en tu usuario: `systemctl --user is-active infra-podman-backup-notify.timer` → `active`.

**En el GX10:**

<!-- test: healthy-gx10 -->
```bash
svc systemctl --user is-active prod-backup-server.service
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18000/
```

Tiene que salir `active` y `401`: el servidor responde y pide contraseña. Además, `sudo tailscale serve status` tiene que mostrar el puerto 18000.

Si algo no sale así: los logs del apartado 2 y [`SETUP.md`](SETUP.md), 18.6.

## 5. Restaurar

Reglas, en todos los casos:

- **Nunca encima de la base que tienes.** Se restaura con otro nombre (`<base>_restaurada`), lo compruebas y después se cambia por la buena. Si la copia resulta mala, no has perdido nada.
- **El volcado sin cifrar no toca ningún disco.** Va de restic directo a Postgres o, como mucho, pasa por la memoria (`/dev/shm`) y se borra.
- Para leer las copias **basta la clave de restic** (`backup-restic-password` en KeePassXC).

### 5.1 Desde la copia local

En el portátil. No para nada: la base que tienes sigue funcionando.

**Paso 1. Restaurar con otro nombre.**

<!-- test: restore-local -->
```bash
db=<base>
superuser=<superusuario>
img=$(sudo sed -n 's/^Image=//p' ~svc_runner/.config/containers/systemd/prod-backup.container)
svc podman exec prod-pg-main createdb -U "$superuser" -T template0 "${db}_restaurada"
svc podman run --rm --network=none --security-opt label=disable -v prod-backup-repo:/repo:ro \
  --secret prod-backup-restic-password,type=env,target=RESTIC_PASSWORD -e RESTIC_REPOSITORY=/repo \
  "$img" --no-lock dump --path "/backup/pg-main/pgdump/$db" latest "/backup/pg-main/pgdump/$db/$db.dump" \
  | svc podman exec -i prod-pg-main pg_restore -U "$superuser" -d "${db}_restaurada" --single-transaction --exit-on-error
```

- `<superusuario>` es el `superuser:` de tu repo de datos.
- `latest` es la copia más nueva. Para otra, pon su ID (la primera columna de `snapshots` sin `--latest 1`, apartado 2).
- Si `pg_restore` falla, la base nueva queda vacía. Bórrala antes de repetir: `svc podman exec prod-pg-main dropdb -U "$superuser" "${db}_restaurada"`.

**Paso 2. Mirar que es lo que esperas.** Las tablas y cuántas filas tienen, aproximadamente:

<!-- test: check-restored -->
```bash
svc podman exec prod-pg-main psql -U "$superuser" -d "${db}_restaurada" -c "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY 1, 2"
```

**Paso 3. Cambiarla por la que tienes.** Si la usa una aplicación (desde la fase 2), párala antes: `svc systemctl --user stop prod-<aplicación>.service`.

<!-- test: swap -->
```bash
svc podman exec prod-pg-main psql -U "$superuser" -d postgres -1 \
  -c "ALTER DATABASE \"$db\" RENAME TO \"${db}_antigua\"" -c "ALTER DATABASE \"${db}_restaurada\" RENAME TO \"$db\""
```

- La de antes queda como `<base>_antigua`. Para deshacerlo, renombra al revés.
- Cuando estés seguro, bórrala: `svc podman exec prod-pg-main dropdb -U "$superuser" "${db}_antigua"`.
- Arranca la aplicación si la paraste: `svc systemctl --user start prod-<aplicación>.service`.
- Los permisos sobre la propia base (quién puede conectarse) no van en la copia. Desde la fase 2 los pondrá Ansible con un `apply postgres` (ROADMAP).

### 5.2 Desde el GX10

Para cuando la copia local no está o no sirve. Se lee **directamente del volumen del GX10**: no hace falta su servidor de copias ni su contraseña, solo la clave de restic. Funciona aunque el servidor esté caído.

**Paso 1, en el GX10.** Saca el volcado a la memoria del GX10, no a su disco.

- `<imagen_de_restic>`: la línea que da en el portátil `sudo sed -n 's/^Image=//p' ~svc_runner/.config/containers/systemd/prod-backup.container`. Es la misma que `restic_image` en `playbooks/group_vars/all/images.yml`.
- `<instalación>`: tu `infra_site` (por ejemplo, `laperl`).
- La clave de restic se pega cuando la pide; no se ve ni se guarda.

<!-- test: gx10-dump -->
```bash
img=<imagen_de_restic>
db=<base>
read -rs -p 'Clave de restic: ' key; echo
install -m 600 /dev/null /dev/shm/restaurar.dump
printf '%s' "$key" | svc podman run --rm -i --network=none -v prod-backup-server-data:/data:ro \
  -e RESTIC_REPOSITORY=/data/<instalación>/prod-laptop -e RESTIC_PASSWORD_FILE=/dev/stdin \
  "$img" --no-lock dump --path "/backup/pg-main/pgdump/$db" latest "/backup/pg-main/pgdump/$db/$db.dump" > /dev/shm/restaurar.dump
unset key
```

Para ver antes qué copias hay, la misma orden con `snapshots --latest 1` en lugar de todo lo que va desde `dump`, y sin `> /dev/shm/restaurar.dump`.

**Paso 2, en el portátil.** Lo carga en una base nueva y lo borra del GX10:

<!-- test: gx10-restore -->
```bash
db=<base>
superuser=<superusuario>
svc podman exec prod-pg-main createdb -U "$superuser" -T template0 "${db}_restaurada"
ssh -n gx10 cat /dev/shm/restaurar.dump \
  | svc podman exec -i prod-pg-main pg_restore -U "$superuser" -d "${db}_restaurada" --single-transaction --exit-on-error
ssh gx10 rm /dev/shm/restaurar.dump
```

Y sigue con los pasos 2 y 3 de 5.1.

### 5.3 El repo de datos

Si lo borras o lo estropeas. En el portátil, lo saca de la copia local a una carpeta nueva, sin tocar el que tienes:

<!-- test: data-repo -->
```bash
img=$(sudo sed -n 's/^Image=//p' ~svc_runner/.config/containers/systemd/prod-backup.container)
install -m 600 /dev/null /dev/shm/datos.bundle
svc podman run --rm --network=none --security-opt label=disable -v prod-backup-repo:/repo:ro \
  --secret prod-backup-restic-password,type=env,target=RESTIC_PASSWORD -e RESTIC_REPOSITORY=/repo \
  "$img" --no-lock dump --path /backup/infra-podman/files/data-repo latest \
  /backup/infra-podman/files/data-repo/infra-podman-data.bundle > /dev/shm/datos.bundle
git clone -q /dev/shm/datos.bundle ~/infra-podman-datos-restaurados && rm /dev/shm/datos.bundle
git -C ~/infra-podman-datos-restaurados log -1 --format='%h %ad %s'
```

Tiene todos los commits, con sus firmas, tal como estaban tras la última ejecución correcta de `deploy.sh`.

### 5.4 Portátil perdido o nuevo

En el GX10 están tus bases y tu repo de datos. Necesitas tu copia de `infra-pro.kdbx` (la que guardas a mano), tu cuenta de GitHub y el GX10 encendido. En este orden:

1. **Prepara el portátil nuevo:** [`SETUP.md`](SETUP.md), pasos 0 a 10.
2. **En el GX10**, saca el repo de datos a su memoria, como en 5.2:
   <!-- test: lost-gx10 -->
   ```bash
   img=<imagen_de_restic>
   read -rs -p 'Clave de restic: ' key; echo
   install -m 600 /dev/null /dev/shm/restaurar.bundle
   printf '%s' "$key" | svc podman run --rm -i --network=none -v prod-backup-server-data:/data:ro \
     -e RESTIC_REPOSITORY=/data/<instalación>/prod-laptop -e RESTIC_PASSWORD_FILE=/dev/stdin \
     "$img" --no-lock dump --path /backup/infra-podman/files/data-repo latest \
     /backup/infra-podman/files/data-repo/infra-podman-data.bundle > /dev/shm/restaurar.bundle
   unset key
   ```
   `<imagen_de_restic>`: `restic_image` en `playbooks/group_vars/all/images.yml`, en GitHub.
3. **En el portátil nuevo**, tráelo y bórralo del GX10:
   <!-- test: lost-laptop -->
   ```bash
   scp -q gx10:/dev/shm/restaurar.bundle /dev/shm/datos.bundle && ssh gx10 rm /dev/shm/restaurar.bundle
   git clone -q /dev/shm/datos.bundle ~/Documents/SECURE_vc/ansible/infra-podman && rm /dev/shm/datos.bundle
   git -C ~/Documents/SECURE_vc/ansible/infra-podman remote remove origin
   git -C ~/Documents/SECURE_vc/ansible/infra-podman log -1 --format='%h %ad %s'
   ```
4. **Configura ese repo:** la firma y la línea `data_repo` ([`SETUP.md`](SETUP.md), paso 14, puntos 2 y 5).
5. **Despliega**, desde tu copia del código y con `--limit laptop`: `./deploy.sh secrets`, y `plan` y `apply` de `base`, `postgres` y `backup`.
6. **Las bases:** como 5.2, una por una. En la fase 1 no hay ninguna aparte de `postgres`, que la prepara Ansible.
7. **Comprueba** que todo está sano (apartado 4).

La copia local del portátil nuevo empieza vacía. El GX10 sigue guardando todas las anteriores.
