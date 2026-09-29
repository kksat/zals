import type { LanguageClientOptions } from "vscode-languageclient/node.js";

/**
 * Creates LanguageClientOptions configured per ADR-0033 and ADR-0036.
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
