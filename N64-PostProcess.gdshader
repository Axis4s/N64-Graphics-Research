shader_type canvas_item;

// ============================================================================
// SHADER UNIFORMS - User-configurable parameters
// ============================================================================

/** You can set the exact bit value for all 3 color components. (Ex: 5 = 15 BitRGB) */
uniform int bitdepth : hint_range(1, 8) = 5;

/** Controls the strength of the dithering effect */
uniform float dither_strength : hint_range(0.0, 1.0) = 1.0;

/** The resolution of your subviewport (e.g., 320x240 for retro pixel art) */
uniform vec2 virtual_resolution = vec2(320.0, 240.0);

/** Toggle between standard Bayer matrix and magic matrix */
uniform bool use_magic_matrix = false;

/** Enable/disable dedithering effect */
uniform bool enable_dedithering = false;

/** Controls the strength of the dedithering effect */
uniform float dedither_strength : hint_range(0.0, 1.0) = 1.0;

/** Enable/disable blur effect */
uniform bool enable_blur = false;

/** Controls the strength of the blur effect */
uniform float blur_strength : hint_range(0.0, 1.0) = 0.5;

/** Blur radius X - horizontal blur amount */
uniform float blur_radius_x : hint_range(0.0, 8.0) = 2.0;

/** Blur radius Y - vertical blur amount */
uniform float blur_radius_y : hint_range(0.0, 8.0) = 2.0;

/** Blur quality - higher values = better quality but slower */
uniform int blur_samples : hint_range(3, 16) = 8;

// ============================================================================
// DITHERING MATRICES - Predefined patterns for dithering
// ============================================================================

// Standard 4x4 Bayer matrix - creates ordered dithering pattern
const mat4 bayer_matrix = mat4(
    vec4( 0.0,  4.0,  1.0,  5.0),
    vec4( 4.0,  0.0,  5.0,  1.0),
    vec4( 3.0,  7.0,  2.0,  6.0),
    vec4( 7.0,  3.0,  6.0,  2.0)
);

// Alternative "magic" 4x4 matrix - creates different dithering pattern
const mat4 magic_matrix = mat4(
    vec4( 0.0,  6.0,  1.0,  7.0),
    vec4( 4.0,  2.0,  5.0,  3.0),
    vec4( 3.0,  5.0,  2.0,  4.0),
    vec4( 7.0,  1.0,  6.0,  0.0)
);

// ============================================================================
// CORE DITHERING FUNCTIONS
// ============================================================================

/**
 * Gets the dithering threshold value from the selected matrix
 * @param screen_pos: Screen position coordinates
 * @return: Normalized threshold value (0.0 to 1.0)
 */
float get_bayer_threshold(vec2 screen_pos) {
    // Calculate matrix coordinates using modulo for tiling
    int x = int(floor(screen_pos.x)) % 4;
    int y = int(floor(screen_pos.y)) % 4;

    // Select which matrix to use based on uniform setting
    mat4 selected_matrix = use_magic_matrix ? magic_matrix : bayer_matrix;

    // Return normalized threshold (divide by 7 since max matrix value is 7)
    return selected_matrix[y][x] / 7.0;
}

/**
 * Quantizes a single color channel with dithering applied
 * @param value: Original color channel value (0.0 to 1.0)
 * @param bits: Number of bits for quantization
 * @param threshold: Dithering threshold from matrix
 * @return: Quantized color value with dithering
 */
float quantize_channel_with_dither(float value, int bits, float threshold) {
    // Handle edge cases
    if (bits <= 0) return 0.0;
    if (bits >= 8) return value;

    // Calculate maximum value for this bit depth
    float max_value = float((1 << bits) - 1);

    // Apply dithering offset based on threshold
    float dither_amount = (threshold - 0.5) * dither_strength / max_value;
    float dithered_value = clamp(value + dither_amount, 0.0, 1.0);

    // Quantize to discrete levels
    float quantized = round(dithered_value * max_value) / max_value;
    return quantized;
}

