extends RefCounted

# Central UI translations (English source -> Spanish). Registered with Godot's
# TranslationServer so plain Label/Button text auto-translates when the locale
# changes; code also calls tr("...") for bbcode fragments and dynamic templates.
# Concept DATA (cards/pieces) is NOT translated here — it comes pre-translated
# from data/concepts.es.json, so those nodes disable auto-translation.

const CFG_PATH := "user://settings.cfg"

static var lang := "en"

const ES := {
	# HUD
	"SCORE": "PUNTAJE",
	"COMBO": "COMBO",
	"LIVES": "VIDAS",
	"SPEED": "VELOCIDAD",
	"GET READY": "PREPARATE",
	"GO": "¡YA!",
	# Side panel
	"SNOMED CT relationship match": "coincidencia de relaciones SNOMED CT",
	"CONTROLS": "CONTROLES",
	"Move     ← →\nDrop      Space\nPause    Esc\nMute      M": "Mover     ← →\nSoltar    Space\nPausa     Esc\nSilenciar M",
	"RESOURCES": "RECURSOS",
	"Implementation Support Portal →": "Portal de Soporte a la Implementación →",
	"SNOMED Demonstrators →": "Demostradores SNOMED →",
	# Main menu
	"Drop each SNOMED relationship onto the concept it defines.": "Soltá cada relación SNOMED sobre el concepto que define.",
	"START": "EMPEZAR",
	# Difficulty
	"CHOOSE DIFFICULTY": "ELEGÍ LA DIFICULTAD",
	"Speed only — Easy always shows the tutorial": "Solo velocidad — Fácil siempre muestra el tutorial",
	"EASY": "FÁCIL",
	"NORMAL": "NORMAL",
	"HARD": "DIFÍCIL",
	# Theme / topic filter
	"CHOOSE TOPIC": "ELEGÍ EL TEMA",
	"Topic: %s": "Tema: %s",
	"All hierarchies": "Todas las jerarquías",
	"Clinical findings": "Hallazgos clínicos",
	"Procedures": "Procedimientos",
	"Products": "Fármacos",
	"Situations": "Situaciones",
	# Tutorial overlay
	"This attribute is part of the '%s' definition": "Este atributo es parte de la definición de '%s'",
	"Move it over the card and drop — or click the card": "Llevala sobre la tarjeta y soltala — o hacé clic en la tarjeta",
	"Nice — that's how it works!": "¡Muy bien! Así se juega.",
	"Not quite — the right card is highlighted": "Casi — la tarjeta correcta está resaltada",
	"Good! Now it's your turn…": "¡Bien! Ahora te toca a vos…",
	"HOW TO PLAY": "CÓMO JUGAR",
	"HIGH SCORES": "MEJORES PUNTAJES",
	"CREDITS": "CRÉDITOS",
	"EXIT": "SALIR",
	"Made with Godot": "Hecho con Godot",
	# How to play
	"Move the falling relationship onto the concept it defines, and drop it.": "Llevá la relación que cae sobre el concepto que define y soltala.",
	"Fill a concept to clear it — a new one takes its place. Endless mode.": "Completá un concepto para eliminarlo — aparece otro. Modo infinito.",
	"A relationship can fit more than one concept — any valid card counts.": "Una relación puede servir a más de un concepto — vale cualquier tarjeta válida.",
	"Wrong drop costs a life (you start with 3). Chain correct drops for combo ×5.": "Un error cuesta una vida (empezás con 3). Encadená aciertos para combo ×5.",
	"Earn a bonus life at 2,500 points, then every 7,500 (up to 6).": "Ganás una vida extra a los 2.500 puntos, y luego cada 7.500 (hasta 6).",
	"Move": "Mover",
	"Soft / hard drop": "Caída suave / dura",
	"Pause": "Pausa",
	"Gamepad: D-pad / stick move · A drop · Start pause        Mouse / touch: click a card        M: mute music": "Gamepad: D-pad / stick mover · A soltar · Start pausa        Mouse / touch: clic en una tarjeta        M: silenciar",
	# How-to demo example
	"Finding site": "sitio del hallazgo",
	"Lung structure": "estructura pulmonar",
	"Pneumonia": "neumonía",
	"✓ Finding site → Lung structure": "✓ sitio del hallazgo → estructura pulmonar",
	# Hierarchy legend
	"Card border color = concept hierarchy:": "Color del borde = jerarquía del concepto:",
	"Clinical finding": "Hallazgo clínico",
	"Procedure": "Procedimiento",
	"Product": "Producto",
	"Situation": "Situación",
	"Substance": "Sustancia",
	# Credits
	"Questions? Write to ": "¿Consultas? Escribí a ",
	"Music: Free Rhythm Game Music Pack 1 — Tricks & Traps (CC0, OpenGameArt.org)": "Música: Free Rhythm Game Music Pack 1 — Tricks & Traps (CC0, OpenGameArt.org)",
	"Built with Godot Engine (MIT)": "Hecho con Godot Engine (MIT)",
	"SNOMED CT content © SNOMED International": "Contenido SNOMED CT © SNOMED International",
	# Pause
	"PAUSED": "PAUSA",
	"RESUME": "CONTINUAR",
	"RESTART": "REINICIAR",
	"CONCEPTS PLAYED": "CONCEPTOS JUGADOS",
	"MAIN MENU": "MENÚ PRINCIPAL",
	# Game over
	"GAME OVER": "FIN DEL JUEGO",
	"New high score!  Enter your name:": "¡Nuevo récord!  Ingresá tu nombre:",
	"Your name": "Tu nombre",
	"SUBMIT": "ENVIAR",
	"RETRY": "REINTENTAR",
	"TRY AGAIN": "JUGAR DE NUEVO",
	"Concepts completed: %d\nScore: %d\nBest combo: x%d": "Conceptos completados: %d\nPuntaje: %d\nMejor combo: x%d",
	# High scores
	"Loading…": "Cargando…",
	"No scores yet — be the first!": "Aún no hay puntajes — ¡sé el primero!",
	# Review
	"%d concepts played — click an id to open it in the SNOMED browser": "%d conceptos jugados — hacé clic en un id para abrirlo en el navegador SNOMED",
	# In-game feedback
	"Not part of this concept": "No pertenece a este concepto",
	"CONCEPT COMPLETE  +%d": "CONCEPTO COMPLETO  +%d",
	"♥  EXTRA LIFE": "♥  VIDA EXTRA",
	# Music toggle tooltip
	"Music on/off (M)": "Música on/off (M)",
}


# Register the Spanish table with the TranslationServer. Call once at startup.
static func register() -> void:
	var t := Translation.new()
	t.locale = "es"
	for src in ES:
		t.add_message(src, ES[src])
	TranslationServer.add_translation(t)


static func load_pref() -> String:
	var c := ConfigFile.new()
	if c.load(CFG_PATH) == OK:
		lang = str(c.get_value("game", "lang", "en"))
	return lang


static func save_pref(l: String) -> void:
	lang = l
	var c := ConfigFile.new()
	c.load(CFG_PATH)   # keep any other settings
	c.set_value("game", "lang", l)
	c.save(CFG_PATH)
