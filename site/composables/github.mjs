// Every GitHub address the site uses, built from release.json's `repository`.
// Plain JavaScript so that both the Nuxt pages (through site.ts) and
// scripts/preview.mjs can use it; no other file types a GitHub address.

/**
 * @param {{ repository: string, version: string, file: string }} release
 */
export function githubLinks(release) {
  const repo = `https://github.com/${release.repository}`
  return {
    repo,
    /** The release page for the version in release.json. */
    release: `${repo}/releases/tag/v${release.version}`,
    /** The disk image itself, where nginx sends /download. */
    asset: `${repo}/releases/download/v${release.version}/${release.file}`,
    bug: `${repo}/issues/new?template=bug_report.yml`,
    feature: `${repo}/issues/new?template=feature_request.yml`,
    choose: `${repo}/issues/new/choose`,
    discussions: `${repo}/discussions`,
    contributing: `${repo}/blob/main/CONTRIBUTING.md`,
    license: `${repo}/blob/main/LICENSE`,
  }
}
