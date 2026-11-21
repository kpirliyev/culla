<script setup lang="ts">
const { t } = useI18n()
</script>

<template>
  <section class="closing wrap" aria-labelledby="closing-title">
    <h2 id="closing-title">{{ t('closing.title') }}</h2>
    <DownloadButton />
    <VersionLine />
  </section>
</template>
