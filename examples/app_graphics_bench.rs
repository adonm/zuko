// Benchmarks the `zuko app` PNG/Kitty graphics encode path. The `bench` module
// uses the `png` crate, a `cfg(target_os = "linux")` dependency in Cargo.toml,
// so it is gated to Linux; `main` stays defined on every target (cargo requires
// a bin example to have `main`) with a no-op fallback for non-Linux, where the
// `zuko app` backend (cage + wlr-screencopy) doesn't build anyway.
#![cfg_attr(not(target_os = "linux"), allow(unused))]

fn main() -> anyhow::Result<()> {
    #[cfg(target_os = "linux")]
    {
        bench::run()
    }
    #[cfg(not(target_os = "linux"))]
    {
        eprintln!("app_graphics_bench is Linux-only (zuko app needs cage + wlr-screencopy).");
        Ok(())
    }
}

#[cfg(target_os = "linux")]
mod bench {
    use std::time::Instant;

    const W: usize = 960;
    const H: usize = 540;

    #[derive(Clone, Copy)]
    struct Variant {
        name: &'static str,
        compression: png::Compression,
        filter: png::Filter,
    }

    #[derive(Clone, Copy)]
    struct Encoded {
        png_bytes: usize,
        kitty_bytes: usize,
        ms: f64,
    }

    const VARIANTS: &[Variant] = &[
        Variant {
            name: "fastest+up",
            compression: png::Compression::Fastest,
            filter: png::Filter::Up,
        },
        Variant {
            name: "fast+adaptive",
            compression: png::Compression::Fast,
            filter: png::Filter::Adaptive,
        },
        Variant {
            name: "fast+paeth",
            compression: png::Compression::Fast,
            filter: png::Filter::Paeth,
        },
        Variant {
            name: "balanced+adaptive",
            compression: png::Compression::Balanced,
            filter: png::Filter::Adaptive,
        },
        Variant {
            name: "high+adaptive",
            compression: png::Compression::High,
            filter: png::Filter::Adaptive,
        },
        Variant {
            name: "raw-rgba-kitty",
            compression: png::Compression::NoCompression,
            filter: png::Filter::NoFilter,
        },
    ];

    pub fn run() -> anyhow::Result<()> {
        println!(
            "zuko app graphics smoke bench ({W}x{H}, {:.2} MiB RGBA)",
            (W * H * 4) as f64 / 1024.0 / 1024.0
        );
        full_frame_table()?;
        dirty_bbox_table()?;
        scale_table()?;
        Ok(())
    }

    fn full_frame_table() -> anyhow::Result<()> {
        let scenarios = [
            ("ui_static", vec![frame_ui(0), frame_ui(0), frame_ui(0)]),
            (
                "cursor_blink",
                vec![frame_cursor(true), frame_cursor(false), frame_cursor(true)],
            ),
            ("ui_scroll", vec![frame_ui(0), frame_ui(1), frame_ui(2)]),
            (
                "photo_noise",
                vec![frame_photo(1), frame_photo(2), frame_photo(3)],
            ),
        ];
        println!("\nfull-frame encode (avg emitted frame)");
        println!("scenario      variant              png_kib kitty_kib enc_ms max_fps mbps@16");
        for (name, frames) in scenarios {
            for variant in VARIANTS {
                let vals = frames
                    .iter()
                    .map(|f| encode_variant(f, W, H, *variant))
                    .collect::<anyhow::Result<Vec<_>>>()?;
                let avg = average(&vals);
                println!(
                    "{name:12} {:20} {:7.1} {:9.1} {:6.2} {:7.1} {:7.1}",
                    variant.name,
                    avg.png_bytes as f64 / 1024.0,
                    avg.kitty_bytes as f64 / 1024.0,
                    avg.ms,
                    1000.0 / avg.ms.max(0.001),
                    avg.kitty_bytes as f64 * 16.0 * 8.0 / 1_000_000.0,
                );
            }
        }
        Ok(())
    }

