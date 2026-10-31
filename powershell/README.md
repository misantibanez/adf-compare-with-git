# Comparar pipelines de ADF con GitHub usando SHA-256

**Version Python:** la implementacion independiente esta en
[python](../python/README.md), con flujo completo de ADF, comparacion por CSV
e individual, sin paquetes adicionales. Los comandos de esta pagina son
para la version PowerShell, que sigue disponible.

**Ejecuta los comandos de esta pagina desde la carpeta `powershell`:**

```powershell
Set-Location .\powershell
```

Si prefieres ejecutarlos desde la raiz del proyecto, agrega `.\powershell\`
a las rutas de scripts y plantilla. Las rutas relativas de salida se resuelven
desde tu directorio de ejecucion.

Exporta automaticamente los pipelines publicados de Azure Data Factory y
compara sus archivos JSON con GitHub mediante SHA-256. Como alternativas,
permite comparar archivos JSON que ya tengas guardados localmente.

## Alternativas de uso

1. **Recomendada: [Compare-AdfFactory.ps1](./Compare-AdfFactory.ps1)**.
   Solo proporciona el Resource ID de ADF y la URL del repositorio: exporta
   los pipelines, genera la plantilla y compara todos los archivos.
2. **Por lotes: [Compare-AdfPipelines.ps1](./Compare-AdfPipelines.ps1)**.
   Si ya tienes los JSON locales, indica sus rutas en una plantilla CSV.
3. **Individual: [Compare-AdfPipeline.ps1](./Compare-AdfPipeline.ps1)**.
   Compara un JSON local con un archivo de GitHub o con otro archivo local.

SHA-256 es un hash, no un cifrado ni una firma digital. No requiere una clave
secreta. La coincidencia de hashes es evidencia de igualdad de contenido;
no demuestra quien creo el archivo ni su autenticidad.

## Requisitos

- Windows PowerShell 5.1 o PowerShell 7.
- Un archivo JSON local, o acceso de lectura a ADF para el flujo automatico.
- La URL del repositorio o del archivo JSON en GitHub, o una copia local.
- Los modos con archivos locales no requieren modulos ni acceso a Azure.
  Para URLs se requiere acceso a Internet.
- Los repositorios publicos no requieren credenciales. Para repositorios privados,
  configura `GH_TOKEN` o `GITHUB_TOKEN` con permiso de lectura de contenido
  del repositorio (y autorizacion SSO si corresponde). `GH_TOKEN` tiene prioridad.
  Usa variables de entorno o un gestor de secretos; no guardes tokens en archivos.
  No utiliza automaticamente las credenciales de `gh auth login`.

## Alternativa 1 (recomendada): Compare-AdfFactory - flujo completo

[Compare-AdfFactory.ps1](./Compare-AdfFactory.ps1) recibe el Resource ID completo
de una factoria y la URL de un repositorio. No necesita una plantilla previa:

1. Lista todos los pipelines publicados, siguiendo `nextLink`.
2. Descarga cada definicion con la API REST `2018-06-01`.
3. Genera un CSV con `AdfPath` para todas las definiciones.
4. Busca los nombres en el repositorio y fija un commit para la comparacion.
5. Compara los SHA-256 y guarda el reporte.

Requiere **Azure CLI 2.54 o posterior**, una sesion autenticada con `az login`
y permisos de lectura en ADF (por ejemplo, rol Reader en la factoria).
Para automatizacion, Azure CLI tambien puede estar autenticada con una identidad
administrada o un service principal. El script no inicia sesiones interactivas.

```powershell
az login

pwsh -NoProfile -File .\Compare-AdfFactory.ps1 `
    -FactoryResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mi-resource-group/providers/Microsoft.DataFactory/factories/mi-data-factory' `
    -RepoUrl 'https://github.com/OWNER/REPO' `
    -OutputDirectory '.\adf-comparison'

$LASTEXITCODE
```

Sustituye el Resource ID y `OWNER/REPO` por tus propios valores.
El Resource ID es un parametro: se extraen la suscripcion, el resource group
y el nombre de ADF. No estan fijados en el codigo y no se cambia la suscripcion
predeterminada de Azure CLI. Las llamadas a Azure solo leen recursos;
no publican ni ejecutan pipelines.

Opciones: `-GitRef 'main'` para elegir otra referencia de GitHub y
`-Delimiter ';'` para generar CSV separados por punto y coma.

Cada ejecucion crea una carpeta nueva con nombre de factoria, fecha y un
identificador unico dentro de `OutputDirectory`, sin reemplazar ejecuciones previas:

