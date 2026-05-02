{{ config(materialized='view') }}

with src as (
    select
        payload,
        kafka_ts,
        ingestion_ts,
        event_date
    from {{ source('bronze', 'persona_created') }}
)

select
    json_extract_scalar(payload, '$.payload.bsn')             as bsn,
    json_extract_scalar(payload, '$.payload.voornaam')        as voornaam,
    json_extract_scalar(payload, '$.payload.achternaam')      as achternaam,
    json_extract_scalar(payload, '$.payload.geslacht')        as geslacht,
    cast(json_extract_scalar(payload, '$.payload.geboortedatum') as date) as geboortedatum,
    json_extract_scalar(payload, '$.payload.straat')          as straat,
    cast(json_extract_scalar(payload, '$.payload.huisnummer') as integer) as huisnummer,
    json_extract_scalar(payload, '$.payload.postcode')        as postcode,
    json_extract_scalar(payload, '$.payload.woonplaats')      as woonplaats,
    json_extract_scalar(payload, '$.payload.nationaliteit')   as nationaliteit,
    kafka_ts                                                  as ingestion_kafka_ts,
    event_date
from src
