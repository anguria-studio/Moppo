# Información de privacidad de Moppo

## Archivos y fotos

Moppo analiza los archivos del Mac para buscar elementos que se pueden limpiar y medir el espacio ocupado.
Moppo lee tu fototeca cuando buscas fotos duplicadas.
Moppo no envía a Anguria los archivos analizados, sus rutas, las fotos ni el contenido de la fototeca.

## Registros locales

Moppo guarda los ajustes, las mediciones de almacenamiento y los justificantes de eliminación en el Mac.
Los justificantes pueden contener las rutas originales de los archivos y su ubicación en la Papelera.
Moppo usa estos registros para el historial y para la acción Sacar de la papelera.
Los resultados de los comandos incluyen el comando, la ruta de destino, el código de salida y parte de los mensajes de error.
Moppo guarda estos resultados localmente aun si desactivas los justificantes para Sacar de la papelera.

## Línea de comandos

La interfaz de línea de comandos guarda los informes de análisis en el Mac durante siete días.
Después de guardar un informe correctamente, quedan como máximo diez informes válidos.
Los informes pueden contener nombres de archivos, rutas, tamaños, explicaciones y verificaciones de la identidad de archivos.
Los planes de limpieza guardados contienen identificadores y caducan al cabo de un día.
Un plan puede caducar antes si caduca su informe de origen. Se conservan hasta veinte planes válidos.
Los resultados de los planes guardados contienen identificadores, códigos de estado y recuentos. No contienen nombres de archivos ni rutas.
Los registros de resultados caducan al cabo de siete días.
Moppo conserva hasta 100 registros de resultados, incluidos registros separados para el inicio y el resultado final.
Moppo usa carpetas privadas dentro de ~/Library/Application Support/Moppo.
Las carpetas tienen el modo de acceso 0700. Los archivos de registro tienen el modo de acceso 0600.
Los registros caducados no se pueden usar. Los archivos pueden quedar hasta la siguiente limpieza del almacén.
Los archivos no válidos y las copias de seguridad pueden permanecer más allá de estos límites.
La salida normal de los comandos omite nombres, rutas y explicaciones detalladas.
La opción --include-paths muestra estos datos a quien ejecuta el comando.
Los resultados de eliminación de un plan omiten nombres y rutas.
La salida reducida sigue incluyendo categorías, tamaños y clasificaciones de almacenamiento.
La interfaz de línea de comandos admitida no devuelve el contenido de archivos.
Un agente de IA puede enviar la salida del comando a su proveedor.
Moppo no controla ese proveedor ni garantiza que el modelo procese los datos localmente.
Los ajustes y las políticas del proveedor determinan cuánto tiempo guarda los datos y con quién los comparte.

## Actualizaciones de la aplicación

Moppo busca actualizaciones automáticamente.
Puedes desactivar la búsqueda automática en Ajustes > Actualizaciones.
Cuando Moppo busca actualizaciones, se conecta al sitio de actualizaciones por HTTPS.
El sitio recibe tu dirección IP y la información habitual de conexión.
Sparkle compara la versión instalada de Moppo con la fuente de actualizaciones.
Moppo desactiva el envío del perfil del sistema por parte de Sparkle.
Moppo pide tu confirmación antes de instalar una actualización.

## Servicios externos

Las consultas a Fotos y a iCloud usan los servicios de Apple y tu cuenta de Apple.
La eliminación con Homebrew usa las herramientas de Homebrew instaladas.
Homebrew puede consultar las fuentes de sus paquetes según sus propios ajustes.
Cuando Homebrew pide tu contraseña, Moppo la envía directamente a sudo y no la guarda.
Para comprobar la fusión de un worktree, Moppo puede usar la CLI de GitHub instalada y su sesión activa.
Estas consultas envían los nombres de repositorios y los identificadores de commits a GitHub.
No envían rutas locales ni el contenido de archivos.
Moppo no guarda tus credenciales de GitHub.

## Soporte

Puedes enviar una solicitud de soporte a hello@anguria.studio.
El informe indica las versiones de Moppo y macOS.
El informe no incluye rutas de archivos, fotos, registros de eliminación ni mediciones guardadas.
Puedes revisar el informe antes de enviarlo.
Tu proveedor de correo y Anguria reciben la información que decidas enviar.

## Contacto

Si tienes preguntas sobre privacidad, escribe a hello@anguria.studio.
