/**
 * Status-bar surface for server readiness, driven by the server's custom
 * notifications (`ansible/workspaceIndexReady` and
 * `ansible/docsLibraryReady`).
 *
 * Formatting and notification handling stay free of VS Code imports so they
 * remain testable under `node --test`; `extension.ts` supplies the view.
 */

export const WORKSPACE_INDEX_READY = "ansible/workspaceIndexReady";
export const DOCS_LIBRARY_READY = "ansible/docsLibraryReady";

/** Where the status is rendered. */
export interface StatusView {
  set(text: string, tooltip: string): void;
}

/** A LanguageClient-like source of server notifications. */
export interface NotificationSource {
  onNotification(method: string, handler: (params: unknown) => void): unknown;
}

export function indexingText(): string {
  return "$(sync~spin) zals: indexing…";
}

export function indexingTooltip(): string {
  return "zals is indexing the workspace for navigation";
}

export function indexReadyText(filesCount: number): string {
  return `$(check) zals: ${filesCount} ${filesCount === 1 ? "file" : "files"}`;
}

export function indexReadyTooltip(filesCount: number, docsModules: number | null): string {
  const files = `Workspace index ready (${filesCount} ${filesCount === 1 ? "file" : "files"})`;
  return docsModules === null ? files : `${files}; module docs ready (${docsModules} modules)`;
}

/** Renders server readiness into a {@link StatusView}. */
export class ServerStatus {
  private readonly source: NotificationSource;
  private readonly view: StatusView;
  private indexReady = false;
  private filesCount = 0;
  private docsModules: number | null = null;

  constructor(source: NotificationSource, view: StatusView) {
    this.source = source;
    this.view = view;
  }

  /**
   * Show the initial state (when a Workspace folder is open) and subscribe to
   * the readiness notifications. Handlers registered before the client starts
   * are applied by the client once the connection is up, and survive restarts.
   */
  start(hasWorkspace: boolean): void {
    if (hasWorkspace) {
      this.view.set(indexingText(), indexingTooltip());
    }
    this.source.onNotification(WORKSPACE_INDEX_READY, (params) => {
      this.indexReady = true;
      this.filesCount = readCount(params, "filesCount");
      this.render();
    });
    this.source.onNotification(DOCS_LIBRARY_READY, (params) => {
      this.docsModules = readCount(params, "modulesCount");
      this.render();
    });
  }

  private render(): void {
    if (!this.indexReady) return;
    this.view.set(indexReadyText(this.filesCount), indexReadyTooltip(this.filesCount, this.docsModules));
  }
}

function readCount(params: unknown, key: string): number {
  if (typeof params !== "object" || params === null) return 0;
  const value = (params as Record<string, unknown>)[key];
  return typeof value === "number" ? value : 0;
}
