import type { LanguageClientOptions } from "vscode-languageclient/node.js";

/**
 * Creates the language client's document and configuration options.
 *
 * - Selects file and untitled schemes for 'ansible' language
 * - Synchronizes the 'ansible' configuration section
 * - Forwards current ansible settings via initializationOptions
 */
export function createClientOptions(
  ansibleConfig?: Record<string, unknown>,
): LanguageClientOptions {
  return {
    documentSelector: [
      { scheme: "file", language: "ansible" },
      { scheme: "untitled", language: "ansible" },
    ],
    synchronize: {
      configurationSection: "ansible",
    },
    initializationOptions: {
      ansible: ansibleConfig ?? {},
    },
  };
}
