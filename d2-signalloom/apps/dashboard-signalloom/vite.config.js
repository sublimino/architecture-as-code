import { defineConfig } from "vite";

export default defineConfig({
  base: "/",
  esbuild: {
    jsx: "transform",
    jsxFactory: "React.createElement",
    jsxFragment: "React.Fragment",
  },
  optimizeDeps: {
    esbuildOptions: {
      jsx: "transform",
      jsxFactory: "React.createElement",
      jsxFragment: "React.Fragment",
      loader: {
        ".jsx": "jsx",
      },
    },
  },
  build: {
    outDir: "dist",
  },
});
