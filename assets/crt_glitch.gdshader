shader_type canvas_item;

// Screen-space CRT/glitch. Reads what's rendered behind this node (backbuffer)
// via hint_screen_texture. `intensity` 0 = invisible passthrough.
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

float hash(float n) {
	return fract(sin(n) * 43758.5453123);
}

void fragment() {
	vec2 uv = SCREEN_UV;

	// Random horizontal tearing on a few bands.
	float row = floor(uv.y * 60.0);
	float t = floor(TIME * 12.0);
	float band = step(0.93, hash(row + t));
	float shift = (hash(row * 1.7 + t) - 0.5) * 0.03 * intensity * band;
	uv.x += shift;

	// Chromatic aberration (RGB split).
	float ca = 0.005 * intensity;
	vec3 col;
	col.r = texture(screen_tex, uv + vec2(ca, 0.0)).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - vec2(ca, 0.0)).b;

	// Scanlines.
	float scan = 1.0 - 0.10 * intensity * (0.5 + 0.5 * sin(FRAGCOORD.y * 3.14159));

	// Subtle flicker noise.
	float noise = (hash(uv.y * 133.0 + TIME * 50.0) - 0.5) * 0.06 * intensity;

	COLOR = vec4(col * scan + noise, 1.0);
}
