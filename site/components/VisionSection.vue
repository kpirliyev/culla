<script setup lang="ts">
const { t } = useI18n()
const rows = ['eyes', 'blur', 'alike', 'smudge'] as const
</script>

<template>
  <section class="section wrap" aria-labelledby="vision-title">
    <h2 id="vision-title">{{ t('vision.title') }}</h2>
    <p class="section-lead">{{ t('vision.lead') }}</p>
    <div class="vision">
      <figure class="vision-figure">
        <ShotSlot name="vision-evidence" :width="600" :height="400" />
        <figcaption>{{ t('vision.caption') }}</figcaption>
      </figure>
      <table class="how-table">
        <thead>
          <tr><th scope="col">{{ t('vision.what') }}</th><th scope="col">{{ t('vision.how') }}</th></tr>
        </thead>
        <tbody>
          <tr v-for="row in rows" :key="row">
            <th scope="row">{{ t(`vision.${row}`) }}</th>
            <td>{{ t(`vision.${row}How`) }}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <div class="closing-lines">
      <p>{{ t('vision.closing1') }}</p>
      <p>{{ t('vision.closing2') }}</p>
    </div>
  </section>
</template>
