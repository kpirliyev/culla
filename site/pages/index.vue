<script setup lang="ts">
import { GITHUB, SITE_URL, pagePath } from '~/composables/site'
import { useFaqJsonLd } from '~/composables/faq'

const { locale, t } = useI18n()
const { info } = useRelease()

const app = {
  '@context': 'https://schema.org',
  '@type': 'SoftwareApplication',
  name: 'Culla',
  description: t('meta.description'),
  url: SITE_URL + pagePath(locale.value),
  applicationCategory: 'PhotographyApplication',
  operatingSystem: 'macOS 26',
  softwareVersion: info.version,
  downloadUrl: `${SITE_URL}/download`,
  ...(info.size > 0 ? { fileSize: `${Math.round(info.size / 1_000_000)} MB` } : {}),
  image: `${SITE_URL}/icon-512.png`,
  inLanguage: ['en', 'ru', 'tk'],
  isAccessibleForFree: true,
  license: GITHUB.license,
  isBasedOn: {
    '@type': 'SoftwareSourceCode',
    codeRepository: GITHUB.repo,
    license: GITHUB.license,
    programmingLanguage: 'Swift',
  },
  offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
  author: { '@type': 'Person', name: 'Kerim Pirliyev' },
}

useSiteHead({
  page: '',
  title: t('meta.title'),
  description: t('meta.description'),
  script: true,
  jsonLd: [app, useFaqJsonLd()],
})
</script>

<template>
  <SiteHeader />
  <main id="main">
    <HeroSection />
    <ProofStrip />
    <HowItWorks />
    <VisionSection />
    <KeyboardSection />
    <SafeSection />
    <CatchSection />
    <NotFinishedSection />
    <QuestionsSection />
    <ClosingSection />
  </main>
  <SiteFooter />
</template>
