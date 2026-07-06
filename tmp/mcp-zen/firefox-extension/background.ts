import { WebsocketClient } from "./client";
import { MessageHandler } from "./message-handler";
import { getConfig, generateSecret } from "./extension-config";

function initClient(port: number, secret: string) {
  const wsClient = new WebsocketClient(port, secret);
  const messageHandler = new MessageHandler(wsClient);

  wsClient.connect();

  wsClient.addMessageListener(async (message) => {
    console.log("mcp-zen: message from server:", message);
    try {
      await messageHandler.handleDecodedMessage(message);
    } catch (error) {
      console.error("mcp-zen: error handling message:", error);
      if (error instanceof Error) {
        await wsClient.sendErrorToServer(message.correlationId, error.message);
      } else {
        await wsClient.sendErrorToServer(message.correlationId, String(error));
      }
    }
  });
}

async function initExtension() {
  let config = await getConfig();
  if (!config.secret) {
    console.log("mcp-zen: no secret found, generating new one");
    await generateSecret();
    await browser.runtime.openOptionsPage();
    config = await getConfig();
  }
  return config;
}

initExtension()
  .then((config) => {
    const secret = config.secret;
    if (!secret) {
      console.error("mcp-zen: secret not found in storage - reinstall extension");
      return;
    }
    for (const port of config.ports) {
      initClient(port, secret);
    }
    console.log("mcp-zen: extension initialized");
  })
  .catch((error) => {
    console.error("mcp-zen: error initializing extension:", error);
  });
