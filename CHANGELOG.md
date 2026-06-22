# Changelog

## 1.0 - 2026-06-22

Primera version estable de **YtDOWNLOADER by OsageP**.

### Añadido

- Interfaz grafica para Windows con PowerShell + Windows Forms.
- Descarga de video en MP4 mediante `yt-dlp`.
- Descarga de audio en MP3 mediante `yt-dlp` + FFmpeg.
- Selector de calidad de video.
- Selector de calidad MP3.
- Soporte opcional para playlists.
- Progreso visible en la interfaz.
- Indicador de playlist tipo `Lista: X de Y` cuando `yt-dlp` informa del total.
- Cancelacion segura de descargas y playlists con cierre del arbol de procesos.
- Carpeta predeterminada configurable.
- Configuracion persistente en JSON.
- Asistente de primera configuracion.
- Tema claro, oscuro o segun sistema.
- Casilla para abrir carpeta al terminar.
- Historial opcional de descargas.
- Botones para ver y borrar historial.
- Botones de mantenimiento:
  - Comprobar dependencias.
  - Actualizar componentes.
  - Limpiar temporales.
  - Borrar logs.
- Recorte automatico de logs grandes.
- Opciones avanzadas:
  - Formato de nombre de archivo.
  - Crear subcarpetas para Video y MP3.
  - Usar cookies del navegador.
- Descarga automatica de componentes:
  - `yt-dlp.exe`.
  - `ffmpeg.exe`.
  - `ffprobe.exe`.
  - `deno.exe`.
- Enlace inferior: `2026 | Basado en: https://github.com/yt-dlp/yt-dlp`.
- Boton para crear acceso directo en el escritorio.
- Icono propio en `assets/YtDOWNLOADER.ico`.
- Documentacion preparada para GitHub.
- `.gitignore` para evitar subir binarios, logs, temporales, configuracion local e historial.
