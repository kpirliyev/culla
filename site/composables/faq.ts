export const FAQ_KEYS = ['systems', 'internet', 'changes', 'rejects', 'free', 'open', 'counting', 'report'] as const

/** The Questions as FAQPage structured data, in plain text: the link texts stand in for the links. */
export function useFaqJsonLd() {
  const { t } = useI18n()
  const params = {
    folder: '_Rejected',
    github: 'GitHub',
    fix: t('faq.open.fix'),
    bug: t('faq.report.bug'),
    feature: t('faq.report.feature'),
    question: t('faq.report.question'),
  }
  return {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: FAQ_KEYS.map((key) => ({
      '@type': 'Question',
      name: t(`faq.${key}.q`),
      acceptedAnswer: { '@type': 'Answer', text: t(`faq.${key}.a`, params) },
    })),
  }
}
