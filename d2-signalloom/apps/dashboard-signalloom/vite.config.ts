import { defineConfig } from 'vite'
import { configDefaults } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      '/api': 'http://127.0.0.1:5173',
      '/dex': 'http://127.0.0.1:5173',
      '/fleet-api': 'http://127.0.0.1:5173',
      '/afm': 'http://127.0.0.1:5173',
    },
  },
  build: {
    outDir: 'dist',
    sourcemap: false,
    rollupOptions: {
      output: {
        manualChunks: {
          'vendor-react': ['react', 'react-dom', 'react-router-dom'],
          'vendor-auth': ['oidc-client-ts', 'react-oidc-context'],
        },
      },
    },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test-setup.ts'],
    // SLCD-P5-GOV: the end-to-end suite spawns a real Go server and binds a
    // real socket, so it cannot run in the default unit lane. It is included
    // only by vitest.e2e.config.ts, via scripts/slcd-p5-e2e.sh.
    exclude: [...configDefaults.exclude, '**/*.e2e.test.tsx'],
  },
})
