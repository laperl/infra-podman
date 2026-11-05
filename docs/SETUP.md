# Puesta en marcha del portátil

Lo que se hace **una vez** en el nodo de control (Fedora Atomic 44, x86_64). Ningún paso necesita `rpm-ostree`: todo queda en tu usuario.

## 0. Copia del repo en el portátil

Todo lo de esta guía, y más adelante `deploy.sh`, se ejecuta **en el portátil**, dentro de una copia (clon) del repo. Se hace una vez y luego solo se actualiza:

```bash
mkdir -p ~/src && cd ~/src
git clone git@github.com:laperl/infra-podman.git    # por SSH, con la clave que sirve KeePassXC
cd infra-podman
```

Para clonar por SSH, tu clave tiene que estar dada de alta en GitHub como clave de **autenticación** (Settings → SSH and GPG keys), además de como clave de firma.

Para probar un PR antes del merge, cámbiate a su rama:

```bash
git fetch origin && git switch feat/phase-0b-ee-kdbx    # el nombre de la rama aparece en el PR
git pull
```

Para volver a `main`: `git switch main && git pull`.

## 1. ansible-navigator

En un entorno virtual de Python de tu usuario. Todas sus dependencias tienen paquetes binarios para Python 3.14, así que no hace falta compilador (comprobado el 2026-11-02 para `ansible-navigator==26.10.0`).

```bash
python3 -m venv ~/.local/share/ansible-navigator
~/.local/share/ansible-navigator/bin/pip install ansible-navigator==26.10.0
mkdir -p ~/.local/bin/
ln -s ~/.local/share/ansible-navigator/bin/ansible-navigator ~/.local/bin/ansible-navigator
ansible-navigator --version
```

Ansible no se instala en el portátil: corre dentro de la imagen de Ansible.

## 2. Acceso a la imagen de Ansible en GHCR

La imagen es privada. Crea en GitHub un token **classic** con solo el permiso `read:packages` (Settings → Developer settings → Personal access tokens) y guárdalo en `infra-pro.kdbx`. GHCR solo admite tokens clásicos ([documentación de GitHub](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)). Ponle **caducidad** (por ejemplo, 90 días) en lugar de indefinida. La mejora está pendiente en `ROADMAP.md`. Luego:

```bash
podman login ghcr.io --username laperl   # pega el token cuando lo pida
```

`podman login` guarda la credencial en `${XDG_RUNTIME_DIR}/containers/auth.json`, que se borra al reiniciar. Hay que repetirlo tras cada reinicio, o cuando `ansible-navigator` no pueda descargar la imagen.

## 3. Base de DEV

Con KeePassXC 2.8 crea `infra-dev.kdbx` **fuera del repo** (el `.gitignore` excluye `*.kdbx` igualmente):

- un grupo con el **nombre de tu instalación**, `laperl` (el mismo que pondrás en `infra_site` del repo de datos, paso 16);
- entrada `test_dummy` con una contraseña ficticia cualquiera;
- contraseña maestra distinta de la de `infra-pro.kdbx`.

Este fichero **vive solo en el portátil**: no se copia a la VM y no hace falta hacerle copia de seguridad. Solo contiene valores ficticios y se recrea en dos minutos con el grupo y los nombres de `infra_secrets` en `inventory/dev/group_vars/all.yml` de tu repo de datos (paso 14; R17). La copia de seguridad que sí importa es la de `infra-pro.kdbx`: está apuntada en el `ROADMAP`.

## 4. Prueba del lookup contra tu `.kdbx` (criterio de hecho de la fase 0)

En el portátil, dentro de tu copia del repo (paso 0), en la rama del PR 0b. Hace falta haber hecho el paso 2 (`podman login`). La primera vez descarga la imagen (~1 GB). La imagen es la que fija `ansible-navigator.yml`:

```bash
IMAGE=$(sed -n 's/^ *image: *\([^ ]*\).*/\1/p' ansible-navigator.yml)
KDBX=~/ruta/a/infra-dev.kdbx                      # cámbialo
read -rs -p 'Contraseña de infra-dev.kdbx: ' P; echo
printf '%s\n' "$P" | podman run --rm -i --user root \
  -v "$PWD:/work:ro,z" -w /work \
  -v "$KDBX:/kdbx/infra-dev.kdbx:ro,z" \
  "$IMAGE" bash -c 'IFS= read -r KDBX_PASSWORD; export KDBX_PASSWORD KDBX_DATABASE=/kdbx/infra-dev.kdbx; exec ansible-playbook -e infra_site=laperl tests/ee/operator_selftest.yml'
unset P
```

`--user root` hace falta porque, en Podman sin root, el root del contenedor es tu propio usuario en el portátil: así puede leer tu `.kdbx`, que normalmente solo tú puedes leer. ansible-navigator hace lo mismo.

Resultado esperado: `OK: read laperl/test_dummy (N characters)`. El valor no se muestra.

La contraseña viaja así: `read -s` (no se ve ni queda en el historial) → `printf`, que es una orden interna de bash y por tanto no aparece en la lista de procesos → entrada estándar del contenedor → variable de entorno solo dentro del contenedor → entrada estándar de `keepassxc-cli`. No toca el disco.

Desde la fase 0c, `deploy.sh secrets --env dev` hace esto por ti (paso 7).

## 5. Firma SSH

Sigue [`SIGNING.md`](SIGNING.md).

## 6. La VM DEV

**En la VM no se clona el repo ni se instala Ansible.** Todo se ejecuta desde el portátil, que se conecta a la VM por SSH (R2 en `DECISIONS.md`). La VM solo necesita Podman y tu clave pública en `authorized_keys`.

