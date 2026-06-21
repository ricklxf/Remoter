import { resolve } from 'path'
import { createRequire } from 'module'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const { version } = createRequire(import.meta.url)('./package.json') as { version: string }

// Standalone web build — no Electron, outputs to dist-web/
// Usage:
//   npm run build:web          → dist-web/ (embed into Mac app bundle)
//   npm run dev:web            → http://localhost:5174 (dev server)
export default defineConfig({
  root: resolve(__dirname, 'src/renderer'),
  plugins: [react()],
  define: { __APP_VERSION__: JSON.stringify(version) },
  resolve: {
    alias: { '@': resolve(__dirname, 'src/renderer/src') }
  },
  // Strip ALL console output + debugger from the production bundle so internal
  // state (server OS, e2e status, URLs, input coords…) isn't dumped to the
  // browser console. User-facing errors surface via the app's error-state UI,
  // not console.error, so dropping console wholesale is safe here.
  // (esbuild `pure` can't remove logs in event-handler bodies or side-effecting
  //  conditions, so `drop` is the only reliable option.)
  esbuild: {
    drop: ['console', 'debugger'],
  },
  build: {
    // Output directly into the relay server's public directory so a single
    // `build:all` produces one deployable artifact.
    outDir: resolve(__dirname, '../Remoter-Server/public'),
    emptyOutDir: true,
  },
  server: {
    port: 5174,
    host: true,
  }
})
