struct Globals {
    viewport_size: vec2<f32>,
    pad: vec2<u32>,
}

var<uniform> globals: Globals;

const M_PI_F: f32 = 3.1415926;

struct ViewId {
	lo: u32,
	hi: u32,
}

struct Bounds {
    origin: vec2<f32>,
    size: vec2<f32>,
}
struct Corners {
    top_left: f32,
    top_right: f32,
    bottom_right: f32,
    bottom_left: f32,
}
struct Edges {
    top: f32,
    right: f32,
    bottom: f32,
    left: f32,
}
struct Hsla {
    h: f32,
    s: f32,
    l: f32,
    a: f32,
}

fn to_device_position(unit_vertex: vec2<f32>, bounds: Bounds) -> vec4<f32> {
    let position = unit_vertex * vec2<f32>(bounds.size) + bounds.origin;
    let device_position = position / globals.viewport_size * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0);
    return vec4<f32>(device_position, 0.0, 1.0);
}

fn distance_from_clip_rect(unit_vertex: vec2<f32>, bounds: Bounds, clip_bounds: Bounds) -> vec4<f32> {
    let position = unit_vertex * vec2<f32>(bounds.size) + bounds.origin;
    let tl = position - clip_bounds.origin;
    let br = clip_bounds.origin + clip_bounds.size - position;
    return vec4<f32>(tl.x, br.x, tl.y, br.y);
}

fn hsla_to_rgba(hsla: Hsla) -> vec4<f32> {
    let h = hsla.h * 6.0; // Now, it's an angle but scaled in [0, 6) range
    let s = hsla.s;
    let l = hsla.l;
    let a = hsla.a;

    let c = (1.0 - abs(2.0 * l - 1.0)) * s;
    let x = c * (1.0 - abs(h % 2.0 - 1.0));
    let m = l - c / 2.0;

    var color = vec4<f32>(m, m, m, a);

    if (h >= 0.0 && h < 1.0) {
        color.r += c;
        color.g += x;
    } else if (h >= 1.0 && h < 2.0) {
        color.r += x;
        color.g += c;
    } else if (h >= 2.0 && h < 3.0) {
        color.g += c;
        color.b += x;
    } else if (h >= 3.0 && h < 4.0) {
        color.g += x;
        color.b += c;
    } else if (h >= 4.0 && h < 5.0) {
        color.r += x;
        color.b += c;
    } else {
        color.r += c;
        color.b += x;
    }

    return color;
}

fn over(below: vec4<f32>, above: vec4<f32>) -> vec4<f32> {
    let alpha = above.a + below.a * (1.0 - above.a);
    let color = (above.rgb * above.a + below.rgb * below.a * (1.0 - above.a)) / alpha;
    return vec4<f32>(color, alpha);
}

// A standard gaussian function, used for weighting samples
fn gaussian(x: f32, sigma: f32) -> f32{
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * M_PI_F) * sigma);
}

// This approximates the error function, needed for the gaussian integral
fn erf(v: vec2<f32>) -> vec2<f32> {
    let s = sign(v);
    let a = abs(v);
    let r1 = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    let r2 = r1 * r1;
    return s - s / (r2 * r2);
}

fn blur_along_x(x: f32, y: f32, sigma: f32, corner: f32, half_size: vec2<f32>) -> f32 {
  let delta = min(half_size.y - corner - abs(y), 0.0);
  let curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
  let integral = 0.5 + 0.5 * erf((x + vec2<f32>(-curved, curved)) * (sqrt(0.5) / sigma));
  return integral.y - integral.x;
}

// --- quads --- //

struct Quad {
    view_id: ViewId,
    layer_id: u32,
    order: u32,
    bounds: Bounds,
    content_mask: Bounds,
    background: Hsla,
    border_color: Hsla,
    corner_radii: Corners,
    border_widths: Edges,
}
var<storage, read> b_quads: array<Quad>;

struct QuadVarying {
    @builtin(position) position: vec4<f32>,
    @location(0) @interpolate(flat) background_color: vec4<f32>,
    @location(1) @interpolate(flat) border_color: vec4<f32>,
    @location(2) @interpolate(flat) quad_id: u32,
    //TODO: use `clip_distance` once Naga supports it
    @location(3) clip_distances: vec4<f32>,
}

@vertex
fn vs_quad(@builtin(vertex_index) vertex_id: u32, @builtin(instance_index) instance_id: u32) -> QuadVarying {
    let unit_vertex = vec2<f32>(f32(vertex_id & 1u), 0.5 * f32(vertex_id & 2u));
    let quad = b_quads[instance_id];

    var out = QuadVarying();
    out.position = to_device_position(unit_vertex, quad.bounds);
    out.background_color = hsla_to_rgba(quad.background);
    out.border_color = hsla_to_rgba(quad.border_color);
    out.quad_id = instance_id;
    out.clip_distances = distance_from_clip_rect(unit_vertex, quad.bounds, quad.content_mask);
    return out;
}