En la VM (Ubuntu Server 24.04 x86_64), con tu usuario:

```bash
sudo apt update && sudo apt install -y podman   # Podman 4.9, igual que el GX10
podman --version
```

Para entrar desde el portátil, tu clave pública tiene que estar en el `~/.ssh/authorized_keys` de la VM (`ssh-copy-id` desde el portátil).

En el portátil, define en `~/.ssh/config` el alias que usa el inventario, `vmiadev`. La dirección y el usuario se quedan en tu `~/.ssh/config`, fuera del repo:

```text
Host vmiadev
    HostName 192.168.122.10      # la IP de tu VM
    User tu_usuario_en_la_vm
    ForwardAgent no
```

Si ya tienes un bloque `Host *` con `ForwardAgent yes`, el bloque `Host vmiadev` tiene que ir **antes**: ssh se queda con el primer valor que encuentra. Comprueba con `ssh -G vmiadev | grep -i forwardagent`: tiene que salir `forwardagent no`.

Conéctate una vez a mano para aceptar su huella: `ssh vmiadev true`. Ansible corre en un contenedor que lee tu `~/.ssh` en solo lectura y no puede preguntarte por huellas nuevas.

### La VM no debe ver tus claves

Entra en la VM (`ssh vmiadev`) y comprueba:

```bash
echo "$SSH_AUTH_SOCK"    # vacío
ssh-add -l               # "Could not open a connection to your authentication agent" o "The agent has no identities"
ls ~/.ssh                # solo authorized_keys y known_hosts, ninguna clave privada
```

Si `ssh-add -l` lista tus claves, la sesión está **reenviando tu agente** (`ssh -A` o `ForwardAgent yes`). Mientras dure esa sesión, cualquier proceso de la VM, opencode incluido, puede usar tus claves: entrar en el GX10 o firmar un tag. Es justo lo que D14 prohíbe. Pon `ForwardAgent no` como arriba y vuelve a entrar. Los inventarios ya lo desactivan para las conexiones de Ansible (R17), pero tu `ssh` a mano depende de tu `~/.ssh/config`.

Si más adelante opencode ejecuta pruebas dentro de la VM, necesitará una copia del repo. Eso se decide cuando llegue ese momento; no hace falta para la fase 0.

## 7. Configuración de `deploy.sh`

`~/.config/infra-podman/deploy.conf` dice dónde están tus bases de KeePassXC. Solo contiene rutas, nunca contraseñas:

```text
kdbx_dev = ~/ruta/a/infra-dev.kdbx
kdbx_prod = ~/ruta/a/infra-pro.kdbx
data_repo = ~/Documents/SECURE_vc/ansible/infra-podman
```

`data_repo` es la ruta de tu repo de datos, donde vive el inventario (paso 14). La lee `deploy.sh` desde la fase 1c, en DEV y en producción.

## 8. Prueba contra DEV (criterio de hecho de la fase 0)

En tu copia del repo, en la rama del PR, con KeePassXC desbloqueado:

```bash
./deploy.sh plan check --env dev       # conecta con vmiadev y comprueba Podman >= 4.9 sin cambiar nada
./deploy.sh secrets --env dev          # pide la contraseña de infra-dev.kdbx y lee test_dummy
tail -2 ~/.local/state/infra-podman/deploy.log
```

Resultado esperado:
- **`plan`:** una línea `vmiadev: Ubuntu 24.04, podman version 4.9.3, connected as …` y `failed=0`.
- **`secrets`:** `1 secret(s) readable from KeePassXC for dev`.
- **Registro:** dos líneas acabadas en `ok`.

## 9. El portátil como servidor (fase 1)

Desde la fase 1 el portátil también aloja servicios (R18). Ansible corre en un contenedor, así que entra en el portátil por SSH a `127.0.0.1`, como a cualquier otro servidor (R23). Se hace **una vez**.

### 9.1 Tu clave en `authorized_keys`

Con KeePassXC desbloqueado, mira las claves que sirve el agente y copia la que usas para **entrar** en GitHub y en los servidores. No la de firmar (`git-signing`): esa solo firma tags ([`SIGNING.md`](SIGNING.md)).

```bash
ssh-add -L                          # una línea por clave; la última palabra es su comentario
ssh-add -L | grep 'COMENTARIO' >> ~/.ssh/authorized_keys     # cambia COMENTARIO
chmod 600 ~/.ssh/authorized_keys
```

### 9.2 sshd solo en `127.0.0.1` y solo con clave

```bash
sudo tee /etc/ssh/sshd_config.d/10-infra-podman.conf >/dev/null <<CONF
# infra-podman (R23): Ansible enters the laptop over loopback only, with a key.
ListenAddress 127.0.0.1
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $USER
CONF
sudo sshd -t && sudo systemctl enable --now sshd
ss -tln | grep ':22 '               # tiene que salir solo 127.0.0.1:22
```

`sshd -t` comprueba la configuración antes de arrancar; si da un error, no sigas. El fichero empieza por `10-` para que gane a los de Fedora (`50-redhat.conf`): sshd se queda con el primer valor que encuentra.

### 9.3 El alias `laptop`

En `~/.ssh/config`, **antes** de cualquier bloque `Host *`:

```text
Host laptop
    HostName 127.0.0.1
    User tu_usuario
    ForwardAgent no
```

Acepta la huella una vez: `ssh laptop true`. Tiene que entrar sin pedir contraseña.

### 9.4 Comprobación

