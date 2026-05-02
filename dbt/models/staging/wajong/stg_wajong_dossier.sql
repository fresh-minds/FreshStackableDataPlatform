{{ config(materialized='view') }}

with src as (
    select payload, kafka_ts, event_date
    from {{ source('bronze', 'wajong_dossier') }}
)

select
    json_extract_scalar(payload, '$.payload.dossier_id')              as dossier_id,
    json_extract_scalar(payload, '$.payload.bsn')                     as bsn,
    json_extract_scalar(payload, '$.payload.regime')                  as regime,
    json_extract_scalar(payload, '$.payload.arbeidsvermogen')         as arbeidsvermogen,
    cast(json_extract_scalar(payload, '$.payload.ingangsdatum') as date) as ingangsdatum,
    kafka_ts                                                           as ingestion_kafka_ts,
    event_date
from src
