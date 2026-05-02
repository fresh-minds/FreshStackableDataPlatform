"""Genereer + publiceer synthetische events naar Kafka.

SYNTHETIC DATA — NOT FOR REAL USE.

Per topic publiceren we de event-envelope van `_common.envelope` als JSON.
Topic-naming: `uwv.<domain>.<event>`. De Spark streaming-job onder
`spark-jobs/streaming_kafka_to_lakehouse.py` consumeert alle `uwv\\..*\\..*`
en schrijft naar Delta-bronze.

Voorbeeldgebruik:
  uv run python load_to_kafka.py --count 10000 \\
    --bootstrap uwv-kafka-bootstrap.uwv-platform.svc.cluster.local:9092

In-cluster: zie data-generation/k8s/seed-job.yaml.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any, Callable, Iterable

import click

# Maak imports zowel in repo als in k8s ConfigMap-mount werken.
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, "/app")

from generators import (  # noqa: E402
    crm,
    fez,
    persona as persona_mod,
    polisadministratie,
    wajong,
    wia,
    ww,
    zw,
)


def _produce(producer, topic: str, envelope: dict[str, Any], key: str | None = None) -> None:
    payload = json.dumps(envelope, ensure_ascii=False).encode("utf-8")
    key_bytes = key.encode("utf-8") if key else None
    producer.send(topic, value=payload, key=key_bytes)


def _flush_log(producer, label: str, count: int, started: float) -> None:
    producer.flush()
    dur = time.monotonic() - started
    print(f"  {label}: {count} events in {dur:.1f}s ({count / dur:.0f}/s)", flush=True)


@click.command()
@click.option("--count", default=10000, show_default=True, help="Aantal personas (anchor count).")
@click.option("--seed", default=2026, show_default=True, help="RNG-seed.")
@click.option("--bootstrap", default="localhost:9092", show_default=True,
              help="Kafka bootstrap servers, comma-separated.")
@click.option("--include-domains", default="persona,polisadm,ww,wia,wajong,zw,crm,fez",
              show_default=True, help="Comma-separated lijst van domeinen om te publiceren.")
@click.option("--dry-run", is_flag=True, help="Genereer maar verstuur niet.")
def main(count: int, seed: int, bootstrap: str, include_domains: str, dry_run: bool) -> None:
    """Genereer en publiceer synthetische events naar Kafka."""
    domains = {d.strip() for d in include_domains.split(",") if d.strip()}

    # Lazy import: kafka-python pas wanneer we niet in dry-run zitten.
    if not dry_run:
        from kafka import KafkaProducer  # noqa: PLC0415

        producer = KafkaProducer(
            bootstrap_servers=bootstrap.split(","),
            client_id="uwv-data-generation-loader",
            acks="all",
            retries=3,
            linger_ms=100,
            compression_type="gzip",
        )
    else:
        class _Null:
            def send(self, *a, **kw): pass
            def flush(self): pass
        producer = _Null()

    print(f"==> Loader start (count={count}, seed={seed}, dry_run={dry_run})", flush=True)

    # 1. Persona — anchor; alle andere domeinen leunen op deze BSN-set.
    bsns: list[str] = []
    if "persona" in domains:
        started = time.monotonic()
        for p in persona_mod.generate_personas(count, seed=seed):
            bsns.append(p.bsn)
            _produce(producer, "uwv.persona.created",
                     persona_mod.to_kafka_envelope(p), key=p.bsn)
        _flush_log(producer, "persona.created", count, started)
    else:
        # Genereer enkel BSN's zonder publiceren (voor downstream-domeinen).
        bsns = [p.bsn for p in persona_mod.generate_personas(count, seed=seed)]

    # 2. Polisadm — IKV's per persoon.
    if "polisadm" in domains:
        started = time.monotonic()
        n = 0
        for ikv in polisadministratie.generate_ikvs(bsns, seed=seed):
            _produce(producer, "uwv.polisadm.ikv",
                     polisadministratie.to_kafka_envelope(ikv), key=ikv.bsn)
            n += 1
        _flush_log(producer, "polisadm.ikv", n, started)

    # 3. WW — aanvragen voor ~30% van de personas.
    if "ww" in domains:
        started = time.monotonic()
        n = 0
        for a in ww.generate_ww_aanvragen(bsns, seed=seed):
            _produce(producer, "uwv.ww.aanvraag", ww.to_kafka_envelope(a), key=a.bsn)
            n += 1
        _flush_log(producer, "ww.aanvraag", n, started)

    # 4. WIA — ~15% van de personas.
    if "wia" in domains:
        started = time.monotonic()
        n = 0
        for a in wia.generate_wia_aanvragen(bsns, seed=seed):
            _produce(producer, "uwv.wia.aanvraag", wia.to_kafka_envelope(a), key=a.bsn)
            n += 1
        _flush_log(producer, "wia.aanvraag", n, started)

    # 5. Wajong — ~5%.
    if "wajong" in domains:
        started = time.monotonic()
        n = 0
        for d in wajong.generate_wajong_dossiers(bsns, seed=seed):
            _produce(producer, "uwv.wajong.dossier", wajong.to_kafka_envelope(d), key=d.bsn)
            n += 1
        _flush_log(producer, "wajong.dossier", n, started)

    # 6. ZW — ~20%.
    if "zw" in domains:
        started = time.monotonic()
        n = 0
        for m in zw.generate_zw_meldingen(bsns, seed=seed):
            _produce(producer, "uwv.zw.melding", zw.to_kafka_envelope(m), key=m.bsn)
            n += 1
        _flush_log(producer, "zw.melding", n, started)

    # 7. CRM — meerdere contacts per persoon.
    if "crm" in domains:
        started = time.monotonic()
        n = 0
        for c in crm.generate_klantcontacten(bsns, seed=seed):
            _produce(producer, "uwv.crm.contact", crm.to_kafka_envelope(c), key=c.bsn)
            n += 1
        _flush_log(producer, "crm.contact", n, started)

    # 8. FEZ — geaggregeerde maanddata, geen BSN-koppeling.
    if "fez" in domains:
        started = time.monotonic()
        n = 0
        for ag in fez.generate_fez_aggregaten(seed=seed):
            _produce(producer, "uwv.fez.uitkeringslast", fez.to_kafka_envelope(ag),
                     key=f"{ag.jaar}-{ag.maand:02d}-{ag.wet}-{ag.regio_code}")
            n += 1
        _flush_log(producer, "fez.uitkeringslast", n, started)

    if not dry_run:
        producer.close(timeout=30)
    print("==> Loader klaar.", flush=True)


if __name__ == "__main__":
    main()
