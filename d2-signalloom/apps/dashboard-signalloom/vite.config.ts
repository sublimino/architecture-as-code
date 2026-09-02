import { defineConfig } from 'vite'
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
  build: { outDir: 'dist', sourcemap: false },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test-setup.ts'],
  },
})