`laptop` está en el inventario de producción, así que `deploy.sh` exige un tag firmado (`docs/WORKFLOW.md`). Para comprobar **antes del merge** que el contenedor de Ansible llega al portátil, desde la rama del PR, lanza ansible-navigator a mano con `check`, que solo lee:

```bash
ansible-navigator run playbooks/check.yml -i ~/Documents/SECURE_vc/ansible/infra-podman/inventory/prod/hosts.yml -- --limit laptop
```

Resultado esperado: `laptop: Fedora 44, podman version 5…` y `failed=0`.

## 10. sudo

`deploy.sh plan` y `apply` piden siempre la contraseña de sudo (`BECOME password:`). Si el playbook no la necesita, pulsa Intro (R24).

- Ansible entra con **tu usuario** y usa sudo para crear `svc_runner`, activar el linger y convertirse en `svc_runner`, que es quien ejecuta los contenedores.
- Tu usuario ya tiene sudo si `sudo true` te funciona: está en el grupo `wheel` en Fedora y `sudo` en Ubuntu (`id -nG`). No hay que añadir nada.
- Ansible pide una sola contraseña por ejecución. Si la del portátil y la del GX10 son distintas, despliega cada máquina por separado: `--limit laptop` y `--limit gx10`.

## 11. Usuario de servicio (fase 1, PR 1/4)

Primero en DEV, desde la rama del PR:

```bash
./deploy.sh plan base --env dev
./deploy.sh apply base --env dev
./deploy.sh apply base --env dev      # el segundo apply tiene que dar changed=0
```

Después, en producción: merge, tag firmado y `plan`/`apply` en cada máquina con `--limit laptop` y `--limit gx10`. Paso a paso en [`WORKFLOW.md`](WORKFLOW.md), pasos 4 a 6.

Comprobación a mano en cada máquina:

```bash
loginctl show-user svc_runner -p Linger      # Linger=yes
grep svc_runner /etc/subuid /etc/subgid      # una línea en cada fichero
```

## 12. Mirar los contenedores como `svc_runner`

Los contenedores son de `svc_runner`, no tuyos: `podman ps` con tu usuario no los ve. En cada máquina puedes definir esta función, por ejemplo en tu `~/.bashrc`:

```bash
svc() { (cd / && sudo -u svc_runner env HOME="$(getent passwd svc_runner | cut -d: -f6)" \
  XDG_RUNTIME_DIR="/run/user/$(id -u svc_runner)" "$@"); }
```

Y luego:

```bash
svc podman ps                                         # los contenedores
svc podman ps --filter label=infra.app=pg-main        # filtrar por etiqueta (SPEC 4.12)
svc systemctl --user status prod-pg-main.service      # el servicio
sudo journalctl _SYSTEMD_USER_UNIT=prod-pg-main.service -n 50   # sus logs
```

El `cd /` evita un error de permisos: `svc_runner` no puede entrar en tu carpeta personal.

## 13. Postgres (fase 1, PR 2/4)

### 13.1 La contraseña en KeePassXC

En **`infra-dev.kdbx`**, grupo `laperl` (el nombre de tu instalación, paso 16): entrada `pg-main-superuser-password` con cualquier valor ficticio.

En **`infra-pro.kdbx`**, la misma entrada con una contraseña generada por KeePassXC (32 caracteres o más). Solo se usa al crear la base por primera vez; cambiarla después tiene su procedimiento (`docs/SECRETS_INVENTORY.md`).

### 13.2 En DEV, desde la rama del PR

```bash
./deploy.sh secrets --env dev --limit vmiadev   # contraseña de infra-dev.kdbx y después la de sudo de vmiadev
./deploy.sh plan postgres --env dev
./deploy.sh apply postgres --env dev
./deploy.sh apply postgres --env dev            # changed=0
```

Comprueba en `vmiadev` (con la función `svc` del paso 12):

```bash
svc podman healthcheck run dev-pg-main && echo sano
svc podman port dev-pg-main                      # vacío: no publica puertos
sudo reboot                                      # y, al volver, repite la primera línea
```

### 13.3 En producción, después del merge y del tag

Postgres solo va en el portátil (R18):

```bash
./deploy.sh secrets --limit laptop
./deploy.sh plan postgres --limit laptop
./deploy.sh apply postgres --limit laptop
./deploy.sh apply postgres --limit laptop       # changed=0
```

Después reinicia el portátil y comprueba `svc podman healthcheck run prod-pg-main && echo sano`. Es parte del criterio de hecho de la fase 1: «sobrevive a un reinicio del portátil».

## 14. Repo de datos (fase 1c)

Desde la fase 1c, el inventario (máquinas, instancias y, más adelante, bases, usuarios y aplicaciones) no vive en el repo de código sino en tu **repo de datos**: un repo git solo en el portátil, sin GitHub y con los commits firmados (SPEC 4.13, R38). Su estructura es la de [`inventory.example/`](../inventory.example/README.md).

Se hace **una vez**, **antes** de probar en DEV la rama del PR de la fase 1c: desde esa versión, `deploy.sh` ya no encuentra el inventario en el repo de código.

Con el volumen cifrado `SECURE_vc` montado y KeePassXC desbloqueado:

