<script setup lang="ts">
import { GITHUB } from '~/composables/site'
import en from '~~/data/release-notes/en.json'
import ru from '~~/data/release-notes/ru.json'
import tk from '~~/data/release-notes/tk.json'

type Note = string | { text: string, beta?: boolean }
interface Entry { version: string, notes: Note[] }

const { locale, t } = useI18n()
const { info, date } = useRelease()
const entries = ({ en, ru, tk } as Record<string, Entry[]>)[locale.value] ?? en

useSiteHead({
  page: 'release-notes',
  title: t('meta.releaseNotesTitle'),
  description: t('release.lead'),
})
</script>

<template>
  <SiteHeader page="release-notes" />
  <main id="main" class="wrap page">
    <h1>{{ t('release.title') }}</h1>
    <p class="section-lead">{{ t('release.lead') }}</p>
    <article v-for="entry in entries" :key="entry.version" class="release" :aria-labelledby="`v-${entry.version}`">
      <h2 :id="`v-${entry.version}`">{{ t('release.heading', { version: entry.version }) }}</h2>
      <p v-if="entry.version === info.version && date" class="release-date">{{ t('release.date', { date }) }}</p>
      <ul class="release-notes">
        <li v-for="(note, i) in entry.notes" :key="i">
          <template v-if="typeof note === 'string'">{{ note }}</template>
          <template v-else><BetaLabel v-if="note.beta" /> {{ note.text }}</template>
        </li>
      </ul>
      <template v-if="entry.version === info.version">
        <div class="release-download">
          <DownloadButton />
          <VersionLine />
          <p class="release-github"><a :href="GITHUB.release" rel="noopener">{{ t('release.github') }}</a></p>
        </div>
        <div v-if="info.sha256" class="checksum">
          <h3>{{ t('release.sha') }}</h3>
          <p><code class="hash">{{ info.sha256 }}</code></p>
          <p>{{ t('release.shaHelp') }}</p>
          <p><code>shasum -a 256 ~/Downloads/{{ info.file }}</code></p>
        </div>
      </template>
    </article>
    <p class="back"><a :href="`/${locale}/`">{{ t('release.back') }}</a></p>
  </main>
  <SiteFooter page="release-notes" />
</template>
