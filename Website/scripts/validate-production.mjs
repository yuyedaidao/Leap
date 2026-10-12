import release from '../release.json' with { type: 'json' };
import { validateRelease } from './release.mjs';
try {
  validateRelease(release, { production: true, siteURL: process.env.SITE_URL, icpNumber: process.env.ICP_NUMBER });
  console.log('正式发行配置校验通过。');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
