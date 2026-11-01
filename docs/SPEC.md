# Especificación: plataforma Podman + Ansible

Versión 1 · 1 de noviembre de 2026 · Operador: @Jau

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

**Máquinas**

| Rol | Equipo | Sistema | Podman | Notas |
| --- | --- | --- | --- | --- |
| Nodo de control (PRO) | Portátil, solo CPU, 16 GB RAM | Fedora Atomic Sway 44 | El de Fedora 44 (Podman 6) | Ejecuta Ansible y KeePassXC. Disco cifrado con LUKS y VeraCrypt: **no volver a preguntar**. Aloja la VM DEV |
| DEV | VM dentro del portátil | A definir en la fase 0 | — | Pruebas locales con opencode e IA local. Sin credenciales de producción |
| Servidor principal | ASUS Ascent GX10, ARM64, 128 GB, GPU con CUDA 13 | DGX OS 7 (Ubuntu 24.04) | **4.9** | Docker con vLLM. Se queda en Ubuntu 24.04: ASUS solo soporta DGX OS y DGX OS 8 aún no admite este equipo |
| Servidor opcional | Lenovo x86 con GPU NVIDIA | Fedora Atomic Sway 44 | 6 | Parado. Solo se usará si hace falta. El diseño no debe depender de él |

**Excepción Docker en el GX10:** vLLM corre en Docker porque Podman 4.9 no ve la GPU con CUDA 13 (comprobado por el operador). Fuera de alcance de migrar.

**Red:** todo va por Tailscale. Ningún puerto expuesto a internet. Los servicios publican solo en `127.0.0.1` o en la IP de Tailscale del host.

**Prioridad de servicio:** best effort. Lo primero es la integridad de los datos y la sencillez de recuperación, por delante de la alta disponibilidad.

**Servicios previstos:** Postgres (una instancia compartida más, como mucho, una de test), Firefly III, LiteLLM (ya funcionando contra vLLM), instancias de OpenClaw, SearXNG, un servicio de audio y proyectos propios (por ejemplo `rag`) que publican imagen.

## 3. Decisiones cerradas (no reabrir)

| # | Decisión |
| --- | --- |
| D1 | Todos los contenedores Podman se gestionan con systemd mediante **Quadlet**, rootless |
| D2 | Despliegue con **Ansible** desde el portátil, ejecutado con **ansible-navigator** y una imagen de entorno de ejecución (Execution Environment) en Podman |
| D3 | **Un solo usuario de servicio** en cada servidor (variable `service_user`, por defecto `svc_runner`), con `loginctl enable-linger`. Ansible entra por SSH con el usuario del operador y cambia al de servicio. Un segundo usuario solo se añadirá si se cumple un disparador (sección 7) |
| D4 | **Plantillas Quadlet nativas por servicio** (`.container.j2`, `.network.j2`, `.volume.j2`), sin un lenguaje intermedio propio en YAML |
| D5 | **Compatibilidad mínima: Podman 4.9.** Ver la sección 4.3 |
| D6 | **Imágenes fijadas por digest**, nunca etiquetas móviles. Para imágenes multiarquitectura se fija el digest del índice (manifest list) y se comprueba que incluye `linux/arm64` |
| D7 | **Secretos:** KeePassXC es la copia maestra; los secretos de Podman son el mecanismo de entrega. Lookup propio que invoca `keepassxc-cli`, la herramienta oficial de KeePassXC. Ver la sección 4.5 |
| D8 | **Un único Postgres compartido**, con una base y un rol por aplicación, más como mucho una instancia de test |
| D9 | **Una red por consumidor de Postgres**, todas con `isolate=true` (comprobado que funciona en el GX10) |
| D10 | **Cortafuegos: firewalld** en todos los servidores. Nada de ufw |
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
  execution-environment.yml    # imagen de Ansible (ansible-builder)
  inventory/  group_vars/  host_vars/
  plugins/lookup/kdbx.py       # lookup propio que invoca keepassxc-cli
  roles/
    host_base/                 # usuario de servicio, linger, firewalld
    quadlet_deploy/            # copia, valida y activa Quadlets
    postgres/  firefly/  ...   # un rol fino por servicio con sus plantillas
  playbooks/
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

### 4.4 Redes y Postgres