/**
 * Applies dithering to a color at a specific UV coordinate
 * @param tex: Input texture sampler
 * @param uv: UV coordinates to sample
 * @return: Dithered color
 */
vec3 get_dithered_color_at_uv(sampler2D tex, vec2 uv) {
    // Sample original color
    vec4 color = texture(tex, uv);

    // Convert UV to virtual pixel coordinates for matrix lookup
    vec2 virtual_pixel_coords = uv * virtual_resolution;
    float bayer_threshold = get_bayer_threshold(virtual_pixel_coords);

    // Apply dithering to each color channel
    vec3 quantized_color;
    quantized_color.r = quantize_channel_with_dither(color.r, bitdepth, bayer_threshold);
    quantized_color.g = quantize_channel_with_dither(color.g, bitdepth, bayer_threshold);
    quantized_color.b = quantize_channel_with_dither(color.b, bitdepth, bayer_threshold);

    return quantized_color;
}

// ============================================================================
// DEDITHERING FUNCTIONS - Smooths out dithering artifacts
// ============================================================================

/**
 * Reconstructs smoother color by analyzing neighboring pixels
 * @param center_color: The center pixel's dithered color
 * @param neighbors: Array of 8 neighboring pixel colors
 * @param bits: Bit depth for level comparison
 * @param strength: Strength of the reconstruction effect
 * @return: Reconstructed color
 */
vec3 reconstruct_color(vec3 center_color, vec3 neighbors[8], int bits, float strength) {
    float max_value = float((1 << bits) - 1);
    vec3 reconstructed = vec3(0.0);

    // Process each color channel independently
    for (int channel = 0; channel < 3; channel++) {
        // Extract current channel value
        float center_val = (channel == 0) ? center_color.r :
                          (channel == 1) ? center_color.g : center_color.b;

        // Start with center pixel
        float sum = center_val;
        float count = 1.0;

        // Analyze all 8 neighbors
        for (int i = 0; i < 8; i++) {
            float neighbor_val = (channel == 0) ? neighbors[i].r :
                                (channel == 1) ? neighbors[i].g : neighbors[i].b;

            // Calculate quantization levels
            float center_level = floor(center_val * max_value);
            float neighbor_level = floor(neighbor_val * max_value);

            // Determine tolerance based on strength
            float level_tolerance = mix(0.5, 2.0, strength);

            // Include neighbor if it's within tolerance
            if (abs(center_level - neighbor_level) <= level_tolerance) {
                float weight = strength;
                sum += neighbor_val * weight;
                count += weight;
            }
        }

        // Calculate averaged value
        float averaged = sum / count;

        // Assign to appropriate channel
        if (channel == 0) reconstructed.r = averaged;
        else if (channel == 1) reconstructed.g = averaged;
        else reconstructed.b = averaged;
    }

    // Blend between original dithered color and reconstructed color
    return mix(center_color, reconstructed, strength);
}

/**
 * Gets processed color (dithered + optional dedithering) at UV coordinate
 * @param tex: Input texture sampler
 * @param uv: UV coordinates to sample
 * @param texel_size: Size of one texel for neighbor sampling
 * @return: Processed color
 */
vec3 get_processed_color_at_uv(sampler2D tex, vec2 uv, vec2 texel_size) {
    // Always start with dithered color
    vec3 dithered_color = get_dithered_color_at_uv(tex, uv);

    // Return early if dedithering is disabled
    if (!enable_dedithering) {
        return dithered_color;
    }

    // Define 8-neighbor offsets (Moore neighborhood)
    vec2 neighbor_offsets[8] = vec2[](
        vec2(-1.0, -1.0), vec2(0.0, -1.0), vec2(1.0, -1.0),  // Top row
        vec2(-1.0,  0.0),                   vec2(1.0,  0.0),  // Middle row (excluding center)
        vec2(-1.0,  1.0), vec2(0.0,  1.0), vec2(1.0,  1.0)   // Bottom row
    );

    // Sample all 8 neighbors
    vec3 neighbors[8];
    for (int i = 0; i < 8; i++) {
        vec2 neighbor_uv = uv + neighbor_offsets[i] * texel_size;

        // Check bounds and sample
        if (neighbor_uv.x >= 0.0 && neighbor_uv.x <= 1.0 &&
            neighbor_uv.y >= 0.0 && neighbor_uv.y <= 1.0) {
            neighbors[i] = get_dithered_color_at_uv(tex, neighbor_uv);
        } else {
            neighbors[i] = dithered_color; // Use center color for out-of-bounds
        }
    }

    // Apply dedithering reconstruction
    vec3 dedithered_color = reconstruct_color(dithered_color, neighbors, bitdepth, dedither_strength);
    return clamp(dedithered_color, 0.0, 1.0);
}

