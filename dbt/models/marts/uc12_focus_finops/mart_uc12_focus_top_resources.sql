{{ config(
    materialized='table',
    properties=table_format_properties()
) }}

-- UC-12 — Top-resources per maand op effective_cost.
--
-- Eén rij per (billing_month × resource_id) met aggregated metrics. Geen
-- top-N filter op SQL-niveau — Superset's `row_limit` doet dat per dashboard
-- query. Resources zonder ResourceId (account-level charges) krijgen een
-- synthetic key zodat ze niet samenklonteren.

with src as (
    select * from {{ ref('stg_focus_billing') }}
    where charge_category = 'Usage'
)

select
    billing_month,
    provider,
    coalesce(resource_id, 'account-level:' || sub_account_id) as resource_id,
    max(resource_name)                                as resource_name,
    max(resource_type)                                as resource_type,
    max(service_name)                                 as service_name,
    max(service_category)                             as service_category,
    max(region)                                       as region,
    max(coalesce(tag_application, 'unknown'))         as application,
    max(coalesce(tag_environment, 'unknown'))         as environment,
    max(coalesce(tag_cost_center, 'unknown'))         as cost_center,
    max(sub_account_name)                             as sub_account_name,
    billing_currency,

    sum(effective_cost)                               as effective_cost,
    sum(billed_cost)                                  as billed_cost,
    sum(usage_quantity)                               as usage_quantity,
    max(usage_unit)                                   as usage_unit,
    count(*)                                          as n_charges,
    -- Rank per maand × provider — Superset kan hierop sorteren ipv top-N filter.
    row_number() over (
        partition by billing_month, provider
        order by sum(effective_cost) desc
    )                                                 as rank_in_month
from src
group by
    billing_month, provider,
    coalesce(resource_id, 'account-level:' || sub_account_id),
    billing_currency
