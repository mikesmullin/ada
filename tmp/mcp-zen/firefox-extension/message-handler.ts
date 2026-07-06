import type { ServerMessageRequest } from "@mcp-zen/common";
import { WebsocketClient } from "./client";
import { isCommandAllowed } from "./extension-config";
import * as scripts from "./page-scripts";

const DEFAULT_WAIT_FOR_TIMEOUT = 10000;

export class MessageHandler {
  private client: WebsocketClient;

  constructor(client: WebsocketClient) {
    this.client = client;
  }

  public async handleDecodedMessage(req: ServerMessageRequest): Promise<void> {
    if (!isCommandAllowed(req.cmd)) {
      throw new Error(`Command '${req.cmd}' is disabled (see allowed-tools.yaml)`);
    }

    switch (req.cmd) {
      case "list-tabs":
        return this.listTabs(req.correlationId);
      case "navigate":
        return this.navigate(req.correlationId, req.url, req.tabId);
      case "new-tab":
        return this.newTab(req.correlationId, req.url);
      case "close-tab":
        return this.closeTab(req.correlationId, req.tabId);
      case "activate-tab":
        return this.activateTab(req.correlationId, req.tabId);
      case "snapshot":
        return this.runInTab(
          req.correlationId,
          "snapshot-result",
          req.tabId,
          scripts.snapshotScript(req.filter ?? "all", req.selector ?? null)
        );
      case "screenshot":
        return this.screenshot(req.correlationId, req.tabId);
      case "get-page-text":
        return this.runInTab(
          req.correlationId,
          "page-text",
          req.tabId,
          scripts.getPageTextScript(req.maxLength ?? 8000)
        );
      case "get-form-fields":
        return this.runInTab(
          req.correlationId,
          "form-fields",
          req.tabId,
          scripts.getFormFieldsScript()
        );
      case "click":
        return this.runInTab(
          req.correlationId,
          "click-result",
          req.tabId,
          scripts.clickScript(req.selector)
        );
      case "fill":
        return this.runInTab(
          req.correlationId,
          "fill-result",
          req.tabId,
          scripts.fillScript(req.selector, req.value)
        );
      case "select-option":
        return this.runInTab(
          req.correlationId,
          "select-option-result",
          req.tabId,
          scripts.selectOptionScript(req.selector, req.value)
        );
      case "check":
        return this.runInTab(
          req.correlationId,
          "check-result",
          req.tabId,
          scripts.checkScript(req.selector, req.checked !== false)
        );
      case "fill-form":
        return this.runInTab(
          req.correlationId,
          "fill-form-result",
          req.tabId,
          scripts.fillFormScript(req.fields)
        );
      case "scroll":
        return this.runInTab(
          req.correlationId,
          "scroll-result",
          req.tabId,
          scripts.scrollScript(req.direction, req.amount, req.selector)
        );
      case "press-key":
        return this.runInTab(
          req.correlationId,
          "press-key-result",
          req.tabId,
          scripts.pressKeyScript(req.key, req.modifiers ?? [])
        );
      case "evaluate":
        return this.runInTab(
          req.correlationId,
          "evaluate-result",
          req.tabId,
          scripts.evaluateScript(req.script),
          (value) => ({ result: value?.value })
        );
      case "wait-for":
        return this.runInTab(
          req.correlationId,
          "wait-for-result",
          req.tabId,
          scripts.waitForScript(req.text, req.selector, req.timeout ?? DEFAULT_WAIT_FOR_TIMEOUT)
        );
      default:
        const _exhaustiveCheck: never = req;
        console.error("mcp-zen: invalid message received:", req);
    }
  }

  private async resolveTabId(tabId?: number): Promise<number> {
    if (tabId !== undefined) return tabId;
    const [activeTab] = await browser.tabs.query({ active: true, currentWindow: true });
    if (!activeTab?.id) throw new Error("No active tab found");
    return activeTab.id;
  }

  private async ensureAutomationPermission(): Promise<void> {
    const granted = await browser.permissions.contains({ origins: ["<all_urls>"] });
    if (!granted) {
      throw new Error(
        "Browser automation permission not granted yet. Open the extension's options page and click 'Enable browser automation'."
      );
    }
  }

  /**
   * Run an in-page script in the target tab and forward its result to the
   * server under `resource`. `mapResult` lets a caller reshape the raw
   * executeScript return value into the expected extension-message shape;
   * by default the script's own return value is spread as-is.
   */
  private async runInTab(
    correlationId: string,
    resource: string,
    tabId: number | undefined,
    code: string,
    mapResult: (value: any) => Record<string, unknown> = (value) => value
  ): Promise<void> {
    await this.ensureAutomationPermission();
    const resolvedTabId = await this.resolveTabId(tabId);
    const results = await browser.tabs.executeScript(resolvedTabId, { code });
    const raw = results?.[0];
    if (raw && typeof raw === "object" && "error" in raw) {
      throw new Error(String((raw as { error: string }).error));
    }
    await this.client.sendResourceToServer({
      resource,
      correlationId,
      ...mapResult(raw),
    } as any);
  }

  private async listTabs(correlationId: string): Promise<void> {
    const tabs = await browser.tabs.query({});
    await this.client.sendResourceToServer({
      resource: "tabs-list",
      correlationId,
      tabs: tabs.map((t) => ({
        id: t.id,
        url: t.url,
        title: t.title,
        active: t.active,
        windowId: t.windowId,
      })),
    });
  }

  private async navigate(correlationId: string, url: string, tabId?: number): Promise<void> {
    const resolvedTabId = await this.resolveTabId(tabId);
    await browser.tabs.update(resolvedTabId, { url });
    await this.client.sendResourceToServer({
      resource: "navigated",
      correlationId,
      tabId: resolvedTabId,
      url,
    });
  }

  private async newTab(correlationId: string, url?: string): Promise<void> {
    const tab = await browser.tabs.create({ url });
    await this.client.sendResourceToServer({
      resource: "tab-opened",
      correlationId,
      tabId: tab.id,
    });
  }

  private async closeTab(correlationId: string, tabId: number): Promise<void> {
    await browser.tabs.remove(tabId);
    await this.client.sendResourceToServer({
      resource: "tab-closed",
      correlationId,
      tabId,
    });
  }

  private async activateTab(correlationId: string, tabId: number): Promise<void> {
    await browser.tabs.update(tabId, { active: true });
    await this.client.sendResourceToServer({
      resource: "tab-activated",
      correlationId,
      tabId,
    });
  }

  private async screenshot(correlationId: string, tabId?: number): Promise<void> {
    await this.ensureAutomationPermission();
    const resolvedTabId = await this.resolveTabId(tabId);
    // captureVisibleTab only ever captures the focused/active tab, so bring
    // the target tab to the front first -- a real limitation vs. zen-mcp's
    // BiDi screenshot, which can capture any background context.
    const tab = await browser.tabs.update(resolvedTabId, { active: true });
    const dataUrl = await browser.tabs.captureVisibleTab(tab?.windowId, { format: "png" });
    await this.client.sendResourceToServer({
      resource: "screenshot-result",
      correlationId,
      dataUrl,
    });
  }
}
