{# Format-agnostische table-properties.

   Gebruik:
     {{ config(
         materialized='table',
         properties=table_format_properties()
     ) }}

   Voor partitionering: roep door met partition_columns:
     properties=table_format_properties(partition_columns=['event_date'])
#}
{% macro table_format_properties(partition_columns=none, extra_props=none) %}
    {%- set fmt = var('table_format', 'delta') -%}
    {%- set props = {} -%}

    {%- if fmt == 'delta' -%}
        {# Trino's delta_lake connector heeft geen `format` property
           (Delta is altijd Parquet). Alleen `partitioned_by` zetten. #}
        {%- if partition_columns -%}
            {%- set parts = partition_columns | join("','") -%}
            {%- do props.update({'partitioned_by': "ARRAY['" ~ parts ~ "']"}) -%}
        {%- else -%}
            {# Non-partitioned table — geef een no-op property zodat dbt geen
               lege WITH () genereert (syntax error in Trino). #}
            {%- do props.update({'checkpoint_interval': "10"}) -%}
        {%- endif -%}
    {%- elif fmt == 'iceberg' -%}
        {%- do props.update({'format': "'PARQUET'"}) -%}
        {%- if partition_columns -%}
            {# Iceberg ondersteunt expressie-partitions; default day(col). #}
            {%- set parts = partition_columns | map('upper') | list -%}
            {%- set partition_clauses = [] -%}
            {%- for col in partition_columns -%}
                {%- do partition_clauses.append("day(" ~ col ~ ")") -%}
            {%- endfor -%}
            {%- do props.update({'partitioning': "ARRAY['" ~ partition_clauses | join("','") ~ "']"}) -%}
        {%- endif -%}
    {%- else -%}
        {{ exceptions.raise_compiler_error("Unknown table_format: " ~ fmt) }}
    {%- endif -%}

    {%- if extra_props -%}
        {%- do props.update(extra_props) -%}
    {%- endif -%}

    {{ return(props) }}
{% endmacro %}
