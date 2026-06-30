#[cfg(target_os = "ios")]
fn main() {
    eprintln!("not supported on iOS");
}

#[cfg(not(target_os = "ios"))]
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    use iroh::{Endpoint, endpoint::presets};
    use std::time::Instant;
    use zuko::wire::{ALPN_V2, TYPE_DATA, TYPE_PING, ping_frame, try_parse_frame};

    let host = Endpoint::builder(presets::N0)
        .secret_key(iroh::SecretKey::generate())
        .alpns(vec![ALPN_V2.to_vec()])
        .bind()
        .await?;
    let addr = host.addr();
    let host_task = tokio::spawn(async move {
        let incoming = host.accept().await.expect("incoming");
        let conn = incoming.accept()?.await?;
        let (mut send, mut recv) = conn.accept_bi().await?;
        let mut acc = Vec::new();
        let mut tmp = vec![0u8; 64 * 1024];
        let mut data_bytes = 0usize;
        while let Some(n) = recv.read(&mut tmp).await? {
            acc.extend_from_slice(&tmp[..n]);
            while let Some(frame) = try_parse_frame(&mut acc) {
                match frame.typ {
                    TYPE_PING => send.write_all(&zuko::wire::pong_frame(0)).await?,
                    TYPE_DATA => data_bytes += frame.payload.len(),
                    _ => {}
                }
            }
        }
        let _ = data_bytes;
        anyhow::Ok(())
    });

    let client = Endpoint::builder(presets::N0)
        .secret_key(iroh::SecretKey::generate())
        .bind()
        .await?;
    let conn = client.connect(addr, ALPN_V2).await?;
    let (mut send, mut recv) = conn.open_bi().await?;

    let mut tmp = vec![0u8; 4096];
    let mut acc = Vec::new();
    let mut rtts = Vec::new();
    for _ in 0..100 {
        let started = Instant::now();
        send.write_all(&ping_frame(1)).await?;
        loop {
            let n = recv.read(&mut tmp).await?.expect("pong");
            acc.extend_from_slice(&tmp[..n]);
            if try_parse_frame(&mut acc).is_some() {
                rtts.push(started.elapsed().as_secs_f64() * 1000.0);
                break;
            }
        }
    }
    rtts.sort_by(f64::total_cmp);
    println!(
        "iroh local ping: p50={:.2}ms p95={:.2}ms min={:.2}ms",
        rtts[rtts.len() / 2],
        rtts[rtts.len() * 95 / 100],
        rtts[0]
    );

    let payload = vec![0x55; 60 * 1024];
    let frame = zuko::wire::data_frame(&payload);
    let frames = 512usize;
    let started = Instant::now();
    for _ in 0..frames {
        send.write_all(&frame).await?;
    }
    let _ = send.finish();
    host_task.await??;
    let elapsed = started.elapsed().as_secs_f64();
    let mib = (payload.len() * frames) as f64 / 1024.0 / 1024.0;
    println!(
        "iroh local throughput: {:.1} MiB in {:.2}s = {:.1} MiB/s ({:.0} Mbps)",
        mib,
        elapsed,
        mib / elapsed,
        mib * 8.0 / elapsed
    );

    client.close().await;
    Ok(())
}
