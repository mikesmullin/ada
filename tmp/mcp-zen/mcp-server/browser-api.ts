import WebSocket from "ws";
import * as path from "path";
import { readFileSync } from "fs";
import type {
  ExtensionMessage,
  ServerMessage,
  ServerMessageRequest,
  ExtensionError,
  BrowserTab,
  SnapshotFilter,
  SnapshotElement,
  FormField,
  FillFormField,
  FillFormFieldResult,
  ScrollDirection,
} from "@mcp-zen/common";
import { isPortInUse } from "./util";
import * as crypto from "crypto";

const WS_DEFAULT_PORT = 8765;
const DEFAULT_RESPONSE_TIMEOUT_MS = 3000;

interface ExtensionRequestResolver<T extends ExtensionMessage["resource"]> {
  resource: T;
  resolve: (value: Extract<ExtensionMessage, { resource: T }>) => void;
  reject: (reason?: unknown) => void;
}

export class BrowserAPI {
  private ws: WebSocket | null = null;
  private wsServer: WebSocket.Server | null = null;

  private extensionRequestMap: Map<
    string,
    ExtensionRequestResolver<ExtensionMessage["resource"]>
  > = new Map();

  async init(): Promise<void> {
    const port = readPort();
    if (!currentSecret()) {
      throw new Error(
        "EXTENSION_SECRET env var missing. Copy the secret from the extension's options page."
      );
    }

    if (await isPortInUse(port)) {
      throw new Error(
        `Configured port ${port} is already in use. Please configure a different EXTENSION_PORT.`
      );
    }

    const host = process.env.CONTAINERIZED ? "0.0.0.0" : "localhost";

    this.wsServer = new WebSocket.Server({ host, port });

    console.error(`mcp-zen: WebSocket server listening on ${host}:${port}`);
    this.wsServer.on("connection", (connection) => {
      this.ws = connection;
      console.error("mcp-zen: extension connected");

      this.ws.on("message", (message) => {
        const decoded = JSON.parse(message.toString());
        if (isErrorMessage(decoded)) {
          this.handleExtensionError(decoded);
          return;
        }
        const signature = this.createSignature(JSON.stringify(decoded.payload));
        if (signature !== decoded.signature) {
          console.error("mcp-zen: invalid message signature");
          return;
        }
        this.handleDecodedExtensionMessage(decoded.payload);
      });
    });
    this.wsServer.on("error", (error) => {
      console.error("mcp-zen: WebSocket server error:", error);
    });
  }

  close(): void {
    this.wsServer?.close();
  }

  async listTabs(): Promise<BrowserTab[]> {
    const correlationId = this.send({ cmd: "list-tabs" });
    const message = await this.waitForResponse(correlationId, "tabs-list");
    return message.tabs;
  }

  async navigate(url: string, tabId?: number): Promise<{ tabId: number; url: string }> {
    const correlationId = this.send({ cmd: "navigate", url, tabId });
    const message = await this.waitForResponse(correlationId, "navigated");
    return { tabId: message.tabId, url: message.url };
  }

  async newTab(url?: string): Promise<number | undefined> {
    const correlationId = this.send({ cmd: "new-tab", url });
    const message = await this.waitForResponse(correlationId, "tab-opened");
    return message.tabId;
  }

  async closeTab(tabId: number): Promise<void> {
    const correlationId = this.send({ cmd: "close-tab", tabId });
    await this.waitForResponse(correlationId, "tab-closed");
  }

  async activateTab(tabId: number): Promise<void> {
    const correlationId = this.send({ cmd: "activate-tab", tabId });
    await this.waitForResponse(correlationId, "tab-activated");
  }

  async snapshot(
    tabId: number | undefined,
    filter?: SnapshotFilter,
    selector?: string
  ): Promise<{ count: number; elements: SnapshotElement[] }> {
    const correlationId = this.send({ cmd: "snapshot", tabId, filter, selector });
    const message = await this.waitForResponse(correlationId, "snapshot-result");
    return { count: message.count, elements: message.elements };
  }

  async screenshot(tabId?: number): Promise<string> {
    const correlationId = this.send({ cmd: "screenshot", tabId });
    const message = await this.waitForResponse(correlationId, "screenshot-result", 8000);
    return message.dataUrl;
  }

  async getPageText(
    tabId?: number,
    maxLength?: number
  ): Promise<{ title: string; url: string; text: string }> {
    const correlationId = this.send({ cmd: "get-page-text", tabId, maxLength });
    const message = await this.waitForResponse(correlationId, "page-text");
    return { title: message.title, url: message.url, text: message.text };
  }

  async getFormFields(tabId?: number): Promise<FormField[]> {
    const correlationId = this.send({ cmd: "get-form-fields", tabId });
    const message = await this.waitForResponse(correlationId, "form-fields");
    return message.fields;
  }

  async click(selector: string, tabId?: number): Promise<string> {
    const correlationId = this.send({ cmd: "click", selector, tabId });
    const message = await this.waitForResponse(correlationId, "click-result");
    return message.clicked;
  }

  async fill(selector: string, value: string, tabId?: number): Promise<string> {
    const correlationId = this.send({ cmd: "fill", selector, value, tabId });
    const message = await this.waitForResponse(correlationId, "fill-result");
    return message.value;
  }

  async selectOption(
    selector: string,
    value: string,
    tabId?: number
  ): Promise<{ selected: string; text: string }> {
    const correlationId = this.send({ cmd: "select-option", selector, value, tabId });
    const message = await this.waitForResponse(correlationId, "select-option-result");
    return { selected: message.selected, text: message.text };
  }

