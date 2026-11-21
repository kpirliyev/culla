<script setup lang="ts">
import { COPYRIGHT_YEAR, GITHUB, pagePath, type SitePage } from '~/composables/site'

const props = withDefaults(defineProps<{ page?: SitePage }>(), { page: '' })
const { locale, t } = useI18n()
</script>

<template>
  <footer class="footer">
    <div class="wrap footer-inner">
      <ul class="footer-links">
        <li><a :href="pagePath(locale, 'release-notes')">{{ t('footer.releaseNotes') }}</a></li>
        <li><a :href="GITHUB.repo" rel="noopener">{{ t('footer.source') }}</a></li>
        <li><a :href="GITHUB.choose" rel="noopener">{{ t('footer.report') }}</a></li>
      </ul>
      <LangSwitch :page="props.page" />
      <p class="copyright">{{ t('footer.copyright', { year: COPYRIGHT_YEAR }) }}</p>
    </div>
  </footer>
</template>
