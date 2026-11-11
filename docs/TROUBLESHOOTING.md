# Guía de problemas

Qué hacer cuando algo falla, ordenado por pieza. Busca el mensaje que ves (Ctrl+F con un trozo): aquí está tal como lo escribe el código, con `…` en lo que cambia en cada caso.

- Las órdenes funcionan desde cualquier carpeta, salvo `./deploy.sh`, que va en tu copia del código. Usan la función `svc` de [`SETUP.md`](SETUP.md), paso 12.
- En DEV, cambia `prod` por `dev` y `laptop`/`gx10` por `vmiadev`.
- Lo que depende de SELinux está marcado **«por comprobar en el portátil»**: el CI no tiene SELinux.
- Cómo está montada cada pieza: [`ARCHITECTURE.md`](ARCHITECTURE.md). El día a día y cómo restaurar: [`OPERATIONS.md`](OPERATIONS.md).

## 0. Dónde mirar primero

| Qué | Orden |
| --- | --- |
| Los últimos despliegues, también los rechazados | `tail -5 ~/.local/state/infra-podman/deploy.log` |
| El estado de las copias | `cat /var/lib/infra-podman/backup-status/*.status` |
| Los logs de un servicio | `sudo journalctl _SYSTEMD_USER_UNIT=prod-<servicio>.service -n 50` |
| Qué corre y qué espera a su temporizador | `svc podman ps` y `svc systemctl --user list-timers` |
| Si todo está sano | [`OPERATIONS.md`](OPERATIONS.md), apartado 4 |