    fn dirty_bbox_table() -> anyhow::Result<()> {
        let current = Variant {
            name: "fast+paeth",
            compression: png::Compression::Fast,
            filter: png::Filter::Paeth,
        };
        let scenarios = [
            (
                "ui_static",
                vec![frame_ui(0), frame_ui(0), frame_ui(0), frame_ui(0)],
            ),
            (
                "cursor_blink",
                vec![
                    frame_cursor(true),
                    frame_cursor(false),
                    frame_cursor(true),
                    frame_cursor(false),
                ],
            ),
            (
                "ui_scroll",
                vec![frame_ui(0), frame_ui(1), frame_ui(2), frame_ui(3)],
            ),
            (
                "photo_noise",
                vec![frame_photo(1), frame_photo(2), frame_photo(3)],
            ),
        ];
        println!("\ndirty skip + bounding-box crop model (current fast+paeth)");
        println!("scenario      emits avg_full_kib avg_bbox_kib bbox_area% bytes_saved");
        for (name, frames) in scenarios {
            let mut prev: Option<Vec<u8>> = None;
            let mut full = Vec::new();
            let mut bbox_bytes = Vec::new();
            let mut area = Vec::new();
            for frame in frames {
                if prev.as_deref() == Some(frame.as_slice()) {
                    prev = Some(frame);
                    continue;
                }
                let full_enc = encode_variant(&frame, W, H, current)?;
                full.push(full_enc.kitty_bytes);
                if let Some(prev_frame) = prev.as_deref() {
                    if let Some((x0, y0, x1, y1)) = bbox(prev_frame, &frame, W, H) {
                        let (crop, cw, ch) = crop(&frame, W, x0, y0, x1, y1);
                        bbox_bytes.push(encode_variant(&crop, cw, ch, current)?.kitty_bytes);
                        area.push((cw * ch) as f64 * 100.0 / (W * H) as f64);
                    } else {
                        bbox_bytes.push(0);
                        area.push(0.0);
                    }
                } else {
                    bbox_bytes.push(full_enc.kitty_bytes);
                    area.push(100.0);
                }
                prev = Some(frame);
            }
            let avg_full = full.iter().sum::<usize>() as f64 / full.len().max(1) as f64;
            let avg_bbox = bbox_bytes.iter().sum::<usize>() as f64 / bbox_bytes.len().max(1) as f64;
            let avg_area = area.iter().sum::<f64>() / area.len().max(1) as f64;
            let saved = if avg_full > 0.0 {
                100.0 * (1.0 - avg_bbox / avg_full)
            } else {
                0.0
            };
            println!(
                "{name:12} {:5} {:12.1} {:12.1} {:9.2} {:10.1}%",
                full.len(),
                avg_full / 1024.0,
                avg_bbox / 1024.0,
                avg_area,
                saved
            );
        }
        Ok(())
    }

    fn scale_table() -> anyhow::Result<()> {
        let current = Variant {
            name: "fast+paeth",
            compression: png::Compression::Fast,
            filter: png::Filter::Paeth,
        };
        println!("\nresolution scale model (current fast+paeth, nearest downsample)");
        println!("scenario    scale res        kitty_kib enc_ms mbps@16 max_fps");
        for (name, frame) in [("ui_scroll", frame_ui(1)), ("photo", frame_photo(1))] {
            for scale in [1.0, 0.75, 0.5] {
                let nw = (W as f64 * scale) as usize;
                let nh = (H as f64 * scale) as usize;
                let scaled = downsample_nearest(&frame, W, H, nw, nh);
                let enc = encode_variant(&scaled, nw, nh, current)?;
                println!(
                    "{name:10} {scale:4.2} {nw}x{nh:<5} {:9.1} {:6.2} {:7.1} {:7.1}",
                    enc.kitty_bytes as f64 / 1024.0,
                    enc.ms,
                    enc.kitty_bytes as f64 * 16.0 * 8.0 / 1_000_000.0,
                    1000.0 / enc.ms.max(0.001),
                );
            }
        }
        Ok(())
    }

