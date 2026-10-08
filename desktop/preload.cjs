"use strict";
const { contextBridge, ipcRenderer } = require("electron");
function listen(channel, callback) {
  if (typeof callback !== "function")
    throw new TypeError("Expected a callback");
  const handler = (_event, value) => callback(value);
  ipcRenderer.on(channel, handler);
  return () => ipcRenderer.removeListener(channel, handler);
}
contextBridge.exposeInMainWorld(
  "pet",
  Object.freeze({
    getState: () => ipcRenderer.invoke("pet:state"),
    action: (name, payload) => ipcRenderer.invoke("pet:action", name, payload),
    launch: (value) => ipcRenderer.send("pet:launch", value),
    setHitRegion: (value) => ipcRenderer.send("pet:hit", value === true),
    onState: (callback) => listen("pet:state-update", callback),
    onEffect: (callback) => listen("pet:effect", callback),
  }),
);
