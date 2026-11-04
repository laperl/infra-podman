# Especificación: plataforma Podman + Ansible

Versión 1.8 · 4 de noviembre de 2026 · Operador: @Jau

Los cambios respecto a la versión 1, con su motivo, están en [`DECISIONS.md`](DECISIONS.md).

Este documento es la fuente de verdad del proyecto. Los cambios se hacen por pull request, como cualquier otro fichero.

## 1. Rol y reglas de trabajo

Eres el ingeniero que implementa esta plataforma para un operador único. Eres experto en Ansible, Podman (rootless, Quadlet, systemd), Linux, GitHub Actions y seguridad. Este documento es la especificación completa: lo que no esté aquí no está decidido.

**Reglas**

1. **No reabras decisiones cerradas** (sección 3). Si detectas un fallo real en una, explícalo con evidencia y espera aprobación antes de cambiarla.
2. **Verifica contra la documentación oficial** de la versión exacta que se usa (Podman 4.9 en el servidor, no la última). Si una opción no existe en esa versión, no la uses. No inventes módulos, opciones ni parámetros: si no puedes confirmarlos, dilo.
3. **Nunca toques producción.** Trabajas en el repositorio y abres pull requests. El `apply` en servidores lo ejecuta solo el operador.
4. **Nunca escribas secretos** en el repo, en logs, en el chat ni en ejemplos. Usa nombres de secretos y valores ficticios.
5. **Trabaja por fases** (sección 6). Un PR por fase o subfase, pequeño, con su criterio de hecho comprobado. No avances de fase sin aprobación.
6. **Simplicidad primero.** El operador es una sola persona. Antes de añadir una herramienta o capa, justifica por qué no basta con lo que ya hay.
7. **Marca tus supuestos.** Si algo es inferencia y no está verificado, escríbelo así en el PR.
8. **Pregunta antes de decidir** lo que figura como abierto (sección 7). Propón una opción con su motivo, no la implantes por tu cuenta.
9. **Idioma:** documentación y mensajes en español; código, nombres de variables y commits en inglés.

## 2. Contexto y entorno

**Objetivo:** una plataforma estándar y mantenible por una persona para desplegar, actualizar y vigilar servicios en contenedores Podman gestionados por systemd, con Ansible desde un nodo de control.

**Principio rector:** la IA propone, código determinista ejecuta y un humano aprueba lo irreversible.

**Solo software libre y gratuito:** herramientas oficiales de código abierto y sin coste. En Ansible, la versión comunitaria (ansible-core, ansible-navigator, ansible-builder, ansible-runner y colecciones de Galaxy). Nada de Red Hat Ansible Automation Platform, Automation Hub ni imágenes que pidan suscripción.

**Máquinas**

| Rol | Equipo | Sistema | Podman | Notas |
| --- | --- | --- | --- | --- |
| Nodo de control y servicios personales (PRO) | Portátil, solo CPU, 16 GB RAM | Fedora Atomic Sway 44 | El de Fedora 44 (Podman 5). Podman 6 llega con Fedora 45 | Ejecuta Ansible y KeePassXC. Desde la versión 1.2 aloja también el Postgres principal y las aplicaciones personales, disponibles sin conexión (R18). Disco cifrado con LUKS y VeraCrypt: **no volver a preguntar**. Aloja la VM DEV |
| DEV | VM dentro del portátil | Ubuntu Server 24.04 x86_64 | **4.9** (apt) | Misma versión de Podman y misma base que el GX10. El operador despliega a mano desde la rama del PR; opencode con IA local solo ejecuta pruebas. Sin credenciales de producción |
| Servidor principal | ASUS Ascent GX10, ARM64, 128 GB, GPU con CUDA 13 | DGX OS 7 (Ubuntu 24.04) | **4.9** | Docker con vLLM. Destino de las copias de backup (4.11). Disco **sin cifrar**: solo guarda datos cifrados en origen. Se queda en Ubuntu 24.04: ASUS solo soporta DGX OS y DGX OS 8 aún no admite este equipo |
| Servidor opcional | Lenovo x86 con GPU NVIDIA | Fedora Atomic Sway 44 | 5 (6 con Fedora 45) | Parado. Solo se usará si hace falta. El diseño no debe depender de él |

**Excepción Docker en el GX10:** vLLM corre en Docker porque Podman 4.9 no ve la GPU con CUDA 13 (comprobado por el operador). Fuera de alcance de migrar.

**Red:** todo va por Tailscale. Ningún puerto expuesto a internet. Los servicios publican solo en `127.0.0.1`; lo que haya que alcanzar desde otra máquina se expone con `tailscale serve` (R25).

**Prioridad de servicio:** best effort. Lo primero es la integridad de los datos y la sencillez de recuperación, por delante de la alta disponibilidad.

**Servicios previstos:** Postgres (una o más instancias por máquina: la principal en el portátil y, cuando sus servicios lo necesiten, otra en el GX10), Firefly III, LiteLLM (ya funcionando contra vLLM), pgAdmin 4 para administrar Postgres (R37), instancias de OpenClaw, SearXNG, un servicio de audio y proyectos propios (por ejemplo `rag`) que publican imagen.

## 3. Decisiones cerradas (no reabrir)

