"""YAML-source-registry loader.

Eén bron van waarheid voor alle DAG-factories. Leest YAML's uit
`UWV_SOURCES_DIR` (default `/opt/uwv/airflow/sources`) en geeft typed
SourceSpec objecten terug. Zie docs/adr/0007-airflow-pipeline-architecture.md.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

import yaml


SOURCES_DIR_ENV = "UWV_SOURCES_DIR"
DEFAULT_SOURCES_DIR = "/opt/uwv/airflow/sources"


@dataclass(frozen=True)
class KafkaSpec:
    topic: str
    partitions: int
    key: str


@dataclass(frozen=True)
class BronzeSpec:
    catalog: str
    schema: str
    table: str
    partition_by: str

    @property
    def fqn(self) -> str:
        return f"{self.catalog}.{self.schema}.{self.table}"


@dataclass(frozen=True)
class SilverSpec:
    catalog: str
    schema: str
    staging_model: str
    dbt_tag: str

    @property
    def fqn(self) -> str:
        return f"{self.catalog}.{self.schema}.{self.staging_model}"


@dataclass(frozen=True)
class GovernanceSpec:
    legal_basis: str
    doelbinding: tuple[str, ...]
    bio_classificatie: str
    bewaartermijn_jaren: int
    eigenaar: str
    pii_kolommen: tuple[str, ...]
    risk_tier: str


@dataclass(frozen=True)
class SLASpec:
    mode: str                              # streaming | batch
    expected_event_freq: str
    max_acceptable_lag_seconds: int
    alert_threshold_seconds: int


@dataclass(frozen=True)
class SourceSpec:
    schema_version: int
    name: str
    domain: str
    kafka: KafkaSpec
    bronze: BronzeSpec
    silver: SilverSpec
    governance: GovernanceSpec
    sla: SLASpec
    used_by_use_cases: tuple[str, ...]
    anchor: bool

    # Voor Airflow tags op de gegenereerde DAGs.
    @property
    def airflow_tags(self) -> list[str]:
        return [
            "uwv",
            f"domain:{self.domain}",
            f"classificatie:{self.governance.bio_classificatie}",
            f"risk:{self.governance.risk_tier}",
            f"mode:{self.sla.mode}",
        ]


def _sources_dir() -> Path:
    return Path(os.environ.get(SOURCES_DIR_ENV, DEFAULT_SOURCES_DIR))


def _coerce(d: dict) -> SourceSpec:
    return SourceSpec(
        schema_version=int(d["schema_version"]),
        name=d["name"],
        domain=d["domain"],
        kafka=KafkaSpec(**d["kafka"]),
        bronze=BronzeSpec(**d["bronze"]),
        silver=SilverSpec(**d["silver"]),
        governance=GovernanceSpec(
            legal_basis=d["governance"]["legal_basis"],
            doelbinding=tuple(d["governance"]["doelbinding"]),
            bio_classificatie=d["governance"]["bio_classificatie"],
            bewaartermijn_jaren=int(d["governance"]["bewaartermijn_jaren"]),
            eigenaar=d["governance"]["eigenaar"],
            pii_kolommen=tuple(d["governance"].get("pii_kolommen") or []),
            risk_tier=d["governance"]["risk_tier"],
        ),
        sla=SLASpec(**d["sla"]),
        used_by_use_cases=tuple(d.get("used_by_use_cases") or []),
        anchor=bool(d.get("anchor", False)),
    )


@lru_cache(maxsize=1)
def load_all_sources() -> tuple[SourceSpec, ...]:
    """Laad alle YAML's uit UWV_SOURCES_DIR. Gecached per Airflow-parse."""
    base = _sources_dir()
    if not base.exists():
        return ()
    specs: list[SourceSpec] = []
    for path in sorted(base.glob("*.yml")):
        with path.open(encoding="utf-8") as fp:
            data = yaml.safe_load(fp)
        try:
            specs.append(_coerce(data))
        except (KeyError, TypeError) as exc:
            raise ValueError(f"Invalid source spec in {path}: {exc}") from exc
    _validate_uniqueness(specs)
    return tuple(specs)


def get_source(name: str) -> SourceSpec:
    for spec in load_all_sources():
        if spec.name == name:
            return spec
    raise KeyError(f"Unknown source: {name}")


def sources_for_use_case(uc: str) -> tuple[SourceSpec, ...]:
    return tuple(s for s in load_all_sources() if uc in s.used_by_use_cases)


def _validate_uniqueness(specs: list[SourceSpec]) -> None:
    seen_names: set[str] = set()
    seen_topics: set[str] = set()
    seen_bronze: set[str] = set()
    for s in specs:
        if s.name in seen_names:
            raise ValueError(f"Duplicate source name: {s.name}")
        if s.kafka.topic in seen_topics:
            raise ValueError(f"Duplicate kafka topic: {s.kafka.topic}")
        if s.bronze.fqn in seen_bronze:
            raise ValueError(f"Duplicate bronze table: {s.bronze.fqn}")
        seen_names.add(s.name)
        seen_topics.add(s.kafka.topic)
        seen_bronze.add(s.bronze.fqn)