```bash
CODE=~/Documents/src/github.com/laperl/infra-podman
DATA=~/Documents/SECURE_vc/ansible/infra-podman

# 1. El tag desplegado está firmado (tiene que decir Good "git" signature)
git -C "$CODE" fetch --tags && git -C "$CODE" verify-tag v0.2.0

# 2. Crear el repo de datos. La firma se configura SOLO en este repo, igual que en el de código
mkdir -p "$DATA" && cd "$DATA"
git init -b main
git config gpg.format ssh
git config user.signingkey "key::$(ssh-add -L | grep git-signing)"
git config user.email reposja@pm.me
git config commit.gpgSign true
git config gpg.ssh.allowedSignersFile ~/.config/infra-podman/allowed_signers

# 3. Copiar el inventario EXACTAMENTE como está en v0.2.0, lo que tienes desplegado
git -C "$CODE" archive v0.2.0 inventory | tar -x -C "$DATA"
git add inventory
git commit -m "inventory from infra-podman v0.2.0"

# 4. Comprobaciones
git verify-commit HEAD                               # Good "git" signature
git -C "$CODE" rev-parse v0.2.0:inventory            # estas dos líneas tienen que ser
git -C "$DATA" rev-parse HEAD:inventory              # el MISMO número: copia idéntica
git status --short                                   # vacío

# 5. Decirle a deploy.sh dónde está
echo 'data_repo = ~/Documents/SECURE_vc/ansible/infra-podman' >> ~/.config/infra-podman/deploy.conf
cat ~/.config/infra-podman/deploy.conf               # una sola línea data_repo
```

Qué hace cada cosa:

- **`git archive v0.2.0 inventory`** saca la carpeta tal como está en el tag, sin ficheros sueltos de tu copia. Tu copia del código no cambia.
- **El paso 4** compara la «huella» de la carpeta en los dos repos: si es la misma, el contenido es idéntico byte a byte.
- **La firma** se configura con `git config` sin `--global`: solo afecta a este repo. Usa la misma clave de firma que los tags y el mismo fichero de firmantes de confianza. Si git pide `user.name`, ponlo también con `git config user.name "<tu nombre>"`, sin `--global`.
- **La línea `data_repo`** la ignora el `deploy.sh` de `v0.2.0`, así que puedes añadirla ya: lo desplegado sigue funcionando igual hasta que pases a la versión nueva.

Si el volumen `SECURE_vc` no está montado, `deploy.sh` se niega con `no existe el repo de datos … ¿Está montado el volumen cifrado?`.

La copia de seguridad del repo de datos la harán los backups de la fase 1e. Mientras tanto vive solo en el portátil: si se perdiera, se rehace con estos mismos pasos desde `v0.2.0`, pero se perderían los cambios hechos después.

Cómo se cambian los datos a partir de ahora: [`WORKFLOW.md`](WORKFLOW.md), «Cambiar datos».

## 15. Recrear `pg-main` con el estándar de PostgreSQL (fase 1d)

Los parámetros de una instancia (superusuario, locale, codificación, checksums) solo se fijan al crearla por primera vez ([`POSTGRES.md`](POSTGRES.md), sección 1). La `pg-main` de la fase 1b se creó antes del estándar, así que hay que **borrarla y crearla de nuevo**. Se puede porque está vacía. Se hace una vez en DEV y una vez en el portátil.

Ansible nunca borra una instancia por su cuenta (D11). Si encuentra una creada de otra forma, se para con `was not created with the platform's parameters` y te remite aquí.

No hace falta nada nuevo en KeePassXC: el superusuario nuevo usa la misma entrada, `pg-main-superuser-password`, y el mismo secreto de Podman.

### 15.1 El superusuario en el repo de datos

En `inventory/dev/group_vars/postgres_hosts.yml` **y** en `inventory/prod/group_vars/postgres_hosts.yml` de tu repo de datos, la instancia tiene que quedar así:

```yaml
postgres_instances:
  - name: main
    superuser: laperl
```

```bash
cd ~/Documents/SECURE_vc/ansible/infra-podman
$EDITOR inventory/dev/group_vars/postgres_hosts.yml inventory/prod/group_vars/postgres_hosts.yml
git diff                                       # solo las dos líneas superuser
git commit -am "pg-main: superuser (infra-podman phase 1d)"
git verify-commit HEAD                         # Good "git" signature
```

### 15.2 En DEV, desde la rama del PR

**a. Comprueba que la protección funciona.** Con la instancia antigua aún en marcha, `plan` tiene que pararse:

```bash
./deploy.sh plan postgres --env dev --limit vmiadev
# … FAILED … dev-pg-main was not created with the platform's parameters … docs/SETUP.md, section 15
```

**b. Comprueba que está vacía y bórrala.** En `vmiadev`, con la función `svc` del paso 12. La instancia antigua tiene el superusuario `postgres`:

```bash
ssh vmiadev
svc podman exec dev-pg-main psql -XAt -U postgres -c "SELECT datname FROM pg_database ORDER BY 1"
#   postgres, template0 y template1. Si sale otra base, PARA y avísame.
svc podman exec dev-pg-main psql -XAt -U postgres -d postgres \
  -c "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')"
#   0. Si no, PARA y avísame.

svc systemctl --user stop dev-pg-main.service              # para y elimina el contenedor
svc systemctl --user stop dev-pg-main-data-volume.service  # para que el apply vuelva a crear el volumen
svc podman volume rm dev-pg-main-data                      # BORRA los datos de pg-main
svc podman volume ls --filter label=infra.app=pg-main      # vacío
exit
```

**c. Créala de nuevo**, desde el portátil:

```bash
./deploy.sh plan  postgres --env dev --limit vmiadev
./deploy.sh apply postgres --env dev --limit vmiadev
./deploy.sh apply postgres --env dev --limit vmiadev       # changed=0
```

**d. Comprueba**, en `vmiadev`:

```bash
svc podman healthcheck run dev-pg-main && echo sano
svc podman exec dev-pg-main psql -XAt -U laperl -d postgres -c \
  "SELECT datlocprovider, datlocale, pg_encoding_to_char(encoding), current_setting('data_checksums'), current_setting('TimeZone') FROM pg_database WHERE datname = 'postgres'"
#   b|C.UTF-8|UTF8|on|UTC
```

