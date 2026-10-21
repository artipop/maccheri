/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import { mockControlPlane } from './dev/mock-control-plane.ts'

// `npm run dev`: the client with an in-memory control plane (dev/mock-control-plane.ts).
// `VITE_API=http://localhost:8080 npm run dev`: the client against a real control plane, proxied
// so it still looks same-origin, as in production.
const api = process.env.VITE_API

export default defineConfig({
  plugins: [mockControlPlane()],
  // Relative asset URLs: the bundle works from any path, and inside a webview later.
  base: './',
  server: {
    host: true,
    proxy: api ? { '/v1': { target: api, ws: true, changeOrigin: true }, '/agent': { target: api, changeOrigin: true } } : undefined,
  },
  build: { target: 'es2022', outDir: 'dist', emptyOutDir: true },
  test: { environment: 'node' },
})