```text
adf-comparison\
  mi-data-factory-FECHA-ID\
    exports\
      PL_Ejemplo_2_Actividades.json
      PL_Ejemplo_3_Actividades.json
    pipelines.csv
    export-status.csv
    comparison-results.csv
```

- `exports`: cuerpos JSON originales de las respuestas GET individuales.
- `pipelines.csv`: plantilla automatica con una columna `AdfPath`.
- `export-status.csv`: resultado y error de exportacion por pipeline.
- `comparison-results.csv`: URLs de GitHub, hashes, resultados y errores.

**Por defecto se comparan bytes exactos (`ExactBytes`).** En los archivos exportados se conservan
`id`, `type`, `etag`, codificacion, sangria y saltos de linea de la respuesta.
La definicion se inspecciona para validar la descarga, pero nunca se vuelve
a serializar. Un JSON copiado del editor de ADF puede ser diferente a la
respuesta ARM aunque describa el mismo pipeline. Para comparar la definicion
con JSON copiados de la UI, agrega `-ComparisonMode PipelineDefinition`
(reglas en la siguiente seccion). La normalizacion solo se realiza en memoria;
los archivos originales se conservan intactos en ambos modos.
Nunca se utiliza `etag` como hash SHA-256.

La API devuelve el estado **publicado**, no cambios pendientes en una rama.
Las lecturas de distintos pipelines no son una instantanea atomica de ADF:
evita publicar cambios durante la exportacion.
El token de Azure se obtiene para la suscripcion indicada, se renueva si esta
proximo a vencer y no se escribe en archivos ni reportes.
La autenticacion de GitHub se configura por separado mediante `GH_TOKEN`
o `GITHUB_TOKEN` cuando sea necesaria.

Si una descarga falla, no se conserva un archivo parcial: la fila queda como
`ERROR`, se continua con los demas pipelines y se incluye la causa de Azure
en el reporte final. Los archivos exportados con exito se conservan.
Si falla la autenticacion, la lista, la consulta del repositorio o la escritura,
el proceso devuelve `2` y notifica el error; puede no haber un reporte final.
Una factoria sin pipelines publicados devuelve `2`, no un resultado de igualdad.
Los demas codigos son `0` (todos coinciden) y `1` (hay diferencias sin errores).

La plantilla manual existente no se modifica. Las exportaciones pueden contener
informacion sensible de las definiciones: revisa los archivos antes de compartirlos.
La carpeta predeterminada `adf-comparison` esta excluida mediante `.gitignore`;
si eliges otra ubicacion, gestiona su exclusion y permisos.

