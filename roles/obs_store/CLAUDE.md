# Rol `obs_store`

El almacén de la observabilidad: VictoriaMetrics y VictoriaLogs (SPEC 4.8, R62). Lee antes [`docs/OBSERVABILITY.md`](../../docs/OBSERVABILITY.md).

- **No se toca:** sus datos son una carpeta de la máquina (`obs_store_dir`), no un volumen de Podman, para que pueda vivir en un disco cifrado y moverse. Ansible nunca formatea, cifra ni monta discos. Al quitarlo (`obs_store_state: absent`), los datos se quedan.
- **Sin healthcheck dentro:** el rol espera a `/health` desde la máquina, sin depender de lo que traiga cada imagen (R62).
- **Tests:** `tests/quadlet` (copia de referencia de sus unidades) y el job `obs-store` de `lifecycle` (`tests/lifecycle/check-obs_store.sh`).
