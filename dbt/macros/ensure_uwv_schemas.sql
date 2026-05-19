{# Target-aware schema-bootstrap voor het UWV-platform.

   Gebruik (in dbt_project.yml):
     on-run-start: "{{ ensure_uwv_schemas() }}"

   Per target:
   - trino    → CREATE SCHEMA ... WITH (location = 's3a://uwv-<laag>/<naam>/')
                voor elke silver/gold-schema (huidige Stackable-gedrag).
                Stackable's Hive-Metastore heeft geen globale warehouse.dir,
                dus elke schema MOET een expliciete S3-locatie hebben.
   - databricks → no-op. Unity Catalog catalog/schemas worden out-of-band
                  aangemaakt (eenmalig, via Databricks SQL of Terraform).
                  Tabellen zijn UC-managed; geen schema-locaties nodig.
   - fabric / fabricspark → no-op. Lakehouse + schemas worden via Fabric REST
                  voorgekookt door de uc11_fabric Airflow-DAG (eerste task).
   - default → no-op + waarschuwing, zodat onbekende targets niet stilletjes
               schema-creatie missen.
#}
{% macro ensure_uwv_schemas() %}
    {%- set silver_schemas = [
        'persoon', 'polisadm', 'ww', 'wia', 'wajong', 'zw', 'crm',
        'fez', 'klantcontact', 'finops', 'intermediate', 'sandbox_uc09', 'seed'
    ] -%}
    {%- set gold_schemas = [
        'uc01_wia_funnel', 'uc04_tw_eligibility', 'uc05_client_360',
        'uc06_lastprognose', 'uc07_dq_polisadm', 'uc09_reint_effect',
        'uc11_klantreis', 'uc12_focus_finops', 'uc_klant_tev',
        'dq_overview', 'seed'
    ] -%}

    {%- if target.type == 'trino' -%}
        {%- if execute -%}
            {%- for s in silver_schemas -%}
                {%- do run_query(
                    "CREATE SCHEMA IF NOT EXISTS silver." ~ s ~
                    " WITH (location = 's3a://uwv-silver/" ~ s ~ "/')"
                ) -%}
            {%- endfor -%}
            {%- for g in gold_schemas -%}
                {%- do run_query(
                    "CREATE SCHEMA IF NOT EXISTS gold." ~ g ~
                    " WITH (location = 's3a://uwv-gold/" ~ g ~ "/')"
                ) -%}
            {%- endfor -%}
        {%- endif -%}
        SELECT 1 AS uwv_schemas_ensured_trino
    {%- elif target.type == 'databricks' -%}
        SELECT 1 AS uwv_schemas_skipped_databricks_managed_by_uc
    {%- elif target.type in ('fabric', 'fabricspark') -%}
        SELECT 1 AS uwv_schemas_skipped_fabric_managed_by_airflow
    {%- else -%}
        {{ log("WARN: ensure_uwv_schemas() — onbekende target.type='" ~ target.type ~ "'; schema-creatie overgeslagen", info=true) }}
        SELECT 1 AS uwv_schemas_skipped_unknown_target
    {%- endif -%}
{% endmacro %}
