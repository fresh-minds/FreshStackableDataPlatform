{# Standaard dbt-trino gebruikt target.database. We override zodat
   `+database: silver` of `+database: gold` letterlijk de Trino-catalog wordt
   in plaats van een prefix. #}
{% macro generate_database_name(custom_database_name=none, node=none) -%}
    {%- if custom_database_name is none -%}
        {{ target.database }}
    {%- else -%}
        {{ custom_database_name | trim }}
    {%- endif -%}
{%- endmacro %}