// ============================================================================
// BLUR FUNCTIONS - Fast and adjustable blur implementation
// ============================================================================

/**
 * Fast elliptical blur using optimized sampling pattern with separate X/Y radius
 * @param tex: Input texture sampler
 * @param uv: UV coordinates to sample
 * @param texel_size: Size of one texel for sampling
 * @param radius_x: Horizontal blur radius
 * @param radius_y: Vertical blur radius
 * @param samples: Number of samples for quality vs performance
 * @return: Blurred color
 */
vec3 apply_fast_blur(sampler2D tex, vec2 uv, vec2 texel_size, float radius_x, float radius_y, int samples) {
    vec3 color = vec3(0.0);
    float total_weight = 0.0;

    // Get center sample
    vec3 center_color = get_processed_color_at_uv(tex, uv, texel_size);
    color += center_color;
    total_weight += 1.0;

    // Skip blur if both radii are zero
    if (radius_x <= 0.0 && radius_y <= 0.0) {
        return center_color;
    }

    // Calculate angle increment for elliptical sampling
    float angle_step = 6.28318530718 / float(samples); // 2π / samples

    // Calculate maximum radius for ring count
    float max_radius = max(radius_x, radius_y);
    int rings = max(1, int(max_radius / 2.0));

    for (int ring = 1; ring <= rings; ring++) {
        float ring_factor = float(ring) / float(rings);
        float ring_radius_x = radius_x * ring_factor;
        float ring_radius_y = radius_y * ring_factor;
        float ring_weight = 1.0 / float(ring); // Closer rings have more weight

        for (int i = 0; i < samples; i++) {
            float angle = float(i) * angle_step;
            // Create elliptical offset using separate X/Y radii
            vec2 offset = vec2(cos(angle) * ring_radius_x, sin(angle) * ring_radius_y);
            vec2 sample_uv = uv + offset * texel_size;

            // Sample with bounds checking
            vec3 sample_color;
            if (sample_uv.x >= 0.0 && sample_uv.x <= 1.0 &&
                sample_uv.y >= 0.0 && sample_uv.y <= 1.0) {
                sample_color = get_processed_color_at_uv(tex, sample_uv, texel_size);
            } else {
                sample_color = center_color; // Use center for out-of-bounds
            }

            color += sample_color * ring_weight;
            total_weight += ring_weight;
        }
    }

    return color / total_weight;
}

// ============================================================================
// MAIN FRAGMENT SHADER - Combines all effects
// ============================================================================

void fragment() {
    // Sample original color and calculate texel size
    vec4 original_color = texture(TEXTURE, UV);
    vec2 texel_size = 1.0 / virtual_resolution;

    // Step 1: Apply dithering (and optionally dedithering)
    vec3 processed_color = get_processed_color_at_uv(TEXTURE, UV, texel_size);

    vec3 final_color = processed_color;

    // Step 2: Apply blur if enabled
    if (enable_blur && (blur_radius_x > 0.0 || blur_radius_y > 0.0)) {
        vec3 blurred_color = apply_fast_blur(TEXTURE, UV, texel_size, blur_radius_x, blur_radius_y, blur_samples);
        final_color = mix(processed_color, blurred_color, blur_strength);
    }

    // Step 3: Output final color (preserve original alpha)
    COLOR = vec4(final_color, original_color.a);
}