<script setup lang="ts">
// The page's one moving part. This markup is the complete still picture shown
// without JavaScript; public/js/culla.js makes it work. Every string the script
// shows or announces is passed here as a data attribute.
const { t } = useI18n()
const PICK = 2
const frames = [1, 2, 3, 4, 5]
const keys = [
  { key: 'p', cap: 'P', word: 'keyKeep', label: 'keyKeepLabel' },
  { key: 'x', cap: 'X', word: 'keyReject', label: 'keyRejectLabel' },
  { key: 'ArrowLeft', cap: '←', word: 'keyPrev', label: 'keyPrevLabel' },
  { key: 'ArrowRight', cap: '→', word: 'keyNext', label: 'keyNextLabel' },
  { key: 'Enter', cap: 'Return', word: 'keyAccept', label: 'keyAcceptLabel' },
] as const
</script>

<template>
  <div
    class="demo"
    data-demo
    :data-pick="PICK"
    :data-l-current="t('demo.current', { n: '{n}', total: '{total}' })"
    :data-l-current-pick="t('demo.currentPick', { n: '{n}', total: '{total}' })"
    :data-l-kept="t('demo.kept', { n: '{n}' })"
    :data-l-rejected="t('demo.rejected', { n: '{n}' })"
    :data-l-done="t('demo.done')"
    :data-l-reset="t('demo.reset')"
  >
    <div class="demo-stage" role="group" :aria-label="t('demo.label')">
      <ol class="demo-frames">
        <li
          v-for="n in frames"
          :key="n"
          class="demo-frame"
          :class="{ 'is-pick': n === PICK }"
          :data-frame="n"
        >
          <img :src="`/demo/frame-${n}.svg`" width="120" height="160" :alt="t(`demo.frame${n}`)">
          <span v-if="n === PICK" class="pick-badge"><span aria-hidden="true">★ </span>{{ t('demo.pick') }}</span>
          <span class="demo-mark demo-mark-keep" aria-hidden="true">
            <svg viewBox="0 0 16 16" focusable="false"><path d="M3.5 8.5l3 3 6-7" /></svg>
          </span>
          <span class="demo-mark demo-mark-reject" aria-hidden="true">
            <svg viewBox="0 0 16 16" focusable="false"><path d="M4 4l8 8M12 4l-8 8" /></svg>
          </span>
        </li>
      </ol>
      <p class="demo-status" aria-hidden="true" data-demo-status />
    </div>
    <div class="demo-keys" role="group" :aria-label="t('demo.keysLabel')">
      <button
        v-for="k in keys"
        :key="k.key"
        type="button"
        class="cap"
        :class="{ 'cap-wide': k.key === 'Enter' }"
        :data-key="k.key"
        :aria-label="t(`demo.${k.label}`)"
        disabled
      >
        <kbd>{{ k.cap }}</kbd><span class="cap-word">{{ t(`demo.${k.word}`) }}</span>
      </button>
    </div>
    <p class="demo-hint" data-demo-hint hidden>
      <span class="hint-keys">{{ t('demo.hintKeys') }}</span>
      <span class="hint-touch">{{ t('demo.hintTouch') }}</span>
    </p>
    <button type="button" class="btn btn-secondary demo-again" data-demo-again hidden>{{ t('demo.again') }}</button>
    <p class="visually-hidden" aria-live="polite" data-demo-live />
  </div>
</template>
