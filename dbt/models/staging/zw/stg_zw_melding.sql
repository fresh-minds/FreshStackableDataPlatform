{{ config(materialized='view') }}

with src as (
    select payload, kafka_ts, event_date
    from {{ source('bronze', 'zw_melding') }}
)

select
    json_extract_scalar(payload, '$.payload.melding_id')              as melding_id,
    json_extract_scalar(payload, '$.payload.bsn')                     as bsn,
    cast(json_extract_scalar(payload, '$.payload.eerste_ziektedag') as date) as eerste_ziektedag,
    cast(json_extract_scalar(payload, '$.payload.duur_dagen') as integer) as duur_dagen,
    kafka_ts                                                           as ingestion_kafka_ts,
    event_date
from src
