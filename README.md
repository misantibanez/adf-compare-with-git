# Comparar pipelines de ADF con GitHub usando SHA-256

Dos implementaciones independientes para exportar pipelines publicados desde
Azure Data Factory, buscar sus archivos en GitHub y generar un reporte:

| Version | Carpeta e instrucciones | Requisitos |
| --- | --- | --- |
| Python | [python](./python/README.md) | Python 3.10+, sin paquetes adicionales |
| PowerShell | [powershell](./powershell/README.md) | Windows PowerShell 5.1 o PowerShell 7 |

Para consultar ADF, ambas requieren Azure CLI 2.54+, autenticacion con
`az login` y permisos de lectura en la factoria. No publican ni ejecutan pipelines.

## Primera alternativa: flujo completo desde ADF

### Python

Desde la raiz del proyecto:

```powershell
python .\python\compare_adf_factory.py `
    --factory-resource-id '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mi-resource-group/providers/Microsoft.DataFactory/factories/mi-data-factory' `
    --repo-url 'https://github.com/OWNER/REPO' `
    --comparison-mode PipelineDefinition `
    --output-directory '.\python\adf-comparison'
```

### PowerShell

Desde la raiz del proyecto:

```powershell
pwsh -NoProfile -File .\powershell\Compare-AdfFactory.ps1 `
    -FactoryResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mi-resource-group/providers/Microsoft.DataFactory/factories/mi-data-factory' `
    -RepoUrl 'https://github.com/OWNER/REPO' `
    -ComparisonMode PipelineDefinition `
    -OutputDirectory '.\powershell\adf-comparison'
```

Cada ejecucion conserva las exportaciones JSON originales, genera una plantilla
`AdfPath` y guarda los resultados de exportacion y comparacion en una carpeta nueva.
Sustituye el Resource ID y `OWNER/REPO` de los ejemplos por tus propios valores.

## Otras alternativas

Ambas versiones permiten comparar desde una plantilla CSV o un archivo individual.
Cada carpeta contiene sus propios scripts, plantilla, documentacion y pruebas.

- `ExactBytes` (predeterminado): compara todos los bytes, incluidos formato y metadata.
- `PipelineDefinition`: aplica las reglas `PipelineDefinition-v2`, ignorando formato
  y metadatos especificos de ADF sin descartar los cambios reales de definicion.
  Consulta las reglas detalladas en la documentacion de cada version.

SHA-256 es un hash, no cifrado ni firma digital. Los reportes conservan los hashes
originales y, cuando aplica, los normalizados.
Codigos de salida: `0` todos coinciden, `1` diferencias sin errores, `2` algun error.

## Pruebas

Desde la raiz:

```powershell
python -m unittest discover -s .\python\tests -v

pwsh -NoProfile -File .\powershell\tests\Compare-AdfFactory.Tests.ps1
pwsh -NoProfile -File .\powershell\tests\Compare-AdfPipelines.Tests.ps1
pwsh -NoProfile -File .\powershell\tests\Compare-AdfPipeline.Tests.ps1
pwsh -NoProfile -File .\powershell\tests\PipelineDefinition.Tests.ps1
```
