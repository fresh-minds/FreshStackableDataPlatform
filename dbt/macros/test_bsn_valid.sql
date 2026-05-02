{# Generic test: kolom bevat geldige BSN's (11-proef).

   Gebruik in schema.yml:
     - name: bsn
       tests:
         - bsn_valid

   Faalt als:
     - lengte != 9
     - eerste cijfer == '0'
     - 11-proef faalt
   NULLs worden genegeerd (gebruik `not_null` test daarvoor).
#}
{% test bsn_valid(model, column_name) %}

with bsn_check as (
    select
        {{ column_name }} as bsn,
        cast(substr({{ column_name }}, 1, 1) as integer) as d1,
        cast(substr({{ column_name }}, 2, 1) as integer) as d2,
        cast(substr({{ column_name }}, 3, 1) as integer) as d3,
        cast(substr({{ column_name }}, 4, 1) as integer) as d4,
        cast(substr({{ column_name }}, 5, 1) as integer) as d5,
        cast(substr({{ column_name }}, 6, 1) as integer) as d6,
        cast(substr({{ column_name }}, 7, 1) as integer) as d7,
        cast(substr({{ column_name }}, 8, 1) as integer) as d8,
        cast(substr({{ column_name }}, 9, 1) as integer) as d9
    from {{ model }}
    where {{ column_name }} is not null
      and length({{ column_name }}) = 9
      and regexp_like({{ column_name }}, '^[0-9]{9}$')
),
proef as (
    select
        bsn,
        (9*d1 + 8*d2 + 7*d3 + 6*d4 + 5*d5 + 4*d6 + 3*d7 + 2*d8 - d9) as proef
    from bsn_check
)
-- Een rij retourneren = test fail
select bsn from proef
where mod(proef, 11) <> 0

union all

-- Lege/te-korte/leading-zero BSN's (niet meegenomen in bsn_check) — apart vangen
select {{ column_name }} as bsn
from {{ model }}
where {{ column_name }} is not null
  and (
    length({{ column_name }}) <> 9
    or not regexp_like({{ column_name }}, '^[0-9]{9}$')
    or substr({{ column_name }}, 1, 1) = '0'
  )

{% endtest %}
