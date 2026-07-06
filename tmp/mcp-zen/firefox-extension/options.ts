import { getSecret, getPorts, setPorts, getAllowedCommands } from "./extension-config";

const secretDisplay = document.getElementById("secret-display") as HTMLDivElement;
const copyButton = document.getElementById("copy-button") as HTMLButtonElement;
const secretStatus = document.getElementById("secret-status") as HTMLDivElement;
const portsInput = document.getElementById("ports-input") as HTMLInputElement;
const savePortsButton = document.getElementById("save-ports") as HTMLButtonElement;
const portsStatus = document.getElementById("ports-status") as HTMLDivElement;
const grantPermissionButton = document.getElementById("grant-permission") as HTMLButtonElement;
const permissionStatus = document.getElementById("permission-status") as HTMLDivElement;
const toolList = document.getElementById("tool-list") as HTMLUListElement;

function flashStatus(el: HTMLDivElement, message: string, isError = false) {
  el.textContent = message;
  el.style.color = isError ? "red" : "#4caf50";
  setTimeout(() => {
    el.textContent = "";
    el.style.color = "";
  }, 3000);
}

async function loadSecret() {
  try {
    const secret = await getSecret();
    if (secret) {
      secretDisplay.textContent = secret;
    } else {
      secretDisplay.textContent = "No secret found. Please reinstall the extension.";
      secretDisplay.style.color = "red";
      copyButton.disabled = true;
    }
  } catch (error) {
    console.error("mcp-zen: error loading secret:", error);
    secretDisplay.textContent = "Error loading secret.";
    secretDisplay.style.color = "red";
    copyButton.disabled = true;
  }
}

async function copyToClipboard(event: MouseEvent) {
  if (!event.isTrusted) return;
  const secret = secretDisplay.textContent;
  if (!secret || secret.includes("No secret found") || secret.includes("Error loading")) return;
  try {
    await navigator.clipboard.writeText(secret);
    flashStatus(secretStatus, "Secret copied to clipboard!");
  } catch (error) {
    console.error("mcp-zen: error copying to clipboard:", error);
    flashStatus(secretStatus, "Failed to copy to clipboard", true);
  }
}

async function loadPorts() {
  try {
    const ports = await getPorts();
    portsInput.value = ports.join(", ");
  } catch (error) {
    console.error("mcp-zen: error loading ports:", error);
    flashStatus(portsStatus, "Error loading ports.", true);
  }
}

async function savePorts(event: MouseEvent) {
  if (!event.isTrusted) return;
  try {
    const portStrings = portsInput.value
      .split(",")
      .map((p) => p.trim())
      .filter(Boolean);

    const ports: number[] = [];
    for (const portStr of portStrings) {
      const port = parseInt(portStr, 10);
      if (isNaN(port) || port < 1 || port > 65535) {
        throw new Error(`Invalid port number: ${portStr}`);
      }
      ports.push(port);
    }
    if (ports.length === 0) throw new Error("At least one port must be specified.");

    await setPorts(ports);
    browser.runtime.reload();
  } catch (error) {
    flashStatus(portsStatus, error instanceof Error ? error.message : "Failed to save ports", true);
  }
}

async function refreshPermissionStatus() {
  const granted = await browser.permissions.contains({ origins: ["<all_urls>"] });
  grantPermissionButton.textContent = granted ? "Browser automation enabled" : "Enable browser automation";
  grantPermissionButton.classList.toggle("granted", granted);
  grantPermissionButton.disabled = granted;
}

async function grantPermission(event: MouseEvent) {
  if (!event.isTrusted) return;
  try {
    const granted = await browser.permissions.request({ origins: ["<all_urls>"] });
    if (granted) {
      flashStatus(permissionStatus, "Browser automation enabled.");
    } else {
      flashStatus(permissionStatus, "Permission was not granted.", true);
    }
  } catch (error) {
    console.error("mcp-zen: error requesting permission:", error);
    flashStatus(permissionStatus, "Failed to request permission.", true);
  } finally {
    await refreshPermissionStatus();
  }
}

function renderToolList() {
  toolList.innerHTML = "";
  for (const cmd of getAllowedCommands()) {
    const li = document.createElement("li");
    li.textContent = cmd;
    toolList.appendChild(li);
  }
}

copyButton.addEventListener("click", copyToClipboard);
savePortsButton.addEventListener("click", savePorts);
grantPermissionButton.addEventListener("click", grantPermission);

document.addEventListener("DOMContentLoaded", () => {
  loadSecret();
  loadPorts();
  refreshPermissionStatus();
  renderToolList();
});
