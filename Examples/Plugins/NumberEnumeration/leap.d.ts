interface LeapListItem {
  id: string;
  title: string;
  description?: string;
}
interface LeapContext {
  commandID: string;
  query: string;
  signal: AbortSignal;
}
interface LeapInput {
  commandID: string;
  text: string;
  /** 仅原生列表支持；回调完成或输入过期后更新失效。 */
  setList(items: LeapListItem[]): void;
  signal: AbortSignal;
}
interface LeapSelection {
  commandID: string;
  text: string;
  item: Readonly<LeapListItem>;
  signal: AbortSignal;
}
interface LeapCommonSDK {
  onEnter(callback: (context: LeapContext) => void | Promise<void>): () => void;
  onExit(callback: () => void | Promise<void>): () => void;
  onInputChange(callback: (context: LeapInput) => void | Promise<void>): () => void;
  copyText(text: string): Promise<boolean>;
  outPlugin(): Promise<boolean>;
  hideMainWindow(): Promise<boolean>;
  log(...values: unknown[]): void;
}
interface LeapNodeSDK extends LeapCommonSDK {
  /** Node.js 入口注册；网页通过 invoke 调用入口。 */
  onSelect(callback: (context: LeapSelection) => string | void | Promise<string | void>): () => void;
  onInvoke(callback: (context: LeapContext) => string | void | Promise<string | void>): () => void;
}
interface LeapBrowserSDK extends LeapCommonSDK {
  /** 网页调用当前插件的 Node.js/Python 入口。 */
  invoke(commandID: string, query?: string): Promise<string>;
  chooseDirectory(): Promise<string | null>;
  openDirectory(path: string): Promise<boolean>;
  onSubmit(callback: (text: string) => void | Promise<void>): () => void;
}
declare const leap: LeapNodeSDK;
interface Window { readonly leap: LeapBrowserSDK; }
