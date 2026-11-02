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

## Convenciones

- Documentación y mensajes en español; código, variables y commits en inglés.
- Commits con prefijo convencional (`feat:`, `fix:`, `docs:`, `chore:`, `ci:`).
- Lista completa de prohibiciones: SPEC, sección 8.
