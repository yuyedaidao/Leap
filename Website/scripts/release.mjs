export function validateRelease(release, { production = false, siteURL, icpNumber } = {}) {
  const errors = [];
  if (!/^\d+\.\d+\.\d+$/.test(release.version ?? '')) errors.push('version 必须是三段数字版本');
  if (release.minimumMacOS !== '26.0' || release.architecture !== 'arm64') errors.push('支持范围必须为 macOS 26.0 / arm64');
  const hasDownload = release.downloadURL != null;
  function https(value) {
    try {
      const url = new URL(value);
      return url.protocol === 'https:' && !url.username && !url.password &&
        url.hostname.includes('.') && !/^(localhost|127\.|0\.|\[|.*\.local$|.*\.invalid$|example\.)/.test(url.hostname);
    } catch { return false; }
  }
  if (hasDownload || production) {
    if (!https(release.downloadURL)) errors.push('downloadURL 必须是有效的公开 HTTPS 地址');
    if (!Number.isSafeInteger(release.sizeBytes) || release.sizeBytes <= 0) errors.push('sizeBytes 必须是正整数');
    if (!/^[a-f0-9]{64}$/.test(release.sha256 ?? '')) errors.push('sha256 必须是 64 位小写十六进制');
  } else if (release.sizeBytes != null || release.sha256 != null) errors.push('未开放下载时大小和哈希也应为空');
  if (production) {
    if (!https(siteURL) || new URL(siteURL).pathname !== '/' || new URL(siteURL).search || new URL(siteURL).hash) errors.push('SITE_URL 必须是正式 HTTPS 站点根地址');
    if (!/^[\u4e00-\u9fff]ICP备\d{8,}号(?:-\d+)?$/.test(icpNumber ?? '')) errors.push('ICP_NUMBER 必须填写已取得的备案号');
  }
  if (errors.length) throw new Error('发行配置未就绪：\n' + errors.join('\n'));
  return release;
}
