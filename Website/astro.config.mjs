import { defineConfig } from 'astro/config';
import { validateRelease } from './scripts/release.mjs';
import release from './release.json' with { type: 'json' };
validateRelease(release);
export default defineConfig({ site: process.env.SITE_URL || undefined, output: 'static', trailingSlash: 'always' });