### 15.3 En el portátil, después del merge y del tag

Lo mismo, con `prod` y `--limit laptop`, desde tu copia del código en el tag (`docs/WORKFLOW.md`, pasos 5 y 6). En el portátil la función `svc` se usa directamente, sin `ssh`:

```bash
./deploy.sh plan postgres --limit laptop                   # se para: … not created with the platform's parameters

svc podman exec prod-pg-main psql -XAt -U postgres -c "SELECT datname FROM pg_database ORDER BY 1"
svc podman exec prod-pg-main psql -XAt -U postgres -d postgres \
  -c "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')"
#   Solo postgres, template0 y template1, y 0 tablas. Si no, PARA y avísame.

svc systemctl --user stop prod-pg-main.service
svc systemctl --user stop prod-pg-main-data-volume.service
svc podman volume rm prod-pg-main-data

./deploy.sh plan  postgres --limit laptop
./deploy.sh apply postgres --limit laptop
./deploy.sh apply postgres --limit laptop                  # changed=0
svc podman healthcheck run prod-pg-main && echo sano
```

Después, reinicia el portátil y repite la última línea: forma parte del criterio de hecho de la fase 1 («sobrevive a un reinicio»).

Desde ahora, la consola es `svc podman exec -it prod-pg-main psql -U laperl -d postgres` ([`POSTGRES.md`](POSTGRES.md), sección 5).

## 16. El nombre de la instalación

Cada instalación de esta plataforma tiene un **nombre propio**: la tuya, `laperl`; la de un cliente, el nombre del cliente. Es obligatorio y se escribe una sola vez, en el repo de datos. De él salen:

- **el grupo de KeePassXC** donde están sus secretos: `laperl/pg-main-superuser-password`, `laperl/backup-restic-password`…;
- más adelante, la identificación de sus backups (fase 1e1) y su carpeta en el GX10 (fase 1e2).

Sin él, `deploy.sh secrets` se para antes de leer nada. Con él, nunca puede leer el secreto de otra instalación, y si en el grupo hay **dos entradas con el mismo título** se para en vez de elegir una (R42).

### 16.1 Pasar de `Infra_Podman` a `laperl` (una vez)

Hasta ahora el grupo se llamaba `Infra_Podman`, un nombre fijo en el código. Con KeePassXC abierto:

1. En **`infra-dev.kdbx`**: clic derecho en el grupo `Infra_Podman` → **Editar grupo** → nombre `laperl` → Aceptar. Guarda.
2. Lo mismo en **`infra-pro.kdbx`**.

Las entradas y sus valores no cambian; solo el nombre del grupo.

Después, en el repo de datos, añade el nombre en `inventory/dev/group_vars/all.yml` **y** en `inventory/prod/group_vars/all.yml`, debajo de `infra_env`:

```yaml
infra_site: laperl
```

```bash
cd ~/Documents/SECURE_vc/ansible/infra-podman
git diff                                   # solo esas dos líneas
git commit -am "infra_site: laperl (infra-podman R42)"
git verify-commit HEAD                     # Good "git" signature
```

### 16.2 Comprobación

Desde tu copia del código, en la rama del PR para DEV y en el tag para producción:

```bash
./deploy.sh secrets --env dev --limit vmiadev   # tiene que salir «1 check-only secret(s) readable from KeePassXC for dev»
./deploy.sh secrets --limit laptop              # no crea nada: los secretos ya existen
```

`secrets` solo lee KeePassXC para lo que falta y para `test_dummy`, así que la primera orden comprueba de verdad que el grupo nuevo se lee. En las máquinas no cambia nada.

Si sale `cannot list the group 'laperl'`, el grupo no está renombrado en ese fichero. Si sale `the name of the installation is missing`, falta `infra_site` en el repo de datos.

### 16.3 Si algún día cambias el nombre

Cambias `infra_site` en el repo de datos y renombras el grupo en KeePassXC con el mismo nombre. Nada más: ni el código ni los secretos de las máquinas dependen de él.

## 17. Backups locales (fase 1e1)

Una copia diaria, a las 13:00, de todas las bases de cada instancia y, en el portátil, de tu repo de datos (SPEC 4.11). Se guarda cifrada con restic en el volumen `<entorno>-backup-repo`. Si a esa hora la máquina estaba apagada, la copia se hace al encenderla. La copia al GX10 está en el paso 18.

### 17.1 La clave de restic en KeePassXC

En **`infra-dev.kdbx`**, grupo `laperl` (el nombre de tu instalación, paso 16): entrada `backup-restic-password` con cualquier valor ficticio.

En **`infra-pro.kdbx`**, la misma entrada con una contraseña generada por KeePassXC (32 caracteres o más).

**Sin esta clave, las copias no se pueden leer.** No hay forma de recuperarlas. Vive en `infra-pro.kdbx`, así que la copia manual de ese fichero (ROADMAP) es lo que protege tus backups.

### 17.2 El repo de datos

En `~/Documents/SECURE_vc/ansible/infra-podman` (con `vmiadev` y `laptop`, tus alias):

1. `inventory/dev/hosts.yml` y `inventory/prod/hosts.yml`: un grupo nuevo, `backup_clients`, con la máquina que hace copias:
   ```yaml
       backup_clients:
         hosts:
           vmiadev: {}      # en prod: laptop: {}
   ```