## 1. `deploy.sh`, KeePassXC y la conexión

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `deploy.sh: no existe el repo de datos …. ¿Está montado el volumen cifrado?` | El volumen `SECURE_vc` no está montado | Móntalo en VeraCrypt y repite |
| `deploy.sh: --confirm-drop solo vale con apply postgres` | La usaste con `plan` o con otro playbook | Solo `./deploy.sh apply postgres … --confirm-drop <instancia>` |
| `deploy.sh: --retire solo vale con apply postgres o apply firefly` | La usaste con `plan` o con otro playbook | `./deploy.sh apply postgres … --retire <instancia>` o `./deploy.sh apply firefly … --retire <instancia>` |
| `deploy.sh: nombre de instancia no válido: …` | El nombre no es solo letras minúsculas y números | El de `name:` en `postgres_instances` |
| `deploy.sh: define data_repo = <ruta del repo de datos> en …` | Falta la línea `data_repo` en `~/.config/infra-podman/deploy.conf` | Añádela ([`SETUP.md`](SETUP.md), paso 7) |
| `deploy.sh: falta inventory/prod/hosts.yml en el repo de datos …` | El repo de datos no tiene el inventario de ese entorno | Revisa su estructura con [`inventory.example/`](../inventory.example/README.md) |
| `deploy.sh: define kdbx_prod=<ruta al .kdbx> en …` | Falta la ruta del `.kdbx` en `deploy.conf`, o el fichero no está ahí | Corrige la línea `kdbx_prod` (o `kdbx_dev`): [`SETUP.md`](SETUP.md), paso 7 |
| `deploy.sh: no hay agente SSH (SSH_AUTH_SOCK); desbloquea KeePassXC` | En esa terminal no hay agente SSH: `SSH_AUTH_SOCK` está vacía o no apunta a un agente | Ábrela desde tu sesión de escritorio, con KeePassXC desbloqueado. Comprueba: `ssh-add -l` lista tus claves |
| `deploy.sh: contraseña vacía` | Has pulsado Intro sin escribir la contraseña maestra | Repite y escríbela |
| `deploy.sh: apply --env prod necesita un terminal interactivo` | Lo has lanzado sin terminal (desde un script, por ejemplo) | Lánzalo tú desde una terminal |
| `deploy.sh: cancelado por el operador` | No has escrito exactamente `prod` en la confirmación | Repite y escribe `prod` |
| `deploy.sh: playbook desconocido '…'` | El nombre no corresponde a ningún `playbooks/<nombre>.yml` | Mira la lista: [`WORKFLOW.md`](WORKFLOW.md), «Los playbooks» |
| `kdbx: cannot list the group '…'` | La contraseña maestra es otra, o el grupo de KeePassXC no se llama como tu instalación (`infra_site`) | Repite con la contraseña buena. Si sigue, renombra el grupo ([`SETUP.md`](SETUP.md), paso 16) |
| `kdbx: there is no entry '…' in the group '…'` | Falta esa entrada en el `.kdbx`, o su título es distinto | Créala en KeePassXC, en el grupo de tu instalación, con ese título exacto. El PR que la pide lo dice en «Cómo desplegarlo» |
| `kdbx: the group '…' of … has 2 entries titled '…'` | Dos entradas con el mismo título en el grupo | Deja solo una |
| `infra_site is missing or not valid in group_vars/all.yml of the data repository` | Falta el nombre de la instalación en el repo de datos | `infra_site: laperl` en los dos `group_vars/all.yml` ([`SETUP.md`](SETUP.md), paso 16) |
| `'…' is not in infra_secrets for prod` | El nombre de `--rotate` no está en la lista de secretos | Copia el nombre exacto de `infra_secrets` (repo de datos, `group_vars/all.yml`) |
| `Incorrect sudo password` o `Missing sudo password` | Has escrito la contraseña de sudo de otra máquina, o falta `--limit` | Repite con `--limit` y la contraseña de esa máquina (R24) |
| `UNREACHABLE` en `laptop` | sshd está parado, o el alias `laptop` de `~/.ssh/config` no está bien | `ssh laptop true`; [`SETUP.md`](SETUP.md), paso 9 |
| `UNREACHABLE` en `gx10` | El GX10 está apagado o fuera de Tailscale | `ssh gx10 true` y `tailscale status` |
| `UNREACHABLE` en `vmiadev` | La VM está apagada | Arráncala; `ssh vmiadev true` |
| `Permission denied (publickey)` | Tu clave de acceso no está en el agente (KeePassXC bloqueado) o no está en el `authorized_keys` de esa máquina | Desbloquea KeePassXC; `ssh-add -l`. Si la clave está y sigue, [`SETUP.md`](SETUP.md), pasos 6 y 9.1 |
| `ansible-navigator` no puede descargar la imagen de Ansible | `podman login ghcr.io` se borra al reiniciar el portátil | `podman login ghcr.io --username laperl` con el token de KeePassXC ([`SETUP.md`](SETUP.md), paso 2) |

## 2. Firmas

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `deploy.sh: HEAD (…) no tiene ningún tag firmado por una clave de confianza.` | El tag está en otro commit (lo creaste antes del `git pull`) o no está firmado. El mensaje dice dónde está el último tag | Si no lo has subido: `git tag -d <tag>` y repite [`WORKFLOW.md`](WORKFLOW.md), paso 5. Comprueba con `git tag --points-at HEAD` y `git verify-tag <tag>`. Si ya lo subiste, crea el siguiente número |
| `deploy.sh: hay cambios sin commit o ficheros sin seguimiento; en prod solo se despliega un tag firmado y limpio` | Hay algo modificado en tu copia del código | `git status`. Guarda tus cambios en otra rama o descártalos |
| `deploy.sh: el repo de datos tiene cambios sin commit o ficheros sin seguimiento (…)` | Has editado datos y no has hecho el commit | `git -C ~/Documents/SECURE_vc/ansible/infra-podman status`. Commit firmado o `git restore` ([`WORKFLOW.md`](WORKFLOW.md), «Cambiar datos») |
| `deploy.sh: el último commit del repo de datos (…) no está firmado por una clave de confianza.` | Commit hecho sin firma o con otra clave | `git -C ~/Documents/SECURE_vc/ansible/infra-podman verify-commit HEAD`. Revisa la firma de ese repo ([`SETUP.md`](SETUP.md), paso 14) y rehaz el commit: `git -C ~/Documents/SECURE_vc/ansible/infra-podman commit --amend --no-edit -S` |
| `deploy.sh: falta …/allowed_signers (ver docs/SIGNING.md)` | Falta tu lista de claves de confianza | [`SIGNING.md`](SIGNING.md), paso 2 |
| `deploy.sh: … no puede apuntar a un fichero del repo` (o `del repo de datos`) | `allowed_signers` es un enlace a un fichero de uno de los repos. Así cualquiera con acceso al repo podría añadir su clave (R4) | Que sea un fichero propio en `~/.config/infra-podman/` |
| `gpg.ssh.allowedSignersFile needs to be configured and exist` | Al comprobar un tag a mano, git no sabe qué claves son de confianza | Configúralo en ese repo ([`SIGNING.md`](SIGNING.md)). A `deploy.sh` no le afecta |
| GitHub muestra el tag como «no verificado» | La clave no está dada de alta en GitHub como **Signing Key**, o el correo no está verificado. `deploy.sh` sí lo verifica, y es quien decide | [`SIGNING.md`](SIGNING.md), paso 3 (ROADMAP) |

