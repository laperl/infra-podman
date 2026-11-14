"""The report of the check playbook (playbooks/files/machine-report.py), with canned data.

collect() asks Podman and systemd; report() only turns that data into lines and problems,
so it is tested here without either.
"""
from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "playbooks/files/machine-report.py"
spec = importlib.util.spec_from_file_location("machine_report", SCRIPT)
machine_report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(machine_report)

LABELS = {"infra.managed-by": "infra-podman", "infra.env": "prod"}
HEALTHY = {
    "containers": [
        {"Names": ["prod-pg-main"], "State": "running", "Status": "Up 2 hours (healthy)", "Networks": ["prod-ff-casa-pg-main-net"],
         "NetworkMode": "bridge", "Ports": [], "Image": "docker.io/library/postgres@sha256:" + "a" * 64, "Labels": {**LABELS, "infra.app": "pg-main"}},
        {"Names": ["prod-ff-casa"], "State": "running", "Status": "Up 2 hours (healthy)", "Networks": ["prod-ff-casa-pg-main-net"],
         "Ports": [{"host_ip": "127.0.0.1", "host_port": 18100, "container_port": 8080}],
         "Image": "docker.io/fireflyiii/core@sha256:" + "b" * 64, "Labels": {**LABELS, "infra.app": "ff-casa"}},
    ],
    "volumes": [{"Name": "prod-pg-main-data", "Labels": {**LABELS, "infra.app": "pg-main"}},
                {"Name": "prod-ff-casa-uploads", "Labels": {**LABELS, "infra.app": "ff-casa"}},
                {"Name": "prod-backup-repo", "Labels": {**LABELS, "infra.app": "backup"}}],
    "networks": [{"name": "prod-ff-casa-pg-main-net", "internal": True, "subnets": [{"subnet": "10.89.0.0/24"}],
                  "labels": {**LABELS, "infra.app": "pg-main"}}],
    "secrets": ["prod-pg-main-superuser-password", "prod-ff-casa-app-key", "unrelated"],
    "timers": {
        "prod-backup.timer": {"ActiveState": "active", "NextElapseUSecRealtime": "Sun 2026-11-15 13:00:00 CET",
                              "LastTriggerUSec": "Sat 2026-11-14 13:00:02 CET"},
        "prod-ff-casa-cron.timer": {"ActiveState": "active", "NextElapseUSecRealtime": "Sun 2026-11-15 05:30:00 CET",
                                    "LastTriggerUSec": "Sat 2026-11-14 05:30:01 CET"},
    },
    "services": {
        "prod-pg-main.service": {"ActiveState": "active", "Result": "success"},
        "prod-ff-casa.service": {"ActiveState": "active", "Result": "success"},
        "prod-backup.service": {"ActiveState": "inactive", "Result": "success"},
        "prod-ff-casa-cron.service": {"ActiveState": "inactive", "Result": "success"},
    },
    "backup_items": ["pg pg-main prod-pg-main", "file infra-podman data-repo /var/lib/x/bundle",
                     "volume ff-casa uploads prod-ff-casa-uploads", "exec myapp export prod-myapp tool export --stdout"],
    "backup_files": ["ff-casa"],
    "backup_status": {"prod-backup": {"result": "ok", "last_ok": "2026-11-14T13:00:40+01:00"},
                      "prod-backup-copy": {"result": "unreachable", "last_ok": "2026-11-13T13:30:00+01:00",
                                           "message": "El servidor no responde.", "usage": "1 GB de 30 GB"}},
}
DECLARED = ["backup", "pg-main", "ff-casa"]
SECRETS = ["prod-pg-main-superuser-password", "prod-ff-casa-app-key"]


def report(data: dict, declared: list[str] = DECLARED, secrets: list[str] = SECRETS) -> tuple[str, list[str]]:
    lines, problems = machine_report.report(data, "laptop", "prod", declared, secrets)
    return "\n".join(lines), problems


