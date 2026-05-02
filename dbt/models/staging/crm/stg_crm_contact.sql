{{ config(materialized='view') }}

with src as (
    select payload, kafka_ts, event_date
    from {{ source('bronze', 'crm_contact') }}
)

select
    json_extract_scalar(payload, '$.payload.contact_id')             as contact_id,
    json_extract_scalar(payload, '$.payload.bsn')                    as bsn,
    json_extract_scalar(payload, '$.payload.kanaal')                 as kanaal,
    json_extract_scalar(payload, '$.payload.onderwerp')              as onderwerp,
    cast(json_extract_scalar(payload, '$.payload.timestamp') as timestamp) as contact_ts,
    cast(json_extract_scalar(payload, '$.payload.duur_seconden') as integer) as duur_seconden,
    kafka_ts                                                          as ingestion_kafka_ts,
    event_date
from src