## 3. Usuario de servicio

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `svc_runner does not exist on …. Apply the base playbook first` | Falta el usuario de servicio en esa máquina | `./deploy.sh apply base --limit <máquina>` |
| `Podman 4.9 or newer is required. Found: …` | Podman no está instalado o es antiguo | En Ubuntu: `sudo apt install podman` |
| `… is missing on …` (por ejemplo `/usr/bin/newuidmap`) | Falta una orden que Podman sin root necesita | En Ubuntu lo instala `apply base`. En el portátil viene con Fedora: avísame |
| `/etc/subuid has no range for svc_runner` (o `/etc/subgid`) | El usuario no tiene rangos de identificadores para sus contenedores | El mensaje da la orden `sudo usermod --add-subuids … --add-subgids … svc_runner`: avísame antes, para elegir un rango que no pise otro |
| `podman info as svc_runner does not report rootless mode` | Podman no funciona sin root para ese usuario | `svc podman info` y mándame la salida |
| Los contenedores no arrancan tras reiniciar | Falta el linger del usuario | `loginctl show-user svc_runner -p Linger` tiene que decir `Linger=yes`. Si no, `./deploy.sh apply base --limit <máquina>` |

## 4. Quadlet y systemd

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `… did not pass its healthcheck in … s and has been STOPPED, without rolling back the image (D11).` | El contenedor arrancó pero no está sano. Ansible lo ha parado y no vuelve atrás solo | Mira por qué: `sudo journalctl _SYSTEMD_USER_UNIT=prod-<servicio>.service -n 50`. Si fue un cambio de imagen, vuelve al tag anterior ([`WORKFLOW.md`](WORKFLOW.md)) o mándame los logs |
| Falla la tarea `Run the generator in dry-run mode` con `unsupported key` | Una plantilla usa una clave que el Podman de esa máquina no entiende. No se ha instalado nada | Mándame la salida: es un fallo del código, el CI debió verlo |
| `Changed …. If the object already exists, Podman keeps it as it is` | Ha cambiado un fichero de volumen o de red. Podman no cambia uno que ya existe | Es un aviso. Recrearlo borra datos: pídemelo antes |
| `Could not find the requested service` justo después de instalar una unidad | El systemd de `svc_runner` busca sus unidades en otra carpeta: alguna variable `XDG_*` global apunta a otro usuario | `grep XDG_ /etc/environment` tiene que salir vacío ([`COMPATIBILITY.md`](COMPATIBILITY.md)) |
| Un temporizador no se ha disparado | El temporizador está parado, o la máquina estaba apagada (se recupera al encender) | `svc systemctl --user list-timers` tiene que listarlo con su próxima hora. Si no, `./deploy.sh apply backup --limit laptop` |

