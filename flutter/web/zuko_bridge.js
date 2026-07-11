import init, { ZukoClient } from './wasm/zuko_web.js';

let initialization;

async function ready() {
  initialization ??= init();
  await initialization;
}

globalThis.zukoBridge = {
  ready,

  async spawn(clientKey) {
    await ready();
    return await ZukoClient.spawn(clientKey);
  },

  async claim(client, code, label) {
    const result = await client.claim(code, label, 60n);
    return JSON.stringify({
      label: result.label,
      ticket: result.ticket,
      nodeId: result.nodeId,
    });
  },

  async connect(client, ticket, clientKey, cols, rows, pixelWidth, pixelHeight, onEvent) {
    const session = await client.connect(
      ticket,
      clientKey,
      cols,
      rows,
      pixelWidth,
      pixelHeight,
    );
    const reader = session.events().getReader();
    void (async () => {
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done || !value) break;
          const event = value.type === 'data'
            ? { ...value, bytes: Array.from(value.bytes) }
            : value;
          onEvent(JSON.stringify(event));
        }
      } catch (error) {
        onEvent(JSON.stringify({ type: 'closed', error: String(error) }));
      } finally {
        reader.releaseLock();
      }
    })();
    return session;
  },

  send(session, bytes) {
    return session.send(bytes);
  },

  resize(session, cols, rows, pixelWidth, pixelHeight) {
    return session.resize(cols, rows, pixelWidth, pixelHeight);
  },

  close(session) {
    session.close();
  },
};
