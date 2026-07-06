import yaml from "js-yaml";
import type { ServerMessageRequest } from "@mcp-zen/common";
// esbuild's `--loader:.yaml=text` inlines this file's contents as a string.
import allowedToolsYaml from "./allowed-tools.yaml";

const DEFAULT_WS_PORT = 8765;

export interface ExtensionConfig {
  secret: string;
  ports: number[];
}

/** Static, build-time allow-list -- see allowed-tools.yaml. */
const ALLOWED_COMMANDS: ReadonlySet<ServerMessageRequest["cmd"]> = new Set(
  (yaml.load(allowedToolsYaml) as { enabled: string[] }).enabled as ServerMessageRequest["cmd"][]
);

export function isCommandAllowed(command: ServerMessageRequest["cmd"]): boolean {
  return ALLOWED_COMMANDS.has(command);
}

export function getAllowedCommands(): string[] {
  return [...ALLOWED_COMMANDS];
}

export async function getConfig(): Promise<ExtensionConfig> {
  const configObj = await browser.storage.local.get("config");
  const config: ExtensionConfig = configObj.config || { secret: "", ports: [DEFAULT_WS_PORT] };
  if (!config.ports || config.ports.length === 0) {
    config.ports = [DEFAULT_WS_PORT];
  }
  return config;
}

export async function saveConfig(config: ExtensionConfig): Promise<void> {
  await browser.storage.local.set({ config });
}

export async function getSecret(): Promise<string> {
  const config = await getConfig();
  return config.secret;
}

export async function generateSecret(): Promise<string> {
  const config = await getConfig();
  config.secret = crypto.randomUUID();
  await saveConfig(config);
  return config.secret;
}

export async function getPorts(): Promise<number[]> {
  const config = await getConfig();
  return config.ports;
}

export async function setPorts(ports: number[]): Promise<void> {
  const config = await getConfig();
  config.ports = ports;
  await saveConfig(config);
}
