"""DAG-aanroeper — bronze_watch.

Eén DAG die per bron de bronze-tabel-freshness controleert en bij succes
een Dataset publiceert. Triggert de silver-DAGs.

Zie docs/adr/0007-airflow-pipeline-architecture.md.
SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
"""
from __future__ import annotations

from bronze_factory import build_bronze_watch_dag

dag = build_bronze_watch_dag()