- Una red por consumidor de Postgres (por ejemplo `firefly-pg-net`), con `Options=isolate=true` y subred fija declarada en el `.network`.
- El contenedor de Postgres se une a todas esas redes. Los consumidores no se ven entre sí.
- En Postgres, una base y un rol por aplicación, y en `pg_hba.conf` cada rol solo se admite desde la subred de su red.
- Postgres **no publica puertos** en el host.
- Los servicios accesibles por el operador publican en `127.0.0.1` y se exponen con `tailscale serve`, o en la IP de Tailscale. La elección está abierta (sección 7).

### 4.5 Secretos

- **Copia maestra:** `infra-pro.kdbx` en el portátil, con rutas `Infra_Podman/<secreto>`. En DEV, `infra-dev.kdbx` con las mismas rutas y valores ficticios. La bóveda personal nunca se toca.
- **Lectura:** lookup propio `plugins/lookup/kdbx.py` que invoca `keepassxc-cli show -q -s -a password <base> <entrada>`, instalado en la imagen de Ansible. `deploy.sh secrets` pide la contraseña maestra con `read -s` y la pasa como variable de entorno al proceso; el lookup se la entrega a `keepassxc-cli` por la entrada estándar, **nunca como argumento** (los argumentos son visibles en la lista de procesos). Nunca se escribe en disco ni en logs. Cada consulta vuelve a descifrar la base, lo que es aceptable porque solo ocurre al crear o rotar secretos. No se usa la colección `viczem.keepass`.
- **Sustituible:** el lookup es la única pieza que sabe cómo se leen los secretos. Si `keepassxc-cli` no convence, se cambia su implementación (por ejemplo, a la librería pykeepass) sin tocar playbooks ni roles.
- **Creación:** `containers.podman.podman_secret` con `no_log: true`. Solo se lee KeePassXC si el secreto **no existe** en el servidor o si se pide rotarlo. Un despliegue normal no pide la contraseña.
- **Entrega:** como fichero (`Secret=nombre,type=mount,target=/ruta,mode=0400`). Para Postgres, `POSTGRES_PASSWORD_FILE`. Variables de entorno solo si la aplicación no admite fichero.
- **Riesgo residual conocido:** Podman guarda los secretos en el disco del servidor sin cifrar, porque es el único driver disponible.
- **Rotación en Postgres:** primero `ALTER ROLE` en la base, después actualizar el secreto con `force` y por último reiniciar los consumidores. Cambiar solo el secreto no cambia la contraseña guardada.
- **Inventario:** `docs/SECRETS_INVENTORY.md` con nombre, ruta en KeePassXC, consumidores y política de rotación. Nunca valores.

### 4.6 Cortafuegos

- firewalld con backend nftables en los servidores. En el GX10: instalarlo y desactivar ufw si está activo. Docker se integra con firewalld creando su propia zona.
- Entrada: solo por `tailscale0`, incluido SSH. Gestionado por Ansible.
- Nunca vaciar el conjunto de reglas completo (`flush ruleset`): borraría las de Docker y las de netavark.
- **Control de salida de los agentes:** diferido a la fase de OpenClaw (sección 6).

### 4.7 Excepción Docker

vLLM sigue en Docker y Ansible no lo gestiona en esta etapa. LiteLLM lo alcanza mediante `vllm_host` y `vllm_port`. Hoy LiteLLM usa solo clave maestra; su Postgres (necesario para las virtual keys) llegará más adelante, dentro del Postgres compartido.

### 4.8 Observabilidad

- `prometheus-podman-exporter` como **servicio systemd de usuario**, no como contenedor con el socket de Podman montado. Escucha solo en la IP de Tailscale o en `127.0.0.1`, y se añade como objetivo al Prometheus existente.
- Logs en journald. El análisis de logs con IA queda diferido.

### 4.9 Endurecimiento de contenedores de agentes

Para OpenClaw, SearXNG y el servicio de audio: `NoNewPrivileges=true`, `DropCapability=ALL` (y añadir solo lo imprescindible), `ReadOnly=true` donde se pueda con volúmenes o tmpfs para escrituras, límites de memoria, y **nunca** el socket de Podman o de Docker ni red de host. Comprobar que cada clave existe en Quadlet 4.9.

### 4.10 deploy.sh

- `deploy.sh plan <playbook> [--limit]`: ejecuta `--check --diff` y muestra el plan.
- `deploy.sh apply <playbook> [--limit]`: aplica. Lo lanza solo el operador.
- `deploy.sh secrets [--rotate nombre]`: pide la contraseña de KeePassXC y crea o rota secretos.
- Antes de `plan` o `apply` contra producción, comprueba que el checkout es un **tag firmado** válido (`git verify-tag`).
- Cada ejecución deja una línea en un registro local: fecha, tag, hosts, acción y resultado.