## 5. Postgres

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `The Podman secret prod-pg-main-superuser-password does not exist on …` | Falta el secreto en esa máquina | `./deploy.sh secrets --limit laptop` (entrada `pg-main-superuser-password` en KeePassXC) |
| `Each instance needs its superuser in the data repository` | Falta `superuser:` en la instancia, o su nombre no es válido | En el repo de datos, `superuser:` en `postgres_instances` ([`SETUP.md`](SETUP.md), paso 15.1) |
| `prod-pg-main was not created with the platform's parameters` | La instancia se creó antes del estándar o con otros parámetros. Ansible no toca nada (D11) | [`SETUP.md`](SETUP.md), paso 15. Borra datos: solo si está vacía |
| `prod-pg-main would restart on a new image, and there is no backup service on …` | Cambia la imagen de Postgres y no hay backup con el que hacer antes una copia | `./deploy.sh apply backup --limit laptop` y repite |
| `The backup before changing the image of prod-pg-main failed, so the image has NOT been changed (D11).` | La copia previa al cambio de imagen falló. Postgres sigue igual | Arregla el backup (apartado 6) y repite |
| `Rotating pg-… only changes the Podman secret. PostgreSQL keeps the old password until you run ALTER ROLE first` | Es un aviso: cambiar el secreto no cambia la contraseña en la base | Primero `ALTER ROLE`, después `--rotate` ([`SECRETS_INVENTORY.md`](SECRETS_INVENTORY.md)) |
| `Rotating pg-… changes the Podman secret. PostgreSQL takes it on the next apply of postgres` | Es un aviso, para un usuario de aplicación | `./deploy.sh apply postgres --limit laptop` y reinicia la aplicación ([`POSTGRES.md`](POSTGRES.md), apartado 4) |
| `--retire …: there is no instance … in the inventory of …` | La instancia que quieres retirar ya no está en el fichero | Vuelve a declararla, retírala y quítala después ([`POSTGRES.md`](POSTGRES.md), apartado 7) |
| `Missing Podman secrets on …: prod-pg-main-<usuario>-password` | Un usuario de `databases:` no tiene su secreto en esa máquina | Su entrada en KeePassXC y en `infra_secrets`, y `./deploy.sh secrets --limit laptop` ([`POSTGRES.md`](POSTGRES.md), apartado 6) |
| `databases: of pg-main in the data repository …` | Un nombre, un grupo o un consumidor de `databases:` no es válido, o un usuario está repetido | Corrige el repo de datos según el mensaje ([`POSTGRES.md`](POSTGRES.md), apartado 6) |
| `The network prod-<consumidor>-pg-main-net exists but is not internal with isolate and DNS 127.0.0.1` | Esa red no la creó Ansible y podría tener salida | Lo que dice el mensaje: parar Postgres, borrar la red y repetir el `apply` |
| `the password of … has characters other than printable ASCII` | La contraseña del secreto tiene letras con tilde, eñes u otros caracteres | Genera otra en KeePassXC con letras, números y símbolos, y `--rotate` |
| `Still connected to what would be dropped from prod-pg-main (user\|database): …` | Quitaste del inventario un usuario o una base que una aplicación sigue usando. También pasa justo después de pararla si tenía una consulta larga en marcha: PostgreSQL no se entera hasta que la consulta termina. No se ha cambiado nada | Para esa aplicación y repite el `apply`. Si sigue saliendo, espera a que termine esa consulta ([`POSTGRES.md`](POSTGRES.md), apartado 7) |
| `prod-pg-main has no databases: in the inventory, so these databases would be dropped: …` | Falta `databases:` o está vacío, y hay bases creadas por Ansible. No se ha cambiado nada | Si es un error, vuelve a poner las bases. Si quieres borrarlas todas, repite con `--confirm-drop main` |
| `prod-pg-main would drop the databases …, and there is no backup service on …` | Esa máquina no tiene copias, y sin copia no se borra una base | `./deploy.sh apply backup --limit <máquina>` antes, o vuelve a poner la base en el inventario |
| `The backup before dropping … from prod-pg-main failed, so nothing has been dropped.` | Falló la copia previa al borrado | Mira el log que da el mensaje y repite cuando la copia funcione (OPERATIONS, apartado 2) |
| `not in the inventory and not created by Ansible, left as it is: …` | Es un aviso: hay una base o un rol hecho a mano, o de antes de la fase 2 | Nada, si es tuyo. Ansible nunca lo toca |
| `Not in the inventory of …, left running as they are: pg-…` | Es un aviso: en esa máquina hay una instancia que ya no está en el inventario | Para retirarla conservando sus datos, vuelve a declararla y `./deploy.sh apply postgres --limit laptop --retire <instancia>` ([`POSTGRES.md`](POSTGRES.md), apartado 7) |
| `svc podman healthcheck run prod-pg-main && echo sano` no dice `sano` | Postgres no está sano | `sudo journalctl _SYSTEMD_USER_UNIT=prod-pg-main.service -n 50` y `svc systemctl --user restart prod-pg-main.service` |