2. `inventory/dev/group_vars/all.yml` y `inventory/prod/group_vars/all.yml`: en `infra_secrets`, debajo de `pg-main-superuser-password`:
   ```yaml
     - name: backup-restic-password
       group: backup_clients
   ```
3. `inventory/prod/host_vars/laptop.yml`, un fichero nuevo, solo para el portátil:
   ```yaml
   ---
   backup_data_repo: true   # copia también el repo de datos
   backup_notify: true      # aviso de escritorio si una copia falla o es antigua
   ```

Hay un ejemplo de cada fichero en [`inventory.example/`](../inventory.example/README.md). Después, commit firmado (`docs/WORKFLOW.md`, «Cambiar datos»).

### 17.3 En DEV, desde la rama del PR

```bash
./deploy.sh secrets       --env dev --limit vmiadev    # crea dev-backup-restic-password
./deploy.sh plan  backup  --env dev --limit vmiadev
./deploy.sh apply backup  --env dev --limit vmiadev
./deploy.sh apply backup  --env dev --limit vmiadev    # changed=0
```

En `vmiadev`, con la función `svc` del paso 12, lanza una copia sin esperar a las 13:00 y mira el resultado:

```bash
svc systemctl --user start dev-backup.service           # tarda unos segundos; sin salida si va bien
cat /var/lib/infra-podman/backup-status/dev-backup.status   # result=ok
svc systemctl --user list-timers dev-backup.timer       # la próxima, mañana a las 13:00
```

### 17.4 En el portátil, después del merge y del tag

```bash
./deploy.sh secrets      --limit laptop
./deploy.sh plan  backup --limit laptop
./deploy.sh apply backup --limit laptop                 # al final: «copia del repo de datos lista para el backup»
./deploy.sh apply backup --limit laptop                 # changed=0

svc systemctl --user start prod-backup.service
cat /var/lib/infra-podman/backup-status/prod-backup.status  # result=ok
```

**Comprueba el aviso de escritorio una vez**, provocando un fallo a propósito (Postgres parado):

```bash
svc systemctl --user stop prod-pg-main.service
svc systemctl --user start prod-backup.service          # falla: es lo esperado
systemctl --user start infra-podman-backup-notify.service   # tiene que salir la notificación
svc systemctl --user start prod-pg-main.service
svc systemctl --user start prod-backup.service          # vuelve a result=ok
```

### 17.5 Mirar las copias

- **Logs** de cada copia: qué ha volcado, qué ha guardado, cuánto ocupa y cualquier error. Nunca la clave.
  ```bash
  sudo journalctl _SYSTEMD_USER_UNIT=prod-backup.service -n 100
  ```
- **Logs del aviso**, en tu propio journal:
  ```bash
  journalctl --user -u infra-podman-backup-notify -n 20
  ```
- **Resumen** de la última copia: `cat /var/lib/infra-podman/backup-status/prod-backup.status`.
- **Lista de copias:**
  ```bash
  img=$(svc sed -n 's/^Image=//p' "$(getent passwd svc_runner | cut -d: -f6)/.config/containers/systemd/prod-backup.container")
  svc podman run --rm --network=none --security-opt label=disable -v prod-backup-repo:/repo \
    --secret prod-backup-restic-password,type=mount,target=/run/secrets/restic-password \
    -e RESTIC_REPOSITORY=/repo -e RESTIC_PASSWORD_FILE=/run/secrets/restic-password \
    "$img" snapshots
  ```
  Desde cualquier carpeta: la primera línea lee la imagen de restic del contenedor de backup ya instalado. `--security-opt label=disable` hace falta en Fedora: el backup marca su volumen como privado para SELinux (`:Z`) y, sin esa opción, otro contenedor recibe `permission denied`. No cambia la marca del volumen. Cada copia lleva las etiquetas `site=` (`laperl`), `env=`, `app=`, `type=` (`pgdump` o `files`) y `reason=` (`daily`, o `pre-upgrade` si se hizo antes de cambiar la imagen de Postgres).

La guía de restauración paso a paso, probada, llega en la fase 1f. Lo esencial ya está comprobado en el CI: una base volcada se restaura y queda igual.

### 17.6 Lo que instala en tu cuenta (y si algún día quieres quitar el aviso)

**No tienes que hacer nada aquí.** Solo es para que sepas qué hay en tu usuario.

Para que el aviso salga en tu escritorio, Ansible instala en **tu** usuario, no en `svc_runner`:

- `~/.local/libexec/infra-podman/backup-notify.sh`;
- `~/.config/systemd/user/infra-podman-backup-notify.service` y `.timer`: miran cada hora el estado de `/var/lib/infra-podman/backup-status/` y no cambian nada.

Solo afecta a ese aviso. **Si algún día no lo quieres**, quítalo así:

```bash
systemctl --user disable --now infra-podman-backup-notify.timer
rm ~/.config/systemd/user/infra-podman-backup-notify.{service,timer} ~/.local/libexec/infra-podman/backup-notify.sh
systemctl --user daemon-reload
```

Y pon `backup_notify: false` en `host_vars/laptop.yml` del repo de datos, o el siguiente `apply backup` lo volverá a instalar.

## 18. Copia de los backups al GX10 (fase 1e2)

Cada hora, si el GX10 responde, el portátil le manda las copias que le falten (SPEC 4.11, R44).