Referencias: [listar pipelines](https://learn.microsoft.com/rest/api/datafactory/pipelines/list-by-factory?view=rest-datafactory-2018-06-01)
y [obtener un pipeline](https://learn.microsoft.com/rest/api/datafactory/pipelines/get?view=rest-datafactory-2018-06-01).

## Modos de comparacion

Los tres scripts aceptan `-ComparisonMode ExactBytes` (predeterminado,
comportamiento anterior) o `-ComparisonMode PipelineDefinition`.
Para JSON copiados de la UI, o desplegados sin cambios de definicion en otro
ADF, utiliza el segundo modo:

```powershell
pwsh -NoProfile -File .\Compare-AdfFactory.ps1 `
    -FactoryResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/mi-resource-group/providers/Microsoft.DataFactory/factories/mi-data-factory' `
    -RepoUrl 'https://github.com/OWNER/REPO' `
    -ComparisonMode PipelineDefinition `
    -OutputDirectory '.\adf-comparison'
```

### Reglas PipelineDefinition-v2

Se valida que cada documento sea un objeto con `name` no vacio y `properties`
de tipo objeto. Si existe `type` en la raiz, debe ser exactamente
`Microsoft.DataFactory/factories/pipelines`. Solo se excluyen del hash:

| Ruta exacta | Motivo |
| --- | --- |
| `id` en la raiz | Identidad del recurso y entorno |
| `etag` en la raiz | Version del recurso |
| `type` en la raiz | Metadato de recurso, previamente validado si existe |
| `properties.lastPublishTime` | Fecha de publicacion |

No se eliminan campos con esos nombres en otras rutas.
Se comparan `name`, todas las demas propiedades y cualquier campo desconocido
en la raiz. Por ejemplo, el `type` de una actividad, un `id` anidado,
parametros, dependencias, politicas, expresiones, SQL y referencias a datasets
o linked services siguen participando.

Los objetos se ordenan recursivamente por nombre de propiedad usando orden
ordinal sensible a mayusculas. Los arrays conservan orden y cardinalidad.
Se ignoran sangria, orden de propiedades, BOM, codificacion de texto,
saltos CRLF/LF, salto final y escapes JSON equivalentes. No se alteran
espacios ni mayusculas dentro de cadenas, ni se convierten fechas.
Los numeros se normalizan sin redondeo: `1`, `1.0` y `1e0` son equivalentes;
`"1"` no es igual a `1`. Ausencia, `null`, cadena vacia, objeto y array son
distintos. No se agregan valores predeterminados.

Excepcion acotada para la representacion de la API: un objeto vacio en
`properties.policy.elapsedTimeMetric` se trata como ausente. Si despues de
esa regla `properties.policy` queda vacio, tambien se trata como ausente.
Esto permite comparar la respuesta API `"policy":{"elapsedTimeMetric":{}}`
con la UI que no muestra esa politica. Un `elapsedTimeMetric` configurado,
otros campos de la politica, valores `null` y todas las politicas de actividades
siguen comparandose. No se eliminan objetos vacios en otras rutas.
Esta regla se incorpora en v2; los reportes v1 previos no se modifican.

La representacion determinista se codifica en UTF-8 sin BOM para calcular SHA-256.
Es un formato propio versionado, no una implementacion de RFC 8785 ni una
prueba de equivalencia de ejecucion. El normalizador compartido en
[PipelineDefinition.cs](./PipelineDefinition.cs) se carga con `Add-Type`,
sin paquetes adicionales. Evita conversiones de fecha, claves insensibles
a mayusculas y redondeos numericos de los conversores JSON de PowerShell.
JSON invalido, claves duplicadas o estructura incorrecta devuelven `ERROR`,
incluso si ambos archivos tienen los mismos bytes. Se admite profundidad
de hasta 256 niveles y exponentes numericos normalizados dentro de Int64;
si se exceden esos limites se devuelve un error explicito.

### Evidencia en el reporte

| Campo | Significado |
| --- | --- |
| `ComparisonMode` | Criterio seleccionado para `Result` e `Identical` |
| `AdfSHA256`, `GitSHA256` | Hashes de los archivos originales, en ambos modos |
| `BytesIdentical` | Igualdad de hashes originales |
| `AdfDefinitionSHA256`, `GitDefinitionSHA256` | Hashes normalizados; solo en `PipelineDefinition` |
| `DefinitionIdentical` | Igualdad bajo las reglas de normalizacion; vacio en `ExactBytes` |
| `NormalizationVersion` | `PipelineDefinition-v2`; vacio en `ExactBytes` |
| `Identical` | Igualdad segun el modo seleccionado |

Un resultado `MATCH` con `BytesIdentical=False` y `DefinitionIdentical=True`
indica definiciones iguales bajo estas reglas, no archivos identicos.
Un fallo de normalizacion es `ERROR` y devuelve codigo `2`, nunca `MATCH`
ni `DIFFERENT`. Los hashes originales disponibles se conservan como evidencia.
No se modifican archivos locales, exportaciones ni contenido remoto.

## Alternativa 2: comparacion por lotes usando una plantilla

1. Copia [pipelines-template.csv](./pipelines-template.csv) y abre la copia
   en Excel o en un editor de texto.
2. Solo necesitas la columna `AdfPath`: agrega una ruta local por pipeline.
   No incluyas tokens. Las rutas que ya completaste en la plantilla se conservan.
3. Guarda como **CSV UTF-8**, no como archivo `.xlsx`.
4. Ejecuta:

```powershell
pwsh -NoProfile -File .\Compare-AdfPipelines.ps1 `
    -CsvPath '.\pipelines-template.csv' `
    -RepoUrl 'https://github.com/OWNER/REPO' `
    -ReportPath '.\comparison-results.csv'

$LASTEXITCODE
```

El script obtiene el nombre del archivo de cada `AdfPath`, busca ese mismo
nombre en todo el repositorio (raiz y subcarpetas), construye `GitUrl` y compara
los bytes. No necesitas escribir las URLs de los pipelines.

- La busqueda por nombre es exacta y distingue mayusculas/minusculas.
- Si no encuentra el nombre, marca esa fila como `ERROR`.
- Si encuentra el mismo nombre en varias carpetas, marca `ERROR` e indica
  las rutas candidatas. No elige arbitrariamente.
- Solo considera archivos JSON normales, no carpetas ni enlaces simbolicos.
- Usa la rama predeterminada del repositorio. Para otra rama, etiqueta o
  commit, agrega `-GitRef 'feature/test'` (sin codificar `/`).
- Resuelve la referencia una sola vez y fija todas las URLs al mismo commit
  durante la ejecucion. El reporte conserva esas URLs reproducibles.
- La consulta del arbol del repositorio se hace una vez. Si GitHub devuelve
  un arbol truncado, el proceso falla explicitamente en vez de buscar sobre
  una lista incompleta.
- Admite `https://github.com/OWNER/REPO`, con `/` final o sufijo `.git`.
  No admite URLs de carpetas, archivos ni hosts de GitHub Enterprise en `RepoUrl`.
- El CSV original no se modifica: las URLs generadas se guardan en la columna
  `GitUrl` del reporte. Si el CSV ya tiene `GitUrl`, el modo `-RepoUrl` ignora
  esos valores y genera todas las URLs a partir del repositorio indicado.

### Modo anterior: URLs explicitas por fila

Para escoger una ruta especifica cuando hay nombres duplicados, o comparar
archivos de distintos repositorios, usa un CSV con `AdfPath` y `GitUrl`
y ejecuta sin `-RepoUrl`:

```powershell
pwsh -NoProfile -File .\Compare-AdfPipelines.ps1 `
    -CsvPath '.\pipelines-con-urls.csv' `
    -ReportPath '.\comparison-results.csv'
```

En ese modo `GitUrl` es obligatorio para cada fila. No se permite `-GitRef`
sin `-RepoUrl`.

La plantilla usa comas. Si Excel guarda el CSV con punto y coma, agrega
`-Delimiter ';'`. El reporte usa el mismo separador. Las rutas que contienen
el separador deben ir entre comillas dobles; Excel lo hace al guardar.
Las rutas relativas de `AdfPath` se resuelven desde la carpeta del CSV,
no desde la carpeta de ejecucion.

El script procesa todas las filas secuencialmente y continua ante errores
individuales (por ejemplo archivo inexistente, URL incorrecta o falta de permisos).
El reporte incluye `Row`, `AdfPath`, `GitUrl`, `AdfSHA256`, `GitSHA256`,
`Identical`, `Result` y `Error`. `Row` es el numero de registro contando el
encabezado como 1; los campos CSV pueden contener saltos de linea.
`Result` es `MATCH`, `DIFFERENT` o `ERROR`; un error no se trata como diferencia.
Al final muestra los totales y la ruta del reporte.

- Salida `0`: todas las filas coinciden.
- Salida `1`: existe alguna diferencia, sin errores.
- Salida `2`: existe algun error, aunque otras filas coincidan o difieran.
- CSV vacio, encabezados incorrectos o un error al guardar el reporte:
  salida `2`. Un CSV invalido no inicia las comparaciones.

El reporte se reemplaza si ya existe. Su carpeta debe existir.
No se permite usar como reporte el CSV de entrada ni uno de los archivos ADF
de la plantilla. Si hay errores por fila, el reporte igualmente se guarda;
si hay un error general de entrada/salida o de consulta del repositorio,
no se garantiza un reporte nuevo.

La autenticacion, las URLs y `-ComparisonMode` funcionan igual que en el modo
individual. El modo seleccionado se aplica a todas las filas.

## Alternativa 3: comparacion individual con URL de GitHub

Guarda primero el JSON de ADF como archivo local independiente y ejecuta:

```powershell
pwsh -NoProfile -File .\Compare-AdfPipeline.ps1 `
    -AdfPath 'C:\ADF-Exports\PL_Ejemplo_2_Actividades.json' `
    -GitUrl 'https://github.com/OWNER/REPO/blob/main/PL_Ejemplo_2_Actividades.json'

$LASTEXITCODE
```

Debes proporcionar la URL del **archivo**, no solamente la URL del repositorio.
Admite el formato `https://github.com/OWNER/REPO/blob/REF/PATH.json`,
incluidas carpetas y nombres escapados como `%20`. Si la rama contiene `/`,
codifica ese caracter como `%2F` dentro de REF (por ejemplo, la rama
`feature/test` se escribe `feature%2Ftest`). No admite parametros de consulta,
URLs raw ni GitHub Enterprise.

Descarga el contenido raw mediante la API de GitHub, sin convertirlo a texto
ni volver a serializar el JSON. Calcula el SHA-256 sobre los bytes descargados
y elimina el archivo temporal, incluso si falla la comparacion.
No descarga el HTML de la pagina de GitHub.

La referencia puede ser una rama, etiqueta o SHA de commit. Una rama como
`main` puede cambiar entre ejecuciones; usa un commit para una referencia fija.
Una descarga fallida, falta de permisos, limite de API o respuesta inesperada
se notifica como error, nunca como coincidencia.

### Variante individual con copia local

1. Guarda el JSON de ADF como un archivo independiente fuera de la copia
   del repositorio. Usa el pipeline y la version que deseas verificar.
2. Actualiza la copia local del repositorio y selecciona la rama o commit
   que deseas comparar. El script lee el archivo del disco, incluidos cambios
   locales sin commit: no consulta el estado remoto de GitHub.
3. Ejecuta desde esta carpeta:

```powershell
pwsh -NoProfile -File .\Compare-AdfPipeline.ps1 `
    -AdfPath 'C:\ADF-Exports\MiPipeline.json' `
    -GitPath 'C:\Repos\MiRepo\pipeline\MiPipeline.json'

$LASTEXITCODE
```

Para Windows PowerShell 5.1, usa `powershell.exe` en lugar de `pwsh`.
Ejecuta el script en un proceso separado como en el ejemplo: utiliza `exit`
para devolver el resultado.

La salida muestra la ruta de ADF y la ruta local o `GitUrl`, ambos hashes SHA-256 de 64 caracteres
hexadecimales, `Identical` y `Result` (`MATCH` o `DIFFERENT`).

| Codigo de salida | Significado |
| --- | --- |
| 0 | Los hashes SHA-256 coinciden. |
| 1 | Los hashes SHA-256 son diferentes. |
| 2 | No se pudo comparar: URL invalida, error de descarga, archivo inexistente, ruta a carpeta o error de lectura/calculo. |

Los errores al proporcionar parametros se notifican mediante PowerShell
antes de iniciar la comparacion.

## Alcance e interpretacion

- El modo individual compara un par de archivos; el modo por lotes compara
  todos los pares de la plantilla. Por ahora, solo pipelines.
- No modifica archivos. `ExactBytes` no analiza ni normaliza el JSON;
  `PipelineDefinition` aplica exclusivamente las reglas documentadas.
- Espacios, sangria, orden de propiedades, saltos de linea (CRLF/LF), BOM,
  codificacion y salto de linea final afectan al hash original; no al
  hash normalizado si solo cambia la representacion.
- Copiar y pegar desde el editor de ADF puede cambiar el formato. Un resultado
  `DIFFERENT` indica bytes distintos, no necesariamente logica distinta.
- Git puede transformar los saltos de linea durante el checkout mediante
  `core.autocrlf` o atributos del repositorio. Con `-GitPath` se compara la copia
  local; con `-GitUrl`, el contenido remoto sin transformaciones de checkout.
- Usa `-GitPath` o `-GitUrl`, nunca ambos en la misma ejecucion.
- Mantiene ambos archivos sin cambios durante la ejecucion.
- No compara un pipeline individual con una plantilla ARM completa:
  son representaciones diferentes.
- No utiliza el SHA de un objeto Git como hash SHA-256 del archivo:
  calcula SHA-256 directamente sobre el contenido de cada archivo.

La integracion de ADF con Git y el estado publicado de ADF son conceptos
distintos. Selecciona explicitamente la version del pipeline de referencia.
Consulta la [documentacion de control de versiones de ADF](https://learn.microsoft.com/azure/data-factory/source-control).

## Pruebas

Sin dependencias adicionales:

```powershell
pwsh -NoProfile -File .\tests\Compare-AdfPipeline.Tests.ps1
pwsh -NoProfile -File .\tests\Compare-AdfPipelines.Tests.ps1
pwsh -NoProfile -File .\tests\Compare-AdfFactory.Tests.ps1
pwsh -NoProfile -File .\tests\PipelineDefinition.Tests.ps1
```

Verifican igualdad, cambios de contenido, espacios, CRLF/LF, BOM, rutas con
espacios/corchetes, errores de rutas, descarga simulada, autenticacion,
URLs escapadas, errores HTTP/timeout y rechazo de contenido HTML.
Las pruebas por lotes validan la plantilla, los hashes y estados del reporte,
la continuidad despues de errores, codigos de salida, separadores, rutas
relativas y la proteccion de los archivos de entrada.
Tambien validan busqueda recursiva por nombre, rama predeterminada y explicita,
URLs escapadas, commit fijo, nombres duplicados, distincion de mayusculas,
arboles truncados, errores de API y compatibilidad con URLs por fila.
El flujo ADF se prueba con API y autenticacion simuladas: paginacion,
renovacion del token, preservacion de bytes/BOM/CRLF/metadatos, exportaciones
fallidas, limpieza de archivos parciales, reportes y errores de acceso.

Prueba opcional contra el archivo publico del ejemplo (requiere Internet):

```powershell
pwsh -NoProfile -File .\tests\Compare-AdfPipeline.Tests.ps1 -IncludeGitHubIntegration
```
