import { resolve } from 'path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Standalone web build — no Electron, outputs to dist-web/
// Usage:
//   npm run build:web          → dist-web/ (embed into Mac app bundle)
//   npm run dev:web            → http://localhost:5174 (dev server)
export default defineConfig({
  root: resolve(__dirname, 'src/renderer'),
  plugins: [react()],
  resolve: {
    alias: { '@': resolve(__dirname, 'src/renderer/src') }
  },
  build: {
    outDir: resolve(__dirname, 'dist-web'),
    emptyOutDir: true,
  },
  server: {
    port: 5174,
    host: true,
  }
})
