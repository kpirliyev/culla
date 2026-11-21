<script setup lang="ts">
// One screenshot slot. Shows public/shots/<name>.<lang>.png when it exists
// (or the English one when the language has none yet), otherwise a drawn grey
// placeholder of the same proportions with a short label.
type ShotName = 'hero-stack-review' | 'how-1-open' | 'how-2-groups' | 'how-3-decide' | 'vision-evidence'

const props = withDefaults(defineProps<{
  name: ShotName
  /** The largest size the slot is shown at, in CSS pixels. Fixes the aspect
   *  ratio; images are made at this size and twice it (1x and 2x). */
  width: number
  height: number
  eager?: boolean
}>(), { eager: false })

const { locale, t } = useI18n()
const shots = useRuntimeConfig().public.shots as string[]

const src = computed(() => {
  for (const code of [locale.value, 'en']) {
    const file = `${props.name}.${code}.png`
    if (shots.includes(file)) return `/shots/${file}`
  }
  return null
})
</script>

<template>
  <div class="shot" :class="`shot-${props.name}`">
    <NuxtPicture
      v-if="src"
      :src="src"
      :width="props.width"
      :height="props.height"
      :sizes="`${props.width}px`"
      :alt="t(`shots.${props.name}.alt`)"
      :loading="props.eager ? 'eager' : 'lazy'"
      :img-attrs="props.eager ? { fetchpriority: 'high', decoding: 'async' } : { decoding: 'async' }"
      class="shot-picture"
    />
    <div
      v-else
      class="shot-placeholder"
      role="img"
      :aria-label="`${t(`shots.${props.name}.label`)}. ${t('shots.placeholder')}.`"
    >
      <div class="ph-window" aria-hidden="true">
        <div class="ph-bar"><i /><i /><i /></div>
        <div class="ph-body">
          <template v-if="props.name === 'hero-stack-review' || props.name === 'how-3-decide'">
            <div class="ph-pair">
              <div class="ph-frame" />
              <div class="ph-frame ph-frame-pick"><b>★</b></div>
            </div>
            <div class="ph-strip"><i v-for="n in 7" :key="n" :class="{ on: n === 3 }" /></div>
          </template>
          <template v-else-if="props.name === 'how-2-groups'">
            <div class="ph-side ph-side-wide"><i v-for="n in 6" :key="n" :class="{ on: n === 2 }" /></div>
            <div class="ph-grid ph-grid-small"><i v-for="n in 6" :key="n" /></div>
          </template>
          <template v-else-if="props.name === 'vision-evidence'">
            <div class="ph-photo">
              <span class="ph-face ph-face-1"><em>{{ t('vision.eyesOpen') }}</em></span>
              <span class="ph-face ph-face-2 closed"><em>{{ t('vision.eyesClosed') }}</em></span>
              <span class="ph-face ph-face-3"><em>{{ t('vision.eyesOpen') }}</em></span>
              <span class="ph-soft"><em>{{ t('vision.soft') }}</em></span>
            </div>
          </template>
          <template v-else>
            <div class="ph-side"><i v-for="n in 5" :key="n" /></div>
            <div class="ph-grid"><i v-for="n in 12" :key="n" /></div>
          </template>
        </div>
      </div>
      <p class="ph-label">
        <span>{{ t(`shots.${props.name}.label`) }}</span>
        <span class="ph-soon">{{ t('shots.placeholder') }}</span>
      </p>
    </div>
  </div>
</template>