## 5. CI/CD, firma y flujo de cambios

### 5.1 Flujo de un cambio

1. El operador describe la idea. Claude trabaja en una rama y abre un PR en borrador.
2. El CI se ejecuta en cada push. Claude corrige en el mismo PR hasta que está en verde, con un máximo de 5 intentos por el mismo fallo; después pregunta.
3. El operador revisa y, si es un servicio nuevo, lo prueba en DEV.
4. Merge a `main` y **tag firmado** creado por el operador.
5. En el portátil: `deploy.sh plan`, revisión y `deploy.sh apply`.

### 5.2 Repositorio en GitHub (privado)

- **Protección de `main`: diferida.** En una cuenta gratuita, GitHub no aplica la protección de ramas ni los rulesets en repos privados; hace falta GitHub Pro, Team o Enterprise. Mientras tanto, `main` se cambia solo por PR mergeado con **Squash and merge**, por disciplina del operador. Si se pasa a un plan de pago, se activan: solo por PR, CI en verde obligatorio, commits firmados, sin force-push ni borrado, y 0 aprobaciones obligatorias (GitHub no deja aprobar el propio PR).
- **El control efectivo es el tag firmado:** `deploy.sh` solo despliega desde un tag firmado con la clave SSH del operador, que vive en su KeePassXC. Un cambio que llegue a `main` por error no alcanza los servidores sin esa firma.
- Claude trabaja solo en ramas y PRs (regla de `CLAUDE.md`). Hoy GitHub no lo impide técnicamente: es una regla de proceso, no un control. No crea tags ni accede a secretos de Actions de producción.
- Ajustes del repo: solo **Squash and merge** permitido y borrado automático de ramas tras el merge.
- Antes de hacer público cualquier repo: escaneo del historial completo en busca de secretos.

### 5.3 Firma con SSH

- Git configurado con `gpg.format ssh` y `user.signingkey` apuntando a la clave pública. La privada la sirve el agente SSH de KeePassXC.
- El repo incluye un fichero de firmantes permitidos (`gpg.ssh.allowedSignersFile`), para que `git verify-tag` funcione en el portátil.
- La clave pública se sube a GitHub como clave de firma, para que los commits aparezcan verificados.

### 5.4 Workflows del repo de infraestructura

| Workflow | Cuándo | Qué hace |
| --- | --- | --- |
| `lint` | Cada push | yamllint, ansible-lint, shellcheck de `deploy.sh` y validación de las plantillas Quadlet renderizadas con el generador de Podman |
| `lifecycle` | PR que toca un rol | En un runner `ubuntu-24.04-arm` (misma base y arquitectura que el GX10) con Podman rootless: desplegar, esperar healthcheck, reaplicar (cero cambios) y destruir conservando el volumen. Usa secretos aleatorios generados en el propio CI, nunca KeePassXC |
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
| **1. Postgres** | Rol `host_base` en el GX10 (usuario de servicio, linger, firewalld y ufw desactivado); Postgres con volumen, secreto como fichero y healthcheck; backup y restauración (herramienta por decidir); workflow `lifecycle` | `apply` correcto y un segundo `apply` con cero cambios; sobrevive a un reinicio del servidor; no publica puertos; backup restaurado con éxito en una prueba; ningún secreto en repo ni logs |
| **2. Firefly III** | Red `firefly-pg-net` con `isolate=true`; base, rol y regla `pg_hba` propios; espera a Postgres según 4.3; exposición al operador | Firefly solo arranca con Postgres sano; no alcanza otras redes; al destruirlo se conserva su volumen |
| **3. Observabilidad** | `prometheus-podman-exporter` como servicio de usuario y objetivo en el Prometheus existente | Métricas visibles en el Grafana actual |
| 4. LiteLLM (más adelante) | Pasar LiteLLM a Quadlet con `vllm_host` y `vllm_port`; su base en el Postgres compartido cuando lleguen las virtual keys | LiteLLM responde igual que hoy |
| 5. Agentes (más adelante) | OpenClaw, SearXNG y audio con el endurecimiento de 4.9; control de salida por usuario tras una prueba previa (sección 7); evaluar el disparador del segundo usuario | Un contenedor de agente no alcanza la LAN, Tailscale ni Postgres salvo lo permitido |
| 6. Análisis de logs (más adelante) | Exportar journald, limpiar datos sensibles y analizar con el vLLM local en solo lectura, sin herramientas | Un log con instrucciones maliciosas no provoca ninguna acción |