| # | Decisión |
| --- | --- |
| D1 | Todos los contenedores Podman se gestionan con systemd mediante **Quadlet**, rootless |
| D2 | Despliegue con **Ansible** desde el portátil, ejecutado con **ansible-navigator** y una imagen de entorno de ejecución (Execution Environment) en Podman |
| D3 | **Un solo usuario de servicio** en cada máquina que aloja servicios (variable `service_user`, por defecto `svc_runner`), con `loginctl enable-linger`. Ansible entra por SSH con el usuario del operador y cambia al de servicio. Un segundo usuario solo se añadirá si se cumple un disparador (sección 7) |
| D4 | **Plantillas Quadlet nativas por servicio** (`.container.j2`, `.network.j2`, `.volume.j2`), sin un lenguaje intermedio propio en YAML |
| D5 | **Compatibilidad mínima: Podman 4.9.** Ver la sección 4.3 |
| D6 | **Imágenes fijadas por digest**, nunca etiquetas móviles. Para imágenes multiarquitectura se fija el digest del índice (manifest list) y se comprueba que incluye `linux/arm64` |
| D7 | **Secretos:** KeePassXC es la copia maestra; los secretos de Podman son el mecanismo de entrega. Lookup propio que invoca `keepassxc-cli`, la herramienta oficial de KeePassXC. Ver la sección 4.5 |
| D8 | **Un Postgres por máquina que lo necesite.** En una misma máquina pueden convivir varias instancias (por ejemplo, una de test), cada una con su nombre, su volumen y sus redes. Cada aplicación tiene **su base, tres grupos sin LOGIN (`_owner`, `_writer` y `_reader`) y usuarios a demanda** ([`POSTGRES.md`](POSTGRES.md)). **Sin replicación entre máquinas:** la protección son los backups (4.11). Modificada en las versiones 1.2 (R18) y 1.5 (R33) |
| D9 | **Una red por consumidor de Postgres**, todas con `isolate=true` (comprobado que funciona en el GX10) |
| D10 | **Cortafuegos: firewalld** en todos los servidores. Nada de ufw. Se aplica en la fase 1b |
| D11 | **Servicios con datos sin rollback automático de imagen.** Si falla el healthcheck tras un cambio, se detiene y se avisa para intervención humana |
| D12 | **GitHub** con repos privados; **GHCR privado** para las imágenes propias |
| D13 | **Tags y commits firmados con la clave SSH** del operador, servida por el agente SSH de KeePassXC |
| D14 | Claude solo accede al repositorio y abre pull requests. opencode con IA local solo en DEV. **Ninguna IA ejecuta el `apply`** |
| D15 | La dirección y el puerto de vLLM son **parámetros** (`vllm_host`, `vllm_port`), nunca valores fijos en el código |

## 4. Arquitectura técnica

### 4.1 Estructura del repositorio

```text
(raíz del repo)/
  deploy.sh                    # plan | apply | secrets
  ansible-navigator.yml
  ansible.cfg                  # rutas de plugins y roles
  execution-environment.yml    # imagen de Ansible (ansible-builder)
  inventory.example/           # datos inventados para el CI y como plantilla; el real, en el repo de datos (4.13)
  plugins/lookup/kdbx.py       # lookup propio que invoca keepassxc-cli
  roles/
    host_base/                 # usuario de servicio, linger, firewalld
    quadlet_deploy/            # copia, valida y activa Quadlets
    postgres/  firefly/  ...   # un rol fino por servicio con sus plantillas
  playbooks/
  scripts/                     # utilidades de CI: render y validación de Quadlets
  tests/                       # fixtures y pruebas de CI
  docs/  SPEC.md  VISION.md  ROADMAP.md  DECISIONS.md  COMPATIBILITY.md  SECRETS_INVENTORY.md
  CLAUDE.md
```

`CLAUDE.md` resume para cualquier agente las reglas de la sección 1 y las prohibiciones de la sección 8.

### 4.2 Despliegue de Quadlets

El rol `quadlet_deploy`, para cada servicio:

1. Renderiza las plantillas en un directorio temporal del servidor.
2. Las valida con el generador de Quadlet del propio servidor antes de instalarlas: `QUADLET_UNIT_DIRS=<temporal> /usr/lib/systemd/system-generators/podman-system-generator --user --dryrun`. Esa ruta y esa variable están documentadas en el manual de Podman 4.9 de Ubuntu 24.04.
3. Si es válido, las copia a `~/.config/containers/systemd/` del usuario de servicio.
4. Ejecuta `daemon-reload` y reinicia solo lo que cambió, mediante handlers con `ansible.builtin.systemd_service` y `scope: user`. Hay que gestionar `XDG_RUNTIME_DIR` al cambiar de usuario.
5. Al destruir un servicio, elimina el `.container` pero **nunca el `.volume`**, salvo purga explícita.

Un segundo `apply` sin cambios debe dar **cero cambios** (idempotencia).

### 4.3 Compatibilidad con Podman 4.9

Esta sección debe copiarse a `docs/COMPATIBILITY.md`.

- **Prohibido** usar funciones de Quadlet posteriores a 4.9. En concreto, `Notify=healthy` y los ficheros `.pod` llegaron con Podman 5.0. Cualquier clave se comprueba en la documentación de 4.9.
- **Dependencias entre servicios** (por ejemplo, Firefly espera a Postgres): `Requires=` y `After=` más un `ExecStartPre` que espere, con tiempo máximo, a que la dependencia esté sana. Fija `TimeoutStartSec` explícito. Este patrón está pendiente de validar (sección 7).
- **Red rootless:** en 4.9 la salida al exterior de las redes rootless usa slirp4netns. Podman 5.0 cambió a pasta y Podman 6 elimina slirp4netns. Por eso **ninguna plantilla lleva opciones de slirp4netns ni de pasta**: así el cambio de versión no toca el código.
- **Al actualizar el GX10 a Podman 5 o superior:** se sustituye el patrón de espera por `Notify=healthy` en un único sitio de las plantillas.
- **El generador de 4.9 no basta para hacer cumplir estas reglas:** acepta `Notify=healthy` e ignora los `.pod` sin error. El CI añade una comprobación de política propia (`scripts/quadlet_policy.py`). Detalle en `docs/COMPATIBILITY.md`.

