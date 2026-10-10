interface LeapListItem {
  id: string;
  title: string;
  /** 条目标题下方的子标题；空白时隐藏。 */
  description?: string;
}
interface LeapListOptions { title?: string; }
interface LeapContext {
  commandID: string;
  query: string;
  signal: AbortSignal;
}
interface LeapInput {
  commandID: string;
  text: string;
  /** 仅原生列表支持；回调完成或输入过期后更新失效。 */
  setList(items: LeapListItem[], options?: LeapListOptions): void;
  signal: AbortSignal;
}
interface LeapSelection {
  commandID: string;
  text: string;
  item: Readonly<LeapListItem>;
  signal: AbortSignal;
}
interface LeapCopiedFile {
  path: string;
  name: string;
  isFile: boolean;
  /** 与 uTools 字段保持兼容。 */
  isDiractory: boolean;
}
type LeapImage = string | Uint8Array;
type LeapPathName = 'home' | 'appData' | 'userData' | 'temp' | 'exe' | 'desktop' | 'documents' | 'downloads' | 'music' | 'pictures' | 'videos' | 'logs';
interface LeapCommonSDK {
  onEnter(callback: (context: LeapContext) => void | Promise<void>): () => void;
  onExit(callback: () => void | Promise<void>): () => void;
  onInputChange(callback: (context: LeapInput) => void | Promise<void>): () => void;
  copyText(text: string): Promise<boolean>;
  copyFile(filePath: string | string[]): Promise<boolean>;
  copyImage(image: LeapImage): Promise<boolean>;
  hideMainWindowPasteText(text: string): Promise<boolean>;
  hideMainWindowPasteFile(filePath: string | string[]): Promise<boolean>;
  hideMainWindowPasteImage(image: LeapImage): Promise<boolean>;
  hideMainWindowTypeString(text: string): Promise<boolean>;
  shellOpenPath(fullPath: string): Promise<boolean>;
  shellTrashItem(fullPath: string): Promise<boolean>;
  shellShowItemInFolder(fullPath: string): Promise<boolean>;
  shellOpenExternal(url: string): Promise<boolean>;
  getPath(name: LeapPathName): Promise<string>;
  getFileIcon(filePath: string): Promise<string>;
  getCopyedFiles(): Promise<LeapCopiedFile[]>;
  shellBeep(): Promise<boolean>;
  getNativeId(): Promise<string>;
  getAppName(): Promise<string>;
  getAppVersion(): Promise<string>;
  readCurrentFolderPath(): Promise<string>;
  readCurrentBrowserUrl(): Promise<string>;
  isDev(): Promise<boolean>;
  isMacOS(): Promise<boolean>;
  isWindows(): Promise<boolean>;
  isLinux(): Promise<boolean>;
  showNotification(body: string, clickFeatureCode?: string): Promise<boolean>;
  simulateKeyboardTap(key: string, ...modifiers: string[]): Promise<boolean>;

  outPlugin(): Promise<boolean>;
  hideMainWindow(): Promise<boolean>;
  /** 仅支持当前原生列表回调，结束或取消时宿主自动清理。 */
  showLoading(): Promise<boolean>;
  hideLoading(): Promise<boolean>;
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
