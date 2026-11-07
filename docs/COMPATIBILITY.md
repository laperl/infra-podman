# Compatibilidad con Podman 4.9

Copia de la sección 4.3 de [`SPEC.md`](SPEC.md), más lo comprobado en la práctica. Si este fichero y el SPEC discrepan, manda el SPEC.

## Reglas (SPEC 4.3)

- **Prohibido** usar funciones de Quadlet posteriores a 4.9. En concreto, `Notify=healthy` y los ficheros `.pod` llegaron con Podman 5.0. Cualquier clave se comprueba en la documentación de 4.9.
- **Dependencias entre servicios** (por ejemplo, Firefly espera a Postgres): `Requires=` y `After=` más un `ExecStartPre` que espere, con tiempo máximo, a que la dependencia esté sana. Fija `TimeoutStartSec` explícito. Este patrón está pendiente de validar (SPEC 7.1, fase 2).
- **Red rootless:** en 4.9 la salida al exterior de las redes rootless usa slirp4netns. Podman 5.0 cambió a pasta y Podman 6 elimina slirp4netns. Por eso **ninguna plantilla lleva opciones de slirp4netns ni de pasta**: así el cambio de versión no toca el código.
- **Al actualizar el GX10 a Podman 5 o superior:** se sustituye el patrón de espera por `Notify=healthy` en un único sitio de las plantillas.

## Cómo se comprueba una clave

