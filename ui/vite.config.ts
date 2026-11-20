/// <reference types="vitest/config" />
import { fileURLToPath, URL } from 'node:url'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// The server the development proxy forwards the API and classic pages to.
const target = process.env.UNPUB_DEV_SERVER ?? 'http://localhost:4000'
const proxied = [
  '/webapi',
  '/api',
  '/badge',
  '/static',
  '/classic',
  '/healthz',
  '/readyz',
  '/metrics',
]

export default defineConfig({
  // Relative, so that one build is served at / and under /app: the server
  // rewrites the references of index.html under its base path.
  base: './',
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
      // See src/lib/style-singleton.ts: no <style> elements under the CSP.
      'react-style-singleton': fileURLToPath(
        new URL('./src/lib/style-singleton.ts', import.meta.url),
      ),
    },
  },
  build: {
    // Keep every asset a file: inline data: URLs are fine for the policy,
    // but files are cached for good and keep the shell small.
    assetsInlineLimit: 0,
    sourcemap: true,
  },
  server: {
    port: 5173,
    proxy: {
      ...Object.fromEntries(proxied.map((path) => [path, { target, changeOrigin: false }])),
      // Archives: /packages/<name>/versions/<version>.tar.gz. Other
      // /packages paths are routes of the client.
      '^/packages/[^/]+/versions/[^/]+\\.tar\\.gz$': { target, changeOrigin: false },
    },
  },
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'],
    css: false,
  },
})
