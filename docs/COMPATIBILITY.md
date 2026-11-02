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
| `Notify=healthy` | Lo acepta sin error (código de salida 0) | `scripts/quadlet_policy.py` |
| Fichero `.pod` | Lo ignora en silencio. Solo falla la clave `Pod=` del `.container` | `scripts/quadlet_policy.py` |
| Imagen sin digest (`:latest`) | Solo da un aviso si el nombre no es completo; con nombre completo, nada | `scripts/quadlet_policy.py` |
| Opciones de slirp4netns o pasta | Las acepta: son válidas en 4.9 | `scripts/quadlet_policy.py` |
| Socket de Podman o Docker montado | Lo acepta | `scripts/quadlet_policy.py` |
| Directorio sin ficheros | Falla con `No files parsed` | `scripts/validate-quadlets.sh` lo trata como «nada que validar» |

Por eso el CI ejecuta dos comprobaciones: la política del repo y el generador. Cada caso tiene una plantilla de prueba en `tests/quadlet/fixtures/invalid/`, que el CI exige que se rechace por el motivo correcto.

## Claves comprobadas contra el generador 4.9

Aceptadas: `NoNewPrivileges`, `DropCapability`, `AddCapability`, `ReadOnly`, `ReadOnlyTmpfs`, `Tmpfs`, `UserNS`, `Secret` (con `type=mount,target=…,mode=…`), `HealthCmd`, `HealthInterval`, `HealthStartPeriod`, `Sysctl`, `AutoUpdate`, `PodmanArgs`, `PublishPort`, `Network`, `Volume` y, en `.network`, `Subnet` y `Options=isolate=true`.

**No existe en 4.9:** `Memory=`. Los límites de memoria de la fase 5 tendrán que ir por `PodmanArgs=--memory=…` o por `MemoryMax=` en la sección `[Service]` (systemd). Queda por decidir cuál, en esa fase.

Aceptar una clave solo demuestra que el generador la entiende, no que el contenedor se comporte como se espera. Eso lo comprueba el workflow `lifecycle` (fase 1).

## Versiones más nuevas

Las plantillas se escriben para 4.9 y no se ramifican por versión. Está previsto, como mejora posterior a la fase 2, que Ansible lea la versión de Podman del servidor y use `Notify=healthy` en el único sitio del patrón de espera cuando sea 5 o superior. Ver [`ROADMAP.md`](ROADMAP.md).
