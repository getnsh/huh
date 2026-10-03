import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// Two entry points, because the overlay is its own window and has to exist from
// launch. Key-down to visible is budgeted at 50 ms, and building a WebView
// takes longer than that on any machine.
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
      },
    },
  },
});
