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
  - En el portátil, cada hora, `pg_dump` de cada base y copia de los volúmenes de datos a un repositorio restic local.
  - Cuando el GX10 está alcanzable, copia a un rest-server de restic en el GX10 en modo `--append-only`, desde el que se aplica la retención.
  - restic y rest-server corren como contenedores Quadlet.
- **Motivo:**
  - Un solo binario que cifra en origen y deduplica.
  - El GX10 no necesita disco cifrado, porque solo recibe datos cifrados.
  - En modo append-only, un portátil comprometido no puede borrar la copia externa.
  - borg necesitaría borg instalado también en el GX10.
- **Pérdida aceptada:** lo hecho desde el último contacto con el GX10, si se pierde el portátil.
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
