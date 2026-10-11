# GenMap Lite — Mazmorras 2D jugables en segundos para Godot 4

**Elige el tamaño y el número de salas, pulsa un botón y tendrás una mazmorra jugable en tu `TileMapLayer`.** Paredes con colisión, todas las salas conectadas y `Ctrl+Z` para deshacer. Funciona nada más activarlo, sin instalar nada más.

*Generate playable 2D dungeons in your Godot `TileMapLayer` in one click: rooms, corridors and walls with collisions, every room reachable, fully undoable. No setup required.*



---

## Qué hace

- **Mazmorras en un clic** desde un panel en el editor: tamaño, número de salas y listo.
- **Mapas siempre jugables:** salas que no se pisan, todas conectadas, y un perímetro de paredes cerrado para que el personaje no pueda salirse.
- **Paredes con colisión** si tu tile de muro tiene forma de colisión en el TileSet.
- **`Ctrl+Z`** deshace cada generación. Después puedes retocar el mapa a mano como cualquier otro.
- **Sin congelar el editor:** el cálculo va en un hilo aparte y el pintado se reparte entre frames, con barra de progreso.
- **Modo descripción (opcional):** escribe *"cripta de 40x30 con 6 salas pequeñas"* y un modelo local lo interpreta. Necesita [Ollama](https://ollama.com) instalado; si el mapa sale inválido, se vuelve a pedir solo.

## Lite y Pro

| | **Lite** (gratis, MIT) | **Pro** |
|---|:---:|:---:|
| Panel del editor, `Ctrl+Z`, progreso y cancelar | ✅ | ✅ |
| Modo clásico (sin instalar nada) y modo descripción | ✅ | ✅ |
| Suelo, paredes y salas siempre conectadas | ✅ | ✅ |
| Tamaño máximo | 48×48 | 128×128 |
| Sala del jefe (siempre la más lejana) y salas de tesoro | — | ✅ |
| Entidades: punto de inicio, jefe y cofres (con tu propia escena) | — | ✅ |
| Terrenos (autotiling con Terrain Sets) | — | ✅ |
| Exportar e importar mapas `.json` | — | ✅ |
| API para generar o cargar mapas desde el código de tu juego | — | ✅ |
| Presets con nombre | — | ✅ |
| Soporte | Issues de GitHub | Prioritario |

**[Consigue GenMap Pro](https://jaime-7997.itch.io/genmap-pro)**

## Requisitos

- **Godot 4.3** o superior (usa `TileMapLayer`).
- Nada más para el modo clásico.
- Solo para el modo descripción: [Ollama](https://ollama.com/download) 0.9 o superior y el modelo `qwen3:8b` (`ollama pull qwen3:8b`, unos 5 GB).

## Instalación

1. Instala el plugin de una de estas formas:
   - **Asset Library:** en Godot, pestaña *AssetLib* → busca **GenMap Lite** → *Descargar* → *Instalar*.
   - **Manual:** copia la carpeta `addons/genmap/` de este repositorio en la carpeta `addons/` de tu proyecto.
2. Activa el plugin en **Proyecto > Configuración del proyecto > Plugins**. Aparecerá la pestaña **GenMap** en el panel derecho.

Para probarlo sin configurar nada, abre este repositorio como proyecto en Godot: incluye un demo con TileSet, jugador y un mapa ya generado.

## Guía rápida

1. Necesitas un **`TileMapLayer`** con un TileSet cuyo atlas (source `0`) tenga el **suelo en `(0, 0)`** y el **muro en `(1, 0)`**. Si tu atlas es distinto, cámbialo en *Ajustes avanzados*.
2. **Selecciona** el `TileMapLayer` en el árbol de escena.
3. En el panel GenMap, con el modo **Clásico**, elige ancho, alto y número de salas, y pulsa **Generar mapa**.
4. ¿No te gusta? `Ctrl+Z` y vuelve a generar: cada vez sale distinto.

En el demo (`demo/demo_lite.tscn`): selecciona `Ground`, genera, guarda la escena y pulsa **F5** para recorrer el mapa con las flechas.

**Modo descripción:** cambia el modo a *Descripción en texto*, escribe algo como `mazmorra de 20x20 con 3 habitaciones` y pulsa Generar. El botón **Comprobar** te dice si Ollama está listo.

## Solución de problemas

| Mensaje | Qué hacer |
|---|---|
| *El atlas no tiene tile de suelo/muro en …* | Ajusta source y coordenadas en *Ajustes avanzados*. |
| *No se puede conectar con Ollama* (modo descripción) | Abre la app de Ollama o ejecuta `ollama serve`. O usa el modo clásico. |
| *El modelo … no está instalado* | `ollama pull qwen3:8b`, o elige otro modelo en el panel. |
| *Ollama no respondió en 180 s* | El modelo es demasiado grande para tu equipo: prueba `qwen3:4b` o el modo clásico. |

## Para contribuir

Los tests no necesitan Ollama:

```bash
godot --headless --path . --script res://tests/run_tests.gd
```

También puedes abrir `tests/run_tests_editor.gd` en el editor y pulsar *File > Run*.

## Licencia

GenMap Lite se distribuye bajo la [licencia MIT](LICENSE). Ollama y los modelos de lenguaje no se incluyen: se instalan por separado y tienen sus propias licencias.
