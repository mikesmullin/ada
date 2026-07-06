import type {
  ExtensionMessage,
  ExtensionError,
  ServerMessageRequest,
} from "@mcp-zen/common";
import { getMessageSignature } from "./auth";

const RECONNECT_INTERVAL = 2000; // 2 seconds

export class WebsocketClient {
  private socket: WebSocket | null = null;
  private readonly port: number;
  private readonly secret: string;
  private reconnectTimer: number | null = null;
  private connectionAttempts = 0;
  private messageCallback: ((data: ServerMessageRequest) => void) | null = null;

  constructor(port: number, secret: string) {
    this.port = port;
    this.secret = secret;
  }

  public connect(): void {
    console.log("mcp-zen: connecting to WebSocket server at port", this.port);

    this.socket = new WebSocket(`ws://localhost:${this.port}`);

    this.socket.addEventListener("open", () => {
      console.log("mcp-zen: connected to WebSocket server at port", this.port);
      this.connectionAttempts = 0;
    });

    this.socket.addEventListener("close", () => {
      console.log("mcp-zen: WebSocket connection closed at port", this.port);
      this.connectionAttempts = 0;
    });

    this.socket.addEventListener("error", (event) => {
      console.error("mcp-zen: WebSocket error:", event);
    });

    this.socket.addEventListener("message", async (event) => {
      if (this.messageCallback === null) return;
      try {
        const signedMessage = JSON.parse(event.data);
        const messageSig = await getMessageSignature(
          JSON.stringify(signedMessage.payload),
          this.secret
        );
        if (messageSig.length === 0 || messageSig !== signedMessage.signature) {
          console.error("mcp-zen: invalid message signature");
          await this.sendErrorToServer(
            signedMessage.payload.correlationId,
            "Invalid message signature - extension and server not in sync"
          );
          return;
        }
        this.messageCallback(signedMessage.payload);
      } catch (error) {
        console.error("mcp-zen: failed to parse message:", error);
      }
    });

    if (this.reconnectTimer === null) {
      this.startReconnectTimer();
    }
  }

  public addMessageListener(callback: (data: ServerMessageRequest) => void): void {
    this.messageCallback = callback;
  }

  private startReconnectTimer(): void {
    this.reconnectTimer = window.setInterval(() => {
      if (this.socket && this.socket.readyState === WebSocket.CONNECTING) {
        this.connectionAttempts++;
        if (this.connectionAttempts > 2) {
          this.socket.close();
        }
      }

      if (!this.socket || this.socket.readyState === WebSocket.CLOSED) {
        this.connect();
      }
    }, RECONNECT_INTERVAL);
  }

  public async sendResourceToServer(resource: ExtensionMessage): Promise<void> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      console.error("mcp-zen: socket is not open");
      return;
    }
    const signedMessage = {
      payload: resource,
      signature: await getMessageSignature(JSON.stringify(resource), this.secret),
    };
    this.socket.send(JSON.stringify(signedMessage));
  }

  public async sendErrorToServer(correlationId: string, errorMessage: string): Promise<void> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      console.error("mcp-zen: socket is not open", this.socket);
      return;
    }
    const extensionError: ExtensionError = { correlationId, errorMessage };
    this.socket.send(JSON.stringify(extensionError));
  }

  public disconnect(): void {
    if (this.reconnectTimer !== null) {
      window.clearInterval(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.socket) {
      this.socket.close();
      this.socket = null;
    }
  }
}
