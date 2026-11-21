import release from '~~/release.json'
import { githubLinks } from './github.mjs'

export const SITE_URL = 'https://cullaapp.com'
/** The year in the footer's copyright line. */
export const COPYRIGHT_YEAR = 2026
export const LOCALES = [
  { code: 'en', name: 'English', og: 'en_US' },
  { code: 'ru', name: 'Русский', og: 'ru_RU' },
  { code: 'tk', name: 'Türkmençe', og: 'tk_TM' },
] as const

export type SitePage = '' | 'release-notes'

/** Every address on the site ends in a slash, as nginx serves them. */
export function pagePath(locale: string, page: SitePage = ''): string {
  return `/${locale}/${page ? `${page}/` : ''}`
}

export interface ReleaseInfo {
  repository: string
  version: string
  file: string
  size: number
  sha256: string
  date: string
}

/** The repository, the release, the issue forms, Discussions and the files on GitHub. */
export const GITHUB = githubLinks(release as ReleaseInfo)

export function useRelease() {
  const { locale } = useI18n()
  const info = release as ReleaseInfo
  /** The size in megabytes for the version line, or null while release.json has none. */
  const sizeMB = computed(() => {
    if (!info.size || info.size <= 0) return null
    const mb = info.size / 1_000_000
    return new Intl.NumberFormat(locale.value, { maximumFractionDigits: mb < 10 ? 1 : 0 }).format(mb)
  })
  const date = computed(() => {
    if (!info.date) return null
    const parsed = new Date(`${info.date}T12:00:00Z`)
    if (Number.isNaN(parsed.getTime())) return null
    return new Intl.DateTimeFormat(locale.value, { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' }).format(parsed)
  })
  return { info, sizeMB, date }
}

interface HeadOptions {
  page: SitePage
  title: string
  description: string
  /** Load the page's one script (keyboard demo and copy link). */
  script?: boolean
  jsonLd?: object[]
  noindex?: boolean
}

/** Title, description, canonical, hreflang, Open Graph and structured data for one page. */
export function useSiteHead(options: HeadOptions) {
  const { locale, t } = useI18n()
  const code = locale.value
  const url = SITE_URL + pagePath(code, options.page)
  const og = LOCALES.find((l) => l.code === code)?.og ?? 'en_US'
  useHead({
    htmlAttrs: { lang: code },
    title: options.title,
    link: [
      { rel: 'canonical', href: url },
      ...LOCALES.map((l) => ({ rel: 'alternate', hreflang: l.code, href: SITE_URL + pagePath(l.code, options.page) })),
      { rel: 'alternate', hreflang: 'x-default', href: SITE_URL + pagePath('en', options.page) },
    ],
    meta: [
      { name: 'description', content: options.description },
      ...(options.noindex ? [{ name: 'robots', content: 'noindex' }] : []),
      { property: 'og:type', content: 'website' },
      { property: 'og:site_name', content: 'Culla' },
      { property: 'og:title', content: options.title },
      { property: 'og:description', content: options.description },
      { property: 'og:url', content: url },
      { property: 'og:locale', content: og },
      ...LOCALES.filter((l) => l.code !== code).map((l) => ({ property: 'og:locale:alternate', content: l.og })),
      { property: 'og:image', content: `${SITE_URL}/og-image.png` },
      { property: 'og:image:width', content: '1200' },
      { property: 'og:image:height', content: '630' },
      { property: 'og:image:alt', content: t('meta.ogAlt') },
      { name: 'twitter:card', content: 'summary_large_image' },
    ],
    script: [
      ...(options.script ? [{ src: '/js/culla.js', defer: true }] : []),
      ...(options.jsonLd ?? []).map((data) => ({ type: 'application/ld+json', innerHTML: JSON.stringify(data) })),
    ],
  })
}
