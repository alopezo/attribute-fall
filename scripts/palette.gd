class_name Palette
extends RefCounted

# Central color palette for the prototype (see design doc section 11).
const BG := Color("0B1020")
const CARD_BG := Color("151C2F")
const CARD_BORDER := Color("2A3552")
const ACCENT := Color("20C7B5")      # primary (teal)
const ACCENT2 := Color("6EA8FE")     # secondary (blue)
const TEXT := Color("F4F7FB")        # main text
const MUTED := Color("9AA7BD")       # muted text
const CORRECT := Color("3DDC97")
const INCORRECT := Color("FF6B6B")
const SLOT := Color("56627A")        # incomplete slot
const PIECE_BG := Color("1B2540")

# Distinct, readable hues assigned per attribute type for visual variety.
const ATTR_COLORS := [
	Color("2DD4BF"),  # teal
	Color("6EA8FE"),  # blue
	Color("F0A868"),  # orange
	Color("C792EA"),  # purple
	Color("F78CA0"),  # pink
	Color("7FD77F"),  # green
	Color("E6C84F"),  # yellow
	Color("5FD3E0"),  # cyan
]

# Deterministic color for an attribute name (same attribute -> same color).
static func attr_color(attr: String) -> Color:
	return ATTR_COLORS[absi(attr.hash()) % ATTR_COLORS.size()]

# Concept-card color by top-level hierarchy (Tetris-style category cue).
# Avoids CORRECT/INCORRECT hues so it never clashes with feedback flashes.
const HIER_COLORS := {
	"finding": Color("F78CA0"),        # rose
	"procedure": Color("6EA8FE"),      # blue
	"specimen": Color("5FD3E0"),       # cyan
	"product": Color("F0A868"),        # orange
	"situation": Color("C792EA"),      # purple
	"substance": Color("E6C84F"),      # yellow
	"observable": Color("7FD77F"),     # green
	"bodystructure": Color("9AA7BD"),  # muted
	"organism": Color("B0BEC5"),
	"object": Color("A1887F"),
	"event": Color("80CBC4"),
}

static func hier_color(key: String) -> Color:
	return HIER_COLORS.get(key, CARD_BORDER)
