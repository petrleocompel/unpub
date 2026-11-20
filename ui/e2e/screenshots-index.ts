// The index.html written next to the screenshots: one section per screen,
// the four variants side by side, filters by theme and width in plain CSS.

export type Shot = {
  screen: string
  title: string
  file: string
  width: 1440 | 390
  theme: 'light' | 'dark'
}

const escape = (text: string) =>
  text.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!)

const css = `
:root { color-scheme: light dark; font: 14px/1.5 system-ui, sans-serif; }
body { margin: 0; background: Canvas; color: CanvasText; }
header { position: sticky; top: 0; z-index: 1; display: flex; flex-wrap: wrap; gap: 8px 24px;
  align-items: center; padding: 12px 24px; background: Canvas; border-bottom: 1px solid #8884; }
h1 { font-size: 16px; margin: 0 16px 0 0; }
fieldset { border: 0; margin: 0; padding: 0; display: flex; gap: 12px; align-items: center; }
legend { float: left; margin-right: 8px; font-weight: 600; }
main { padding: 8px 24px 48px; }
section { padding: 16px 0; border-bottom: 1px solid #8884; }
h2 { font-size: 15px; margin: 0 0 10px; }
h2 code { font-weight: 400; opacity: .7; margin-left: 8px; }
.row { display: flex; flex-wrap: wrap; gap: 16px; align-items: flex-start; }
figure { margin: 0; }
figcaption { font-size: 12px; opacity: .75; margin-bottom: 4px; }
figure a { display: block; overflow: hidden; max-height: 760px; border: 1px solid #8886;
  border-radius: 6px; }
figure img { display: block; }
figure[data-width="1440"] img { width: 340px; }
figure[data-width="390"] img { width: 300px; }
body:has(#theme-light:checked) figure[data-theme="dark"],
body:has(#theme-dark:checked) figure[data-theme="light"],
body:has(#width-1440:checked) figure[data-width="390"],
body:has(#width-390:checked) figure[data-width="1440"] { display: none; }
body:has(#width-390:checked) figure[data-width="390"] img { width: 390px; }
body:has(#width-1440:checked) figure[data-width="1440"] img { width: 680px; }
`

function radios(name: string, legend: string, values: string[]) {
  return `<fieldset><legend>${legend}</legend>${values
    .map(
      (value, i) =>
        `<label><input type="radio" name="${name}" id="${name}-${value}"${i === 0 ? ' checked' : ''}> ${value}</label>`,
    )
    .join('')}</fieldset>`
}

export function indexHtml(shots: Shot[]) {
  const screens = [...new Set(shots.map((shot) => shot.screen))]
  const sections = screens.map((screen) => {
    const ofScreen = shots.filter((shot) => shot.screen === screen)
    const figures = ofScreen
      .map(
        (shot) =>
          `<figure data-width="${shot.width}" data-theme="${shot.theme}">` +
          `<figcaption>${shot.width} px · ${shot.theme}</figcaption>` +
          `<a href="${escape(shot.file)}" target="_blank" rel="noopener">` +
          `<img src="${escape(shot.file)}" alt="${escape(`${ofScreen[0].title}, ${shot.width} px, ${shot.theme}`)}" loading="lazy"></a>` +
          `</figure>`,
      )
      .join('\n')
    return `<section id="${escape(screen)}"><h2>${escape(ofScreen[0].title)}<code>${escape(screen)}</code></h2>
<div class="row">
${figures}
</div></section>`
  })
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>unpub screenshots</title>
<style>${css}</style>
</head>
<body>
<header>
<h1>unpub web client, ${shots.length} screenshots, ${new Date().toISOString().slice(0, 10)}</h1>
${radios('theme', 'Theme', ['all', 'light', 'dark'])}
${radios('width', 'Width', ['all', '1440', '390'])}
</header>
<main>
${sections.join('\n')}
</main>
</body>
</html>
`
}
