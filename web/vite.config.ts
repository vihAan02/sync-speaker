import { defineConfig } from "vite";

// `npm run dev` proxies the leader's API so the UI can be developed against a running node.
export default defineConfig({
  server: {
    proxy: {
      "/api": "http://localhost:8080",
      "/ws": { target: "ws://localhost:8080", ws: true },
    },
  },
});
