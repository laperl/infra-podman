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
