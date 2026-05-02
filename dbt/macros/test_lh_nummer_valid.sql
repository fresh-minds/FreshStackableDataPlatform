{# Generic test: loonheffingennummer-format.

   Format: 9 cijfers + 'L' + 2 cijfers (bv. '123456789L01').
#}
{% test lh_nummer_valid(model, column_name) %}

select {{ column_name }} as lh_nummer
from {{ model }}
where {{ column_name }} is not null
  and not regexp_like({{ column_name }}, '^[0-9]{9}L[0-9]{2}$')

{% endtest %}
