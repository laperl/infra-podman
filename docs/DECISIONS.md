# Registro de decisiones

Las decisiones vigentes viven en [`SPEC.md`](SPEC.md): las cerradas D1 a D15 en su sección 3 y el resto en la sección que corresponda. Este fichero registra **cuándo y por qué** se tomó cada decisión posterior a la versión 1 del SPEC, para no volver a discutirla.

Cada entrada: fecha, decisión, motivo, quién la aprobó y dónde quedó reflejada en el SPEC.

## 2026-11-02

### R1. Sistema de la VM DEV: Ubuntu Server 24.04 x86_64

- **Decisión:** la VM DEV usa Ubuntu Server 24.04 x86_64, con Podman 4.9 instalado por apt.
- **Motivo:** DEV sirve para ver sorpresas antes de que lleguen al GX10, así que debe llevar la misma versión de Podman (4.9) y la misma base (DGX OS 7 es Ubuntu 24.04). Una distro con Podman 5 aceptaría funciones que fallarían en el GX10. La diferencia de arquitectura (x86_64 frente a ARM64) la cubre el workflow `lifecycle`, que corre en ARM64.
- **Aprobada por:** el operador.
- **SPEC:** sección 2 (tabla de máquinas) y 7.2.

### R2. Uso de DEV

- **Decisión:** el portátil es el nodo de control también para DEV. El operador despliega en DEV a mano con `deploy.sh --env dev`, desde la rama del PR, antes del merge. opencode, en DEV, solo ejecuta pruebas; no hace `apply`. D14 no cambia.
- **Motivo:** mantiene a cualquier IA lejos del `apply` y permite probar una rama antes de mergearla.
- **Aprobada por:** el operador.
- **SPEC:** sección 4.10 y paso 3 de 5.1.

### R3. `deploy.sh --env dev|prod`

- **Decisión:** `deploy.sh` recibe `--env dev|prod`, con `prod` por defecto. Solo `prod` exige un tag firmado. `--env` lo consume `deploy.sh` y no llega a ansible-navigator, que no tiene ninguna opción con ese nombre.
- **Motivo:** con DEV se prueban ramas de PR, que no tienen tag. Por defecto `prod`, para que olvidarse la opción sea lo más seguro.
- **Aprobada por:** el operador.
- **SPEC:** sección 4.10.

### R4. Firmantes permitidos fuera del repo

- **Decisión:** `deploy.sh` verifica los tags contra `~/.config/infra-podman/allowed_signers`, en el portátil y fuera del repo. El fichero de firmantes del repo queda como referencia para configurar git y para que GitHub y los colaboradores sepan qué clave es la válida.
- **Motivo:** si la verificación usara el fichero del repo, cualquiera con permiso de escritura (incluida una IA) podría añadir su clave a ese fichero, firmar su propio tag y pasar la comprobación. Eso anularía el control de 5.2 («el control efectivo es el tag firmado»).
- **Aprobada por:** el operador.
- **SPEC:** sección 5.3.

### R5. Imagen base de la imagen de Ansible: Fedora minimal

- **Decisión:** la imagen de Ansible parte de Fedora minimal, fijada por digest. `keepassxc-cli` se instala con el paquete `keepassxc` de Fedora.
- **Motivo:** Fedora empaqueta `keepassxc-cli` y la imagen corre en el portátil, que también es Fedora. Si la versión empaquetada no abre bases guardadas con KeePassXC 2.8, se propondrá otra base (SPEC 7.1).
- **Aprobada por:** el operador.
- **SPEC:** sección 4.1.

### R6. Comprobación de política además del generador de Quadlet

- **Decisión:** el workflow `lint` ejecuta `scripts/quadlet_policy.py` además del generador de Podman 4.9.
- **Motivo:** comprobado que el generador de 4.9 acepta `Notify=healthy`, ignora los ficheros `.pod` y no exige digests (ver [`COMPATIBILITY.md`](COMPATIBILITY.md)). Sin esta comprobación, las prohibiciones de la sección 8 no se harían cumplir.
- **Propuesta en:** PR de la fase 0a. Pendiente de aprobación con ese PR.
- **SPEC:** secciones 4.3 y 5.4.

### R7. Aplazados

- **Decisión:** el escáner de vulnerabilidades en CI y las propuestas automáticas de actualización de digests no entran en la fase 0. Siguen abiertos en SPEC 7.2.
- **Motivo:** evitar herramientas nuevas antes de que la base funcione.
- **Aprobada por:** el operador, con la condición de no olvidarlos. Están en [`ROADMAP.md`](ROADMAP.md).

### R8. Corrección: Fedora 44 trae Podman 5, no 6