    fn encode_variant(
        bytes: &[u8],
        width: usize,
        height: usize,
        variant: Variant,
    ) -> anyhow::Result<Encoded> {
        if variant.name == "raw-rgba-kitty" {
            let bytes = bytes.len();
            return Ok(Encoded {
                png_bytes: bytes,
                kitty_bytes: base64_len(bytes),
                ms: 0.01,
            });
        }
        let start = Instant::now();
        let mut out = Vec::new();
        let mut encoder = png::Encoder::new(&mut out, width as u32, height as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(variant.compression);
        encoder.set_filter(variant.filter);
        {
            let mut writer = encoder.write_header()?;
            writer.write_image_data(bytes)?;
        }
        let ms = start.elapsed().as_secs_f64() * 1000.0;
        Ok(Encoded {
            png_bytes: out.len(),
            kitty_bytes: kitty_bytes(out.len()),
            ms,
        })
    }

    fn average(vals: &[Encoded]) -> Encoded {
        let n = vals.len().max(1) as f64;
        Encoded {
            png_bytes: (vals.iter().map(|v| v.png_bytes).sum::<usize>() as f64 / n) as usize,
            kitty_bytes: (vals.iter().map(|v| v.kitty_bytes).sum::<usize>() as f64 / n) as usize,
            ms: vals.iter().map(|v| v.ms).sum::<f64>() / n,
        }
    }

    fn base64_len(bytes: usize) -> usize {
        bytes.div_ceil(3) * 4
    }

    fn kitty_bytes(png_bytes: usize) -> usize {
        let b64 = base64_len(png_bytes);
        b64 + b64.div_ceil(4096) * 32
    }

    fn frame_ui(seed: u32) -> Vec<u8> {
        let mut b = vec![0u8; W * H * 4];
        for px in b.chunks_exact_mut(4) {
            px.copy_from_slice(&[28, 30, 34, 255]);
        }
        fill_rect(&mut b, W, 0, 0, W, 36, [42, 46, 54, 255]);
        for line in 0..28usize {
            let y = 58 + line * 16;
            let mut x = 36 + ((line * 17 + seed as usize * 3) % 13);
            for word in 0..8usize {
                let ww = 28 + ((line * 11 + word * 19) % 74);
                let col = if word % 5 == 0 {
                    [100, 180, 255, 255]
                } else {
                    [205, 210, 220, 255]
                };
                fill_rect(&mut b, W, x, y, ww, 8, col);
                x += ww + 14;
            }
        }
        fill_rect(&mut b, W, W - 220, 48, 15, H - 72, [55, 62, 74, 255]);
        b
    }

    fn frame_cursor(on: bool) -> Vec<u8> {
        let mut b = frame_ui(0);
        if on {
            fill_rect(&mut b, W, 408, 250, 6, 20, [255, 255, 255, 255]);
        }
        b
    }

    fn frame_photo(seed: u32) -> Vec<u8> {
        let mut b = vec![0u8; W * H * 4];
        let mut s = seed;
        for y in 0..H {
            for x in 0..W {
                s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let r = (((x * 255) / W) as u8).wrapping_add((s & 63) as u8);
                let g = (((y * 255) / H) as u8).wrapping_add(((s >> 8) & 63) as u8);
                let blue = ((((x + y) * 255) / (W + H)) as u8).wrapping_add(((s >> 16) & 63) as u8);
                let i = (y * W + x) * 4;
                b[i..i + 4].copy_from_slice(&[r, g, blue, 255]);
            }
        }
        b
    }

    fn fill_rect(b: &mut [u8], width: usize, x: usize, y: usize, w: usize, h: usize, col: [u8; 4]) {
        for yy in y..(y + h).min(H) {
            for xx in x..(x + w).min(width) {
                let i = (yy * width + xx) * 4;
                b[i..i + 4].copy_from_slice(&col);
            }
        }
    }

    fn bbox(
        a: &[u8],
        b: &[u8],
        width: usize,
        height: usize,
    ) -> Option<(usize, usize, usize, usize)> {
        let mut min_x = width;
        let mut min_y = height;
        let mut max_x = 0;
        let mut max_y = 0;
        let mut found = false;
        for y in 0..height {
            for x in 0..width {
                let i = (y * width + x) * 4;
                if a[i..i + 4] != b[i..i + 4] {
                    found = true;
                    min_x = min_x.min(x);
                    min_y = min_y.min(y);
                    max_x = max_x.max(x + 1);
                    max_y = max_y.max(y + 1);
                }
            }
        }
        found.then_some((min_x, min_y, max_x, max_y))
    }

    fn crop(
        bytes: &[u8],
        width: usize,
        x0: usize,
        y0: usize,
        x1: usize,
        y1: usize,
    ) -> (Vec<u8>, usize, usize) {
        let cw = x1 - x0;
        let ch = y1 - y0;
        let mut out = vec![0u8; cw * ch * 4];
        for y in 0..ch {
            let src = ((y0 + y) * width + x0) * 4;
            let dst = y * cw * 4;
            out[dst..dst + cw * 4].copy_from_slice(&bytes[src..src + cw * 4]);
        }
        (out, cw, ch)
    }

    fn downsample_nearest(bytes: &[u8], sw: usize, sh: usize, dw: usize, dh: usize) -> Vec<u8> {
        let mut out = vec![0u8; dw * dh * 4];
        for y in 0..dh {
            let sy = (y * sh / dh).min(sh - 1);
            for x in 0..dw {
                let sx = (x * sw / dw).min(sw - 1);
                let src = (sy * sw + sx) * 4;
                let dst = (y * dw + x) * 4;
                out[dst..dst + 4].copy_from_slice(&bytes[src..src + 4]);
            }
        }
        out
    }
}