### 4.4 Redes y Postgres

- Una red por consumidor de Postgres (por ejemplo `firefly-pg-net`), con `Options=isolate=true` y subred fija declarada en el `.network`.
- El contenedor de Postgres se une a todas esas redes. Los consumidores no se ven entre sí.
- Con varias instancias en la misma máquina, cada red de consumidor se une solo a la instancia que usa ese consumidor. No hay una red común para todos los Postgres.
- En Postgres, el modelo de [`POSTGRES.md`](POSTGRES.md): una base y tres grupos por aplicación y usuarios a demanda. En `pg_hba.conf`, generado desde el inventario, cada usuario solo se admite en su base y desde la subred de su red. El superusuario y `backup` nunca entran por TCP, salvo el superusuario desde la red de pgAdmin (R37).
- Postgres **no publica puertos** en el host.
- **Exposición (R25):** los contenedores publican solo en `127.0.0.1`. Si hay que alcanzar un servicio desde otra máquina, se expone por Tailscale con `tailscale serve --bg --tcp=<puerto> tcp://localhost:<puerto>`, que aplica Ansible. No se publica en la IP de Tailscale: un servicio de usuario no puede esperar limpiamente a que esa interfaz tenga dirección.

### 4.5 Secretos

- **Copia maestra:** `infra-pro.kdbx` en el portátil, con rutas `Infra_Podman/<secreto>`. En DEV, `infra-dev.kdbx` con las mismas rutas y valores ficticios. La bóveda personal nunca se toca.
- **Lectura:** lookup propio `plugins/lookup/kdbx.py` que invoca `keepassxc-cli show -q -s -a password <base> <entrada>`, instalado en la imagen de Ansible. `deploy.sh secrets` pide la contraseña maestra con `read -s` y la pasa por la **entrada estándar** del contenedor de la imagen de Ansible, lanzado con `podman run -i` y no con ansible-navigator, que escribiría las variables de entorno en un fichero (R11 en `DECISIONS.md`). Dentro del contenedor queda como variable de entorno solo de ese proceso; el lookup se la entrega a `keepassxc-cli` por la entrada estándar, **nunca como argumento** (los argumentos son visibles en la lista de procesos). Nunca se escribe en disco ni en logs. Cada consulta vuelve a descifrar la base, lo que es aceptable porque solo ocurre al crear o rotar secretos. No se usa la colección `viczem.keepass`.
- **Sustituible:** el lookup es la única pieza que sabe cómo se leen los secretos. Si `keepassxc-cli` no convence, se cambia su implementación (por ejemplo, a la librería pykeepass) sin tocar playbooks ni roles.
- **Creación:** `deploy.sh secrets` (playbook `secrets`), máquina a máquina con `--limit`. Instala cada secreto declarado en `infra_secrets` como `<entorno>-<nombre>` en las máquinas de su grupo. Pide también la contraseña de sudo de esa máquina, que viaja por la entrada estándar como la maestra (R29). Usa `containers.podman.podman_secret` con `no_log: true`. Solo se lee KeePassXC si el secreto **no existe** en el servidor o si se pide rotarlo. Un despliegue normal no pide la contraseña.
- **El lookup va siempre en los argumentos de la tarea, nunca en `loop:`.** Comprobado en la fase 0 (`tests/ee/`): con `when:` falso, Ansible no evalúa el lookup de los argumentos, pero `loop:` se evalúa antes que `when:` y el lookup se ejecutaría igualmente.
- **Entrega:** como fichero (`Secret=nombre,type=mount,target=/ruta,mode=0400`). Para Postgres, `POSTGRES_PASSWORD_FILE`. Variables de entorno solo si la aplicación no admite fichero.
- **Riesgo residual conocido:** Podman guarda los secretos en el disco del servidor sin cifrar, porque es el único driver disponible.
- **Rotación en Postgres:** primero `ALTER ROLE` en la base, después actualizar el secreto con `force` y por último reiniciar los consumidores. Cambiar solo el secreto no cambia la contraseña guardada.
- **Inventario:** `docs/SECRETS_INVENTORY.md` con nombre, ruta en KeePassXC, consumidores y política de rotación. Nunca valores.

### 4.6 Cortafuegos

Se aplica en la fase 1b, empezando por una auditoría de solo lectura (R20).

- firewalld con backend nftables en los servidores. En el GX10: instalarlo y desactivar ufw si está activo. Docker se integra con firewalld creando su propia zona.
- Entrada: solo por `tailscale0`, incluido SSH. Gestionado por Ansible.
- Nunca vaciar el conjunto de reglas completo (`flush ruleset`): borraría las de Docker y las de netavark.
- **Control de salida de los agentes:** diferido a la fase de OpenClaw (sección 6).

### 4.7 Excepción Docker

vLLM sigue en Docker y Ansible no lo gestiona en esta etapa. LiteLLM lo alcanza mediante `vllm_host` y `vllm_port`. Hoy LiteLLM usa solo clave maestra; su Postgres (necesario para las virtual keys) llegará más adelante, como una instancia en el GX10 (D8).

### 4.8 Observabilidad