## 6. Backup local

Los mensajes que empiezan por «La copia de … ha fallado» salen en el aviso de escritorio y en `cat /var/lib/infra-podman/backup-status/prod-backup.status`.

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `The Podman secret prod-backup-restic-password does not exist on …` | Falta la clave de restic en esa máquina | `./deploy.sh secrets --limit laptop` (entrada `backup-restic-password`) |
| `prod-pg-main no está en marcha: no se pueden volcar sus bases.` | Postgres estaba parado a la hora de la copia | `svc systemctl --user start prod-pg-main.service` y `svc systemctl --user start prod-backup.service` |
| `el rol backup no puede leer la lista de bases de …` | Al rol `backup` le falta algo en Postgres | `./deploy.sh apply postgres --limit laptop` (lo repone) y repite la copia |
| `no existe o no se puede leer …/infra-podman-data.bundle` | No está la copia del repo de datos que deja `deploy.sh` | Haz un `./deploy.sh plan` correcto cualquiera: al terminar la deja. Después repite la copia |
| `deploy.sh: AVISO: no se ha podido dejar la copia del repo de datos en …` | `deploy.sh` no puede escribir en `/var/lib/infra-podman/data-repo` | `ls -ld /var/lib/infra-podman/data-repo`: tiene que ser tuyo. Si no, `./deploy.sh apply backup --limit laptop` |
| `falta …/backup.conf. Vuelve a aplicar el playbook backup.` | Falta la configuración del backup | `./deploy.sh apply backup --limit laptop` |
| `ERROR: the repository exists but cannot be opened (wrong password?)` (en los logs) | El secreto `prod-backup-restic-password` no es la clave con la que se creó el repositorio | **No borres nada.** Busca en el historial de esa entrada de KeePassXC la clave buena y pídeme cómo cambiarla |
| `la última copia correcta es de …, hace más de 36 h. Comprueba el temporizador` | Hace más de un día y medio sin copia buena | `svc systemctl --user list-timers` y los logs de `prod-backup.service` |
| `Todavía no se ha hecho ninguna copia (instalado hace … h)` | El backup está instalado pero no ha copiado nunca | `svc systemctl --user start prod-backup.service` y mira el resultado |
| `No existe /var/lib/infra-podman/backup-status: el backup no está instalado.` | El aviso está instalado, pero el backup no | `./deploy.sh apply backup --limit laptop` |

## 7. Copia al GX10

