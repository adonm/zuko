declare module "./wasm/zuko_web.js" {
  export default function init(input?: RequestInfo | URL | Response | BufferSource | WebAssembly.Module): Promise<void>;

  export class ZukoClient {
    static spawn(clientKey: Uint8Array): Promise<ZukoClient>;
    endpoint_id(): string;
    claim(code: string, label: string, timeoutSecs: bigint): Promise<ClaimResult>;
    connect(ticket: string, clientKey: Uint8Array, cols: number, rows: number, pixelWidth: number, pixelHeight: number): Promise<ZukoSession>;
  }

  export class ZukoSession {
    events(): ReadableStream<SessionEvent>;
    send(data: Uint8Array): Promise<void>;
    resize(cols: number, rows: number, pixelWidth: number, pixelHeight: number): Promise<void>;
    close(): void;
  }

  export class ClaimResult {
    readonly label: string;
    readonly ticket: string;
    readonly tokenHex: string;
  }

  export type SessionEvent =
    | { type: "connected" }
    | { type: "attached"; tokenHex: string }
    | { type: "data"; bytes: number[] }
    | { type: "error"; code: number; message: string }
    | { type: "closed"; error?: string };
}
