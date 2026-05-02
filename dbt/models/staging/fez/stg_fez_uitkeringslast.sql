{{ config(materialized='view') }}

with src as (
    select payload, kafka_ts, event_date
    from {{ source('bronze', 'fez_uitkeringslast') }}
)

select
    cast(json_extract_scalar(payload, '$.payload.jaar') as integer)            as jaar,
    cast(json_extract_scalar(payload, '$.payload.maand') as integer)           as maand,
    json_extract_scalar(payload, '$.payload.wet')                              as wet,
    json_extract_scalar(payload, '$.payload.regio_code')                       as regio_code,
    cast(json_extract_scalar(payload, '$.payload.uitbetaald_bruto_eur') as integer) as uitbetaald_bruto_eur,
    cast(json_extract_scalar(payload, '$.payload.aantal_uitkeringen') as integer)   as aantal_uitkeringen,
    kafka_ts                                                                    as ingestion_kafka_ts,
    event_date
from src
