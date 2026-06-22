# YtDOWNLOADER by OsageP

**YtDOWNLOADER by OsageP** es una aplicacion portable para Windows hecha con **PowerShell + Windows Forms** que facilita el uso de [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) mediante una interfaz grafica sencilla.

> Version actual: **1.0**  
> Año: **2026**

## Caracteristicas

- Interfaz grafica para Windows.
- Descarga de video en MP4.
- Descarga de audio en MP3.
- Selector de calidad de video.
- Selector de calidad MP3: mejor calidad, 320K, 256K, 192K, 160K y 128K.
- Soporte opcional para playlists de YouTube.
- Progreso visible en la interfaz.
- Indicador de playlists tipo `Lista: X de Y` cuando `yt-dlp` informa del total.
- Cancelacion segura de descargas y playlists usando detencion del arbol de procesos.
- Carpeta de descarga configurable.
- Configuracion persistente en `YtDOWNLOADER_config.json`.
- Historial opcional en `YtDOWNLOADER_history.jsonl`.
- Botones para ver y borrar historial.
- Botones de mantenimiento: comprobar dependencias, actualizar componentes, limpiar temporales y borrar logs.
- Tema claro, oscuro o segun sistema.
- Boton para abrir la carpeta de descarga.
- Casilla para abrir la carpeta automaticamente al terminar.
- Boton para crear acceso directo en el escritorio desde Configuracion.
- Icono propio en `assets/YtDOWNLOADER.ico`.
- Enlace inferior: `2026 | Basado en: https://github.com/yt-dlp/yt-dlp`.
- Descarga automatica de dependencias si faltan.

## Captura / interfaz

La aplicacion muestra:

- Campo para pegar enlace de video o playlist.
- Carpeta de destino.
- Modo de descarga: Video o Solo MP3.
- Calidad configurable.
- Opcion de playlist completa.
- Casilla para abrir carpeta al terminar.
- Barra de progreso.
- Estado de playlist y archivo actual cuando `yt-dlp` lo informa.
- Registro de salida.
- Boton de configuracion.
- Botones de historial.
- Botones inferiores de mantenimiento.

## Requisitos

- Windows 10/11 recomendado.
- PowerShell 5.1 o superior.
- Conexion a internet para descargar dependencias y videos.
- Sistema Windows de 64 bits para la instalacion automatica de FFmpeg y Deno incluida en esta version.

## Dependencias

La aplicacion descarga automaticamente, si faltan:

- `yt-dlp.exe`
- `ffmpeg.exe`
- `ffprobe.exe`
- `deno.exe`

Estas dependencias **no deben subirse al repositorio**. Estan incluidas en `.gitignore`.

## Uso

1. Descarga o clona el repositorio.
2. Ejecuta `YtDOWNLOADER.bat`.
3. En la primera ejecucion, revisa la configuracion inicial.
4. Pega una URL.
5. Selecciona modo y calidad.
6. Pulsa **Descargar**.

## Configuracion

Desde **Configuracion** puedes ajustar:

- Carpeta predeterminada.
- Modo predeterminado: Video o Solo MP3.
- Calidad de video predeterminada.
- Calidad MP3 predeterminada.
- Descargar playlists completas o solo el video/enlace.
- Activar o desactivar historial.
- Tema visual.
- Abrir carpeta al terminar.
- Opciones avanzadas.
- Crear acceso directo en el escritorio.

## Opciones avanzadas

El modo avanzado permite configurar:

- Formato de nombre de archivo.
- Creacion de subcarpetas para video y MP3.
- Uso opcional de cookies del navegador: Chrome, Edge o Firefox.

## Playlists

Por seguridad, la aplicacion permite elegir si se descarga la playlist completa o solo el video/enlace.

- Opcion desactivada: se usa `--no-playlist`.
- Opcion activada: se usa `--yes-playlist`.

Cuando se descarga una playlist completa, los archivos se organizan en una subcarpeta con el nombre de la lista.

Durante la descarga, si `yt-dlp` informa del total, la interfaz muestra el avance aproximado como `Lista: 1 de 10`, `Lista: 2 de 10`, etc.

El boton **Cancelar** detiene la descarga actual y tambien el arbol de procesos asociado para evitar que una playlist continue descargandose en segundo plano.

## MP3

Para MP3 se usa `yt-dlp` con extraccion de audio mediante FFmpeg:

```powershell
-x --audio-format mp3 --audio-quality CALIDAD
```

Valores disponibles desde la interfaz:

- Mejor calidad MP3 (0)
- 320 kbps
- 256 kbps
- 192 kbps
- 160 kbps
- 128 kbps

## Historial

El historial esta desactivado por defecto.

Si se activa desde **Configuracion**, la aplicacion crea:

```text
YtDOWNLOADER_history.jsonl
```

Cada linea contiene una descarga en formato JSON compacto.

La pantalla principal incluye botones para consultar y borrar el historial.

## Logs

La aplicacion puede crear:

```text
YtDOWNLOADER_error.log
YtDOWNLOADER_debug.log
```

Desde la interfaz se puede usar **Borrar logs** para evitar que crezcan demasiado. Ademas, la aplicacion recorta automaticamente los logs grandes.

## Archivos locales que no se deben subir a GitHub

El repositorio incluye `.gitignore` para evitar subir:

- Binarios descargados (`yt-dlp.exe`, `ffmpeg.exe`, `ffprobe.exe`, `deno.exe`, `.dll`).
- Logs (`YtDOWNLOADER_error.log`, `YtDOWNLOADER_debug.log`).
- Configuracion local (`YtDOWNLOADER_config.json`).
- Historial local (`YtDOWNLOADER_history.jsonl`).
- Temporales de descarga (`*.part`, `*.ytdl`, etc.).

## Aviso de uso

Usa esta herramienta solo con contenido que tengas derecho a descargar. El usuario es responsable de respetar los terminos de uso de cada plataforma y la normativa aplicable.

## Proyecto base

Esta aplicacion esta basada en el uso de:

- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp)
- [`FFmpeg`](https://ffmpeg.org/)
- [`Deno`](https://deno.com/)

## Licencia

El codigo de este wrapper se publica bajo licencia MIT. Las dependencias externas conservan sus propias licencias. Consulta `THIRD_PARTY_NOTICES.md`.
