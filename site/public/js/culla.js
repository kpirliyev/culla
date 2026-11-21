// Culla's site: the one script. It adds two things to a page that works
// without it: the keyboard demo and the "Copy link for your Mac" button.
// No framework, no network requests, nothing stored.
(function () {
  'use strict'

  function fill(template, values) {
    return template.replace(/\{(\w+)\}/g, function (match, name) {
      return Object.prototype.hasOwnProperty.call(values, name) ? String(values[name]) : match
    })
  }

  // ---------- Copy link ----------

  function setupCopy(link) {
    var label = link.querySelector('.hero-copy-text')
    var original = label ? label.textContent : ''
    var live = document.createElement('span')
    live.className = 'visually-hidden'
    live.setAttribute('aria-live', 'polite')
    link.parentNode.appendChild(live)
    var timer = 0

    function show(text, say, ok) {
      if (label) label.textContent = text
      link.classList.toggle('is-copied', ok)
      live.textContent = say
      clearTimeout(timer)
      timer = setTimeout(function () {
        if (label) label.textContent = original
        link.classList.remove('is-copied')
        live.textContent = ''
      }, 4000)
    }

    function copyWithSelection(text) {
      var field = document.createElement('textarea')
      field.value = text
      field.setAttribute('readonly', '')
      field.className = 'trap'
      document.body.appendChild(field)
      field.select()
      var ok = false
      try { ok = document.execCommand('copy') } catch (e) { ok = false }
      document.body.removeChild(field)
      return ok
    }

    link.setAttribute('role', 'button')
    link.addEventListener('click', function (event) {
      event.preventDefault()
      var text = link.getAttribute('data-copy')
      var done = function () { show(link.getAttribute('data-copied'), link.getAttribute('data-copied-say'), true) }
      var failed = function () {
        if (copyWithSelection(text)) done()
        else show(link.getAttribute('data-failed'), link.getAttribute('data-failed'), false)
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, failed)
      } else {
        failed()
      }
    })
    link.addEventListener('keydown', function (event) {
      if (event.key === ' ') { event.preventDefault(); link.click() }
    })
  }

  // ---------- Keyboard demo ----------

  function setupDemo(root) {
    var stage = root.querySelector('.demo-stage')
    var frames = Array.prototype.slice.call(root.querySelectorAll('.demo-frame'))
    var caps = Array.prototype.slice.call(root.querySelectorAll('.cap'))
    var hint = root.querySelector('[data-demo-hint]')
    var again = root.querySelector('[data-demo-again]')
    var live = root.querySelector('[data-demo-live]')
    var status = root.querySelector('[data-demo-status]')
    var pick = Number(root.getAttribute('data-pick')) - 1
    var text = {
      current: root.getAttribute('data-l-current'),
      currentPick: root.getAttribute('data-l-current-pick'),
      kept: root.getAttribute('data-l-kept'),
      rejected: root.getAttribute('data-l-rejected'),
      done: root.getAttribute('data-l-done'),
      reset: root.getAttribute('data-l-reset')
    }
    var total = frames.length
    var current = 0
    var state = []
    var finished = false
    var hovered = false

    function say(message) {
      // Clear first so the same sentence twice is still read out.
      live.textContent = ''
      setTimeout(function () { live.textContent = message }, 30)
    }

    function where() {
      var template = current === pick ? text.currentPick : text.current
      return fill(template, { n: current + 1, total: total })
    }

    function render() {
      frames.forEach(function (frame, i) {
        frame.classList.toggle('is-current', i === current && !finished)
        frame.classList.toggle('is-kept', state[i] === 'keep')
        frame.classList.toggle('is-rejected', state[i] === 'reject')
      })
      status.textContent = finished ? text.done : where()
      again.hidden = !finished
    }

    function reset(announce) {
      current = 0
      state = frames.map(function () { return null })
      finished = false
      render()
      if (announce) say(text.reset + ' ' + where())
    }

    function press(key) {
      var cap = caps.filter(function (c) { return c.getAttribute('data-key') === key })[0]
      if (cap) {
        cap.classList.add('is-pressed')
        setTimeout(function () { cap.classList.remove('is-pressed') }, 160)
      }
      if (finished) return
      var n = current + 1
      if (key === 'ArrowLeft') {
        current = Math.max(0, current - 1)
        render(); say(where())
      } else if (key === 'ArrowRight') {
        current = Math.min(total - 1, current + 1)
        render(); say(where())
      } else if (key === 'p') {
        state[current] = 'keep'
        if (current < total - 1) current += 1
        render(); say(fill(text.kept, { n: n }) + ' ' + where())
      } else if (key === 'x') {
        state[current] = 'reject'
        if (current < total - 1) current += 1
        render(); say(fill(text.rejected, { n: n }) + ' ' + where())
      } else if (key === 'Enter') {
        // As in the app: keep the frames marked with P, or the pick when none
        // is marked, and reject the rest.
        var anyKept = state.some(function (s) { return s === 'keep' })
        state = state.map(function (s, i) {
          if (s === 'keep') return 'keep'
          if (!anyKept && i === pick) return 'keep'
          return 'reject'
        })
        finished = true
        render(); say(text.done)
      }
    }

    function keyFor(event) {
      if (event.metaKey || event.ctrlKey || event.altKey) return null
      if (event.key === 'ArrowLeft' || event.key === 'ArrowRight' || event.key === 'Enter') return event.key
      // By position as well, so P and X work on a Russian or Turkmen layout.
      if (event.code === 'KeyP' || event.key === 'p' || event.key === 'P') return 'p'
      if (event.code === 'KeyX' || event.key === 'x' || event.key === 'X') return 'x'
      return null
    }

    function isTyping(element) {
      if (!element) return false
      var tag = element.tagName
      return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || element.isContentEditable
    }

    // Keys act only while the demo has focus or the pointer is over it, so the
    // rest of the page scrolls and tabs as usual.
    document.addEventListener('keydown', function (event) {
      var active = document.activeElement
      var focused = root.contains(active)
      if (!focused && !hovered) return
      if (!focused && isTyping(active)) return
      var key = keyFor(event)
      if (!key) return
      // Return or Space on a focused button already presses that button.
      if (key === 'Enter' && active && active.tagName === 'BUTTON' && root.contains(active)) return
      event.preventDefault()
      press(key)
    })

    root.addEventListener('mouseenter', function () { hovered = true })
    root.addEventListener('mouseleave', function () { hovered = false })

    caps.forEach(function (cap) {
      cap.disabled = false
      cap.addEventListener('click', function () { press(cap.getAttribute('data-key')) })
    })
    again.addEventListener('click', function () {
      reset(true)
      stage.focus()
    })

    stage.tabIndex = 0
    hint.hidden = false
    root.classList.add('is-live')
    reset(false)
  }

  function start() {
    var copy = document.querySelector('.hero-copy[data-copy]')
    if (copy) setupCopy(copy)
    var demo = document.querySelector('[data-demo]')
    if (demo) setupDemo(demo)
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start)
  else start()
})()
