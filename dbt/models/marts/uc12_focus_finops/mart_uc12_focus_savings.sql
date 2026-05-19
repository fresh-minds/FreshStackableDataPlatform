{{ config(
    materialized='table',
    properties=table_format_properties()
) }}

-- UC-12 — Savings-mart: list-vs-effective per dimensie.
--
-- Voedt de KPI-strip "totale savings deze maand" + drill-down "waar komt
-- savings vandaan". Eén rij per (billing_month × provider × pricing_category
-- × service_category). Negatieve savings betekent dat de effective cost
-- hoger is dan de list — gebeurt bij overages of Tax/Adjustment regels.

with src as (
    select * from {{ ref('stg_focus_billing') }}
)

select
    billing_month,
    provider,
    pricing_category,
    service_category,
    charge_category,
    billing_currency,

    sum(coalesce(list_cost, effective_cost))          as list_cost,
    sum(effective_cost)                               as effective_cost,
    sum(savings_amount)                               as savings_amount,
    case when sum(coalesce(list_cost, effective_cost)) > 0
         then sum(savings_amount) / sum(coalesce(list_cost, effective_cost))
         else 0 end                                   as savings_pct,

    count(*)                                          as n_charges,
    count(distinct resource_id)                       as n_resources
from src
group by
    billing_month, provider, pricing_category,
    service_category, charge_category, billing_currency
