# Visión

Resumen de la sección 2 de [`SPEC.md`](SPEC.md). Si discrepan, manda el SPEC.

## Para qué existe

Una plataforma estándar y mantenible por **una sola persona** para desplegar, actualizar y vigilar servicios en contenedores Podman gestionados por systemd, con Ansible desde el portátil.

## Principio rector

La IA propone, el código determinista ejecuta y un humano aprueba lo irreversible.

## Prioridades, en este orden

1. **Integridad de los datos** y recuperación sencilla.
2. **Sencillez:** cada herramienta nueva tiene que justificarse.
3. Disponibilidad: best effort. No se busca alta disponibilidad.

## Qué queda fuera

- Exponer nada a internet: todo va por Tailscale.
- Gestionar desde Ansible el Docker de vLLM en el servidor principal, por ahora.
- Que una IA despliegue, mergee o cree tags.
