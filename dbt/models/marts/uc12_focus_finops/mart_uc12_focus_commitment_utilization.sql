{{ config(
    materialized='table',
    properties=table_format_properties()
) }}

-- UC-12 — Commitment-utilization (committed vs on-demand spend).
--
-- Hoeveel van de spend gaat door committed-discounts (savings plans,
-- reserved instances) versus standard on-demand? Per maand × provider ×
-- service-categorie. Coverage% = committed_spend / total_usage_spend.

with src as (
    select * from {{ ref('stg_focus_billing') }}
    where charge_category = 'Usage'
),

aggregated as (
    select
        billing_month,
        provider,
        service_category,
        billing_currency,

        sum(case when pricing_category = 'Committed'
                 then effective_cost else 0 end)      as committed_spend,
        sum(case when pricing_category = 'Standard'
                 then effective_cost else 0 end)      as on_demand_spend,
        sum(case when pricing_category = 'Dynamic'
                 then effective_cost else 0 end)      as dynamic_spend,
        sum(effective_cost)                           as total_spend,
        sum(savings_amount)                           as savings_amount,

        count(distinct case when pricing_category = 'Committed'
                            then commitment_discount_id end) as n_active_commitments
    from src
    group by billing_month, provider, service_category, billing_currency
)

select
    *,
    case when total_spend > 0
         then committed_spend / total_spend
         else 0 end                                   as commitment_coverage_pct,
    case when (committed_spend + on_demand_spend + dynamic_spend) > 0
         then savings_amount / (committed_spend + on_demand_spend + dynamic_spend + savings_amount)
         else 0 end                                   as effective_discount_pct
from aggregated