class MachineReport(unittest.TestCase):
    def test_a_healthy_machine_has_no_problems(self) -> None:
        text, problems = report(HEALTHY)
        self.assertEqual(problems, [])
        self.assertIn("RESUMEN: todo correcto", text)
        self.assertIn("prod-ff-casa: en marcha, sano. Entrada: 127.0.0.1:18100->8080", text)
        self.assertIn("prod-ff-casa-pg-main-net: interna (sin salida), 10.89.0.0/24 (de pg-main)", text)
        self.assertIn("prod-backup.timer: activo. Próxima: Sun 2026-11-15 13:00:00 CET", text)
        self.assertIn("ff-casa: el volumen prod-ff-casa-uploads entero (uploads)", text)
        self.assertIn("myapp: lo que imprime «tool export --stdout» en prod-myapp (export)", text)
        self.assertIn("2 declarados para esta máquina, 2 instalados", text)
        self.assertIn("Imagen: docker.io/fireflyiii/core@sha256:bbbbbbbbbbbb\n", text)
        # A sleeping backup service and a server that does not answer are not problems.
        self.assertNotIn("prod-backup.service", text)
        self.assertIn("SOBRA (está en la máquina y el inventario no lo declara; no se toca nada)\n  nada", text)

    def problems_after(self, change) -> list[str]:
        data = copy.deepcopy(HEALTHY)
        change(data)
        return report(data)[1]

    def test_an_unhealthy_container_is_a_problem(self) -> None:
        problems = self.problems_after(lambda d: d["containers"][1].update(Status="Up 2 hours (unhealthy)"))
        self.assertEqual(problems, ["prod-ff-casa está en marcha pero su comprobación de salud falla"])

    def test_a_stopped_container_is_a_problem_once(self) -> None:
        problems = self.problems_after(lambda d: d["containers"][0].update(State="exited", Status="Exited (1)"))
        self.assertEqual(problems, ["prod-pg-main no está en marcha (exited)"])

    def test_a_declared_instance_without_container_and_its_failed_service(self) -> None:
        def change(data: dict) -> None:
            del data["containers"][1]
            data["services"]["prod-ff-casa.service"] = {"ActiveState": "failed", "Result": "exit-code"}
        self.assertEqual(self.problems_after(change), ["ff-casa está declarada y no tiene contenedor",
                                                       "prod-ff-casa.service no está en marcha (failed)"])

    def test_timers(self) -> None:
        problems = self.problems_after(lambda d: d["timers"]["prod-backup.timer"].update(ActiveState="inactive"))
        self.assertEqual(problems, ["el temporizador prod-backup.timer no está activo (inactive)"])
        problems = self.problems_after(lambda d: d["services"]["prod-ff-casa-cron.service"].update(Result="exit-code"))
        self.assertEqual(problems, ["la última ejecución de prod-ff-casa-cron.service terminó mal (exit-code)"])

    def test_a_failed_backup_and_a_missing_secret(self) -> None:
        problems = self.problems_after(lambda d: d["backup_status"]["prod-backup"].update(result="failed", message="Falló."))
        self.assertEqual(problems, ["prod-backup: la última copia falló"])
        problems = self.problems_after(lambda d: d["secrets"].remove("prod-ff-casa-app-key"))
        self.assertEqual(problems, ["falta el secreto prod-ff-casa-app-key"])

    def test_what_is_left_is_listed_and_is_not_a_problem(self) -> None:
        data = copy.deepcopy(HEALTHY)
        data["volumes"].append({"Name": "prod-ff-old-uploads", "Labels": {**LABELS, "infra.app": "ff-old"}})
        data["secrets"].append("prod-ff-old-app-key")
        data["backup_files"].append("ff-old")
        text, problems = report(data)
        self.assertEqual(problems, [])
        for line in ("volumen prod-ff-old-uploads (de ff-old)", "secreto prod-ff-old-app-key (no está en infra_secrets)",
                     "copias de ff-old (fichero en backup.d)"):
            self.assertIn(line, text)
        self.assertNotIn("secreto unrelated", text)

    def test_a_network_with_a_way_out_is_said(self) -> None:
        data = copy.deepcopy(HEALTHY)
        data["networks"][0]["internal"] = False
        self.assertIn("prod-ff-casa-pg-main-net: CON SALIDA", report(data)[0])

    def test_network_and_health_are_said_as_they_are(self) -> None:
        data = copy.deepcopy(HEALTHY)
        data["containers"][0].update(Networks=[], NetworkMode="none", Status="Up 2 hours")
        data["containers"][1].update(Networks=[], NetworkMode="pasta")
        text, problems = report(data)
        self.assertEqual(problems, [])
        self.assertIn("prod-pg-main: en marcha (sin comprobación de salud). Entrada: ninguna. Redes: ninguna (sin red).", text)
        self.assertIn("Redes: la de Podman por defecto, CON SALIDA (pasta).", text)

    def test_a_volume_out_of_the_backup_is_said(self) -> None:
        text, _ = report(HEALTHY)
        self.assertNotIn("FUERA DE LA COPIA", text)
        data = copy.deepcopy(HEALTHY)
        data["backup_items"].remove("volume ff-casa uploads prod-ff-casa-uploads")
        text, problems = report(data)
        self.assertEqual(problems, [])
        self.assertEqual(text.count("FUERA DE LA COPIA"), 1)
        self.assertIn("FUERA DE LA COPIA: el volumen prod-ff-casa-uploads (de ff-casa)", text)

    def test_what_could_not_be_read_is_a_problem(self) -> None:
        data = copy.deepcopy(HEALTHY)
        data["containers"], data["errors"] = [], ["«podman ps --all» falló (125): cannot chdir"]
        text, problems = report(data)
        self.assertIn("NO SE HA PODIDO LEER", text)
        self.assertIn("no se pudo leer: «podman ps --all» falló (125): cannot chdir", problems)

    def test_an_empty_machine(self) -> None:
        empty = {key: type(value)() for key, value in HEALTHY.items()}
        text, problems = report(empty, ["backup"], [])
        self.assertEqual(problems, [])
        self.assertIn("Esta máquina no tiene backup configurado", text)


if __name__ == "__main__":
    unittest.main()