- `prometheus-podman-exporter` como **servicio systemd de usuario**, no como contenedor con el socket de Podman montado. Escucha solo en `127.0.0.1`; si el Prometheus está en otra máquina, se expone con `tailscale serve` (R25). Se añade como objetivo al Prometheus existente.
- Logs en journald. El análisis de logs con IA queda diferido.

### 4.9 Endurecimiento de contenedores de agentes

Para OpenClaw, SearXNG y el servicio de audio: `NoNewPrivileges=true`, `DropCapability=ALL` (y añadir solo lo imprescindible), `ReadOnly=true` donde se pueda con volúmenes o tmpfs para escrituras, límites de memoria, y **nunca** el socket de Podman o de Docker ni red de host. Comprobar que cada clave existe en Quadlet 4.9.

### 4.10 deploy.sh

- `deploy.sh plan <playbook> [--env dev|prod] [--limit]`: ejecuta `--check --diff` y muestra el plan.
- `deploy.sh apply <playbook> [--env dev|prod] [--limit]`: aplica. Lo lanza solo el operador, también en DEV.
- `deploy.sh secrets [--env dev|prod] [--rotate nombre]`: pide la contraseña de KeePassXC y crea o rota secretos. Con `dev` usa `infra-dev.kdbx`.
- `--env` vale `prod` por defecto. Con `prod`, antes de `plan` o `apply` comprueba que el checkout es un **tag firmado** válido (`git verify-tag`). Con `dev` se despliega desde la rama del PR, sin tag.
- `secrets --env prod` también exige el tag firmado: el playbook que se ejecuta recibe la contraseña maestra.
- `apply --env prod` pide además escribir `prod` en un terminal interactivo. Sin terminal, se rechaza.
- Con `prod`, el checkout tiene que estar limpio (sin cambios ni ficheros sin seguimiento).
- Desde la fase 1c, el inventario se lee del **repo de datos** (4.13), cuya ruta está en `~/.config/infra-podman/deploy.conf` (`data_repo`), también en DEV. Con `prod`, ese repo tiene que estar limpio y su último commit firmado por una clave de `allowed_signers` (`git verify-commit`), además del tag firmado del código.
- Cada ejecución deja una línea en un registro local (`~/.local/state/infra-podman/deploy.log`): fecha, entorno, acción, playbook, tag o rama, commit del repo de datos, hosts y resultado, incluidos los rechazos.

### 4.11 Backups

Sin réplica entre máquinas: una réplica copia también los errores, como un borrado equivocado, una migración rota o un ransomware (R18).

- **Herramienta:** restic (R19). Cifra en origen y la clave de cada repositorio vive en KeePassXC.
- **Qué se copia:** todas las bases de cada instancia, una a una, con el rol `backup` de solo lectura ([`POSTGRES.md`](POSTGRES.md)), y sus roles sin contraseñas; los volúmenes de datos de las aplicaciones (desde la fase 2); y el **repo de datos** del operador (4.13), a partir de la copia que `deploy.sh` deja en `/var/lib/infra-podman/data-repo` tras cada ejecución correcta (R42).
- **Cómo (fase 1e1, R42):** un contenedor Quadlet de un solo uso (`<entorno>-backup`), arrancado solo por su temporizador. Antes de arrancarlo, el propio servicio vuelca las bases en una carpeta temporal. El contenedor, sin red, guarda una copia por cosa con las etiquetas `env`, `app`, `type` y `reason` (`daily` o `pre-upgrade`) y la ruta `<app>/<tipo>/<nombre>`. Al terminar, se borran los volcados sin cifrar y se escribe un resumen para el aviso.
- **Avisos:** si una copia falla o la última correcta tiene más de 36 horas, una notificación en el escritorio del operador (un temporizador en su sesión). Todo queda en journald, sin secretos.
- **En el portátil:** un temporizador de systemd de usuario, **una vez al día** y con `Persistent=true` para ponerse al día si el portátil estaba apagado, vuelca cada base con `pg_dump` y guarda los volúmenes de datos en un repositorio restic local, en el disco cifrado.
- **Copia externa:** cuando el GX10 es alcanzable por Tailscale, el repositorio se copia a un **rest-server de restic en el GX10** en modo `--append-only`. El portátil puede añadir copias pero no borrarlas. **Retención (R26, R28):** automática solo en el repositorio local del portátil: 7 copias diarias, 12 mensuales y 5 anuales, por separado para cada motivo (`reason`), de forma que una copia diaria nunca borra la hecha antes de un cambio de imagen. En el GX10 no se borra nada en la fase 1: borrar exige la clave del repositorio, que no debe vivir en un disco sin cifrar; se decide más adelante con el tamaño real.
- **El GX10 no necesita disco cifrado para esto:** solo recibe datos cifrados. Puede usar un disco USB externo por capacidad.
- **restic y rest-server** corren como contenedores Quadlet (D1), fijados por digest.
- **Pérdida aceptada:** lo hecho desde la última copia diaria; y si se pierde el portátil, desde el último contacto con el GX10.
- **Restauración:** se prueba al cerrar la fase 1, desde la copia local y desde la del GX10. Con `--exclude-xattr '*'` (`docs/COMPATIBILITY.md`).


### 4.12 Nombres y etiquetas

Para saber de un vistazo de quién es cada contenedor, red o volumen, para qué sirve y de qué entorno es, sin herramientas nuevas (R22).

**Nombres:** en minúsculas, con guiones, y siempre empiezan por el entorno (`prod` o `dev`, variable `infra_env`).

