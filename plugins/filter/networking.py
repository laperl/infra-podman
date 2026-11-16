"""Filters for the networking block of an instance (R59, docs/DECISIONS.md)."""
from __future__ import annotations

import ipaddress

# Where roles/quadlet_deploy/templates/egress.network.j2 puts the networks with a limited
# way out: a destination must not fall inside it.
PLATFORM_RANGE = ipaddress.ip_network("10.90.0.0/16")


def egress_problems(value) -> list[str]:
    """What is wrong with a networking.egress value; an empty list when it is fine.

    Fine: false (no way out), true (everywhere), or a list with at least one IPv4 address
    or range, like ["100.64.0.7", "192.168.1.0/24"]. Names are not possible: the network
    of a limited way out has routes, not DNS.
    """
    if isinstance(value, bool):
        return []
    if not isinstance(value, (list, tuple)) or not value:
        return ["egress is true, false or a list with at least one IPv4 address or range"]
    problems = []
    for item in value:
        try:
            network = ipaddress.ip_network(str(item), strict=False)
        except ValueError:
            problems.append(f"{item} is not an IPv4 address or range (a name is not possible)")
            continue
        if network.version != 4:
            problems.append(f"{item} is not IPv4")
        elif network.prefixlen == 0:
            problems.append(f"{item} is everything: write egress: true instead")
        elif network.overlaps(PLATFORM_RANGE):
            problems.append(f"{item} overlaps {PLATFORM_RANGE}, which the platform uses for these networks")
    return problems


class FilterModule:
    def filters(self):
        return {"egress_problems": egress_problems}
