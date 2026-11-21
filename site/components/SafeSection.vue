<script setup lang="ts">
const { t } = useI18n()
</script>

<template>
  <section class="section wrap" aria-labelledby="safe-title">
    <h2 id="safe-title">{{ t('safe.title') }}</h2>
    <ul class="points">
      <li class="point">{{ t('safe.nothingMoves') }}</li>
      <li class="point">
        <i18n-t keypath="safe.rejects" scope="global" tag="span">
          <template #folder><code>_Rejected</code></template>
        </i18n-t>
      </li>
      <li class="point">{{ t('safe.undo') }}</li>
    </ul>
    <p class="sidecar"><BetaLabel /> {{ t('safe.sidecar') }}</p>
  </section>
</template>