| Objeto | Patrón | Ejemplos |
| --- | --- | --- |
| Contenedor y su servicio systemd | `<entorno>-<app>[-<pieza>]` | `prod-pg-main`, `prod-firefly`, `prod-backup` |
| Red | `<entorno>-<consumidor>-<proveedor>-net` | `prod-firefly-pg-main-net`: Firefly habla con el Postgres `main` |
| Volumen | `<entorno>-<app>-<contenido>` | `prod-pg-main-data`, `prod-firefly-uploads`, `prod-backup-repo` |
| Secreto de Podman | `<entorno>-<nombre en KeePassXC>` | `prod-pg-main-firefly-password` ↔ `Infra_Podman/pg-main-firefly-password` (la misma ruta en dev y prod) |

- **Postgres:** cada instancia se llama `pg-<instancia>`, por ejemplo `pg-main` o `pg-test`.
- **Ficheros Quadlet:** se llaman como el objeto (`prod-firefly.container` crea el servicio `prod-firefly.service`).
- **Nombres explícitos:** siempre se fijan `ContainerName=`, `NetworkName=` y `VolumeName=`. Sin ellas, Podman antepone `systemd-` al nombre (comprobado con el generador de 4.9).

**Etiquetas:** todo contenedor, red y volumen lleva:
- `infra.env` (`prod`, `dev`);
- `infra.app` (`pg-main`, `firefly`…);
- `infra.component` (`db`, `app`, `backup`…);
- `infra.managed-by=infra-podman`.

Sirven para filtrar, por ejemplo `podman ps --filter label=infra.app=firefly` o `podman volume ls --filter label=infra.env=prod`. Es la misma idea que las etiquetas recomendadas de Kubernetes (`app.kubernetes.io/name`, `component`, `managed-by`), sin Kubernetes.

**CI:** a partir de la fase 1, la política de Quadlet del CI rechaza los objetos sin nombre explícito, sin prefijo de entorno o sin estas etiquetas.

### 4.13 Código y datos

Desde la fase 1c (R38):

| Qué | Dónde | Quién lo cambia |
| --- | --- | --- |
| **Código:** roles, plantillas, playbooks, `deploy.sh`, CI, documentación, digests de imágenes (`images.yml`) e `inventory.example/` con datos inventados | Este repo, en GitHub. Publicable | Claude por PR; el operador mergea y firma el tag |
| **Datos:** inventario de cada entorno (`inventory/dev/`, `inventory/prod/`): máquinas, aplicaciones, instancias, bases, usuarios y configuración de cada aplicación | **Repo git de datos, solo en el portátil** (`~/Documents/SECURE_vc/ansible/infra-podman`), en el disco cifrado, sin remoto en GitHub. Todos sus commits firmados | Solo el operador. Cada PR de código dice qué hay que añadir en él |
| **Secretos** | KeePassXC (4.5) | Solo el operador |

- **Copia de seguridad del repo de datos:** los backups de 4.11 (local y GX10, cifrados).
- **CI:** valida el código con `inventory.example/` y los inventarios de `tests/`. Los datos reales los valida `deploy.sh plan`.
- Claude nunca ve el repo de datos.
- **Estructura:** la de [`inventory.example/`](../inventory.example/README.md), dentro de una carpeta `inventory/`. Un repo de datos por proyecto: la carpeta `ansible/` del operador puede tener otros.
- `deploy.sh` exige que `data_repo` sea la raíz de su propio repo git y que ninguno de los dos repos contenga al otro. En DEV acepta datos sin commit; en prod, no (R40).

## 5. CI/CD, firma y flujo de cambios

### 5.1 Flujo de un cambio

1. El operador describe la idea. Claude trabaja en una rama y abre un PR en borrador.
2. El CI se ejecuta en cada push. Claude corrige en el mismo PR hasta que está en verde, con un máximo de 5 intentos por el mismo fallo; después pregunta.
3. El operador revisa y, si es un servicio nuevo, lo prueba en DEV.
4. Merge a `main` y **tag firmado** creado por el operador.
5. En el portátil: `deploy.sh plan`, revisión y `deploy.sh apply`.

### 5.2 Repositorio en GitHub (privado)

- **Protección de `main`: diferida.** En una cuenta gratuita, GitHub no aplica la protección de ramas ni los rulesets en repos privados; hace falta GitHub Pro, Team o Enterprise. Mientras tanto, `main` se cambia solo por PR mergeado con **Squash and merge**, por disciplina del operador. Si se pasa a un plan de pago, se activan: solo por PR, CI en verde obligatorio, commits firmados, sin force-push ni borrado, y 0 aprobaciones obligatorias (GitHub no deja aprobar el propio PR).
- **El control efectivo es la firma:** `deploy.sh` solo despliega código desde un tag firmado con la clave SSH del operador, que vive en su KeePassXC, y datos desde un commit firmado del repo de datos (4.13). Un cambio que llegue a `main` por error no alcanza los servidores sin esa firma.
- Claude trabaja solo en ramas y PRs (regla de `CLAUDE.md`). Hoy GitHub no lo impide técnicamente: es una regla de proceso, no un control. No crea tags ni accede a secretos de Actions de producción.
- Ajustes del repo: solo **Squash and merge** permitido y borrado automático de ramas tras el merge.
- Antes de hacer público cualquier repo: escaneo del historial completo en busca de secretos.

### 5.3 Firma con SSH

