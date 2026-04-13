import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  build: {
    rollupOptions: {
      output: {
        entryFileNames: `assets/ironlab-[hash].js`,
        chunkFileNames: `assets/ironlab-chunk-[hash].js`,
        assetFileNames: `assets/ironlab-[hash].[ext]`,
      }
    }
  }
})
