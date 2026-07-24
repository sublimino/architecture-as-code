"""Start the ARC identity control plane (EEMS PIP, PlainID PDP, COIN issuer) and
block. Olly, Orbit, and elk-search-mcp are the clients; they are the real agents
in the cluster, not part of this service.

    python -m authz.serve
"""

import time

from . import coin, config, eems, httputil, plainid


def main() -> None:
    services = [
        ("eems-pip", config.EEMS_PORT, eems.server()),
        ("plainid-pdp", config.PDP_PORT, plainid.server()),
        ("coin-issuer", config.COIN_PORT, coin.server()),
    ]
    for name, port, server in services:
        httputil.serve_in_thread(server)
        print(f"  {name:14} {config.BIND_HOST}:{port}", flush=True)
    print("olly-authz control plane up. audit log:", config.AUDIT_LOG, flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        print("\nstopping")


if __name__ == "__main__":
    main()
