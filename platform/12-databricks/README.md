# platform/12-databricks — Databricks-notebooks (UC-11, Microsoft-stack)

De **Databricks-variant** van de UC-11 "integrale klantreis"-pipeline. Dit zijn
notebook-assets voor een Databricks-workspace, niet voor het k3d-cluster — de
open-source default voor verwerking blijft **Spark** (`platform/08-spark/`).
Bedoeld voor de AKS/Entra-deploy waar UWV een Databricks-workspace heeft.

## Wat zit hier?

| Notebook | Doel |
|---|---|
| [`uc11-notebooks/uc11_seed_bronze.ipynb`](uc11-notebooks/uc11_seed_bronze.ipynb) | Seedt de bronze-laag met synthetische klantreis-events. |
| [`uc11-notebooks/uc11_silver.ipynb`](uc11-notebooks/uc11_silver.ipynb) | Bronze → silver: conformeren + pseudonimiseren. |
| [`uc11-notebooks/uc11_dbt_gold.ipynb`](uc11-notebooks/uc11_dbt_gold.ipynb) | Silver → gold: dbt-modellen voor de klantreis-marts. |

Er staan bewust **geen** Kubernetes-manifests in deze map — Databricks is een
managed Azure-dienst, geen in-cluster workload. De notebooks worden in een
Databricks-workspace geïmporteerd (of via de Airflow-DAG
[`uc11_databricks.py`](../11-airflow/dags/uc11_databricks.py) georkestreerd).

## Zie ook

- [UC-11 · Integrale klantreis](../../docs/use-cases/uc11-klantreis.md) — de use-case-spec.
- [`platform/12-powerbi/`](../12-powerbi/) — de Power BI / Fabric-variant van de BI-laag.
- [`platform/12-superset/`](../12-superset/) — de open-source BI-default.