| Pieza | Dónde | Qué hace |
| --- | --- | --- |
| `prod-backup-server` | GX10 | Guarda las copias en el volumen `prod-backup-server-data`. Solo deja **añadir**: nadie puede borrar ni cambiar nada a través de él. Pide usuario (`laperl`) y contraseña, y cada instalación solo ve su carpeta (`laperl/prod-laptop`). Tope: 30 GB |
| Puerto 18000 | GX10 | Solo en `127.0.0.1`. Desde fuera, solo por Tailscale (`tailscale serve`), nunca por la red de casa |
| `prod-backup-copy` | Portátil | Cada hora, a y media. Solo ve el repositorio local, cifrado y en solo lectura. Si el GX10 no responde, no pasa nada: lo intenta a la hora siguiente |
| Aviso de escritorio | Portátil | El del paso 17. Salta si una copia falla, si pasan **7 días** sin una copia buena en el GX10 o si el GX10 pasa del **80 %** del tope |

**Lo más importante:** para recuperar tus datos solo hace falta la clave de restic (`backup-restic-password`). La contraseña del servidor solo sirve para que nadie más use el servidor. Si un día el servidor falla o pierdes esa contraseña, las copias se leen directamente del volumen del GX10 (18.6).

### 18.1 La contraseña del servidor en KeePassXC

En el grupo `laperl` de cada base, una entrada nueva, **`backup-server-password`**:

- en **`infra-dev.kdbx`**, cualquier valor ficticio;
- en **`infra-pro.kdbx`**, una contraseña generada por KeePassXC, de 32 caracteres o más.

### 18.2 El repo de datos

En `~/Documents/SECURE_vc/ansible/infra-podman`:

1. `inventory/dev/hosts.yml` y `inventory/prod/hosts.yml`: un grupo nuevo, `backup_servers`, con la máquina que guarda las copias:
   ```yaml
       backup_servers:
         hosts:
           vmiadev: {}      # en prod: gx10: {}
   ```
2. `inventory/dev/group_vars/all.yml` y `inventory/prod/group_vars/all.yml`: en `infra_secrets`, debajo de `backup-restic-password`, la contraseña nueva, que necesitan las dos puntas; y, al final del fichero, el tope:
   ```yaml
     - name: backup-server-password
       group: [backup_clients, backup_servers]
   ```
   ```yaml
   backup_server_max_size_gb: 30
   ```
3. `inventory/prod/host_vars/laptop.yml`: adónde va la copia. Es el nombre de Tailscale del GX10, el que sale en `sudo tailscale serve status` sin `https://`, con `http://` delante y el puerto detrás:
   ```yaml
   backup_remote_url: http://<nombre del GX10>.<tu red>.ts.net:18000
   ```
4. `inventory/dev/host_vars/vmiadev.yml`, un fichero nuevo. La VM no tiene Tailscale: el servidor no se expone y la copia llega desde la propia VM.
   ```yaml
   ---
   backup_server_tailscale: false
   backup_remote_url: http://127.0.0.1:8000
   backup_remote_network: container:dev-backup-server
   ```

Hay un ejemplo de cada fichero en [`inventory.example/`](../inventory.example/README.md). Después, commit firmado (`docs/WORKFLOW.md`, «Cambiar datos»).

### 18.3 En DEV, desde la rama del PR

```bash
./deploy.sh secrets             --env dev --limit vmiadev   # crea dev-backup-server-password
./deploy.sh plan  backup-server --env dev --limit vmiadev
./deploy.sh apply backup-server --env dev --limit vmiadev
./deploy.sh apply backup-server --env dev --limit vmiadev   # changed=0
./deploy.sh plan  backup        --env dev --limit vmiadev   # añade dev-backup-copy y su temporizador
./deploy.sh apply backup        --env dev --limit vmiadev
./deploy.sh apply backup        --env dev --limit vmiadev   # changed=0
```

En `vmiadev`, una copia y su envío sin esperar:

```bash
svc systemctl --user start dev-backup.service
svc systemctl --user start dev-backup-copy.service
cat /var/lib/infra-podman/backup-status/dev-backup-copy.status   # result=ok y usage=…
```

### 18.4 En producción, después del merge y del tag

**Primero el GX10**, con su contraseña de sudo. Si no tienes allí la función `svc`, defínela como en el paso 12.

```bash
./deploy.sh secrets             --limit gx10
./deploy.sh plan  backup-server --limit gx10
./deploy.sh apply backup-server --limit gx10
./deploy.sh apply backup-server --limit gx10    # changed=0
```

En el GX10, comprueba:

```bash
sudo tailscale serve status        # sigue tu página de siempre y aparece el puerto 18000
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18000/   # 401: responde y pide contraseña
```

Mándame la salida de `sudo tailscale serve status --json` (no tiene nada secreto): cierra lo que queda por comprobar (R44).

**Después el portátil**, con su contraseña de sudo:

```bash
./deploy.sh secrets      --limit laptop
./deploy.sh plan  backup --limit laptop
./deploy.sh apply backup --limit laptop
./deploy.sh apply backup --limit laptop          # changed=0

svc systemctl --user start prod-backup-copy.service
cat /var/lib/infra-podman/backup-status/prod-backup-copy.status   # result=ok
```

**Comprueba una vez que un GX10 sin servicio no es un fallo:** en el GX10, `svc systemctl --user stop prod-backup-server.service`; en el portátil, `svc systemctl --user start prod-backup-copy.service` termina sin error y el estado dice `result=unreachable`. Vuelve a arrancarlo con `svc systemctl --user start prod-backup-server.service`.

### 18.5 Mirar las copias del GX10

