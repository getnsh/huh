import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// One entry point per window. The overlay and the session panel are their own
// windows and exist from launch: key-down to visible is budgeted at 50 ms, and
// building a WebView takes longer than that on any machine. Settings is built
// when it is first opened.
export default defineConfig({
  plugins: [svelte()],
  clearScreen: false,
  server: { port: 5173, strictPort: true },
  build: {
    outDir: "build",
    emptyOutDir: true,
    target: "chrome114",
    rollupOptions: {
      input: {
        main: "index.html",
        hud: "hud.html",
        settings: "settings.html",
        panel: "panel.html",
      },
    },
  },
});
