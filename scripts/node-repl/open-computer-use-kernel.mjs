import { parentPort } from "node:worker_threads";
import { PersistentJavaScriptSession } from "./open-computer-use-repl.mjs";

let nextNativeId = 1;
let activeExecutionId;
const pendingNative = new Map();
const native = {
  request(method, params, timeoutMs) {
    const executionId = activeExecutionId;
    if (executionId == null) return Promise.reject(new Error("no active JavaScript execution"));
    const id = nextNativeId++;
    return new Promise((resolve, reject) => {
      pendingNative.set(id, { resolve, reject });
      parentPort.postMessage({ type: "native_request", id, executionId, method, params, timeoutMs });
    });
  },
};
const session = new PersistentJavaScriptSession({ native });

parentPort.on("message", async message => {
  if (message.type === "native_response") {
    const pending = pendingNative.get(message.id);
    if (!pending) return;
    pendingNative.delete(message.id);
    if (message.error) pending.reject(new Error(message.error));
    else pending.resolve(message.result);
    return;
  }
  if (message.type === "exec") {
    let result;
    try {
      activeExecutionId = message.id;
      result = await session.run(message.code, 0, message.requestMeta);
    } catch (error) {
      result = { content: [{ type: "text", text: `Error: ${error instanceof Error ? error.message : String(error)}` }], isError: true };
    }
    activeExecutionId = undefined;
    parentPort.postMessage({ type: "result", id: message.id, result });
  }
});
