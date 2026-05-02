{{ config(materialized='view') }}

with src as (
    select payload, kafka_ts, event_date
    from {{ source('bronze', 'wia_aanvraag') }}
)

select
    json_extract_scalar(payload, '$.payload.aanvraag_id')                  as aanvraag_id,
    json_extract_scalar(payload, '$.payload.bsn')                          as bsn,
    cast(json_extract_scalar(payload, '$.payload.aanvraag_datum') as date) as aanvraag_datum,
    cast(json_extract_scalar(payload, '$.payload.eerste_ziektedag') as date) as eerste_ziektedag,
    json_extract_scalar(payload, '$.payload.onderdeel')                    as onderdeel,
    json_extract_scalar(payload, '$.payload.regio_code')                   as regio_code,
    json_extract_scalar(payload, '$.payload.status')                       as status,
    cast(json_extract_scalar(payload, '$.payload.arbeidsongeschikt_pct') as integer) as arbeidsongeschikt_pct,
    kafka_ts                                                                as ingestion_kafka_ts,
    event_date
from src
