import * as fs from "node:fs";
import * as vscode from "vscode";
import {
  LanguageClient,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node.js";
import { resolveBinaryPath } from "./binary.ts";
import { createClientOptions } from "./clientOptions.ts";

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const binaryPath = resolveBinaryPath(context.extensionPath);

  if (!fs.existsSync(binaryPath)) {
    vscode.window.showErrorMessage(
      `zals executable not found at ${binaryPath}. Reinstall the extension or verify package integrity.`,
    );
    return;
  }

  const serverOptions: ServerOptions = {
    command: binaryPath,
    transport: TransportKind.stdio,
  };

  const clientOptions = createClientOptions(
    vscode.workspace.getConfiguration("ansible") as unknown as Record<string, unknown>,
  );

  client = new LanguageClient(
    "ansible",
    "Ansible Language Server",
    serverOptions,
    clientOptions,
  );

  await client.start();
}

export async function deactivate(): Promise<void> {
  if (client) {
    await client.stop();
    client = undefined;
  }
}
