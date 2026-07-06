import { defineConfig } from "vite";

export default defineConfig({
  base: "./",
  build: {
    outDir: "../target/book/web",
    emptyOutDir: true,
  },
});