1. Manual de referencia: [quadlet(5) de Podman 4.9 en Ubuntu 24.04](https://manpages.ubuntu.com/manpages/noble/man5/quadlet.5.html).
2. En la práctica: el workflow `lint` renderiza las plantillas y las pasa por el generador de Podman 4.9 de Ubuntu 24.04 (`podman 4.9.3+ds1-1ubuntu0.2`) en modo `--dryrun`. Una clave desconocida da `unsupported key` y el CI falla.

## Lo que el generador de 4.9 no detecta

Comprobado el 2 de noviembre de 2026 con Podman 4.9.3 de Ubuntu 24.04:

| Caso | Qué hace el generador 4.9 | Quién lo detecta |
| --- | --- | --- |
| `Notify=healthy` | Lo acepta sin error (código de salida 0), pero **no lo cumple**: genera `--sdnotify=conmon`, igual que sin `Notify`. systemd da el servicio por listo en cuanto arranca el contenedor, no cuando está sano (ver abajo) | `scripts/quadlet_policy.py` |
| Fichero `.pod` | Lo ignora en silencio. Solo falla la clave `Pod=` del `.container` | `scripts/quadlet_policy.py` |
| Imagen sin digest (`:latest`) | Solo da un aviso si el nombre no es completo; con nombre completo, nada | `scripts/quadlet_policy.py` |
| Opciones de slirp4netns o pasta | Las acepta: son válidas en 4.9 | `scripts/quadlet_policy.py` |
| Socket de Podman o Docker montado | Lo acepta | `scripts/quadlet_policy.py` |
| Directorio sin ficheros | Falla con `No files parsed` | `scripts/validate-quadlets.sh` lo trata como «nada que validar» |

Por eso el CI ejecuta dos comprobaciones: la política del repo y el generador. Cada caso tiene una plantilla de prueba en `tests/quadlet/fixtures/invalid/`, que el CI exige que se rechace por el motivo correcto.

### Por qué `Notify=healthy` es peligroso en 4.9

Salida real del generador 4.9.3 para cada valor:

| En la plantilla | Lo que genera | Cuándo da systemd el servicio por listo |
| --- | --- | --- |
| (sin `Notify`) | `Type=notify` y `--sdnotify=conmon` | Al arrancar el contenedor |
| `Notify=true` | `Type=notify` y `--sdnotify=container` | Cuando la aplicación lo avisa |
| `Notify=healthy` | `Type=notify` y `--sdnotify=conmon` | **Al arrancar el contenedor**, como si no estuviera |

En Podman 5 o superior, `Notify=healthy` hace esperar a que el healthcheck pase. En 4.9 se ignora sin avisar. Firefly arrancaría antes de que Postgres estuviera sano y nada lo indicaría. Por eso se prohíbe y se usa el patrón de espera de la sección 4.3 del SPEC.

## Claves comprobadas contra el generador 4.9

Aceptadas: `ContainerName`, `NetworkName`, `VolumeName`, `Label` (también en `.network` y `.volume`), `Environment`, `HealthRetries`, `HealthTimeout`, `ShmSize`, `NoNewPrivileges`, `DropCapability`, `AddCapability`, `ReadOnly`, `ReadOnlyTmpfs`, `Tmpfs`, `UserNS`, `Secret` (con `type=mount,target=…,mode=…`), `HealthCmd`, `HealthInterval`, `HealthStartPeriod`, `Sysctl`, `AutoUpdate`, `PodmanArgs`, `PublishPort`, `Network`, `Volume` y, en `.network`, `Subnet` y `Options=isolate=true`.

### Límites de recursos

Podman 4.9 sí limita memoria, CPU y procesos. Lo que falta en Quadlet 4.9 es la clave `Memory=`, no la función:

| Límite | En Quadlet 4.9 | Comprobado con el generador |
| --- | --- | --- |
| Memoria | `PodmanArgs=--memory=512m` | Sí |
| CPU | `PodmanArgs=--cpus=1.5` | Sí |
| Procesos | `PidsLimit=200` (clave propia) | Sí |
| `/dev/shm` | `ShmSize=64m` (clave propia) | Sí |
| `Memory=` | **No existe**: `unsupported key` | — |

Los límites se pasan como **parámetros por servicio** y se escriben en un único sitio de las plantillas, para cambiar en un solo punto a claves nativas si la versión de Podman del GX10 llega a tenerlas (se comprobará en la documentación de esa versión). Diseño en la fase 1 (ver [`ROADMAP.md`](ROADMAP.md)).

`MemoryMax=` en `[Service]` (systemd) también funcionaría, pero limita el servicio entero (incluido `conmon`), no solo el contenedor. Se prefieren las opciones de Podman.

Aceptar una clave solo demuestra que el generador la entiende, no que el contenedor se comporte como se espera. Eso lo comprueba el workflow `lifecycle` (fase 1).

## Redes internas (fase 2, R45)

En la documentación de Quadlet de Podman 4.9.3 existen `NetworkName=`, `Internal=` (`--internal`), `Options=` (`--opt`) y `Label=` para los ficheros `.network`, y el generador de 4.9.3 los acepta. Probado a mano con Podman 4.9.3 (netavark y aardvark-dns 1.4) sin root, el 2026-11-06 y 07:

- **Sin `Subnet=`, Podman elige la subred** de su rango (`10.89.0.0/24`, `10.89.1.0/24`…), sin repetir una que ya use otra red.
- **Un contenedor en una red interna no tiene ruta de salida** (`Network is unreachable`). Según la documentación de `podman network create`, su DNS solo resuelve nombres de contenedores: el resto recibe `NXDOMAIN`.
- **Con dos redes internas y aisladas**, un contenedor de una no resuelve ni alcanza a los de la otra, aunque haya un contenedor (Postgres) en las dos: dentro de él `ip_forward` es 0.
- **Un fichero de configuración se monta por su carpeta, no suelto.** Ansible (y `sed -i`) reescriben un fichero creando uno nuevo; un montaje del fichero suelto sigue enseñando al contenedor el antiguo, y una recarga no ve el cambio. Lo destapó `lifecycle` con `pg_hba.conf`: Postgres recargaba y seguía rechazando a los usuarios nuevos.
- **Publicar un puerto en `127.0.0.1` desde una red interna funciona sin root** y el contenedor sigue sin salida. Con root no: netavark no crea las reglas para una red interna (discusión de Podman [#21451](https://github.com/podman-container-tools/podman/discussions/21451)). Lo usará Firefly; se comprueba en su PR y, en el portátil, con Podman 5.

## Comprobado en el workflow `lifecycle`

El 2026-11-03, en `ubuntu-24.04` con Podman 4.9.3 sin root y systemd de usuario:

- `pgvector/pgvector:pg18` arranca con `Network=none`, pasa el healthcheck, no publica puertos y sobrevive a un reinicio del servicio. Tras destruirlo, el volumen sigue y un nuevo despliegue encuentra los mismos datos.
- PostgreSQL 18 guarda los datos en `/var/lib/postgresql/18/docker`: el volumen se monta en `/var/lib/postgresql`.
- **Endurecimiento de Postgres (fase 1d):** la imagen arranca y se inicializa con `ReadOnly=true`, `Tmpfs=` para `/var/run/postgresql` y `/tmp`, `DropCapability=all` más `CHOWN SETUID SETGID FOWNER DAC_OVERRIDE` y `NoNewPrivileges=true`. Dentro del contenedor, el conjunto de capacidades es exactamente esas cinco y no se puede escribir fuera del volumen.
- **`Exec=`** sustituye el comando de la imagen y mantiene su punto de entrada: `Exec=postgres -c …` añade opciones al arranque.
- **`HealthCmd=`** con comillas y una tubería: Quadlet 4.9 lo pasa entero a `--health-cmd` y Podman lo ejecuta con `sh -c`.
- **Contenedores de un solo uso (backup, fase 1e1):** `Type=oneshot` en `[Service]` funciona en 4.9. El generador no añade `--sdnotify`, conserva `ExecStartPre=` y `ExecStopPost=` propios y, sin `[Install]`, el servicio no arranca al encender. Lo arranca un `.timer` normal de systemd.
- **`Entrypoint=` no existe en Quadlet 4.9** (`unsupported key`). Se usa `PodmanArgs=--entrypoint=…`.
- **La unidad generada conserva la sección original** como `[X-Container]`: cada valor aparece dos veces en `systemctl --user cat`.
- **SELinux y el volumen del backup (Fedora):** el contenedor de backup monta su repositorio con `:Z`, que lo marca como privado. Otro contenedor que lo monte sin más recibe `stat /repo/config: permission denied`. Para consultarlo a mano: `--security-opt label=disable`, que no cambia la marca (como el contenedor de Ansible, R16). En Ubuntu no pasa, por eso el CI no lo vio. Detectado por el operador en el portátil el 2026-11-04.
- **restic y los atributos extendidos:** restic guarda los de cada carpeta (listas de permisos, etiquetas de SELinux en Fedora). Si el destino de una restauración no los admite, restaura los ficheros pero termina con error. Se restaura con `--exclude-xattr '*'` (restic 0.18 o posterior). Visto en el CI y [en Fedora](https://discussion.fedoraproject.org/t/selinux-errors-on-restic-restore-test/181360).
- **Copia al GX10 (fase 1e2, R44), comprobado con el generador 4.9.3:**
  - `SecurityLabelDisable=true` existe y genera `--security-opt label:disable`.
  - `Network=container:<nombre>` pasa tal cual a `--network`: en DEV y en el CI, la copia comparte la red del servidor.
  - `SuccessExitStatus=` en `[Service]` se conserva: el código 75 (el servidor no responde) no es un fallo.
  - `Environment="OPTIONS=--a --b"`, con comillas, llega como un único valor.
  - `Volume=<nombre>.volume:` solo da el nombre de `VolumeName=` si el `.volume` está en la misma carpeta: si no, 4.9 inventa `systemd-<nombre>`. Por eso el contenedor de copia va en el mismo rol que el de backup y se valida con su `.volume`.
- **Un fichero montado en una ruta que no existe en la imagen** (`/etc/postgresql/pg_hba.conf`) funciona también con `ReadOnly=true`.
- **Salvedad del runner de GitHub, no de los servidores:** su `/etc/environment` fija `XDG_CONFIG_HOME` y otras `XDG_*` para su propio usuario, y PAM se las pasa al systemd de **cualquier** usuario. El generador de Quadlet de `svc_runner` buscaba entonces sus unidades en `/home/runner/.config`. El workflow borra esas líneas antes de crear el usuario. Si alguna vez un servidor tuviera lo mismo, el síntoma sería `Could not find the requested service` justo después de instalar una unidad.

## Versiones más nuevas

Las plantillas se escriben para 4.9 y no se ramifican por versión. Está previsto, como mejora posterior a la fase 2, que Ansible lea la versión de Podman del servidor y use `Notify=healthy` en el único sitio del patrón de espera cuando sea 5 o superior. Ver [`ROADMAP.md`](ROADMAP.md).
