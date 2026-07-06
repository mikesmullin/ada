export interface ExtensionMessageBase {
  resource: string;
  correlationId: string;
}

export interface BrowserTab {
  id?: number;
  url?: string;
  title?: string;
  active?: boolean;
  windowId?: number;
}

export interface TabsListExtensionMessage extends ExtensionMessageBase {
  resource: "tabs-list";
  tabs: BrowserTab[];
}

export interface NavigatedExtensionMessage extends ExtensionMessageBase {
  resource: "navigated";
  tabId: number;
  url: string;
}

export interface TabOpenedExtensionMessage extends ExtensionMessageBase {
  resource: "tab-opened";
  tabId: number | undefined;
}

export interface TabClosedExtensionMessage extends ExtensionMessageBase {
  resource: "tab-closed";
  tabId: number;
}

export interface TabActivatedExtensionMessage extends ExtensionMessageBase {
  resource: "tab-activated";
  tabId: number;
}

export interface SnapshotElement {
  tag: string;
  selector: string;
  type?: string;
  name?: string;
  id?: string;
  value?: string;
  placeholder?: string;
  checked?: boolean;
  href?: string;
  role?: string;
  ariaLabel?: string;
  label?: string;
  text?: string;
}

export interface SnapshotExtensionMessage extends ExtensionMessageBase {
  resource: "snapshot-result";
  count: number;
  elements: SnapshotElement[];
}

export interface ScreenshotExtensionMessage extends ExtensionMessageBase {
  resource: "screenshot-result";
  dataUrl: string;
}

export interface PageTextExtensionMessage extends ExtensionMessageBase {
  resource: "page-text";
  title: string;
  url: string;
  text: string;
}

export interface FormField {
  index: number;
  tag: string;
  type: string;
  name: string;
  id: string;
  selector: string;
  value: string;
  placeholder: string;
  label: string;
  checked?: boolean;
  required: boolean;
  disabled: boolean;
  visible: boolean;
  options?: Array<{ value: string; text: string; selected: boolean }>;
}

export interface FormFieldsExtensionMessage extends ExtensionMessageBase {
  resource: "form-fields";
  fields: FormField[];
}

export interface ClickExtensionMessage extends ExtensionMessageBase {
  resource: "click-result";
  clicked: string;
}

export interface ClickTextExtensionMessage extends ExtensionMessageBase {
  resource: "click-text-result";
  clickedText: string;
}

export interface FillExtensionMessage extends ExtensionMessageBase {
  resource: "fill-result";
  filled: string;
  value: string;
}

export interface SelectOptionExtensionMessage extends ExtensionMessageBase {
  resource: "select-option-result";
  selected: string;
  text: string;
}

export interface CheckExtensionMessage extends ExtensionMessageBase {
  resource: "check-result";
  selector: string;
  checked: boolean;
}

export interface FillFormFieldResult {
  selector: string;
  action: string;
  status: "ok" | "error";
  error?: string;
}

export interface FillFormExtensionMessage extends ExtensionMessageBase {
  resource: "fill-form-result";
  results: FillFormFieldResult[];
}

export interface ScrollExtensionMessage extends ExtensionMessageBase {
  resource: "scroll-result";
  message: string;
}

export interface PressKeyExtensionMessage extends ExtensionMessageBase {
  resource: "press-key-result";
  message: string;
}

export interface EvaluateExtensionMessage extends ExtensionMessageBase {
  resource: "evaluate-result";
  result: unknown;
}

export interface WaitForExtensionMessage extends ExtensionMessageBase {
  resource: "wait-for-result";
  found: boolean;
  elapsedMs: number;
}

export type ExtensionMessage =
  | TabsListExtensionMessage
  | NavigatedExtensionMessage
  | TabOpenedExtensionMessage
  | TabClosedExtensionMessage
  | TabActivatedExtensionMessage
  | SnapshotExtensionMessage
  | ScreenshotExtensionMessage
  | PageTextExtensionMessage
  | FormFieldsExtensionMessage
  | ClickExtensionMessage
  | ClickTextExtensionMessage
  | FillExtensionMessage
  | SelectOptionExtensionMessage
  | CheckExtensionMessage
  | FillFormExtensionMessage
  | ScrollExtensionMessage
  | PressKeyExtensionMessage
  | EvaluateExtensionMessage
  | WaitForExtensionMessage;

export interface ExtensionError {
  correlationId: string;
  errorMessage: string;
}
