import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Local development can proxy /api to a deployed v3 CloudFront distribution.
// No customer or demonstration endpoint is embedded in the source.
const API_TARGET = process.env.VITE_API_TARGET;

export default defineConfig({
  plugins: [react()],
  server: API_TARGET
    ? {
        proxy: {
          "/api": {
            target: API_TARGET,
            changeOrigin: true,
            secure: true,
          },
        },
      }
    : undefined,
});
