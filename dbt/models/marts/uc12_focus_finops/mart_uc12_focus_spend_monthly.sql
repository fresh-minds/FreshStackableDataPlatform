{{ config(
    materialized='table',
    properties=table_format_properties()
) }}

-- UC-12 — FinOps spend per maand × provider × service-categorie.
--
-- Primaire spend-trend mart. Eén rij per (billing_month × provider ×
-- service_category × charge_category). Houdt charge_category gesplitst zodat
-- dashboards Credits (negatief) en Purchases (one-time upfront) apart kunnen
-- weergeven van Usage-spend.

with src as (
    select * from {{ ref('stg_focus_billing') }}
)

select
    billing_month,
    provider,
    service_category,
    charge_category,
    billing_currency,

    sum(billed_cost)                                  as billed_cost,
    sum(effective_cost)                               as effective_cost,
    sum(coalesce(list_cost, effective_cost))          as list_cost,
    sum(savings_amount)                               as savings_amount,

    sum(usage_quantity)                               as usage_quantity,
    count(*)                                          as n_charges,
    count(distinct resource_id)                       as n_resources,
    count(distinct sub_account_id)                    as n_sub_accounts
from src
group by
    billing_month, provider, service_category,
    charge_category, billing_currency
