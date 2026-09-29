import * as path from "node:path";

/**
 * Resolves the bundled zals executable path for the current platform.
 *
 * Per ADR-0031 and ADR-0043, zals is strictly loaded from the extension's bundled
 * bin/ directory, without PATH or environment variable overrides.
 */
export function resolveBinaryPath(
  extensionPath: string,
  platform: NodeJS.Platform = process.platform,
): string {
  const binaryName = platform === "win32" ? "zals.exe" : "zals";
  return path.join(extensionPath, "bin", binaryName);
}
