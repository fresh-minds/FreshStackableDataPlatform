{# Standaard dbt prefixt schema's met `target.schema_<custom>`.
   We willen letterlijk de custom schema-naam (bv. silver.ww, gold.uc01_*).
   Daarom override hier. #}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
