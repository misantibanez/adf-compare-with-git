# Comparacion de pipelines ADF con GitHub en Python

Version independiente de la implementacion PowerShell, con los mismos tres
modos de ejecucion, codigos de salida y reglas `PipelineDefinition-v2`.
Usa **Python 3.10+ y solo la biblioteca estandar**: no requiere `pip install`.
Python 3.12 es la version validada en este entorno.

Los siguientes comandos se ejecutan desde la raiz del proyecto en PowerShell.
Si ya estas dentro de esta carpeta, omite `.\python\` en los comandos.

## 1. Recomendado: flujo completo desde ADF publicado

Requiere Azure CLI 2.54+, una sesion autenticada y permisos de lectura en la
factoria (por ejemplo, Reader). El script no inicia sesion interactivamente,
no cambia la suscripcion predeterminada y no ejecuta ni publica pipelines.

```powershell
az login

python .\python\compare_adf_factory.py `
    --factory-resource-id '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mi-resource-group/providers/Microsoft.DataFactory/factories/mi-data-factory' `
    --repo-url 'https://github.com/OWNER/REPO' `
    --comparison-mode PipelineDefinition `
    --output-directory '.\python\adf-comparison'

$LASTEXITCODE
```

Sustituye el Resource ID y `OWNER/REPO` por tus propios valores.
El Resource ID se recibe como parametro y se extraen la suscripcion,
el resource group y la factoria. Se listan los pipelines publicados con
paginacion y se exporta la respuesta original de cada GET, sin reformatearla.
Se genera la plantilla `AdfPath` y se buscan los nombres en el repositorio.

Cada ejecucion crea una carpeta nueva con nombre de factoria, fecha y UUID:

```text
python\adf-comparison\
  FACTORIA-FECHA-ID\
    exports\
      MiPipeline.json
    pipelines.csv
    export-status.csv
    comparison-results.csv
```

Los archivos originales se conservan incluso en modo normalizado.
Si una exportacion falla, se continua con las demas y el reporte incluye
`ERROR` con la causa. No se conserva un archivo parcial. Los errores generales
de autenticacion, listado o GitHub pueden impedir generar un reporte final;
las exportaciones ya realizadas y su estado se conservan.
Sin pipelines publicados se devuelve error, no una coincidencia.

La API solo devuelve el estado **publicado**, no cambios pendientes en Git.
Evita publicar durante la exportacion: ADF no proporciona aqui una
instantanea atomica de todas las definiciones.
Los tokens de Azure se renuevan antes de vencer y no se escriben en disco.

## 2. Comparar desde una plantilla CSV

Completa [pipelines-template.csv](./pipelines-template.csv) con una columna
`AdfPath` y una ruta local por fila. Puedes editarla en Excel y guardarla como
CSV UTF-8 (no `.xlsx`). Las rutas relativas se resuelven desde la carpeta del CSV.

```powershell
python .\python\compare_adf_pipelines.py `
    --csv-path '.\python\pipelines-template.csv' `
    --repo-url 'https://github.com/OWNER/REPO' `
    --comparison-mode PipelineDefinition `
    --report-path '.\python\comparison-results.csv'
```

Se busca el nombre exacto de cada JSON en la raiz y subcarpetas, distinguiendo
mayusculas/minusculas. Si falta o hay varios con el mismo nombre, la fila
queda como `ERROR`; no se elige arbitrariamente. No se siguen enlaces simbolicos.
Las URLs generadas se guardan en el reporte, no se modifica la plantilla.

Para URLs explicitas por fila, usa columnas `AdfPath` y `GitUrl`, y omite
`--repo-url`. Esto permite seleccionar archivos con nombres duplicados o
comparar varios repositorios. Con `--repo-url` se ignoran los `GitUrl` previos.

Si Excel utiliza punto y coma, agrega `--delimiter ';'`. El reporte usa
el mismo separador. Las rutas con comas deben estar entre comillas dobles.
La carpeta del reporte debe existir. Un reporte existente se reemplaza;
no puede ser el CSV de entrada ni uno de los archivos ADF listados.

## 3. Comparacion individual

Con un archivo de GitHub:

```powershell
python .\python\compare_adf_pipeline.py `
    --adf-path 'C:\ADF-Exports\MiPipeline.json' `
    --git-url 'https://github.com/OWNER/REPO/blob/main/pipeline/MiPipeline.json' `
    --comparison-mode PipelineDefinition
```

Con otro archivo local:

```powershell
python .\python\compare_adf_pipeline.py `
    --adf-path 'C:\ADF-Exports\MiPipeline.json' `
    --git-path 'C:\Repos\MiRepo\pipeline\MiPipeline.json' `
    --comparison-mode ExactBytes
```

La salida individual es JSON con hashes, modo y resultado.
Usa `--help` en cualquiera de los tres scripts para consultar sus parametros.

## GitHub y autenticacion

- Solo se admite GitHub.com mediante HTTPS, sin credenciales, query ni fragmento.
- `--repo-url`: `https://github.com/OWNER/REPO`, con `/` final o sufijo `.git`.
- `--git-url`: `https://github.com/OWNER/REPO/blob/REF/PATH.json`.
  Si REF contiene `/`, codificalo como `%2F` en la URL de archivo.
