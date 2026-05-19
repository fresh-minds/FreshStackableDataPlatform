{{ config(materialized='view') }}

-- UC-11 — Integrale Klantreis: unified event-stream.
-- UNION ALL over zeven staging-equivalents; één rij per cliënt-gebeurtenis.
-- Geen nieuwe brongegevens; de klantreis is een derivaat.
--
-- Cross-engine portable:
--   - bron via `klantreis_entity(name)` — ref('stg_*') op Trino,
--     source('silver', name) op Fabric (silver_* Lakehouse-tabellen).
--   - types via `dbt.type_timestamp()` / `dbt.type_string()` zodat
--     dezelfde SQL compileert op Trino (timestamp(6)/varchar) én
--     Spark (timestamp/string).

with persoon as (
    select
        bsn,
        cast(ingestion_source_ts as {{ dbt.type_timestamp() }})    as event_ts,
        event_date                                                  as event_date,
        cast('persoon' as {{ dbt.type_string() }})                  as domein,
        cast('persoon.aangemaakt' as {{ dbt.type_string() }})       as event_type,
        cast('Cliënt-record aangemaakt' as {{ dbt.type_string() }}) as event_label,
        cast(null as {{ dbt.type_string() }})                       as event_status,
        cast(null as {{ dbt.type_string() }})                       as regio_code,
        cast(null as double)                                        as numeric_value,
        bsn                                                         as source_ref_id
    from {{ klantreis_entity('persona') }}
),

ikv_start as (
    select
        bsn,
        cast(aanvang_dienstverband as {{ dbt.type_timestamp() }})   as event_ts,
        aanvang_dienstverband                                       as event_date,
        cast('polisadm' as {{ dbt.type_string() }})                 as domein,
        cast('polisadm.ikv.start' as {{ dbt.type_string() }})       as event_type,
        concat('Dienstverband begonnen bij ',
               coalesce(werkgever_naam, '(onbekend)'))              as event_label,
        cast(null as {{ dbt.type_string() }})                       as event_status,
        cast(null as {{ dbt.type_string() }})                       as regio_code,
        cast(loon_bruto_jaar as double)                             as numeric_value,
        ikv_id                                                      as source_ref_id
    from {{ klantreis_entity('polisadm_ikv') }}
    where aanvang_dienstverband is not null
),

ikv_einde as (
    select
        bsn,
        cast(einde_dienstverband as {{ dbt.type_timestamp() }})     as event_ts,
        einde_dienstverband                                         as event_date,
        cast('polisadm' as {{ dbt.type_string() }})                 as domein,
        cast('polisadm.ikv.einde' as {{ dbt.type_string() }})       as event_type,
        concat('Dienstverband beëindigd bij ',
               coalesce(werkgever_naam, '(onbekend)'))              as event_label,
        cast(null as {{ dbt.type_string() }})                       as event_status,
        cast(null as {{ dbt.type_string() }})                       as regio_code,
        cast(null as double)                                        as numeric_value,
        ikv_id                                                      as source_ref_id
    from {{ klantreis_entity('polisadm_ikv') }}
    where einde_dienstverband is not null
),

ww_evt as (
    select
        bsn,
        cast(aanvraag_datum as {{ dbt.type_timestamp() }})          as event_ts,
        aanvraag_datum                                              as event_date,
        cast('ww' as {{ dbt.type_string() }})                       as domein,
        concat('ww.aanvraag.',
               lower(coalesce(status, 'onbekend')))                 as event_type,
        concat('WW-aanvraag (status: ', coalesce(status, '?'),
               ', reden: ',
               coalesce(reden_einde_dienstverband, '?'),
               ')')                                                 as event_label,
        status                                                      as event_status,
        cast(null as {{ dbt.type_string() }})                       as regio_code,
        cast(null as double)                                        as numeric_value,
        aanvraag_id                                                 as source_ref_id
    from {{ klantreis_entity('ww_aanvraag') }}
),

zw_evt as (
    select
        bsn,
        cast(eerste_ziektedag as {{ dbt.type_timestamp() }})        as event_ts,
        eerste_ziektedag                                            as event_date,
        cast('zw' as {{ dbt.type_string() }})                       as domein,
        cast('zw.melding' as {{ dbt.type_string() }})               as event_type,
        concat('Ziekmelding (duur ~',
               cast(coalesce(duur_dagen, 0) as {{ dbt.type_string() }}),
               ' dagen)')                                           as event_label,
        cast(null as {{ dbt.type_string() }})                       as event_status,
        cast(null as {{ dbt.type_string() }})                       as regio_code,
        cast(duur_dagen as double)                                  as numeric_value,
        melding_id                                                  as source_ref_id
    from {{ klantreis_entity('zw_melding') }}
),

wia_evt as (
    select
        bsn,
        cast(aanvraag_datum as {{ dbt.type_timestamp() }})          as event_ts,
        aanvraag_datum                                              as event_date,
        cast('wia' as {{ dbt.type_string() }})                      as domein,
        concat('wia.aanvraag.',
               lower(coalesce(status, 'onbekend')))                 as event_type,
        concat('WIA-aanvraag (', coalesce(onderdeel, '?'),
               ', status: ', coalesce(status, '?'),
               case when arbeidsongeschikt_pct is not null
                    then concat(', AO ',
                                cast(arbeidsongeschikt_pct as {{ dbt.type_string() }}),
                                '%')
                    else '' end,
               ')')                                                 as event_label,
        status                                                      as event_status,
        regio_code                                                  as regio_code,
        cast(arbeidsongeschikt_pct as double)                       as numeric_value,
        aanvraag_id                                                 as source_ref_id
    from {{ klantreis_entity('wia_aanvraag') }}
),

wajong_evt as (
    select
        bsn,
        cast(ingangsdatum as {{ dbt.type_timestamp() }})            as event_ts,
        ingangsdatum                                                as event_date,
        cast('wajong' as {{ dbt.type_string() }})                   as domein,
        cast('wajong.dossier.geopend' as {{ dbt.type_string() }})   as event_type,
        concat('Wajong-dossier (', coalesce(regime, '?'),
               ', arbeidsvermogen: ',
               coalesce(arbeidsvermogen, '?'),
               ')')                                                 as event_label,
        cast(null as {{ dbt.type_string() }})                       as event_status,
        cast(null as {{ dbt.type_string() }})                       as regio_code,
        cast(null as double)                                        as numeric_value,
        dossier_id                                                  as source_ref_id
    from {{ klantreis_entity('wajong_dossier') }}
    where ingangsdatum is not null
),

crm_evt as (
    select
        bsn,
        cast(contact_ts as {{ dbt.type_timestamp() }})              as event_ts,
        cast(contact_ts as date)                                    as event_date,
        cast('crm' as {{ dbt.type_string() }})                      as domein,
        concat('crm.contact.',
               lower(coalesce(kanaal, 'onbekend')))                 as event_type,
        concat('Klantcontact ', coalesce(kanaal, '?'),
               ' over ', coalesce(onderwerp, '?'))                  as event_label,
        cast(null as {{ dbt.type_string() }})                       as event_status,
        cast(null as {{ dbt.type_string() }})                       as regio_code,
        cast(duur_seconden as double)                               as numeric_value,
        contact_id                                                  as source_ref_id
    from {{ klantreis_entity('crm_contact') }}
)

select * from persoon
union all
select * from ikv_start
union all
select * from ikv_einde
union all
select * from ww_evt
union all
select * from zw_evt
union all
select * from wia_evt
union all
select * from wajong_evt
union all
select * from crm_evt