Los mensajes salen en el aviso de escritorio y en `cat /var/lib/infra-podman/backup-status/prod-backup-copy.status`. Si la copia al GX10 falla, **tus copias locales siguen bien**.

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `result=unreachable` y `El servidor de copias (…) no responde. Se volverá a intentar cada hora.` | El GX10 está apagado o fuera de Tailscale. No es un fallo | Nada, si es puntual. Si dura, la fila siguiente |
| `la última copia correcta es de …, hace más de 168 h. El servidor de copias (…) no responde` | Una semana sin llegar al GX10 | 1. `ssh gx10 true`. 2. Desde el portátil: `curl -s -o /dev/null -w '%{http_code}\n' http://<nombre del GX10>.<tu red>.ts.net:18000/`: `401` es que responde; `000`, que no llega. 3. En el GX10, el apartado 8 |
| `bad address` en los logs de la copia | El contenedor no resuelve el nombre de Tailscale del GX10. Por comprobar en el portátil | Usa la IP de Tailscale del GX10, que no cambia: `tailscale ip -4 <nombre del GX10>`. Ponla en `backup_remote_url` del repo de datos y `./deploy.sh apply backup --limit laptop` |
| `el servidor de copias no acepta el usuario o la contraseña.` | La contraseña del portátil y el hash del GX10 no coinciden | `./deploy.sh secrets --rotate backup-server-password --limit gx10`, lo mismo con `--limit laptop`, y `./deploy.sh apply backup-server --limit gx10` |
| `la clave de restic no abre el repositorio del servidor.` | `backup-restic-password` no es la clave con la que se creó la copia del GX10 | **No borres nada.** La buena está en el historial de esa entrada de KeePassXC. Nunca se crea un repositorio nuevo encima |
| `el servidor de copias está al … % de su tope` o `el servidor de copias está lleno` | Las copias del GX10 se acercan a su tope (30 GB) o lo han alcanzado. Lleno, no copia nada nuevo | En el GX10, `df -h /`. Sube `backup_server_max_size_gb` en `group_vars/all.yml` del repo de datos, commit firmado, `./deploy.sh apply backup-server --limit gx10` y `./deploy.sh apply backup --limit laptop`. En el GX10 no se borra nada solo (R26) |
| `el servidor de copias no deja escribir en …` | La carpeta no empieza por el nombre de la instalación | `infra_site` tiene que ser el mismo en el repo de datos que en la carpeta del mensaje |
| `The Podman secret prod-backup-server-password does not exist on …, and backup_remote_url asks for a copy` | Falta la contraseña del servidor en esa máquina | `./deploy.sh secrets --limit laptop` (o `gx10`; entrada `backup-server-password`) |
| `The Podman secret prod-backup-server-password does not exist on gx10` | Lo mismo, en el GX10, al desplegar el servidor | `./deploy.sh secrets --limit gx10` |
| El servidor no arranca o has perdido su contraseña | — | Las copias siguen en su volumen y se leen solo con la clave de restic: [`OPERATIONS.md`](OPERATIONS.md), 5.2. Para una contraseña nueva: cámbiala en KeePassXC y sigue la fila «no acepta el usuario o la contraseña» |

## 8. Tailscale

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `'tailscale serve status' failed on …. Is Tailscale installed and connected?` | Tailscale no está instalado o no está conectado en esa máquina | En el GX10: `tailscale status`. En una máquina sin Tailscale (la VM DEV), `backup_server_tailscale: false` en el repo de datos |
| `tailscale serve already uses port 18000 on … for something else` | Ese puerto ya lo usa otra cosa en `tailscale serve`. Ansible no la toca | `sudo tailscale serve status`. Libéralo a mano o elige otro `backup_server_port` en el repo de datos |
| `sudo tailscale serve status` no muestra el 18000 | Se ha borrado la configuración de `tailscale serve` | `./deploy.sh apply backup-server --limit gx10` (solo añade ese puerto) |
| Quieres quitar el puerto 18000 | — | En el GX10: `sudo tailscale serve --tcp=18000 tcp://localhost:18000 off` |

## 9. SELinux (por comprobar en el portátil)