Las fases 0 a 3 son el alcance actual. Las 4 a 6 se diseñan en detalle cuando lleguen.

## 7. Verificaciones pendientes y decisiones abiertas

### 7.1 Verificar antes o durante la fase indicada

Son supuestos razonables pero no comprobados. Si alguno falla, detente y propón alternativa.

| Fase | Qué verificar |
| --- | --- |
| 0 | Cómo instalar ansible-navigator en Fedora Atomic 44 y que la imagen de Ansible funcione con Podman 6 y el reenvío del agente SSH |
| 0 | Que `keepassxc-cli` dentro de la imagen de Ansible abre un `.kdbx` guardado con KeePassXC 2.8, cómo se instala en esa imagen y qué versión trae |
| 0 | Que `keepassxc-cli` acepta la contraseña maestra por la entrada estándar sin terminal. La documentación oficial describe `-q` (silencia la petición de contraseña) y `-s`/`-a`, pero no detalla este comportamiento |
| 0 | Que Ansible no evalúa el lookup de KeePassXC en una tarea saltada (`when:` falso) cuando el secreto ya existe |
| 1 | Que el runner `ubuntu-24.04-arm` permite instalar Podman 4.9 y usarlo en modo rootless para el workflow `lifecycle` |
| 1 | Que instalar firewalld en DGX OS convive con Docker y con la pila de NVIDIA |
| 1 | En la página oficial de facturación de GitHub, que el almacenamiento y la transferencia de imágenes en GHCR siguen siendo gratuitos |
| 2 | Que el patrón de espera con `ExecStartPre` funciona en 4.9 y respeta `TimeoutStartSec` |
| 3 | Cómo se instala `prometheus-podman-exporter` en Ubuntu 24.04 ARM64 (paquete o binario) |
| 5 | Que una regla nftables por usuario captura el tráfico de salida de slirp4netns, y qué excepciones de DNS hacen falta (incluido el DNS de Tailscale, 100.100.100.100) |
| 5 | Que las claves de endurecimiento de la sección 4.9 existen en Quadlet de Podman 4.9 |

### 7.2 Decisiones abiertas (proponer y esperar aprobación)

| Tema | Opciones conocidas |
| --- | --- |
| Backups de Postgres y volúmenes | Herramienta (restic, borg u otra) y destino fuera del GX10 |
| Exposición de servicios al operador | `tailscale serve` hacia `127.0.0.1`, o publicar en la IP de Tailscale. Inferencia a comprobar: publicar en esa IP puede fallar al arrancar si la interfaz aún no tiene dirección |
| Prometheus y Grafana existentes | Dónde corren exactamente y si sus objetivos se gestionan desde Ansible o a mano |
| Escáner de vulnerabilidades en CI | Por elegir |
| Propuestas automáticas de actualización de digests | Herramienta por elegir. Siempre como PR, nunca aplicación automática |
| Sistema de la VM DEV | Por definir. Debe permitir probar contra Podman 4.9 |
| Plan de GitHub | Gratuito ahora. GitHub Pro activaría la protección de `main` según la documentación oficial, pero el aviso de la interfaz menciona cuentas Team; comprobar que desaparece antes de dar por hecho que funciona |

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
- Preguntar de nuevo por el cifrado del portátil: ya está resuelto.

## 9. Fuentes de referencia

Verificadas en noviembre de 2026. Para cualquier detalle técnico, manda la documentación oficial de la versión instalada.

**Podman y Quadlet**

- [Manual de Quadlet en Podman 4.9 (Ubuntu 24.04)](https://manpages.ubuntu.com/manpages/noble/man5/quadlet.5.html): validación con el generador y `QUADLET_UNIT_DIRS`.
- [Notas de Podman 5.0](https://github.com/containers/podman/releases/tag/v5.0.0): llegada de `Notify=healthy` y ficheros `.pod`.
- [Cambios de Podman 5.0](https://blog.podman.io/2024/03/podman-5-0-breaking-changes-in-detail/): paso de slirp4netns a pasta.
- [Podman 6 en Fedora 44](https://fedoraproject.org/wiki/Changes/Podman6): eliminación de slirp4netns.
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
