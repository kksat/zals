import test from "node:test";
import assert from "node:assert/strict";
import {
  ServerStatus,
  WORKSPACE_INDEX_READY,
  DOCS_LIBRARY_READY,
  indexingText,
  indexReadyText,
  indexReadyTooltip,
} from "../src/status.ts";

interface Rendered {
  text: string;
  tooltip: string;
}

function harness(): {
  handlers: Map<string, (params: unknown) => void>;
  rendered: Rendered[];
  status: ServerStatus;
} {
  const handlers = new Map<string, (params: unknown) => void>();
  const rendered: Rendered[] = [];
  const status = new ServerStatus(
    {
      onNotification: (method, handler) => {
        handlers.set(method, handler);
        return {};
      },
    },
    {
      set: (text, tooltip) => rendered.push({ text, tooltip }),
    },
  );
  return { handlers, rendered, status };
}

test("index-ready formatting is count-aware", () => {
  assert.equal(indexingText(), "$(sync~spin) zals: indexing…");
  assert.equal(indexReadyText(1), "$(check) zals: 1 file");
  assert.equal(indexReadyText(3), "$(check) zals: 3 files");
  assert.equal(indexReadyTooltip(2, null), "Workspace index ready (2 files)");
  assert.equal(
    indexReadyTooltip(2, 41),
    "Workspace index ready (2 files); module docs ready (41 modules)",
  );
});

test("a workspace shows indexing until the index is ready", () => {
  const h = harness();
  h.status.start(true);

  assert.equal(h.rendered.length, 1);
  assert.equal(h.rendered[0].text, indexingText());

  h.handlers.get(DOCS_LIBRARY_READY)!({ modulesCount: 12 });
  assert.equal(h.rendered.length, 1);

  h.handlers.get(WORKSPACE_INDEX_READY)!({ filesCount: 7 });
  assert.equal(h.rendered.length, 2);
  assert.equal(h.rendered[1].text, indexReadyText(7));
  assert.equal(h.rendered[1].tooltip, indexReadyTooltip(7, 12));
});

test("docs readiness after the index enriches the tooltip", () => {
  const h = harness();
  h.status.start(true);

  h.handlers.get(WORKSPACE_INDEX_READY)!({ filesCount: 1 });
  h.handlers.get(DOCS_LIBRARY_READY)!({ modulesCount: 3 });
  const last = h.rendered[h.rendered.length - 1];
  assert.equal(last.text, indexReadyText(1));
  assert.equal(last.tooltip, indexReadyTooltip(1, 3));
});

test("without a workspace nothing shows until the index is ready", () => {
  const h = harness();
  h.status.start(false);

  assert.equal(h.rendered.length, 0);
  h.handlers.get(WORKSPACE_INDEX_READY)!({ filesCount: 5 });
  assert.equal(h.rendered.length, 1);
  assert.equal(h.rendered[0].text, indexReadyText(5));
});

test("malformed readiness params render as zero counts", () => {
  const h = harness();
  h.status.start(false);

  h.handlers.get(WORKSPACE_INDEX_READY)!(null);
  h.handlers.get(DOCS_LIBRARY_READY)!({});
  const last = h.rendered[h.rendered.length - 1];
  assert.equal(last.text, indexReadyText(0));
  assert.equal(last.tooltip, indexReadyTooltip(0, 0));
});
