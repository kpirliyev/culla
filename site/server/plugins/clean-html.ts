// The generated pages carry no Nuxt runtime. Two things Nuxt still adds are
// removed here:
// - the inline speculation-rules script, which the site's Content-Security-Policy
//   (script-src 'self') would block and report on every page;
// - the comment markers Vue leaves for hydration, which never happens here;
// - the inline onerror handler and data-nuxt-pic marker that @nuxt/image puts on
//   every <img> for its client runtime (the CSP would block the handler too).
export default defineNitroPlugin((nitroApp) => {
  nitroApp.hooks.hook('render:html', (html) => {
    const clean = (chunk: string) => chunk
      .replace(/<script type="speculationrules">[\s\S]*?<\/script>/g, '')
      .replace(/<!--\[-->|<!--]-->|<!---->/g, '')
      .replace(/ onerror="[^"]*"/g, '')
      .replace(/ data-nuxt-(?:img|pic)(?:="[^"]*")?/g, '')
    html.head = html.head.map(clean)
    html.body = html.body.map(clean)
    html.bodyAppend = html.bodyAppend.map(clean)
    html.bodyPrepend = html.bodyPrepend.map(clean)
  })
})
