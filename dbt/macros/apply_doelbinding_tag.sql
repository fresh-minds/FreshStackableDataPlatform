{# Documentatie-helper. Genereert geen SQL — bestaat zodat schema.yml in elke
   model een `meta.doelbinding`-array heeft die OpenMetadata's dbt-workflow
   oppikt en als classifications/tags propageert.

   Convention voor elk model in marts/* en bepaalde silver/* :
     meta:
       doelbinding: [uitkering, reintegratie]
       legal_basis: WIA_art_64
       bewaartermijn_jaren: 7
       pii_kolommen: [bsn]
       risk_tier: laag

   Deze macro is een no-op; zie scripts/check-meta-completeness.py (TODO fase 9)
   voor CI-validatie dat elk model verplichte meta-velden heeft.
#}
{% macro apply_doelbinding_tag() %}
    -- no-op
{% endmacro %}