- **Estado** de la última copia: `cat /var/lib/infra-podman/backup-status/prod-backup-copy.status`. Dice cuándo fue la última buena (`last_ok`) y cuánto ocupa (`usage`).
- **Logs** de cada intento, en el portátil: `sudo journalctl _SYSTEMD_USER_UNIT=prod-backup-copy.service -n 100`.
- **Logs del servidor**, en el GX10: `sudo journalctl _SYSTEMD_USER_UNIT=prod-backup-server.service -n 100`.
- **Lista de copias del GX10, desde el portátil**, a través del servidor (cambia el nombre del GX10):
  ```bash
  img=$(svc sed -n 's/^Image=//p' "$(getent passwd svc_runner | cut -d: -f6)/.config/containers/systemd/prod-backup-copy.container")
  svc podman run --rm \
    --secret prod-backup-restic-password,type=mount,target=/run/secrets/restic-password \
    --secret prod-backup-server-password,type=env,target=RESTIC_REST_PASSWORD \
    -e RESTIC_PASSWORD_FILE=/run/secrets/restic-password -e RESTIC_REST_USERNAME=laperl \
    -e RESTIC_REPOSITORY=rest:http://<nombre del GX10>.<tu red>.ts.net:18000/laperl/prod-laptop/ \
    "$img" snapshots
  ```
  Desde cualquier carpeta: la primera línea lee la imagen de restic del contenedor de copia ya instalado. Las contraseñas llegan desde los secretos de Podman: no aparecen en la orden ni en el historial.

### 18.6 Si algo falla

| Lo que ves | Qué pasa | Qué hacer |
| --- | --- | --- |
| Aviso «la última copia correcta es de …, hace más de 168 h. El servidor de copias … no responde» | El portátil no llega al GX10 desde hace una semana | 1. ¿Está encendido el GX10? `ssh gx10 true`. 2. Desde el portátil: `curl -s -o /dev/null -w '%{http_code}\n' http://<nombre del GX10>.<tu red>.ts.net:18000/`. `401` es que responde; `000` es que no llega. 3. En el GX10: `svc systemctl --user status prod-backup-server.service` y `sudo tailscale serve status` (tiene que salir el 18000). Si falta el puerto: `./deploy.sh apply backup-server --limit gx10` |
| El nombre del GX10 no se resuelve dentro del contenedor (`bad address` en los logs de la copia) | El contenedor no ve los nombres de Tailscale (por comprobar en el portátil) | Usa la IP de Tailscale del GX10, que no cambia: `tailscale ip -4 <nombre del GX10>`. Ponla en `backup_remote_url` del repo de datos y `apply backup --limit laptop` |
| Aviso «el servidor de copias no acepta el usuario o la contraseña» | La contraseña del portátil y el hash del GX10 no coinciden | `./deploy.sh secrets --rotate backup-server-password --limit gx10`, `./deploy.sh secrets --rotate backup-server-password --limit laptop` y `./deploy.sh apply backup-server --limit gx10`. Ansible ve que el hash ya no corresponde y lo rehace |
| Aviso «la clave de restic no abre el repositorio del servidor» | `backup-restic-password` no es la misma con la que se creó la copia del GX10 | **No borres nada.** Comprueba en KeePassXC el historial de esa entrada: la buena es la que abre las copias. Nunca se crea un repositorio nuevo encima de uno que existe |
| Aviso «el servidor de copias está al … % de su tope» o «está lleno» | Las copias del GX10 se acercan a los 30 GB o los han alcanzado. Lleno no copia nada nuevo; tus copias locales siguen bien | Mira el espacio del GX10 (`df -h /`). Sube `backup_server_max_size_gb` en `group_vars/all.yml` del repo de datos, commit firmado, y `apply backup-server --limit gx10` y `apply backup --limit laptop`. En el GX10 no se borra nada solo (R26) |
| Aviso «el servidor de copias no deja escribir en …» | El usuario solo puede escribir en su carpeta, y la carpeta no empieza por su nombre | Comprueba que `infra_site` es el mismo en el repo de datos que la carpeta del mensaje |
| El servidor no arranca o has perdido su contraseña | — | Tus copias siguen en el volumen. Para leerlas sin el servidor, en el GX10 (pega la clave de restic de KeePassXC cuando la pida; no se guarda): <br>`svc podman run --rm -it --network=none -v prod-backup-server-data:/data:ro -e RESTIC_REPOSITORY=/data/laperl/prod-laptop <restic_image de images.yml> --no-lock snapshots` <br>`<restic_image de images.yml>` es el valor de `restic_image` en `playbooks/group_vars/all/images.yml` de tu copia del código, sin comillas: en el GX10 no hay contenedor de restic de donde leerlo. <br>Para una contraseña nueva: cambia la entrada en KeePassXC y sigue la fila de «no acepta el usuario o la contraseña» |

La guía de restauración paso a paso, desde la copia local y desde la del GX10, llega en la fase 1f.

### 18.7 Lo que se instala

**No tienes que hacer nada aquí.** Solo es para que sepas qué hay en cada máquina.

- **GX10**, en `svc_runner`: el contenedor `prod-backup-server`, su volumen `prod-backup-server-data` y el hash de la contraseña en `~/.config/infra-podman/prod-backup-server/htpasswd`. Con sudo: la entrada del puerto 18000 en `tailscale serve`. Ansible no toca nada más de `tailscale serve`.
- **Portátil**, en `svc_runner`: el contenedor `prod-backup-copy`, su temporizador `prod-backup-copy.timer` y la carpeta `~/.local/state/infra-podman/backup-copy`. En tu cuenta, el script del aviso del paso 17 cambia: ahora también entiende el estado de la copia al GX10.
- **Para dejar de copiar al GX10:** quita `backup_remote_url` de `host_vars/laptop.yml` y `apply backup --limit laptop`: borra el contenedor de copia y su temporizador. En el GX10 no se toca nada.
