# Guía rápida para subir a GitHub

## 1. Crear repositorio

Nombre recomendado:

```text
YtDOWNLOADER-by-OsageP
```

Descripción recomendada:

```text
Aplicación portable para Windows con interfaz gráfica para usar yt-dlp, FFmpeg y Deno.
```

## 2. Subir desde Git Bash o CMD

Abre una terminal dentro de la carpeta del proyecto y ejecuta:

```bash
git init
git add .
git commit -m "Release inicial 1.0"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/YtDOWNLOADER-by-OsageP.git
git push -u origin main
```

Sustituye `TU_USUARIO` por tu usuario real de GitHub.

## 3. Crear release

En GitHub:

1. Entra en el repositorio.
2. Ve a **Releases**.
3. Pulsa **Draft a new release**.
4. Tag recomendado: `v1.0`.
5. Título recomendado: `YtDOWNLOADER by OsageP 1.0`.
6. Adjunta el ZIP de la versión portable si quieres ofrecer descarga directa.

## 4. No subir estos archivos

El `.gitignore` ya evita subir:

- `yt-dlp.exe`
- `ffmpeg.exe`
- `ffprobe.exe`
- `ffplay.exe`
- `deno.exe`
- `*.dll`
- `YtDOWNLOADER_config.json`
- `YtDOWNLOADER_history.jsonl`
- logs y temporales de descarga

Antes de hacer `git add .`, revisa con:

```bash
git status
```
