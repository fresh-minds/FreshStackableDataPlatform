# platform/12-powerbi — Power BI-rapport (UC-12 FOCUS FinOps)

De **Power BI-variant** van het UC-12 FOCUS-FinOps-dashboard, als
[PBIP-project](https://learn.microsoft.com/power-bi/developer/projects/projects-overview)
(`uc12_focus_finops/`). Dit is de Microsoft-stack-variant van het open-source
Superset-dashboard (`platform/12-superset/`) en hoort bij de AKS/Entra-deploy.

## Wat zit hier?

| Pad | Doel |
|---|---|
| [`uc12_focus_finops/Report/`](uc12_focus_finops/Report/) | De rapportdefinitie — één pagina met 12 visuals (KPI-strip, spend/coverage-lijnen, verdeling per service/regio/omgeving, top-N tabellen). |
| [`uc12_focus_finops/SemanticModel/`](uc12_focus_finops/SemanticModel/) | Het semantische model (`model.bim`) — Direct Lake op het Fabric-lakehouse. |

Er staan bewust **geen** Kubernetes-manifests in deze map — Power BI / Fabric is
een managed Microsoft-dienst. Het rapport wordt via Fabric/Power BI gepubliceerd
en in de portal ingebed.

## Zie ook

- [UC-12 · FOCUS FinOps — Power BI-variant](../../docs/use-cases/uc12-focus-finops-powerbi.md) — de spec van deze variant.
- [UC-12 · FOCUS FinOps](../../docs/use-cases/uc12-focus-finops.md) — de open-source Superset-baseline.
- [Power BI in-portal embed (AKS + Entra)](../../docs/use-cases/powerbi-embed-aks-entra.md) — hoe het rapport in de portal-shell wordt ingebed.
- [`platform/12-databricks/`](../12-databricks/) — de Databricks-variant van de verwerkingslaag.