- **Decisión:** se corrige el SPEC. El portátil y el Lenovo (Fedora 44) tienen Podman 5. Podman 6 llega con Fedora 45.
- **Motivo:** la propuesta de cambio de Fedora [Changes/Podman6](https://fedoraproject.org/wiki/Changes/Podman6) figura como aceptada para Fedora 45 (`ChangeAcceptedF45`). Lo señaló el operador.
- **SPEC:** secciones 2, 7.1 y 9.

### R9. Validación de plantillas con un Podman más nuevo

- **Decisión:** el workflow `lint` tiene un segundo job, `quadlet-forward`, que pasa las mismas comprobaciones con el Podman de Fedora 44 (5). Cuando salga Fedora 45 se cambia su digest para validar con Podman 6. Las plantillas siguen escritas solo para 4.9 (D5).
- **Motivo:** ver a tiempo qué dejaría de funcionar al actualizar el GX10, sin ramificar las plantillas por versión.
- **Aprobada por:** el operador («dejarla preparada»).
- **SPEC:** sección 5.4.

### R10. Rulesets de GitHub: no se crean

- **Decisión:** no se crean rulesets ni reglas de protección de rama mientras el plan sea gratuito.
- **Motivo:** comprobado en el formulario de rulesets de este repo: «Your rulesets won't be enforced on this private repository until you move to GitHub Team organization account». Confirma SPEC 5.2: el control es el tag firmado.
- **SPEC:** sección 7.2 (plan de GitHub).

### R11. La contraseña maestra no pasa por ansible-navigator

- **Hallazgo:** en el código de ansible-navigator 26.10.0 y ansible-runner 2.4.3, toda variable que se pase al contenedor (`--penv`) acaba en `self.config.env`, y ansible-runner la escribe **en texto plano** en `<artifact_dir>/env.list` (`ansible_runner/runner.py`) para dárselo a `podman --env-file`. Ese directorio es temporal y se borra al terminar, pero si el proceso se interrumpe, queda. Además, pasar una variable con `podman run -e` la guarda en la configuración del contenedor en disco mientras existe (es lo que dice la especificación OCI; sin comprobar en el portátil). Las dos vías incumplen SPEC 4.5: «nunca se escribe en disco».
- **Propuesta:** `deploy.sh secrets` no usa ansible-navigator. Lanza la misma imagen con `podman run -i` y le pasa la contraseña por la **entrada estándar**. Dentro del contenedor se lee con `read` y se exporta solo a ese proceso, que es lo que el lookup espera. `plan` y `apply` siguen con ansible-navigator, porque no llevan la contraseña. Así se ha hecho ya la prueba del operador (`docs/SETUP.md`, paso 4).
- **Por qué no es reabrir D2:** el despliegue sigue siendo con ansible-navigator y la misma imagen. Solo cambia el lanzador de la orden que maneja la contraseña maestra.
- **Aprobada por:** el operador, el 2026-11-02, manteniendo ansible-navigator para todo lo demás. Se implementa en la fase 0c.
- **SPEC:** sección 4.5.

### R12. Solo software libre y gratuito

- **Decisión:** todo lo que use la plataforma es software libre, oficial y gratuito. En Ansible se usa la versión comunitaria: ansible-core, ansible-navigator, ansible-builder y ansible-runner desde PyPI, y colecciones desde Ansible Galaxy. Nada de Red Hat Ansible Automation Platform, Automation Hub, imágenes de `registry.redhat.io` ni nada que pida suscripción.
- **Motivo:** decisión del operador. Las «imágenes de entorno de ejecución» (Execution Environments) son un formato abierto de la comunidad. La nuestra se construye sobre Fedora, no sobre las imágenes de pago de Red Hat.
- **Aprobada por:** el operador.
- **SPEC:** secciones 2 y 8.

### R13. Token de GHCR: clásico de momento

- **Decisión:** el portátil descarga la imagen de Ansible con un token clásico de solo `read:packages`, guardado en KeePassXC.
- **Motivo:** GHCR solo admite tokens clásicos. Ese token puede leer **todos** los paquetes a los que llega tu cuenta y el operador lo creó sin caducidad.
- **Pendiente:** buscar una vía más segura antes de la fase 1, porque los servidores necesitarán lo mismo (SPEC 5.6). Está en [`ROADMAP.md`](ROADMAP.md).

### R14. Inventario por entorno

- **Decisión:** `inventory/dev/` e `inventory/prod/`, cada uno con su `hosts.yml`, `group_vars/` y `host_vars/`. Sustituye a `group_vars/` y `host_vars/` en la raíz (SPEC 4.1).
- **Motivo:** Ansible solo carga `group_vars/` y `host_vars/` junto al inventario o al playbook. En la raíz no se cargarían. Además, DEV y producción necesitan valores distintos.
- **Direcciones fuera del repo:** los hosts son alias de `~/.ssh/config` (`vmiadev`, `gx10`). La IP y el usuario viven en el portátil.
- **Propuesta en:** PR de la fase 0c.

### R15. Protecciones adicionales de `deploy.sh` en producción

- **Decisión:** en `prod`:
  - el checkout tiene que estar limpio;
  - `secrets` también exige el tag firmado;
  - `apply` pide escribir `prod` en un terminal interactivo.
- **Motivo:**
  - Un fichero sin commit se desplegaría sin estar firmado.
  - El playbook de `secrets` recibe la contraseña maestra, así que debe ser código firmado.
  - La confirmación evita un `apply` por error y bloquea cualquier ejecución sin persona delante (D14).
- **Propuesta en:** PR de la fase 0c.

### R16. Contenedores de Ansible con `label=disable`

- **Decisión:** ansible-navigator y `deploy.sh secrets` lanzan la imagen con `--security-opt label=disable`.
- **Motivo:** ansible-runner 2.4.3 monta `~/.ssh` y el socket del agente SSH sin etiqueta SELinux (`_handle_automounts` en `config/_base.py`). En Fedora, con SELinux activo, el contenedor no podría usarlos. Reetiquetarlos (`:z`) cambiaría la etiqueta de tu `~/.ssh` en el portátil, que es peor.
- **Coste:** SELinux no aísla ese contenedor del resto de tu usuario. Es nuestra propia imagen, lanzada por ti, y Podman sin root ya la limita a tus permisos.
- **Estado:** funciona. El operador ejecutó `plan check` y `secrets` contra DEV el 2026-11-02 con esta opción. No se ha probado sin ella, así que no está demostrado que sea imprescindible. Se mantiene hasta que alguien lo pruebe.

### R17. La VM DEV no ve las claves del operador, y `infra-dev.kdbx` vive solo en el portátil

- **Hallazgo:** el 2026-11-02 el operador vio todas sus claves con `ssh-add -l` dentro de la VM. Eso solo ocurre si la sesión SSH reenvía el agente (`ssh -A` o `ForwardAgent yes`).
- **Riesgo:** mientras dure la sesión, cualquier proceso de la VM, incluido opencode con IA local, puede usar las claves del agente: entrar en el GX10 o firmar un tag. Contradice D14 y R2 («la VM no tiene nada de producción»).
- **Decisión (propuesta):**
  - `ForwardAgent no` para la VM en `~/.ssh/config` (`docs/SETUP.md`, paso 6);
  - `-o ForwardAgent=no` en los inventarios, para las conexiones de Ansible, que no necesitan reenvío (Ansible corre en el portátil);
  - `infra-dev.kdbx` solo existe en el portátil, sin copia en la VM y sin copia de seguridad.
- **Motivo del kdbx:** solo tiene valores ficticios y se recrea con los nombres de `infra_secrets` en `inventory/dev/group_vars/all.yml`. La VM no es nodo de control (R2), así que no lo necesita.
- **Salvedad:** si DEV guardara datos que dependan de un secreto de ese fichero (por ejemplo, un volumen de Postgres de DEV creado con su contraseña), perderlo obligaría a recrear ese volumen. Es DEV y es aceptable. Si DEV deja de ser desechable, se reconsidera.
- **Propuesta en:** PR de la fase 0c.

### R18. El portátil es el principal de los datos personales; sin réplica

- **Decisión:**
  - El Postgres principal y las aplicaciones personales viven en el portátil, para tenerlas siempre disponibles, también sin conexión.
  - No hay réplica de Postgres en el GX10.
  - D8 pasa a ser «un Postgres por máquina que lo necesite»: en una misma máquina pueden convivir varias instancias, cada una con su nombre, su volumen y sus redes.
  - Los servicios del GX10 que necesiten base de datos (por ejemplo, LiteLLM en la fase 4) tendrán su propia instancia allí, sin sincronizarse con la del portátil.
- **Motivo:**
  - Una réplica copia también los errores.
  - Con conexión intermitente, el portátil acumula WAL sin límite o la réplica se rompe. Según la documentación de Postgres, por defecto `max_slot_wal_keep_size = -1`.
  - Sería de solo lectura en el GX10.
  - Dejaría los datos sin cifrar en un disco sin LUKS.
  - Para una sola persona, los backups (R19) protegen más con menos piezas.
- **Redes:** sigue D9. Cada red de consumidor se une solo a su instancia; no hay una red común para todos los Postgres.
- **Aprobada por:** el operador, el 2026-11-02, con la condición de no complicarlo en exceso.
- **SPEC:** secciones 2, 3 (D3, D8), 4.4, 4.7 y 6.

### R19. Backups con restic y copia append-only en el GX10

- **Decisión:**
  - En el portátil, una vez al día, `pg_dump` de cada base y copia de los volúmenes de datos a un repositorio restic local. El operador lo pidió diario en vez de cada hora, para no cargar el portátil.
  - Cuando el GX10 está alcanzable, copia a un rest-server de restic en el GX10 en modo `--append-only`, desde el que se aplica la retención.
  - restic y rest-server corren como contenedores Quadlet.
- **Motivo:**
  - Un solo binario que cifra en origen y deduplica.
  - El GX10 no necesita disco cifrado, porque solo recibe datos cifrados.
  - En modo append-only, un portátil comprometido no puede borrar la copia externa.
  - borg necesitaría borg instalado también en el GX10.
- **Pérdida aceptada:** lo hecho desde la última copia diaria, o desde el último contacto con el GX10 si se pierde el portátil.
- **Aprobada por:** el operador, el 2026-11-02.
- **SPEC:** sección 4.11. Cierra la decisión abierta de backups de 7.2.

### R20. El cortafuegos sale de la fase 1

- **Decisión:** firewalld (D10) pasa a la fase 1b. Se hará cuando el operador lo decida, antes de la fase 5. Empieza con una auditoría de solo lectura de lo que escucha cada servidor, sigue con un ensayo en `vmiadev` y se aplica en dos pasos, con una puerta de emergencia por la red local.
- **Motivo:**
  - Con R18, la fase 1 apenas toca el GX10.
  - Un error en el cortafuegos obliga a ir físicamente al GX10.
  - Todavía está pendiente comprobar cómo convive firewalld con Docker y NVIDIA.
- **Riesgo conocido mientras tanto:** Docker publica sus puertos en todas las interfaces y se salta ufw. Si vLLM se lanzó con `-p`, puede estar accesible desde la red de casa. La auditoría lo confirmará.
- **Aprobada por:** el operador, el 2026-11-02.

### R21. Escáner y actualizaciones automáticas, después de la fase 3

- **Decisión:** Trivy (escáner de vulnerabilidades) y Dependabot (PRs de actualización de las actions y de los paquetes de Python) se añaden después de la fase 3. Las actualizaciones de digests de imágenes se deciden más adelante, porque Dependabot no las cubre en plantillas Quadlet.
- **Aprobada por:** el operador («no es urgente»).

### R22. Convención de nombres y etiquetas

- **Decisión:** los contenedores, redes, volúmenes y secretos se nombran `<entorno>-<app>[-<pieza>]`. Las redes, `<entorno>-<consumidor>-<proveedor>-net`. Todos llevan las etiquetas `infra.env`, `infra.app`, `infra.component` e `infra.managed-by`. Detalle en SPEC 4.12.
- **Motivo:** el operador quiere saber de un vistazo de quién es cada objeto, para qué sirve y de qué entorno es. El nombre lo hace legible y las etiquetas permiten filtrar con `podman … --filter label=…`, sin herramientas nuevas. Es el mismo patrón que las etiquetas recomendadas de Kubernetes.
- **Comprobado:** `ContainerName=`, `NetworkName=`, `VolumeName=` y `Label=` existen en Quadlet 4.9. Sin los nombres explícitos, Podman antepone `systemd-`.
- **Aprobada por:** el operador, con el merge del PR #5 (2026-11-03).
- **SPEC:** sección 4.12.

## 2026-11-03

### R23. Ansible entra en el portátil por SSH a `127.0.0.1`

- **Decisión:**
  - El portátil es un servidor más del inventario de producción (`laptop`). Ansible entra por SSH, con el usuario del operador, y cambia a `svc_runner` con sudo, igual que en el GX10 (D3).
  - sshd escucha **solo en `127.0.0.1`**, solo con clave y solo para el usuario del operador. Se configura a mano una vez (`docs/SETUP.md`, paso 9), porque Ansible lo necesita para entrar.
  - El contenedor de Ansible usa la red del host (`--network=host` en `ansible-navigator.yml`). En la red propia de Podman, `127.0.0.1` sería el propio contenedor.
- **Motivo:**
  - Ansible corre dentro de un contenedor (D2). Una conexión `local` actuaría dentro del contenedor, no en el portátil.
  - Así no se instala Ansible en el portátil y el portátil se trata igual que el resto.
  - sshd en loopback no abre nada hacia la red.
- **Coste:** el contenedor de Ansible ve los servicios del portátil que escuchan en `127.0.0.1`. Es nuestra imagen, lanzada por el operador.
- **Supuesto sin probar:** que con Podman 5 sin root y `--network=host` el contenedor llega al sshd de `127.0.0.1`. Lo comprueba el operador con `check` contra `laptop`.
- **Aprobada por:** el operador, el 2026-11-03.
- **SPEC:** sección 7.1.

### R24. `deploy.sh` pide siempre la contraseña de sudo

- **Decisión:** `deploy.sh plan` y `apply` pasan `--ask-become-pass` a Ansible. La contraseña se teclea en el terminal; si un playbook no la necesita, basta con pulsar Intro.
- **Por qué no repite el problema de R11:** la contraseña no viaja como variable de entorno ni como argumento, ni se escribe en un fichero. En `mode: stdout`, ansible-navigator 26.10.0 entrega a ansible-runner 2.4.3 la entrada estándar del terminal (`input_fd`), y este lanza el contenedor con `--interactive` (y `--tty` si la entrada y la salida son un terminal). La lee `ansible-playbook` dentro del contenedor y solo la guarda en memoria.
- **Contraseñas distintas por máquina:** Ansible pide una sola por ejecución. La del portátil y la del GX10 no coinciden (confirmado por el operador el 2026-11-03), así que en producción se despliega siempre una máquina cada vez, con `--limit` (`docs/WORKFLOW.md`, paso 6).
- **Usuario:** el del operador, que ya está en `wheel` (Fedora) o `sudo` (Ubuntu). `svc_runner` no tiene sudo ni contraseña.
- **Aprobada por:** el operador, el 2026-11-03 («que la pida siempre»).
- **SPEC:** sección 7.1.

### R25. Exposición de servicios: `127.0.0.1` y `tailscale serve`

- **Decisión:** los contenedores publican solo en `127.0.0.1`. Lo que haya que alcanzar desde otra máquina (el primero, el rest-server del GX10) se expone con `tailscale serve --bg --tcp=<puerto> tcp://localhost:<puerto>`, aplicado por Ansible con sudo.
- **Motivo:**
  - Publicar en la IP de Tailscale puede fallar al arrancar si la interfaz aún no tiene dirección, y un servicio de usuario no puede esperar limpiamente a `tailscaled`, que es un servicio del sistema.
  - Una sola regla para todos los contenedores.
  - Según la [documentación de Tailscale](https://tailscale.com/docs/reference/tailscale-cli/serve), con `--bg` la configuración sobrevive a los reinicios.
- **Pendiente de comprobar en el GX10 (Tailscale 1.104.4):** la documentación no dice si el modo `--tcp` necesita certificados HTTPS ni qué permisos pide.
- **Aprobada por:** el operador, el 2026-11-03. Cierra la decisión abierta de SPEC 7.2.
- **SPEC:** secciones 2, 4.4 y 4.8.

### R26. Retención solo en el repositorio local

- **Decisión:** la retención (borrar copias antiguas) es automática solo en el repositorio restic del portátil. En el GX10 no se borra nada en la fase 1.
- **Motivo:** para borrar, restic necesita la clave del repositorio. Si la retención se hiciera desde el GX10, la clave viviría en un disco sin cifrar, que es justo lo que SPEC 4.11 evita. Con la deduplicación, la copia del GX10 crece poco; se decide más adelante con el tamaño real.
- **Aprobada por:** el operador, el 2026-11-03.
- **SPEC:** sección 4.11. Cambia «la retención se aplica desde el GX10».

### R27. Imagen de PostgreSQL: `pgvector/pgvector:pg18`

- **Decisión:** el Postgres compartido usa la imagen del proyecto pgvector para PostgreSQL 18, fijada por digest. Es la única imagen de Postgres que se actualiza.
- **Motivo:** el operador quiere poder usar embeddings más adelante sin cambiar de imagen. La extensión no se carga hasta `CREATE EXTENSION vector`, así que sin usarla no cuesta nada.
- **Comprobado el 2026-11-03:** trae la misma versión de PostgreSQL que la imagen oficial (18.6), se reconstruyó tres días después que ella e incluye `linux/amd64` y `linux/arm64`. Base Debian 12, frente a Debian 13 de la oficial. En CI: PostgreSQL 18.6 y pgvector 0.8.7.
- **Datos:** PostgreSQL 18 guarda los datos en `/var/lib/postgresql/18/docker`; el volumen se monta en `/var/lib/postgresql`.
- **Aprobada por:** el operador, el 2026-11-03.
- **SPEC:** imagen en `playbooks/group_vars/all/images.yml`.

### R28. Retención: 7 diarias, 12 mensuales y 5 anuales

- **Decisión:** el repositorio local de restic guarda 7 copias diarias, 12 mensuales y 5 anuales (`restic forget --keep-daily 7 --keep-monthly 12 --keep-yearly 5`).
- **Motivo:** el esquema habitual de copias diarias, mensuales y anuales. Los 5 años cubren con margen los 4 años en que Hacienda puede revisar datos fiscales, por si Firefly guarda finanzas. `--keep-yearly 1` solo habría guardado la del año en curso.
- **Validación:** el CI crea copias con fechas inventadas (`restic backup --time`), aplica la retención y comprueba que quedan las esperadas (PR 3/4).
- **Aprobada por:** el operador, el 2026-11-03.
- **SPEC:** sección 4.11.

### R29. `deploy.sh secrets` pide también la contraseña de sudo

- **Decisión:** para instalar los secretos en una máquina hace falta convertirse en `svc_runner`, y eso pide sudo. `deploy.sh secrets` pide la contraseña maestra de KeePassXC y después la de sudo, y las pasa las dos por la entrada estándar del contenedor de Ansible. Dentro, `ansible-playbook --become-password-file scripts/become-password.sh` lee la de sudo, sin que aparezca nunca como argumento ni en un fichero.
- **Motivo:** con `podman run -i` no hay terminal dentro del contenedor, así que `--ask-become-pass` no podría preguntar. ansible-core ejecuta un `--become-password-file` que sea ejecutable y usa lo que imprime (comprobado en el código de ansible-core 2.21.5).
- **Riesgo, el mismo que acepta SPEC 4.5:** dentro del contenedor, la contraseña de sudo queda como variable de entorno solo de ese proceso, igual que la maestra.
- **Una máquina cada vez** (`--limit`), porque las contraseñas de sudo son distintas (R24).
- **Propuesta en:** PR 2/4 de la fase 1.
- **SPEC:** sección 4.5.

### R30. Postgres sin red hasta que tenga consumidores

- **Decisión:** mientras una instancia no tenga consumidores, su contenedor va con `Network=none`. En la fase 2 cada consumidor trae su red aislada (D9) y la instancia se une a ella.
- **Motivo:** en la fase 1 nadie se conecta a Postgres por red; los backups usan `podman exec`. Sin red no publica puertos ni puede salir a ningún sitio.
- **Propuesta en:** PR 2/4 de la fase 1.
- **SPEC:** sección 4.4.

### R31. La firma se configura solo en este repo

- **Corrección:** `SIGNING.md` decía `git config --global` para la firma. Con eso, todos los repos del operador firmaban sus commits y pedían KeePassXC abierto. Ahora todo se configura solo en este repo, y la guía explica cómo deshacer lo global.
- **Por qué basta:** `deploy.sh` verifica los tags con su propia configuración (`-c gpg.ssh.program=ssh-keygen -c gpg.ssh.allowedSignersFile=…`), sin depender de la de git.
- **Detectado por:** el operador, el 2026-11-03.

### R32. `deploy.sh secrets` monta el agente SSH en la misma ruta

- **Corrección:** `deploy.sh secrets` montaba el socket del agente en `/run/ssh-agent.sock`. Si `~/.ssh/config` fija `IdentityAgent` con la ruta del portátil, ssh no encontraba el agente dentro del contenedor y fallaba con `Permission denied (publickey)`. En la fase 0 no se vio porque `secrets` aún no se conectaba a ninguna máquina. Ahora se monta en la misma ruta que en el portátil, como hace ansible-navigator (ansible-runner 2.4.3), y también `/etc/ssh/ssh_known_hosts` si existe.
- **Detectado por:** el operador, el 2026-11-03, con `deploy.sh secrets --env dev --limit vmiadev`.

### R33. Estándar de PostgreSQL del operador

- **Decisión:** las instancias y las bases de las aplicaciones siguen el estándar que el operador ya usaba en `personal-data-platform` (sus ADR 0003 y 0004), adaptado a esta plataforma. Detalle en [`POSTGRES.md`](POSTGRES.md).
- **Un solo modelo por aplicación:** base `<app>` cuyo dueño es `<app>_owner`; tres grupos sin LOGIN (`_owner`, `_writer` y `_reader`); usuarios LOGIN a demanda, cada uno en un grupo; esquema `<app>` con `vector`, sin `public`; solo conectan sus roles y `backup`. Sin grupo `_migrate`.
- **Cambia D8**, de «una base y un rol por aplicación» a «una base y tres grupos por aplicación, con usuarios a demanda». Lo aprobó el operador.
- **Del estándar anterior no se mantienen:** la red compartida `postgres-net` (sigue D9: una red aislada por consumidor), los ficheros de contraseñas (`.pass`, `.pgpass`), sustituidos por KeePassXC y secretos de Podman (D7), y el puerto publicado en el host.
- **Aprobada por:** el operador, el 2026-11-03.
- **SPEC:** D8, sección 4.4 y [`POSTGRES.md`](POSTGRES.md).

### R34. Parámetros fijos de cada instancia

- **Decisión:** superusuario `laperl` (configurable), `POSTGRES_DB=postgres`, `UTF8`, locale `builtin` `C.UTF-8`, zona horaria `UTC`, checksums de datos y `scram-sha-256`. Iguales en todas las instancias.
- **Motivo:** el operador pide que nunca den problemas con ningún idioma ni emoji, que el orden de los textos no cambie al actualizar el sistema base y que las migraciones futuras sean predecibles. El proveedor `builtin` (desde PostgreSQL 17) no depende de glibc ni de ICU. UTC con `timestamptz` es lo estándar para las fechas.
- **`pg-main` se recrea** con estos parámetros mientras está vacía: solo se fijan al crear la base por primera vez.
- **Por comprobar en el CI:** que la imagen admite el proveedor `builtin` y que los checksums quedan activados.
- **Aprobada por:** el operador, el 2026-11-03.

### R35. Quién crea las tablas

- **Decisión:**
  - en las aplicaciones propias, un usuario de migraciones en `_owner` y otro de uso diario en `_writer`;
  - en las de terceros que migran solas (por ejemplo Firefly), un único usuario en `_owner`;
  - los cambios a mano los hace el superusuario con `SET ROLE <app>_owner`;
  - a los usuarios de `_owner` se les fija `ALTER ROLE … SET role = <app>_owner`, para que lo que creen quede a nombre del grupo.
- **Motivo:** el dueño de un objeto es quien lo crea, y los privilegios por defecto solo se aplican a lo que crea `_owner`. Separar el usuario de migraciones del de uso diario es la práctica recomendada. Dar `_owner` solo durante la instalación y quitarlo después es frágil: si se olvida quitarlo, sobran permisos; si no se da al actualizar, la actualización falla.
- **Por comprobar en el CI:** `ALTER ROLE … SET role`.
- **Aprobada por:** el operador, el 2026-11-03.

### R36. `_reader` no puede modificar datos de ninguna forma

- **Decisión:** `_reader` solo tiene acceso al esquema y `SELECT` sobre las tablas. Sin permiso de ejecución sobre las funciones de la aplicación ni sobre las secuencias. Si hiciera falta una función concreta, se concede a mano.
- **Motivo:** el estándar anterior daba `EXECUTE` a `_reader`, y una función `SECURITY DEFINER` le habría permitido modificar datos. El operador lo prohíbe.
- **Comprobación:** el CI verifica que `_reader` no puede insertar, modificar, borrar ni ejecutar una función que escribe.
- **Aprobada por:** el operador, el 2026-11-03.

### R37. pgAdmin como aplicación de la plataforma

- **Decisión:**
  - pgAdmin 4 es una aplicación más de `svc_runner`, desplegada con Ansible en la fase 2;
  - tiene su propia red aislada hacia la instancia y publica solo en `127.0.0.1` del portátil;
  - su contraseña de entrada está en KeePassXC;
  - el superusuario solo puede entrar por TCP desde la subred de pgAdmin, con `scram-sha-256`.
- **Motivo:** el operador administra con pgAdmin. El que tiene en su propio Podman no puede llegar a las redes de `svc_runner`, y Postgres no publica puertos (4.4).
- **Servicio nuevo** (SPEC 8): aprobado por el operador el 2026-11-03.

### R38. Los datos del operador viven fuera de este repo

- **Decisión:** el código (roles, plantillas, playbooks, CI y documentación) sigue en este repo, en GitHub. Los **datos** (inventario, bases, usuarios y configuración de cada aplicación) pasan a un **repo git solo en el portátil**, en el disco cifrado, sin GitHub, con todos sus commits firmados. Su copia de seguridad la hacen los backups de restic (local y GX10, cifrados). Detalle en SPEC 4.13.
- **Motivo:** el operador no quiere que GitHub sepa qué aplicaciones usa ni cómo se llaman sus bases y usuarios. Un repo privado puede acabar visible: en 2022 se robaron repos privados de decenas de organizaciones con tokens de OAuth robados. Separar código y datos es como lo hacen quienes publican sus repos de Ansible. Así este repo es publicable y los datos nunca salen de las máquinas del operador.
- **Se mantiene el control:** en `prod`, `deploy.sh` exige el tag firmado del código y además que el último commit del repo de datos esté firmado por una clave de confianza y sin cambios pendientes.
- **Coste:** los cambios de datos no pasan por el CI de GitHub; se comprueban con `deploy.sh plan`. Claude no ve el repo de datos: cada PR dice qué hay que añadir en él.
- **Descartado:** dejar los datos en este repo privado (quedarían en GitHub) y guardarlos en una carpeta sin git (sin firma, `deploy.sh` desplegaría datos sin aprobar).
- **Aprobada por:** el operador, el 2026-11-03.

### R39. Un solo repo de infraestructura para todas las aplicaciones

- **Decisión:** el despliegue de todas las aplicaciones vive en este repo (código) y en el de datos. Las aplicaciones propias tienen su repo, construyen su imagen y la publican en GHCR (SPEC 5.5); aquí solo se apunta su digest.
- **Motivo:** es lo estándar para una persona. Cada aplicación añade unas pocas plantillas y unas líneas de datos, y tener un solo sitio para `plan`, tag y `apply` simplifica. Si muchas aplicaciones se parecen, se creará un rol genérico «aplicación en contenedor».
- **Aprobada por:** el operador, el 2026-11-03.

### R40. Cómo lee `deploy.sh` el repo de datos

- **Decisión** (implementa R38 en la fase 1c):
  - El repo de datos está en `~/Documents/SECURE_vc/ansible/infra-podman`, en el volumen cifrado. Es un repo solo para este proyecto: la carpeta `ansible/` puede tener otros.
  - Su ruta es la línea `data_repo` de `~/.config/infra-podman/deploy.conf`, y la usan DEV y producción: el inventario de DEV también son datos.
  - Tiene que ser la raíz de su propio repo git, con al menos un commit, y ni el repo de código puede estar dentro del de datos ni al revés.
  - En DEV acepta datos sin commit (el registro lo marca con `+dirty`), para probar antes de firmar. En producción, sin cambios y con el último commit firmado, comprobado con `git verify-commit` contra el mismo `allowed_signers` que los tags y con `ssh-keygen` forzado.
  - `allowed_signers` no puede apuntar a un fichero de ninguno de los dos repos (R4).
  - El registro de despliegues gana una columna, el commit del repo de datos, entre el tag y los hosts (SPEC 4.10). Las líneas anteriores se quedan con siete columnas.
  - El repo de código guarda `inventory.example/`, con nombres inventados y comentado, para el CI y como plantilla.
- **Cómo llega el inventario al contenedor de Ansible:** en `plan` y `apply`, ansible-runner 2.4.3 monta él solo la carpeta del fichero que se pasa con `-i`, en la misma ruta (`_handle_ansible_cmd_options_bind_mounts`). Comprobado en su código y con ansible-navigator 26.10.0 y un `podman` falso. Ese montaje no es de solo lectura; Ansible no escribe en el inventario. En `secrets` se monta en solo lectura.
- **Motivo:** el inventario no debe estar en GitHub (R38) y producción solo debe recibir datos aprobados con la firma del operador.
- **Propuesta en:** PR de la fase 1c.

### R41. Superusuario como dato, y sin `public` ni `vector` en la base `postgres`

- **Decisión** (fase 1d):
  - **El superusuario de cada instancia se declara en el repo de datos** (`superuser:` en `postgres_instances`), sin valor por defecto en el código. Cambia lo que decían R34 y `POSTGRES.md` («`laperl`, configurable»): un nombre de usuario real no va en el código (R38). El operador usa `laperl`. No existe ningún rol `postgres`.
  - **Sin esquema `public`** en la base `postgres` ni en `template1`. Así toda base nueva nace sin él, como ya pedía `POSTGRES.md` para las de las aplicaciones.
  - **Sin extensión `vector` en la base `postgres`**: allí solo entran el superusuario y `backup`, así que no sirve. Cada aplicación la tiene en su propio esquema (fase 2).
  - **Healthcheck por el socket**, comprobando que el servidor definitivo escucha (`listen_addresses` no vacío). Por TCP, cada comprobación quedaba rechazada por `pg_hba.conf` y apuntada como `FATAL` en el log cada 30 segundos.
  - **Ansible no recrea nunca una instancia.** Lee en cada `apply` cómo se creó y, si no coincide con R34, se para con un mensaje que remite a `SETUP.md`, paso 15. Recrear es un paso manual del operador, porque borra datos (D11).
- **Por qué `backup` sigue sin contraseña** (pregunta del operador): solo entra por el socket de dentro del contenedor, y para llegar ahí hay que ser `svc_runner`. Quien puede eso ya lee los ficheros del volumen y la contraseña del superusuario, que Podman guarda sin cifrar (SPEC 4.5). Una contraseña no protegería nada más. Por TCP está rechazado, y el CI lo comprueba.
- **Aprobada por:** el operador, el 2026-11-03.

## 2026-11-04

### R42. Nombre de la instalación, obligatorio, y grupo de KeePassXC

- **Decisión:**
  - Cada instalación de la plataforma tiene un nombre propio, `infra_site`, en `group_vars/all.yml` de su repo de datos: `laperl` para la del operador y, por ejemplo, el de un cliente para la suya. Obligatorio, igual en dev y prod, minúsculas, números y guiones.
  - **El grupo de KeePassXC es ese nombre:** `laperl/<secreto>`. Se acaba el `Infra_Podman` fijo en el código. El lookup lo toma del inventario; sin él, no lee nada, y `playbooks/secrets.yml` se para al empezar.
  - **Sin ambigüedad:** antes de leer, el lookup lista el grupo (`keepassxc-cli ls`) y se para si la entrada no existe o si hay dos con el mismo título. KeePassXC permite títulos repetidos, y entonces no estaba claro cuál se usaba.
  - **Se aplaza, con su disparador en el ROADMAP:** gestionar varias instalaciones desde el portátil (cuando llegue el primer cliente) y alojar backups de clientes en el GX10 (1e2 o después).
- **Motivo:** el operador quiere gestionar en el futuro su infraestructura y la de clientes, con secretos y backups separados por nombre, sin duplicados y sin depender de que no haya errores humanos. Ahora es buen momento: en las máquinas no cambia nada, porque los secretos de Podman no llevan el grupo en su nombre.
- **Corrección incluida:** `secrets.yml` empieza con una parte en `localhost` (comprueba `infra_site` y `--rotate` y lee los secretos de prueba). Con `--limit <máquina>`, que es como se usa siempre desde R24, Ansible se la saltaba sin avisar: «skipping: no hosts matched». `deploy.sh secrets` añade ahora `localhost` al `--limit`. Detectado por el operador en DEV el 2026-11-04.
- **Comprobado:** pruebas unitarias con un `keepassxc-cli` falso; en el sandbox, con `keepassxc-cli` 2.7.6 real y una base con dos entradas de título repetido, creada con pykeepass porque `keepassxc-cli add` no permite crearlas: `ls` lista el título dos veces y el lookup se para. En el CI, `tests/ee` con la 2.8.0 de la imagen.

### R43. Backups locales (fase 1e1)

- **Decisión:**
  - **La fase 1e se divide en dos PR:** 1e1, copias locales; 1e2, copia al GX10. El GX10 tiene sus propios riesgos: disco al 97 %, otra contraseña de sudo y `tailscale serve --tcp` sin comprobar.
  - **Un contenedor Quadlet de un solo uso** (`<entorno>-backup`, `Type=oneshot`), arrancado solo por `<entorno>-backup.timer` a las 13:00, con `Persistent=true`. Así se cumple D1 también para los backups. Ni un `apply` ni el arranque de la máquina lanzan una copia: `quadlet_deploy` gana `quadlet_deploy_start: false` para no arrancarlo ni reiniciarlo.
  - **Separación de permisos:** los volcados los hace el servicio en el host (`ExecStartPre`), con `podman exec` y el rol `backup`. El contenedor de restic no tiene red y solo ve la carpeta temporal, sus scripts y el repositorio; no puede llegar a Postgres. Al terminar, `ExecStopPost` borra los volcados sin cifrar.
  - **Una copia por cosa**, etiquetada `site` (el nombre de la instalación, R42), `env`, `app`, `type` y `reason`. La retención 7/12/5 se agrupa también por etiquetas. Sin eso, la copia diaria del mismo día sustituía a la hecha antes de un cambio de imagen, que es justo la que permite volver atrás. Lo destapó el CI.
  - **Repo de datos:** `deploy.sh` deja tras cada ejecución correcta una copia (`git bundle`, de git) en `/var/lib/infra-podman/data-repo`, legible solo por el operador y `svc_runner`. El servicio de backup no puede leer la carpeta del operador, y `SECURE_vc` puede no estar montado a esa hora. Esa copia queda fuera de VeraCrypt, protegida por el LUKS del portátil; solo contiene el inventario, sin secretos. Aprobado por el operador.
  - **Aviso:** `<entorno>-backup.status` en `/var/lib/infra-podman/backup-status` (fechas y un mensaje en español, nunca datos). Un temporizador en la sesión del operador lo lee cada hora y muestra una notificación de escritorio (`notify-send`, ya presente en Sway) si la última copia falló o tiene más de 36 horas. Se instala en la cuenta del operador; `SETUP.md`, paso 17, dice cómo quitarlo. Todo queda en journald.
  - **Antes de cambiar la imagen de Postgres**, el rol `postgres` lanza el backup (`reason=pre-upgrade`) y espera; si falla, no cambia la imagen (D11).
  - **Restauración con `--exclude-xattr '*'`:** restic guarda los atributos extendidos de las carpetas y, si el destino no los admite, termina con error aunque restaure los ficheros.
  - **Sin copia de volúmenes de aplicaciones todavía:** no hay ninguno y, en Fedora, montar el volumen de otro contenedor choca con SELinux. Pasa a la fase 2 (ROADMAP).
- **Comprobado en `lifecycle`** (Ubuntu 24.04, Podman 4.9.3): copia, restauración de una base con los mismos datos, roles sin contraseñas, repo de datos clonable, fallo con mensaje, retención R28 con 37 copias de fechas inventadas (quedan las 20 esperadas), copia antes del cambio de imagen que sobrevive a la diaria, segundo `apply` con cero cambios y la clave nunca en los logs ni en el journal.
- **Aprobada por:** el operador, el 2026-11-04.

### R44. Copia de los backups al GX10 (fase 1e2)

- **Decisión:**
  - **Servidor:** rest-server 0.14.0 de restic en el GX10, como contenedor Quadlet `<entorno>-backup-server` (D1), con su volumen `<entorno>-backup-server-data`. Opciones `--append-only` (se puede añadir, nunca borrar ni cambiar), `--private-repos` y `--max-size`. Solo en `127.0.0.1:18000`, expuesto con `tailscale serve --bg --tcp=18000` (R25). Ansible añade solo ese puerto y nunca toca ni reinicia el resto de la configuración de `tailscale serve`.
  - **Con usuario y contraseña:** el usuario es el nombre de la instalación (`infra_site`), y con `--private-repos` solo entra en su carpeta. Sin contraseña, cualquier equipo de Tailscale (el móvil, la VM DEV o, en la fase 5, los agentes) podría descargarse las copias cifradas o subir basura hasta el tope. La contraseña es `<instalación>/backup-server-password` en KeePassXC; en el GX10 solo se guarda su hash (bcrypt), que genera el `htpasswd` de la propia imagen. Un `apply` comprueba que el hash corresponde al secreto, de modo que un `--rotate` se aplica solo.
  - **Para recuperar los datos basta la clave de restic:** si el servidor falla o se pierde su contraseña, las copias se leen directamente del volumen en el GX10 (`SETUP.md`, paso 18). Probado en `lifecycle`.
  - **Carpeta del repositorio:** `<instalación>/<entorno>-<máquina>`, por ejemplo `laperl/prod-laptop`. El ROADMAP proponía `laperl/prod/laptop`, pero rest-server solo admite dos niveles de carpeta (`MaxFolderDepth = 2` en su código): con tres, crear el repositorio da `404`. Lo destapó el CI. Misma clave que el repositorio local (`backup-restic-password`), aprobado por el operador: una entrada menos y la misma protección, porque las dos viven en el mismo `.kdbx`.
  - **Tope de 30 GB**, aviso al 80 %. El repositorio local ocupaba 23 kB el 2026-11-05 y el GX10 tenía 146 GB libres. Se cambia en el repo de datos (`backup_server_max_size_gb`), y lo leen el servidor y el portátil.
  - **Copia:** un segundo contenedor de un solo uso en el portátil, `<entorno>-backup-copy`, cada hora (minuto 30) con `restic copy`. Solo ve el repositorio local cifrado (en solo lectura), sus scripts, una carpeta para su resultado y las dos claves. El contenedor de la 1e1 sigue sin red. La primera vez crea el repositorio del servidor con los mismos parámetros que el local (`--copy-chunker-params`), para que la deduplicación funcione.
  - **SELinux:** el repositorio local está marcado como privado del contenedor de backup (`:Z`). El de copia lo monta sin volver a marcarlo y sin etiqueta propia (`SecurityLabelDisable=true`), como la orden manual de `SETUP.md` 17.5. Sigue sin root, de solo lectura y sin capacidades. **Por comprobar en el portátil.**
  - **Si el servidor no responde,** la copia termina sin error (código 75) y lo vuelve a intentar a la hora siguiente.
  - **Avisos** (el mismo aviso de escritorio de la 1e1): si una copia falla; si pasan más de 7 días sin una copia correcta en el servidor; y si el servidor pasa del 80 % de su tope. Cada mensaje dice en español qué ha pasado y qué hacer.
  - **DEV y CI no tienen Tailscale:** cliente y servidor en la misma máquina; la copia comparte la red del servidor (`Network=container:<entorno>-backup-server`). La VM DEV no usa el GX10 aunque pudiera llegar a él a través del portátil: no toca nada de producción (R2, R17).
  - **Secretos para dos grupos:** `group:` de `infra_secrets` acepta una lista, porque la contraseña del servidor la necesitan las dos puntas (`[backup_clients, backup_servers]`).
  - **Backups de clientes, más adelante (ROADMAP):** un rest-server aparte por instalación, con su contenedor, su volumen, su puerto y su tope. Nada de este diseño lo impide.
- **Comprobado en `lifecycle`** (Ubuntu 24.04, Podman 4.9.3), con cliente y servidor en el mismo runner: servidor solo en `127.0.0.1`, sin acceso sin contraseña ni con una equivocada, sin acceso a la carpeta de otra instalación y con solo el hash guardado; copia, copia sin cambios, copia de un backup nuevo, borrado rechazado por el servidor, servidor que no responde (sin error), servidor lleno (fallo con mensaje), restauración desde el volumen del servidor sin pasar por él, segundo `apply` con cero cambios y ninguna contraseña en los logs ni en el journal. Los mensajes y avisos, con pruebas propias (`tests/backup/run.sh`).
- **Comprobado en el GX10** (Tailscale 1.104.4, `v0.5.0`, 2026-11-05): `tailscale serve --tcp` funciona sin pedir nada más; el puerto 18000 queda solo dentro de la red de Tailscale y la página que ya había no cambia. El segundo `apply backup-server` da `changed=0`, así que Ansible lee bien `tailscale serve status --json`.
- **Aprobada por:** el operador, el 2026-11-05.

## 2026-11-07

### R45. Redes internas por consumidor, subred elegida por Podman y contraseñas desde el secreto (fase 2)

- **Decisión:**
  - **Red de cada consumidor interna** (`Internal=true`) además de aislada (`isolate=true`, D9): ni el consumidor ni Postgres tienen salida a internet, a la red de casa o al host. Comprobado con Podman 4.9.3 sin root: un contenedor de una red interna no tiene ruta de salida, pero sí resuelve por nombre a los de su red; otro consumidor no ve a Postgres por la red ajena ni resuelve sus contenedores, y Postgres no reenvía paquetes de una red a otra (`ip_forward` a 0).
  - **Sin DNS hacia fuera:** cada red lleva `DNS=127.0.0.1`. En Podman 4.9 el DNS de una red interna reenvía al host lo que no es un contenedor; lo destapó `lifecycle` ([`COMPATIBILITY.md`](COMPATIBILITY.md)).
  - **Sin subred fija.** La elige Podman al crear la red, sin solaparse con sus otras redes, y Ansible la lee (`podman network ls`) para escribir `pg_hba.conf`. Una red que aún no existe no tiene línea: sus usuarios quedan rechazados. Cambia la sección 4.4, que pedía una subred fija en cada `.network`: el operador no quiere un inventario de direcciones a mano.
  - **Contraseña de cada usuario desde su secreto de Podman,** en cada `apply`. Ansible calcula el SCRAM-SHA-256 en el servidor y envía solo eso: según la documentación de PostgreSQL, una contraseña ya cifrada se guarda tal cual, y una en claro podría acabar en su log. Si ya coincide, no envía nada. Por eso la rotación de estos usuarios es: secreto, `apply`, reiniciar el consumidor (SPEC 4.5).
  - **Altas, cambios y bajas** por el fichero: lo que se quita se borra, con las salvaguardas de [`POSTGRES.md`](POSTGRES.md), sección 7 (aprobadas por el operador el 2026-11-07).
- **Vuelta atrás:** el código de la fase 1 no conoce las bases; con él, Postgres vuelve a `Network=none` y conserva los datos. Probado en `lifecycle`.
- **Aprobada por:** el operador, el 2026-11-07.
- **SPEC:** 4.4, 4.5 y [`POSTGRES.md`](POSTGRES.md).

### R46. Límites de recursos en todos los contenedores, como variables

- **Decisión:** todo contenedor lleva tope de memoria, de procesador y de procesos, como variables con valor por defecto que se cambian en el inventario. Se mantiene `PodmanArgs=--memory … --cpus …` (fase 0, [`COMPATIBILITY.md`](COMPATIBILITY.md)), no `MemoryMax=` en `[Service]`.
- **Motivo:** el operador lo pide como requisito general. `MemoryMax=` también funcionaría, pero limita el servicio entero: Quadlet arranca los contenedores con `--cgroups=split`, que separa `conmon` y la aplicación en dos grupos dentro del del servicio (documentación de Podman 4.9.3). `--memory` limita solo la aplicación, se ve en `podman inspect` y, si se pasa, Podman lo anota (`OOMKilled`), lo que se puede probar. Podman ya pone 2048 procesos por defecto cuando el sistema lo permite; en el portátil, `svc_runner` tiene los controladores `cpu`, `io`, `memory` y `pids` (comprobado por el operador el 2026-11-07).
- **Aprobada por:** el operador, el 2026-11-07.
- **SPEC:** 4.14.

### R47. Un lanzador en el menú para cada aplicación de escritorio

- **Decisión:** cada aplicación que el operador abre desde el escritorio (Firefly, pgAdmin y las que lleguen) tiene un `.desktop` que Ansible instala en su cuenta, en `~/.local/share/applications`. El menú del portátil es rofi en modo `drun`, que lee esa carpeta.
- **Aprobada por:** el operador, el 2026-11-07. Se implementa con Firefly.
- **SPEC:** 4.14.

### R48. Toda aplicación admite varias instancias

- **Decisión:** cualquier aplicación (Firefly, pgAdmin y las que lleguen) se despliega por instancias, aunque haya una sola, como ya hace Postgres (D8). Cada rol recibe una lista (`<app>_instances`) y el playbook lo aplica una vez por instancia. Cada instancia tiene su nombre (`^[a-z0-9]{1,14}$`), su puerto, su imagen, su red con su subred, su volumen, sus secretos y su lanzador. Nada se comparte entre instancias. **En Postgres, cada instancia tiene su propia base de datos, con un único esquema del mismo nombre; nunca dos instancias en la misma base**, aunque varias aplicaciones e instancias compartan la misma Postgres. Puertos desde el 18100, elegidos por el operador. Detalle en [`services/README.md`](services/README.md).
- **Motivo:** lo pide el operador como regla general, para tener instancias de uso, canary y test. Es el patrón de `postgres_instances` y el de los roles de sistema de Podman (`linux-system-roles.podman`, lista `podman_quadlet_specs`). La base por instancia, y no el esquema compartido, la eligió el operador: aísla más y cada instancia se copia y restaura sola.
- **Aprobada por:** el operador, el 2026-11-08. Firefly es la primera aplicación que la cumple (PR 3 de la fase 2).
- **SPEC:** 4.12.

### R49. Cada aplicación tiene un nombre corto en lo que se crea

- **Decisión:** lo que una aplicación crea en la máquina (contenedores, volúmenes, bases, usuarios, redes, secretos, etiquetas) lleva su **nombre corto**, no el entero. Firefly III es **`ff`**: la instancia `laptop` es `prod-ff-laptop`, su base `ff_laptop`, su red `prod-ff-laptop-pg-<postgres>-net` y su clave `ff-laptop-app-key`. En el código y el inventario la aplicación conserva su nombre entero (`roles/firefly`, `firefly_hosts`, `firefly_instances`, `firefly_image`), para que se sepa qué es. El nombre corto vive en una sola variable del rol (`firefly_short`), no en el inventario. El operador solo escribe la instancia, y el código rechaza guiones en ella: un nombre entero no puede acabar duplicado (`prod-ff-prod-ff-laptop`).
- **Motivo:** lo pide el operador (nombres como `prod-ff-laptop`). La tabla de nombres cortos está en [`services/README.md`](services/README.md), apartado 3.
- **Aprobada por:** el operador, el 2026-11-11.
- **SPEC:** 4.12.

### R50. Una sola regla de nombres

- **Decisión:**
  - **Un identificador por instancia**, `<corto>-<instancia>` (`ff-laptop`). Todo lo suyo cuelga de él con `-`: contenedor `prod-ff-laptop`, red `prod-ff-laptop-pg-<postgres>-net` (el `consumer:` de Postgres es ese identificador) y secretos `ff-laptop-app-key` y `ff-laptop-db-password`.
  - **Solo dentro de Postgres** el `-` pasa a `_`: base, esquema y usuario `ff_laptop`, porque Postgres no admite `-` en un nombre sin comillas. Fuera, la regla de los nombres DNS (RFC 1123): minúsculas, cifras y `-`.
  - **La contraseña de cualquier usuario de base** es `<usuario>-db-password` con `-` en lugar de `_`. Sustituye a `pg-<instancia>-<usuario>-password`. Un nombre de usuario no se repite en dos instancias de Postgres de una máquina; si se repite, el `apply` se para.
  - `test_dummy` pasa a `test-dummy`.
  - **El entorno** va delante de todo lo que corre en las máquinas (`prod-…`), y nunca en los títulos de KeePassXC: allí lo separa el fichero (`infra-dev.kdbx`, `infra-pro.kdbx`).
- **Motivo:** el operador veía los nombres incoherentes: `ffdevlaptop`, `ff_devlaptop` y `ff-devlaptop` para lo mismo, y secretos de una aplicación repartidos. El entorno se mantiene en las máquinas para que un error entre dev y prod se vea.
- **Aprobada por:** el operador, el 2026-11-11. Corrige R49 en el consumidor y en el nombre de las contraseñas.
- **SPEC:** 4.5, 4.12.
