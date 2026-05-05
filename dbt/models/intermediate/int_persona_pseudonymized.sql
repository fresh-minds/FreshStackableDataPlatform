{{ config(materialized='view', tags=['intermediate']) }}

-- Pseudo-identifier voor downstream-marts die geen ruwe BSN nodig hebben.
-- Gebruikt de centrale `pseudonymize`-macro (SHA-256 + zout) — productie zou
-- HSM-gestuurde tokenisatie + per-cliënt-zout gebruiken.
--
-- Improvements #7: macro daadwerkelijk toepassen.

with src as (
    select * from {{ ref('stg_persona') }}
)

select
    bsn,
    {{ pseudonymize('bsn') }}      as bsn_pseudo,
    voornaam,
    achternaam,
    geslacht,
    geboortedatum,
    -- Voor rapportages die alleen leeftijdsbereik nodig hebben — geen exact dob.
    date_diff('year', geboortedatum, current_date) as leeftijd,
    cast(date_trunc('year', geboortedatum) as date) as geboortejaar,
    woonplaats,
    postcode,
    nationaliteit
from src