- Git configurado con `gpg.format ssh` y `user.signingkey` apuntando a la clave pública. La privada la sirve el agente SSH de KeePassXC.
- La verificación de `deploy.sh` usa un fichero de firmantes permitidos **fuera del repo**, en el portátil (`~/.config/infra-podman/allowed_signers`). Si usara el del repo, cualquiera con permiso de escritura podría añadir su propia clave y firmar un tag que pasaría la comprobación.
- El repo incluye una copia de referencia de ese fichero, para configurar git y documentar qué clave es la válida. No es la que decide.
- La clave pública se sube a GitHub como clave de firma, para que los commits aparezcan verificados.

### 5.4 Workflows del repo de infraestructura

| Workflow | Cuándo | Qué hace |
| --- | --- | --- |
| `lint` | Cada push | yamllint, ansible-lint, shellcheck de `deploy.sh` y de los scripts, y validación de las plantillas Quadlet renderizadas: política del repo (sección 8) y generador de Podman 4.9. Un segundo job repite la validación con un Podman más nuevo (hoy el 5 de Fedora 44), sin cambiar las plantillas |
| `lifecycle` | PR que toca un rol | Con Podman rootless y systemd de usuario: desplegar, esperar healthcheck, reaplicar (cero cambios) y destruir conservando el volumen. Runner `ubuntu-24.04` (Podman 4.9, el mínimo) para los servicios del portátil y `ubuntu-24.04-arm` para los del GX10. Usa secretos aleatorios generados en el propio CI, nunca KeePassXC |
| `ee-image` | Cambio en `execution-environment.yml` | Construye la imagen de Ansible con ansible-builder y la publica en GHCR privado, fijada por digest |

En repos privados, los runners ARM estándar consumen los minutos gratuitos del plan. Mantener los trabajos cortos.

### 5.5 Proyectos propios con imagen

Cada repo de proyecto construye su imagen (multiarquitectura si se despliega en más de una arquitectura), la publica en **GHCR privado** con el token integrado de Actions y deja el digest en la salida del workflow. El repo de infraestructura solo referencia ese digest.

### 5.6 Descarga desde GHCR en los servidores

El usuario de servicio se autentica en `ghcr.io` con un token de solo lectura de paquetes. Ese token es un secreto más: vive en KeePassXC y Ansible lo instala con el módulo de login de `containers.podman`, sin que aparezca en logs.

## 6. Fases de implementación

Cada fase termina en un PR (o varios pequeños) y no se pasa a la siguiente sin aprobación del operador.

| Fase | Contenido | Criterio de hecho |
| --- | --- | --- |
| **0. Base** | Estructura del repo, `CLAUDE.md` y `docs/`; firma SSH y fichero de firmantes permitidos; workflow `lint`; imagen de Ansible; esqueleto de `deploy.sh`; lookup `kdbx.py` probado contra `infra-dev.kdbx` | CI en verde; `deploy.sh plan` funciona contra DEV; un tag sin firmar es rechazado; el lookup lee un secreto ficticio de un `.kdbx` creado con KeePassXC 2.8 |
| **1. Postgres y backups** | Rol `host_base` en el portátil y en el GX10 (usuario de servicio y linger); Postgres en el portátil, parametrizado por instancia, con volumen, secreto como fichero y healthcheck; **repo de datos (4.13)**; **instancia según [`POSTGRES.md`](POSTGRES.md)** (recrear `pg-main`); backups según 4.11, con rest-server en el GX10; workflow `lifecycle` | `apply` correcto y un segundo `apply` con cero cambios; sobrevive a un reinicio del portátil; no publica puertos; restauración correcta desde la copia local y desde la del GX10; ningún secreto en repo ni logs |
| 1b. Cortafuegos (cuando el operador lo decida, antes de la fase 5) | Auditoría de solo lectura de lo que escucha cada servidor; ensayo en `vmiadev` con Docker y Tailscale; firewalld en dos pasos (primero con SSH también desde la red local como puerta de emergencia, después solo por Tailscale); ufw desactivado | Solo se entra por Tailscale; vLLM sigue funcionando; el operador no pierde el acceso en ningún paso |
| **2. Firefly III y pgAdmin** | En el portátil. Bases y usuarios declarados como datos según [`POSTGRES.md`](POSTGRES.md), con `pg_hba` generado; red propia con `isolate=true` para cada consumidor; espera a Postgres según 4.3; pgAdmin solo en `127.0.0.1` (R37) | Firefly solo arranca con Postgres sano; no alcanza otras redes; al destruirlo se conserva su volumen; `_reader` no puede modificar datos; pgAdmin administra la instancia |
| **3. Observabilidad** | `prometheus-podman-exporter` como servicio de usuario y objetivo en el Prometheus existente | Métricas visibles en el Grafana actual |
| 4. LiteLLM (más adelante) | Pasar LiteLLM a Quadlet con `vllm_host` y `vllm_port`; su base en una instancia de Postgres en el GX10 cuando lleguen las virtual keys | LiteLLM responde igual que hoy |
| 5. Agentes (más adelante) | OpenClaw, SearXNG y audio con el endurecimiento de 4.9; control de salida por usuario tras una prueba previa (sección 7); evaluar el disparador del segundo usuario | Un contenedor de agente no alcanza la LAN, Tailscale ni Postgres salvo lo permitido |
| 6. Análisis de logs (más adelante) | Exportar journald, limpiar datos sensibles y analizar con el vLLM local en solo lectura, sin herramientas | Un log con instrucciones maliciosas no provoca ninguna acción |

Las fases 0 a 3 son el alcance actual. Las 4 a 6 se diseñan en detalle cuando lleguen.

## 7. Verificaciones pendientes y decisiones abiertas

### 7.1 Verificar antes o durante la fase indicada