@fragment
fn fs_quad(input: QuadVarying) -> @location(0) vec4<f32> {
    // Alpha clip first, since we don't have `clip_distance`.
    let min_distance = min(
        min(input.clip_distances.x, input.clip_distances.y),
        min(input.clip_distances.z, input.clip_distances.w)
    );
    if min_distance <= 0.0 {
        return vec4<f32>(0.0);
    }

    let quad = b_quads[input.quad_id];
    let half_size = quad.bounds.size / 2.0;
    let center = quad.bounds.origin + half_size;
    let center_to_point = input.position.xy - center;

    var corner_radius = 0.0;
    if (center_to_point.x < 0.0) {
        if (center_to_point.y < 0.0) {
            corner_radius = quad.corner_radii.top_left;
        } else {
            corner_radius = quad.corner_radii.bottom_left;
        }
    } else {
        if (center_to_point.y < 0.) {
            corner_radius = quad.corner_radii.top_right;
        } else {
            corner_radius = quad.corner_radii.bottom_right;
        }
    }

    let rounded_edge_to_point = abs(center_to_point) - half_size + corner_radius;
    let distance =
      length(max(vec2<f32>(0.0), rounded_edge_to_point)) +
      min(0.0, max(rounded_edge_to_point.x, rounded_edge_to_point.y)) -
      corner_radius;

    let vertical_border = select(quad.border_widths.left, quad.border_widths.right, center_to_point.x > 0.0);
    let horizontal_border = select(quad.border_widths.top, quad.border_widths.bottom, center_to_point.y > 0.0);
    let inset_size = half_size - corner_radius - vec2<f32>(vertical_border, horizontal_border);
    let point_to_inset_corner = abs(center_to_point) - inset_size;

    var border_width = 0.0;
    if (point_to_inset_corner.x < 0.0 && point_to_inset_corner.y < 0.0) {
        border_width = 0.0;
    } else if (point_to_inset_corner.y > point_to_inset_corner.x) {
        border_width = horizontal_border;
    } else {
        border_width = vertical_border;
    }

    var color = input.background_color;
    if (border_width > 0.0) {
        let inset_distance = distance + border_width;
        // Blend the border on top of the background and then linearly interpolate
        // between the two as we slide inside the background.
        let blended_border = over(input.background_color, input.border_color);
        color = mix(blended_border, input.background_color,
                    saturate(0.5 - inset_distance));
    }

    return color * vec4<f32>(1.0, 1.0, 1.0, saturate(0.5 - distance));
}

// --- shadows --- //

struct Shadow {
    view_id: ViewId,
    layer_id: u32,
    order: u32,
    bounds: Bounds,
    corner_radii: Corners,
    content_mask: Bounds,
    color: Hsla,
    blur_radius: f32,
    pad: u32,
}
var<storage, read> b_shadows: array<Shadow>;

struct ShadowVarying {
    @builtin(position) position: vec4<f32>,
    @location(0) @interpolate(flat) color: vec4<f32>,
    @location(1) @interpolate(flat) shadow_id: u32,
    //TODO: use `clip_distance` once Naga supports it
    @location(3) clip_distances: vec4<f32>,
}

@vertex
fn vs_shadow(@builtin(vertex_index) vertex_id: u32, @builtin(instance_index) instance_id: u32) -> ShadowVarying {
    let unit_vertex = vec2<f32>(f32(vertex_id & 1u), 0.5 * f32(vertex_id & 2u));
    let shadow = b_shadows[instance_id];

    let margin = 3.0 * shadow.blur_radius;
    // Set the bounds of the shadow and adjust its size based on the shadow's
    // spread radius to achieve the spreading effect
    var bounds = shadow.bounds;
    bounds.origin -= vec2<f32>(margin);
    bounds.size += 2.0 * vec2<f32>(margin);

    var out = ShadowVarying();
    out.position = to_device_position(unit_vertex, shadow.bounds);
    out.color = hsla_to_rgba(shadow.color);
    out.shadow_id = instance_id;
    out.clip_distances = distance_from_clip_rect(unit_vertex, shadow.bounds, shadow.content_mask);
    return out;
}

@fragment
fn fs_shadow(input: ShadowVarying) -> @location(0) vec4<f32> {
    // Alpha clip first, since we don't have `clip_distance`.
    let min_distance = min(
        min(input.clip_distances.x, input.clip_distances.y),
        min(input.clip_distances.z, input.clip_distances.w)
    );
    if min_distance <= 0.0 {
        return vec4<f32>(0.0);
    }

    let shadow = b_shadows[input.shadow_id];
    let half_size = shadow.bounds.size / 2.0;
    let center = shadow.bounds.origin + half_size;
    let center_to_point = input.position.xy - center;

    var corner_radius = 0.0;
    if (center_to_point.x < 0.0) {
        if (center_to_point.y < 0.0) {
            corner_radius = shadow.corner_radii.top_left;
        } else {
            corner_radius = shadow.corner_radii.bottom_left;
        }
    } else {
        if (center_to_point.y < 0.) {
            corner_radius = shadow.corner_radii.top_right;
        } else {
            corner_radius = shadow.corner_radii.bottom_right;
        }
    }

    // The signal is only non-zero in a limited range, so don't waste samples
    let low = center_to_point.y - half_size.y;
    let high = center_to_point.y + half_size.y;
    let start = clamp(-3.0 * shadow.blur_radius, low, high);
    let end = clamp(3.0 * shadow.blur_radius, low, high);

    // Accumulate samples (we can get away with surprisingly few samples)
    let step = (end - start) / 4.0;
    var y = start + step * 0.5;
    var alpha = 0.0;
    for (var i = 0; i < 4; i += 1) {
        let blur = blur_along_x(center_to_point.x, center_to_point.y - y,
            shadow.blur_radius, corner_radius, half_size);
        alpha +=  blur * gaussian(y, shadow.blur_radius) * step;
        y += step;
    }

    return input.color * vec4<f32>(1.0, 1.0, 1.0, alpha);
}