Solo el portátil tiene SELinux. Cada volumen va marcado como privado de su contenedor (`:Z`), y otro contenedor no puede leerlo sin más.

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `stat /repo/config: permission denied` al leer las copias con una orden propia | El volumen `prod-backup-repo` es privado del contenedor de backup | Añade `--security-opt label=disable` a la orden, como las de [`OPERATIONS.md`](OPERATIONS.md). No cambia la marca del volumen |
| La copia al GX10 falla y sus logs hablan de permisos al leer el repositorio local | El contenedor de copia no puede leer el repositorio local. Debería poder: va sin etiqueta propia (`SecurityLabelDisable`, R44) | Mándame los logs: `sudo journalctl _SYSTEMD_USER_UNIT=prod-backup-copy.service -n 50` |
| `deploy.sh` no llega a las máquinas aunque KeePassXC está abierto | El contenedor de Ansible no puede usar tu `~/.ssh` ni el agente sin `label=disable` (R16) | Comprueba que `ansible-navigator.yml` sigue con `--security-opt=label=disable` |

## 10. El CI

Los errores salen en GitHub, en el PR: pestaña **Checks**, en el job en rojo, como anotaciones (`::error`).

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `POLICY: …` (job `lint`) | Una plantilla incumple una regla del repo: `Notify=healthy`, imagen sin digest, falta un nombre o una etiqueta… | Lo corrige Claude en el mismo PR |
| `GENERATOR: … rejected the units:` (job `lint` o `quadlet-forward`) | El generador de Podman no acepta una plantilla. En `quadlet-forward` (Podman más nuevo) avisa de lo que fallará al actualizar el GX10 | Lo corrige Claude en el mismo PR |
| `the second apply changed something` (job `lifecycle`) | Un segundo `apply` sin cambios cambió algo: no es idempotente (SPEC 4.2) | Lo corrige Claude en el mismo PR |
| `… appears in the logs` o `the password appears in the Ansible output` | Una contraseña de prueba ha salido en los logs | No mergees. Lo corrige Claude |
| `unknown placeholder in the block '…'` o `the block '…' failed` (`check-operations`) | Un bloque de [`OPERATIONS.md`](OPERATIONS.md) ya no funciona tal como está escrito | Lo corrige Claude en el mismo PR |
| Correo de GitHub: `image-updates` ha fallado, con `New version of …_image` o `New image for …_image` | Hay una versión nueva de esa imagen. No es un fallo | [`WORKFLOW.md`](WORKFLOW.md), «Cuando hay una imagen nueva» |
| `image-updates` falla con `cannot read … from the registry` o `cannot list the tags of …` | Docker Hub no respondía o ha limitado las descargas | Lánzalo otra vez a mano (Actions → `image-updates` → Run workflow). Si sigue, avísame |
| `Platforms: not an index` o sin `linux/arm64` en la imagen nueva | Esa versión no trae las dos arquitecturas | No la uses todavía; avísame (D6) |
| `Expected Podman 4.9` | La máquina de GitHub trae otra versión de Podman | Avísame: hay que revisar el workflow |
| El mismo fallo 5 veces seguidas | — | Claude para y te pregunta (`CLAUDE.md`) |

## 11. Firefly III

Cada instancia tiene sus nombres ([`services/README.md`](services/README.md)): cambia `<instancia>` por la suya (`casa`, `canary`…). Sus logs: `sudo journalctl _SYSTEMD_USER_UNIT=prod-ff-<instancia>.service -n 50`. Los de sus tareas diarias: `sudo journalctl _SYSTEMD_USER_UNIT=prod-ff-<instancia>-cron.service -n 50`.