- Con un repositorio, usa `--git-ref 'feature/test'` para elegir rama, etiqueta
  o commit. Si se omite, se usa la rama predeterminada. Se fija un commit para
  toda la comparacion y se consulta el arbol una sola vez. Un arbol truncado
  produce error explicito, no una busqueda incompleta.
- Para repositorios privados, configura `GH_TOKEN` o `GITHUB_TOKEN` con lectura
  de contenido y autorizacion SSO cuando aplique. `GH_TOKEN` tiene prioridad.
  No se reutiliza automaticamente `gh auth login`.
- Se descarga contenido raw, no HTML. Las solicitudes tienen timeout de
  60 segundos y no siguen redirecciones. No se envia el token de Azure a GitHub.
- Los errores HTTP, limites de API, red o permisos son errores, no diferencias.

## Criterios de comparacion

`--comparison-mode ExactBytes` es el **predeterminado**, igual que PowerShell.
Compara SHA-256 sobre los bytes originales, incluido formato, metadata, BOM
y saltos de linea; no valida la sintaxis JSON.

Para el contenido de pipelines usa `--comparison-mode PipelineDefinition`.
Es la normalizacion versionada **PipelineDefinition-v2**, con hashes compatibles
con la implementacion C#/PowerShell para los valores soportados:

1. Valida objeto raiz, `name` no vacio y `properties` de tipo objeto.
2. Si existe `type` en la raiz, valida que sea
   `Microsoft.DataFactory/factories/pipelines`.
3. Excluye solo `id`, `etag`, `type` de la raiz y `properties.lastPublishTime`.
4. Trata `properties.policy.elapsedTimeMetric: {}` como ausente. Si la politica
   queda vacia (o ya lo estaba), tambien la trata como ausente.
5. Conserva todos los demas campos, incluidos los desconocidos y anidados.
   Politicas configuradas, valores `null` y politicas de actividades se comparan.
6. Ordena propiedades con criterio ordinal UTF-16 y conserva orden de arrays.
   Ignora sangria, BOM, codificacion, salto final y escapes JSON equivalentes;
   no cambia espacios dentro de cadenas, SQL, expresiones ni fechas.
7. Normaliza numeros sin redondeo (`1`, `1.0`, `1e0` son equivalentes),
   conservando diferencias de tipo, ausencia, `null`, objetos y arrays.
8. Calcula SHA-256 sobre la representacion determinista UTF-8 sin BOM.

No elimina objetos vacios en otras rutas ni inventa valores predeterminados.
Cambiar actividades, valores, referencias, dependencias, parametros o nombre
del pipeline sigue produciendo `DIFFERENT`. JSON invalido, claves duplicadas,
NaN/Infinity, estructuras incorrectas o limites numericos/profundidad excedidos
producen `ERROR`. Se admiten hasta 256 niveles y los numeros finitos soportados
por `decimal.Decimal` cuyo exponente normalizado cabe en Int64.
Es un formato propio versionado, no RFC 8785 ni equivalencia de ejecucion.

## Reporte y codigos de salida

| Campo | Descripcion |
| --- | --- |
| `AdfSHA256`, `GitSHA256` | Hashes de los archivos originales |
| `BytesIdentical` | Igualdad de los hashes originales |
| `AdfDefinitionSHA256`, `GitDefinitionSHA256` | Hashes normalizados, si aplica |
| `DefinitionIdentical` | Igualdad normalizada, si aplica |
| `ComparisonMode`, `NormalizationVersion` | Criterio y version de las reglas |
| `Identical`, `Result` | Resultado segun el modo seleccionado |
| `Error` | Causa del fallo; nunca se trata como coincidencia |

El reporte CSV tambien incluye `Row`, las rutas y `GitUrl` fijado al commit.
`Row` cuenta registros desde 2, no necesariamente lineas fisicas si hay campos
multilinea. En modo local individual se incluye `GitPath`.
Es posible `MATCH` con `BytesIdentical=False` y `DefinitionIdentical=True`.

- `0`: todas las comparaciones coinciden.
- `1`: existe alguna diferencia y no hay errores.
- `2`: existe algun error, incluidos errores de parametros.

Las exportaciones pueden contener informacion sensible: revisalas antes de
compartirlas. La salida predeterminada `adf-comparison` y la carpeta de ejemplo
de Python estan excluidas de Git. Si eliges otra ubicacion, gestiona su exclusion.
La version Python no depende de PowerShell ni modifica sus scripts o plantillas.
La implementacion alternativa se encuentra en [powershell](../powershell/README.md).

## Pruebas

Desde la raiz del proyecto:

```powershell
python -m unittest discover -s .\python\tests -v
```

Las pruebas usan archivos temporales y APIs simuladas; no necesitan tokens,
Azure CLI ni acceso a Azure/GitHub. Cubren los tres flujos, errores, paginacion,
autenticacion, reportes, preservacion de bytes y cambios reales del pipeline.
Una prueba adicional verifica paridad de hashes con C#/PowerShell cuando `pwsh`
esta instalado; se omite automaticamente en caso contrario.
