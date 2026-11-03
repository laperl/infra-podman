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

- grupo `Infra_Podman`;
- entrada `test_dummy` con una contraseña ficticia cualquiera;
- contraseña maestra distinta de la de `infra-pro.kdbx`.

Este fichero **vive solo en el portátil**: no se copia a la VM y no hace falta hacerle copia de seguridad. Solo contiene valores ficticios y se recrea en dos minutos con el grupo y los nombres de `infra_secrets` en `inventory/dev/group_vars/all.yml` (R17). La copia de seguridad que sí importa es la de `infra-pro.kdbx`: está apuntada en el `ROADMAP`.

## 4. Prueba del lookup contra tu `.kdbx` (criterio de hecho de la fase 0)

En el portátil, dentro de tu copia del repo (paso 0), en la rama del PR 0b. Hace falta haber hecho el paso 2 (`podman login`). La primera vez descarga la imagen (~1 GB). La imagen es la que fija `ansible-navigator.yml`:

```bash
IMAGE=$(sed -n 's/^ *image: *\([^ ]*\).*/\1/p' ansible-navigator.yml)
KDBX=~/ruta/a/infra-dev.kdbx                      # cámbialo
read -rs -p 'Contraseña de infra-dev.kdbx: ' P; echo
printf '%s\n' "$P" | podman run --rm -i --user root \
  -v "$PWD:/work:ro,z" -w /work \
  -v "$KDBX:/kdbx/infra-dev.kdbx:ro,z" \
  "$IMAGE" bash -c 'IFS= read -r KDBX_PASSWORD; export KDBX_PASSWORD KDBX_DATABASE=/kdbx/infra-dev.kdbx; exec ansible-playbook tests/ee/operator_selftest.yml'
unset P
```

`--user root` hace falta porque, en Podman sin root, el root del contenedor es tu propio usuario en el portátil: así puede leer tu `.kdbx`, que normalmente solo tú puedes leer. ansible-navigator hace lo mismo.

Resultado esperado: `OK: read Infra_Podman/test_dummy (N characters)`. El valor no se muestra.

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
```

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
ansible-navigator run playbooks/check.yml -i inventory/prod/hosts.yml -- --limit laptop
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