Son supuestos razonables pero no comprobados. Si alguno falla, detente y propón alternativa.

| Fase | Qué verificar |
| --- | --- |
| 0 | Cómo instalar ansible-navigator en Fedora Atomic 44 y que la imagen de Ansible funcione con el Podman del portátil (5 en Fedora 44; 6 al pasar a Fedora 45) y el reenvío del agente SSH. Instalación: **comprobada** (`docs/SETUP.md`). Agente SSH: **comprobado** el 2026-11-02 con `deploy.sh plan check --env dev` y `--security-opt=label=disable` (R16) |
| 0 | Que `keepassxc-cli` dentro de la imagen de Ansible abre un `.kdbx` guardado con KeePassXC 2.8, cómo se instala en esa imagen y qué versión trae. Se instala con el paquete `keepassxc` de Fedora 44 y trae la **2.8.0**. **Comprobado** el 2026-11-02 por el operador: el lookup lee `Infra_Podman/test_dummy` de `infra-dev.kdbx` creado con KeePassXC 2.8 de escritorio (`docs/SETUP.md`, paso 4) |
| 0 | Que `keepassxc-cli` acepta la contraseña maestra por la entrada estándar sin terminal. La documentación oficial describe `-q` (silencia la petición de contraseña) y `-s`/`-a`, pero no detalla este comportamiento. **Comprobado** con 2.7.6 en local y con 2.8.0, la que trae la imagen de Ansible, en CI (`tests/ee/run.sh`) |
| 0 | Que Ansible no evalúa el lookup de KeePassXC en una tarea saltada (`when:` falso) cuando el secreto ya existe. **Comprobado**, salvo en `loop:` (ver 4.5) |
| 1 | Que el runner `ubuntu-24.04` permite usar Podman 4.9 rootless con systemd de usuario para `lifecycle` (y `ubuntu-24.04-arm` cuando haya servicios del GX10 con datos). **Comprobado** el 2026-11-03 (jobs `base` y `postgres`): usuario de servicio con linger, Podman 4.9.3 rootless, Quadlet, healthcheck y reinicio. Salvedad del runner, no de los servidores: su `/etc/environment` fija `XDG_*` para su propio usuario y el workflow lo quita (`docs/COMPATIBILITY.md`) |
| 1b | Que instalar firewalld en DGX OS convive con Docker y con la pila de NVIDIA |
| 1 | En la página oficial de facturación de GitHub, que el almacenamiento y la transferencia de imágenes en GHCR siguen siendo gratuitos |
| 1 | Cómo despliega Ansible en el propio portátil desde el contenedor de ansible-navigator. **Propuesta aprobada (R23):** SSH a `127.0.0.1` (sshd solo en loopback y solo con clave) con `--network=host` en el contenedor. Pendiente de la prueba del operador (`docs/SETUP.md`, paso 9) |
| 1 | Que ansible-navigator permite pedir la contraseña de sudo (`--ask-become-pass`) con la configuración del repo. **Comprobado en el código** de ansible-navigator 26.10.0 y ansible-runner 2.4.3: en `mode: stdout` el terminal pasa al contenedor (`--interactive`, y `--tty` si la entrada y la salida son un terminal). Pendiente de la prueba del operador (R24) |
| 1 | Que la imagen oficial de rest-server incluye `linux/arm64`. **Comprobado** el 2026-11-03 por el operador (0.14.0: amd64, arm64 y otras). Cómo se expone: con `tailscale serve` (R25); pendiente de comprobar en el GX10 (Tailscale 1.104.4) si el modo `--tcp` pide permisos o certificados |
| 1 | Que `pgvector/pgvector:pg18` admite `initdb --locale-provider=builtin --builtin-locale=C.UTF-8`, deja los checksums de datos activados y arranca con el endurecimiento de [`POSTGRES.md`](POSTGRES.md) en Podman 4.9 (R34). **Comprobado** el 2026-11-03 en `lifecycle` (fase 1d): `b\|C.UTF-8\|UTF8`, checksums `on`, UTC, solo cinco capacidades y sistema de ficheros de solo lectura |
| 2 | Que `ALTER ROLE … SET role = <app>_owner` hace que lo creado por un usuario de `_owner` quede a nombre del grupo, y que `_reader` no puede modificar datos (R35, R36) |
| 2 | Que el patrón de espera con `ExecStartPre` funciona en 4.9 y respeta `TimeoutStartSec` |
| 3 | Cómo se instala `prometheus-podman-exporter` en Ubuntu 24.04 ARM64 (paquete o binario) |
| 5 | Que una regla nftables por usuario captura el tráfico de salida de slirp4netns, y qué excepciones de DNS hacen falta (incluido el DNS de Tailscale, 100.100.100.100) |
| 5 | Que las claves de endurecimiento de la sección 4.9 existen en Quadlet de Podman 4.9. Adelantado en la fase 0: todas existen salvo `Memory=` (ver `docs/COMPATIBILITY.md`) |

### 7.2 Decisiones abiertas (proponer y esperar aprobación)

