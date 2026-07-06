export interface ServerMessageBase {
  cmd: string;
}

// Every tab-scoped command takes an optional tabId; when omitted, the
// extension resolves it to the active tab of the current window.

export interface ListTabsServerMessage extends ServerMessageBase {
  cmd: "list-tabs";
}

export interface NavigateServerMessage extends ServerMessageBase {
  cmd: "navigate";
  tabId?: number;
  url: string;
}

export interface NewTabServerMessage extends ServerMessageBase {
  cmd: "new-tab";
  url?: string;
}

export interface CloseTabServerMessage extends ServerMessageBase {
  cmd: "close-tab";
  tabId: number;
}

export interface ActivateTabServerMessage extends ServerMessageBase {
  cmd: "activate-tab";
  tabId: number;
}

export type SnapshotFilter = "all" | "interactive" | "form";

export interface SnapshotServerMessage extends ServerMessageBase {
  cmd: "snapshot";
  tabId?: number;
  filter?: SnapshotFilter;
  selector?: string;
}

export interface ScreenshotServerMessage extends ServerMessageBase {
  cmd: "screenshot";
  tabId?: number;
}

export interface GetPageTextServerMessage extends ServerMessageBase {
  cmd: "get-page-text";
  tabId?: number;
  maxLength?: number;
}

export interface GetFormFieldsServerMessage extends ServerMessageBase {
  cmd: "get-form-fields";
  tabId?: number;
}

export interface ClickServerMessage extends ServerMessageBase {
  cmd: "click";
  tabId?: number;
  selector: string;
}

export interface ClickTextServerMessage extends ServerMessageBase {
  cmd: "click-text";
  tabId?: number;
  text: string;
}

export interface FillServerMessage extends ServerMessageBase {
  cmd: "fill";
  tabId?: number;
  selector: string;
  value: string;
}

export interface SelectOptionServerMessage extends ServerMessageBase {
  cmd: "select-option";
  tabId?: number;
  selector: string;
  value: string;
}

export interface CheckServerMessage extends ServerMessageBase {
  cmd: "check";
  tabId?: number;
  selector: string;
  checked?: boolean;
}

export type FillFormAction = "fill" | "select" | "check" | "uncheck" | "click";

export interface FillFormField {
  selector: string;
  value?: string;
  action?: FillFormAction;
}

export interface FillFormServerMessage extends ServerMessageBase {
  cmd: "fill-form";
  tabId?: number;
  fields: FillFormField[];
}

export type ScrollDirection = "up" | "down" | "top" | "bottom";

export interface ScrollServerMessage extends ServerMessageBase {
  cmd: "scroll";
  tabId?: number;
  direction?: ScrollDirection;
  amount?: number;
  selector?: string;
}

export interface PressKeyServerMessage extends ServerMessageBase {
  cmd: "press-key";
  tabId?: number;
  key: string;
  modifiers?: Array<"ctrl" | "shift" | "alt" | "meta">;
}

export interface EvaluateServerMessage extends ServerMessageBase {
  cmd: "evaluate";
  tabId?: number;
  script: string;
}

export interface WaitForServerMessage extends ServerMessageBase {
  cmd: "wait-for";
  tabId?: number;
  text?: string;
  selector?: string;
  timeout?: number;
}

export type ServerMessage =
  | ListTabsServerMessage
  | NavigateServerMessage
  | NewTabServerMessage
  | CloseTabServerMessage
  | ActivateTabServerMessage
  | SnapshotServerMessage
  | ScreenshotServerMessage
  | GetPageTextServerMessage
  | GetFormFieldsServerMessage
  | ClickServerMessage
  | ClickTextServerMessage
  | FillServerMessage
  | SelectOptionServerMessage
  | CheckServerMessage
  | FillFormServerMessage
  | ScrollServerMessage
  | PressKeyServerMessage
  | EvaluateServerMessage
  | WaitForServerMessage;

export type ServerMessageRequest = ServerMessage & { correlationId: string };
