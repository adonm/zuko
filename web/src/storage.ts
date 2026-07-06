export type SavedHost = {
  name: string;
  label: string;
  ticket: string;
  tokenHex?: string;
  updatedAt: number;
};

type StoredState = {
  clientKey: number[];
  hosts: SavedHost[];
};

const DB_NAME = "zuko-web";
const STORE = "state";
const STATE_KEY = "state";

export class BrowserStore {
  private dbPromise: Promise<IDBDatabase>;

  constructor() {
    this.dbPromise = openDb();
  }

  async clientKey(): Promise<Uint8Array> {
    const state = await this.readState();
    if (state.clientKey.length === 32) return new Uint8Array(state.clientKey);
    const key = crypto.getRandomValues(new Uint8Array(32));
    state.clientKey = Array.from(key);
    await this.writeState(state);
    return key;
  }

  async hosts(): Promise<SavedHost[]> {
    return (await this.readState()).hosts.sort((a, b) => b.updatedAt - a.updatedAt);
  }

  async upsertHost(host: Omit<SavedHost, "updatedAt">): Promise<void> {
    const state = await this.readState();
    const next: SavedHost = { ...host, updatedAt: Date.now() };
    state.hosts = [next, ...state.hosts.filter((h) => h.name !== host.name)];
    await this.writeState(state);
  }

  async removeHost(name: string): Promise<void> {
    const state = await this.readState();
    state.hosts = state.hosts.filter((h) => h.name !== name);
    await this.writeState(state);
  }

  private async readState(): Promise<StoredState> {
    const db = await this.dbPromise;
    const tx = db.transaction(STORE, "readonly");
    const state = await request<StoredState | undefined>(tx.objectStore(STORE).get(STATE_KEY));
    return state ?? { clientKey: [], hosts: [] };
  }

  private async writeState(state: StoredState): Promise<void> {
    const db = await this.dbPromise;
    const tx = db.transaction(STORE, "readwrite");
    await request(tx.objectStore(STORE).put(state, STATE_KEY));
    await transactionDone(tx);
  }
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE);
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("open IndexedDB"));
  });
}

function request<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("IndexedDB request failed"));
  });
}

function transactionDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error ?? new Error("IndexedDB transaction failed"));
    tx.onabort = () => reject(tx.error ?? new Error("IndexedDB transaction aborted"));
  });
}