| Tema | Opciones conocidas |
| --- | --- |
| Prometheus y Grafana existentes | Dónde corren exactamente y si sus objetivos se gestionan desde Ansible o a mano |
| Escáner de vulnerabilidades en CI | Propuesta: Trivy. Aplazado hasta después de la fase 3 (R21) |
| Propuestas automáticas de actualización de digests | Propuesta: Dependabot para las actions y Python; los digests de imágenes, más adelante. Siempre como PR, nunca aplicación automática. Aplazado hasta después de la fase 3 (R21) |
| Plan de GitHub | Gratuito ahora. GitHub Pro activaría la protección de `main` según la documentación oficial, pero el aviso de la interfaz menciona cuentas Team; comprobar que desaparece antes de dar por hecho que funciona. Comprobado el 2026-11-02 en este repo (cuenta personal gratuita): el formulario de rulesets avisa de que no se aplicarán «until you move to GitHub Team organization account». No se crean rulesets mientras tanto |
| Cifrado de los datos propios del GX10 | Cuando el GX10 guarde datos sin cifrar en origen (por ejemplo, el Postgres de la fase 4): disco USB externo con LUKS y desbloqueo automático al arrancar (TPM, Clevis/Tang u otra). Se decide en esa fase |

### 7.3 Disparador para un segundo usuario de servicio

Se evalúa si un agente (por ejemplo OpenClaw) recibe capacidad amplia de ejecutar comandos o procesa contenido no confiable teniendo credenciales. Añadirlo es cambiar una variable para servicios sin datos; los servicios con datos requieren migrar su volumen.

## 8. Prohibiciones

- Etiquetas móviles de imagen (`:latest` y similares).
- Funciones de Quadlet o Podman posteriores a 4.9 mientras el GX10 siga en 4.9 (por ejemplo `Notify=healthy` o ficheros `.pod`).
- Opciones específicas de slirp4netns o de pasta en las plantillas.
- Montar el socket de Podman o de Docker en cualquier contenedor, o usar red de host en contenedores de agentes.
- Secretos en Git, aunque estén cifrados, y valores de secretos en logs, en la salida de Ansible o en el chat.
- La colección `viczem.keepass`. Tocar la bóveda personal del operador.
- ufw. Vaciar el conjunto completo de reglas nftables.
- Rollback automático de imagen en servicios con datos.
- Borrar volúmenes al destruir un servicio sin una purga explícita.
- Que cualquier IA ejecute `apply`, haga merge, cree tags o acceda a los servidores.
- Gestionar desde Ansible el Docker de vLLM en esta etapa.
- Añadir herramientas, paneles o servicios no listados aquí sin aprobación.
- Software de pago o que pida suscripción (por ejemplo, Ansible Automation Platform, Automation Hub o `registry.redhat.io`).
- Preguntar de nuevo por el cifrado del portátil: ya está resuelto.

## 9. Fuentes de referencia

Verificadas en noviembre de 2026. Para cualquier detalle técnico, manda la documentación oficial de la versión instalada.

**Podman y Quadlet**

- [Manual de Quadlet en Podman 4.9 (Ubuntu 24.04)](https://manpages.ubuntu.com/manpages/noble/man5/quadlet.5.html): validación con el generador y `QUADLET_UNIT_DIRS`.
- [Notas de Podman 5.0](https://github.com/containers/podman/releases/tag/v5.0.0): llegada de `Notify=healthy` y ficheros `.pod`.
- [Cambios de Podman 5.0](https://blog.podman.io/2024/03/podman-5-0-breaking-changes-in-detail/): paso de slirp4netns a pasta.
- [Podman 6 en Fedora](https://fedoraproject.org/wiki/Changes/Podman6): eliminación de slirp4netns. Aceptado para Fedora 45 (`ChangeAcceptedF45`), no para la 44.
- [podman network create](https://docs.podman.io/en/stable/markdown/podman-network-create.1.html): opción `isolate`.
- [Opción `--secret`](https://docs.podman.io/en/v4.6.0/_sources/markdown/options/secret.md.txt): `target`, `uid`, `gid` y `mode`.
- [Secretos de Podman](https://www.redhat.com/en/blog/new-podman-secrets-command): almacenamiento sin cifrar con el driver de ficheros.
- [prometheus-podman-exporter](https://pkg.go.dev/github.com/containers/prometheus-podman-exporter).

**Ansible**

- [containers.podman.podman_secret](https://docs.ansible.com/ansible/8/collections/containers/podman/podman_secret_module.html): `skip_existing` y `force`.
- [Manual de keepassxc-cli](https://man.archlinux.org/man/keepassxc-cli.1.en): orden `show` y opciones `-q`, `-s`, `-a`, `--no-password` y `-k`.

**Cortafuegos y Docker**

- [Docker: filtrado de paquetes y cortafuegos](https://docs.docker.com/engine/network/packet-filtering-firewalls/): integración con firewalld e incompatibilidad con ufw.
- [firewalld.conf](https://manpages.ubuntu.com/manpages/resolute/man5/firewalld.conf.5.html).

**Hardware, secretos y GitHub**

- [FAQ del ASUS Ascent GX10](https://www.asus.com/us/support/faq/1056142/): solo DGX OS.
- [KeePassXC 2.8.0](https://keepassxc.org/blog/2026-10-21-2.8.0-released/).
- [Agente SSH de KeePassXC](https://github.com/keepassxreboot/keepassxc/blob/develop/docs/topics/SSHAgent.adoc).
- [Ramas protegidas en GitHub](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches): en repos privados requieren Pro, Team o Enterprise.
- [Runners ARM en repos privados](https://github.blog/changelog/2026-01-29-arm64-standard-runners-are-now-available-in-private-repositories/).
- [LiteLLM virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys): requieren Postgres.

**Fuente no oficial usada**

- [DGX OS 7 y 8](https://ailone.io/en/dgx-os/): que DGX OS 8 aún no soporta DGX Spark. Confirmar en las notas oficiales de NVIDIA antes de cualquier cambio de sistema operativo.