  async check(
    selector: string,
    checked: boolean | undefined,
    tabId?: number
  ): Promise<boolean> {
    const correlationId = this.send({ cmd: "check", selector, checked, tabId });
    const message = await this.waitForResponse(correlationId, "check-result");
    return message.checked;
  }

  async fillForm(fields: FillFormField[], tabId?: number): Promise<FillFormFieldResult[]> {
    const correlationId = this.send({ cmd: "fill-form", fields, tabId });
    const message = await this.waitForResponse(correlationId, "fill-form-result");
    return message.results;
  }

  async scroll(
    direction: ScrollDirection | undefined,
    amount: number | undefined,
    selector: string | undefined,
    tabId?: number
  ): Promise<string> {
    const correlationId = this.send({ cmd: "scroll", direction, amount, selector, tabId });
    const message = await this.waitForResponse(correlationId, "scroll-result");
    return message.message;
  }

  async pressKey(
    key: string,
    modifiers: Array<"ctrl" | "shift" | "alt" | "meta"> | undefined,
    tabId?: number
  ): Promise<string> {
    const correlationId = this.send({ cmd: "press-key", key, modifiers, tabId });
    const message = await this.waitForResponse(correlationId, "press-key-result");
    return message.message;
  }

  async evaluate(script: string, tabId?: number): Promise<unknown> {
    const correlationId = this.send({ cmd: "evaluate", script, tabId });
    const message = await this.waitForResponse(correlationId, "evaluate-result");
    return message.result;
  }

  async waitFor(
    text: string | undefined,
    selector: string | undefined,
    timeout: number | undefined,
    tabId?: number
  ): Promise<{ found: boolean; elapsedMs: number }> {
    const correlationId = this.send({ cmd: "wait-for", text, selector, timeout, tabId });
    const message = await this.waitForResponse(
      correlationId,
      "wait-for-result",
      (timeout ?? 10000) + 2000
    );
    return { found: message.found, elapsedMs: message.elapsedMs };
  }

  private createSignature(payload: string): string {
    const secret = currentSecret();
    if (!secret) {
      throw new Error("Shared secret not initialized");
    }
    const hmac = crypto.createHmac("sha256", secret);
    hmac.update(payload);
    return hmac.digest("hex");
  }

  private send(message: ServerMessage): string {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error(
        "Not connected to the mcp-zen browser extension. Make sure Zen is running with the extension loaded."
      );
    }

    const correlationId = Math.random().toString(36).substring(2);
    const req: ServerMessageRequest = { ...message, correlationId };
    const payload = JSON.stringify(req);
    const signature = this.createSignature(payload);

    this.ws.send(JSON.stringify({ payload: req, signature }));
    return correlationId;
  }

  private handleDecodedExtensionMessage(decoded: ExtensionMessage) {
    const { correlationId } = decoded;
    const entry = this.extensionRequestMap.get(correlationId);
    if (!entry) return;
    if (entry.resource !== decoded.resource) {
      console.error("mcp-zen: resource mismatch:", entry.resource, decoded.resource);
      return;
    }
    this.extensionRequestMap.delete(correlationId);
    entry.resolve(decoded);
  }

  private handleExtensionError(decoded: ExtensionError) {
    const { correlationId, errorMessage } = decoded;
    const entry = this.extensionRequestMap.get(correlationId);
    if (!entry) return;
    this.extensionRequestMap.delete(correlationId);
    entry.reject(errorMessage);
  }

  private async waitForResponse<T extends ExtensionMessage["resource"]>(
    correlationId: string,
    resource: T,
    timeoutMs = DEFAULT_RESPONSE_TIMEOUT_MS
  ): Promise<Extract<ExtensionMessage, { resource: T }>> {
    return new Promise<Extract<ExtensionMessage, { resource: T }>>((resolve, reject) => {
      this.extensionRequestMap.set(correlationId, {
        resolve: resolve as (value: ExtensionMessage) => void,
        resource,
        reject,
      });
      setTimeout(() => {
        if (this.extensionRequestMap.delete(correlationId)) {
          reject(new Error(`Timed out waiting for '${resource}' response`));
        }
      }, timeoutMs);
    });
  }
}

const ENV_PATH = path.join(__dirname, "..", ".env");

// Re-read EXTENSION_SECRET from .env fresh on every call rather than caching
// it once at startup. The extension regenerates its secret on every fresh
// "Load Temporary Add-on" (its browser.storage.local is a clean slate each
// time, since Zen won't persist unsigned/temporary extensions across
// restarts -- see mcp-zen's README), so the secret rotates far more often
// than this long-lived server process does. Without this, every rotation
// would silently break signature verification until someone thought to
// restart mcp-zen. Falls back to process.env for deployments with no .env
// file (e.g. an explicit env var passed by a real process supervisor).
function currentSecret(): string | undefined {
  try {
    const content = readFileSync(ENV_PATH, "utf8");
    const match = content.match(/^EXTENSION_SECRET=(.*)$/m);
    if (match) return match[1].trim();
  } catch {
    // no .env file -- fall through to process.env
  }
  return process.env.EXTENSION_SECRET;
}

function readPort(): number {
  return process.env.EXTENSION_PORT ? parseInt(process.env.EXTENSION_PORT, 10) : WS_DEFAULT_PORT;
}

export function isErrorMessage(message: any): message is ExtensionError {
  return message.errorMessage !== undefined && message.correlationId !== undefined;
}
