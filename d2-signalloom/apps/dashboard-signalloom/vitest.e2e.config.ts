// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors
//
// SLCD-P5-GOV end-to-end config.
//
// The e2e suite is deliberately NOT part of the default `vitest run`: it
// spawns a Go server and needs a live socket, so running it by accident in an
// environment without a Go toolchain would report an infrastructure problem as
// a product failure. vite.config.ts excludes `*.e2e.test.tsx`; this config is
// the only thing that includes it, and scripts/slcd-p5-e2e.sh is the only
// supported way to invoke it (it sets the env the api client reads at import).

import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test-setup.ts'],
    include: ['src/**/*.e2e.test.tsx'],
    // One file, one process: the suite owns a fixed listening port and a
    // shared in-memory store, so parallel forks would fight over both.
    fileParallelism: false,
    testTimeout: 180_000,
    hookTimeout: 180_000,
  },
})