| Lo que ves | Por qué | Qué hacer |
| --- | --- | --- |
| `firefly_instances of … (group_vars/firefly_hosts.yml of the data repository): each instance with a name and a port, neither repeated on the same machine` | Una instancia sin nombre o sin puerto, o dos con el mismo nombre o puerto | Corrige `firefly_instances` en el repo de datos: cada una su nombre y su puerto, desde el 18100 |
| `Instance … of firefly_instances (roles/firefly/defaults/main.yml): name ^[a-z0-9]{1,14}$; …` | Un ajuste de esa instancia no vale: nombre, puerto, imagen, zona horaria, límites o el comando del navegador | El mensaje dice el formato de cada uno. El comando del navegador va como lista de palabras, sin espacios dentro de una palabra ni la dirección: `[flatpak, run, org.mozilla.firefox, --new-window]` |
| `Firefly … needs the PostgreSQL instance prod-pg-main and the network prod-ff…-pg-main-net on …` | Falta la base, el usuario o la red de esa instancia en Postgres | El mensaje dice qué declarar en `postgres_hosts.yml` (base y usuario `ff_<instancia>`, `group: owner`, `consumer: ff<instancia>`). Después `./deploy.sh apply postgres --limit laptop` |
| `Missing Podman secrets on …: prod-ff-<instancia>-app-key` (o `prod-pg-main-ff_<instancia>-password`) | Falta ese secreto en la máquina | Decláralo en `infra_secrets`, crea su entrada en KeePassXC y `./deploy.sh secrets --limit laptop` ([`SECRETS_INVENTORY.md`](SECRETS_INVENTORY.md)) |
| `The secret prod-ff-<instancia>-app-key has … characters, and Firefly needs exactly 32` | La clave de la aplicación no tiene 32 caracteres | Antes del primer arranque: corrige la entrada de KeePassXC y `./deploy.sh secrets --limit laptop --rotate ff-<instancia>-app-key`. **Con Firefly ya en uso, no la cambies**: pídeme ayuda |
| `prod-ff-<instancia> did not pass its healthcheck in 300 s and has been STOPPED` | Firefly no llega a leer su base. El primer arranque crea todas las tablas y tarda | Mira sus logs. Si dicen `password authentication failed`, el secreto de su usuario no coincide: `./deploy.sh apply postgres --limit laptop` fija la contraseña desde el secreto. Después `svc systemctl --user start prod-ff-<instancia>.service` |
| `Job for prod-ff-<instancia>.service failed because a timeout was exceeded.` | Firefly ha esperado a que Postgres estuviera sano y no lo ha estado a tiempo (SPEC 4.3). Vuelve a intentarlo solo | `svc podman healthcheck run prod-pg-main && echo sano`. Si Postgres está mal, su apartado (5). Cuando esté sano, Firefly arranca solo |
| `prod-ff-<instancia> would start a new image, which changes its database, and there is no backup service on …` | Al cambiar la imagen de una instancia se hace antes una copia, y no hay servicio de backup | `./deploy.sh apply backup --limit laptop` y repite |
| `The backup before changing the image of prod-ff-<instancia> failed, so the image has NOT been changed` | La copia previa ha fallado; esa instancia sigue con su imagen anterior | El apartado 6 (backup local), con los logs que salen en el mensaje |
| `There is no user in the system with the "owner"-role, cannot continue.` (en los logs de `prod-ff-<instancia>-cron.service`) | Las tareas diarias necesitan un usuario, y aún no has creado el tuyo en esa instancia | Crea tu usuario en `http://127.0.0.1:<puerto>` (el primero es el administrador). Hasta entonces, el temporizador falla cada día sin más consecuencia |
| `Not in the inventory of …, left running as they are: ff-<instancia>` | Has quitado una instancia del inventario y sigue en marcha: quitarla no la para | Si querías retirarla, vuelve a declararla y `./deploy.sh apply firefly … --retire <instancia>` ([`services/INSTALL.md`](services/INSTALL.md), apartado 10; apartado 7) |
| La página no carga en `http://127.0.0.1:<puerto>` | Esa instancia está parada o arrancando, o el puerto es de otra | `svc podman port prod-ff-<instancia>` dice su puerto. `svc systemctl --user status prod-ff-<instancia>.service` |
