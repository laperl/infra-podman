# Instrucciones para agentes de IA

Lee `docs/SPEC.md` antes de cualquier tarea. Es la fuente de verdad: lo que no esté ahí no está decidido.

## Reglas que no se saltan

- **Solo PRs.** Trabajas en una rama y abres un PR en borrador. Nunca haces merge, no creas tags y no accedes a servidores. El `apply` lo ejecuta solo el operador.
- **Una fase cada vez** (SPEC, sección 6). Cada PR comprueba el criterio de hecho de su fase. No avances sin aprobación.
- **No reabras decisiones cerradas** (SPEC, sección 3). Lo abierto (sección 7) se propone y se espera aprobación.
- **Podman 4.9 es el mínimo.** Comprueba cada clave de Quadlet en la documentación de 4.9. Nada de `Notify=healthy`, ficheros `.pod` ni opciones de slirp4netns o pasta.
- **Imágenes por digest**, nunca `:latest`.
- **Cero secretos** en el repo, logs, ejemplos o el chat. Solo nombres de secretos y valores ficticios.
- **No inventes** módulos, opciones ni parámetros. Si no puedes verificarlo en la documentación oficial, dilo en el PR.
- **Simplicidad.** El operador es una sola persona. Justifica cualquier herramienta nueva.
- **Solo software libre y gratuito.** Ansible comunitario; nada de Automation Platform, Automation Hub ni imágenes con suscripción.
- **Si el CI falla 5 veces por lo mismo**, para y pregunta.

## Qué leer para cada tarea

No leas todo el repo: lee lo que pide la tarea. Cada cosa se explica en un solo sitio; los demás documentos enlazan, no repiten.

| Tarea | Lee |
| --- | --- |
| Cualquiera | `docs/SPEC.md` (secciones 3, 4, 6 a 8) y la fila de la fase en `docs/ROADMAP.md` |
| Cualquier nombre nuevo (contenedor, red, volumen, secreto, variable, base) | `docs/NAMING.md`: es obligatoria |
| Un servicio (Firefly, pgAdmin…) | `docs/services/README.md` (lo común e instancias), `docs/services/INSTALL.md` (instalar, paso a paso), `docs/services/<servicio>.md`, `roles/<servicio>/` y su `CLAUDE.md`, si lo tiene |
| Postgres, bases o usuarios | `docs/POSTGRES.md` y `roles/postgres/` |
| Backups o restaurar | SPEC 4.11, `roles/backup/`, `roles/backup_server/` y `docs/OPERATIONS.md`, apartado 5 |
| Secretos | SPEC 4.5, `docs/SECRETS_INVENTORY.md` y `playbooks/secrets.yml` |
| Escribir o aplicar una orden (un parche de otra IA) | `docs/WORKFLOW.md`, «Si una IA escribe el cambio y otra lo aplica»: quién prueba qué y cómo se deja escrito |
| Despliegue o `deploy.sh` | SPEC 4.10, `deploy.sh` y `docs/WORKFLOW.md` |
| Un fallo | `docs/TROUBLESHOOTING.md`, en la pieza que falla |
| Cómo encaja todo | `docs/ARCHITECTURE.md` |
| Por qué algo es así | `docs/DECISIONS.md`, solo la R que lo cita |
| Una auditoría | `docs/ARCHITECTURE.md` y, por pieza, lo de esta tabla |

## Dónde va cada cosa nueva

- **Un servicio nuevo:** siempre por instancias y con un nombre corto (añádelo a la tabla de `docs/NAMING.md`, apartado 2, y sigue su lista del apartado 9), con lo común de [`docs/services/README.md`](docs/services/README.md) (R48): una base de datos por instancia, nunca un esquema compartido. Su rol en `roles/<servicio>/`, su página en `docs/services/<servicio>.md` (solo lo propio de ese servicio) y un `CLAUDE.md` corto en su rol: qué no se toca, qué tests tiene y qué leer.
- **Al añadirlo, al día:** las tablas de `docs/ARCHITECTURE.md`, `docs/OPERATIONS.md` (apartados 1 y 4) y `docs/TROUBLESHOOTING.md` (una sección), y `docs/SECRETS_INVENTORY.md`. No se copian textos entre ellos.
- **Software propio** (por ejemplo `rag`): en su propio repo, que publica su imagen (SPEC 5.5). Aquí solo su despliegue.

## Convenciones

- Documentación y mensajes en español; código, variables y commits en inglés.
- Commits con prefijo convencional (`feat:`, `fix:`, `docs:`, `chore:`, `ci:`).
- Lista completa de prohibiciones: SPEC, sección 8.
