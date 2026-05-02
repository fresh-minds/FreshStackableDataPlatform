{# Generic test: kolom bevat geldig NL-IBAN.

   Pragmatisch: format-check `^NL[0-9]{2}[A-Z]{4}[0-9]{10}$`. Volledige mod-97
   IBAN-checksum kan in een uitgebreide versie (Trino heeft geen native modulo
   op grote integers; we doen het in dbt-Python of laten een verrijking-stap
   doen).
#}
{% test iban_valid(model, column_name) %}

select {{ column_name }} as iban
from {{ model }}
where {{ column_name }} is not null
  and not regexp_like({{ column_name }}, '^NL[0-9]{2}[A-Z]{4}[0-9]{10}$')

{% endtest %}
