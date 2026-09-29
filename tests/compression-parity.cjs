// Guard the compression settings and encoder profiles shared by Direct,
// App Store, and the native Swift app. Update this contract with every codec,
// quality, smart-mode, or fallback change in any implementation.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const html = read('frontend/index.html');
const swiftOptions = read('swift/Sources/OctoShrinkSwift/Models/CompressOptions.swift');
const swiftUI = read('swift/Sources/OctoShrinkSwift/Views/ContentView.swift');
const swiftState = read('swift/Sources/OctoShrinkSwift/ViewModels/AppState.swift');
const swiftEngine = read('swift/Sources/OctoShrinkSwift/Engine/CompressionEngine.swift');
const swiftRunner = read('swift/Sources/OctoShrinkSwift/Engine/CLIRunner.swift');
const directEngine = read('src-tauri/src/engine.rs');
const appStoreEngine = read('src-tauri/src/engine_inproc.rs');
const swiftBuild = read('scripts/build_swift.sh');
const buildAll = read('scripts/build_all.sh');

// The Tauri UI is the settings source of truth for both Tauri variants.
assert.match(html, /id="qualitySlider" min="10" max="100" value="75"/);
assert.match(swiftOptions, /var quality: Int = 75/);
assert.match(html, /id="smartMode" checked/);
assert.match(swiftOptions, /var smartMode: Bool = true/,
  'Swift must default to the same enabled smart mode as Direct and App Store');
assert.match(swiftUI, /Toggle\("自动选择最佳算法和参数", isOn: \$appState\.options\.smartMode\)/);
assert.match(swiftState, /setting-smartMode-direct-default-v1/);
assert.match(swiftState, /d\.set\(true, forKey: "setting-smartMode"\)/,
  'existing Swift installs must migrate off the old, weaker smart-mode default');
assert.match(html, /<option value="auto">自动选择/);
assert.match(swiftOptions, /var backend: CompressionBackend = \.auto/);
assert.match(html, /<option value="6" selected>平衡/);
assert.match(swiftOptions, /var effort: CompressionEffort = \.balanced/);
assert.match(swiftOptions, /case balanced = 6/);
assert.match(html, /name="outputMode" value="replace" checked/);
assert.match(swiftOptions, /var outputMode: OutputMode = \.replace/);
assert.match(swiftState, /options\.smartMode \|\| effectiveOutputFormat != \.original/);
assert.match(swiftState, /CompressionEngine\.compressSmart\(file: path, options: options\)/);

function functionBody(source, start, end) {
  const from = source.indexOf(start);
  assert.notEqual(from, -1, `missing function marker: ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.notEqual(to, -1, `missing function end marker: ${end}`);
  return source.slice(from, to);
}

const directSmart = functionBody(directEngine, 'pub async fn compress_smart', '#[cfg(test)]');
const appStoreSmart = functionBody(appStoreEngine, 'pub async fn compress_smart', '#[cfg(test)]');
const swiftSmart = functionBody(swiftEngine, 'static func compressSmart', 'private static func analyzeQuality');
for (const [name, body, expected] of [
  ['Direct', directSmart, ['compress_png(file, &opts)', 'compress_to_webp(file, &opts)']],
  ['App Store', appStoreSmart, ['compress_png(file, &opts)', 'compress_to_webp(file, &opts)']],
  ['Swift', swiftSmart, ['compressPNG(file: file, options: opts)', 'compressToWebP(file: file, options: opts)']],
]) {
  for (const candidate of expected) {
    assert.ok(body.includes(candidate), `${name} smart PNG mode must compare both PNG and WebP candidates`);
  }
}

// App Store uses in-process equivalents; pin their quality and effort mapping to
// the same values Swift passes to Direct's bundled encoders.
for (const [name, token] of [
  ['PNG quantization quality range', 'attr.set_quality((q - 10) as u8, q as u8)'],
  ['PNG quantization speed', 'attr.set_speed(3)'],
  ['oxipng effort preset', 'oxipng::Options::from_preset(level)'],
  ['JPEG quality', 'cinfo.set_quality(quality as f32)'],
  ['JPEG optimization', 'cinfo.set_optimize_coding(true)'],
  ['JPEG progressive mode', 'cinfo.set_progressive_mode()'],
  ['WebP quality', 'encoder.encode(quality as f32)'],
  ['AVIF quality', 'with_quality(quality as f32)'],
  ['AVIF speed', 'with_speed(6)'],
]) {
  assert.ok(appStoreEngine.includes(token), `App Store encoder profile missing ${name}`);
}

// Swift invokes the same Direct CLI tools with the same quality parameters.
// These paired assertions are the source-level contract for future codec edits.
const cliProfiles = [
  ['pngquant quality range', String.raw`format!("--quality={}-{}", q_low, q_high)`, String.raw`"--quality=\(qLow)-\(qHigh)"`],
  ['pngquant speed', '"--speed=3"', '"--speed=3"'],
  ['pngquant metadata stripping', '"--strip"', '"--strip"'],
  ['oxipng quality level', String.raw`format!("-o{}", level)`, String.raw`"-o\(level)"`],
  ['oxipng safe metadata stripping', '"safe"', '"safe"'],
  ['mozjpeg quality option', '"-quality"', '"-quality"'],
  ['mozjpeg optimization', '"-optimize"', '"-optimize"'],
  ['mozjpeg progressive encoding', '"-progressive"', '"-progressive"'],
  ['gifsicle optimization', '"--optimize=3"', '"--optimize=3"'],
  ['gifsicle color count', String.raw`format!("--colors={}", colors)`, String.raw`"--colors=\(colors)"`],
  ['gifsicle comment stripping', '"--no-comments"', '"--no-comments"'],
  ['cwebp quality', '"-q"', '"-q"'],
  ['cwebp method', '"-m".into(),', '"-m", "6"'],
  ['cwebp passes', '"-pass".into(),', '"-pass", "10"'],
  ['avifenc speed', '"--speed".into(),', '"--speed", "6"'],
  ['avifenc minimum quality', '"--min".into(),', '"--min", "0"'],
  ['avifenc quality maximum', '"--max".into(),', '"--max", "\\(quality)"'],
];
for (const [name, directToken, swiftToken] of cliProfiles) {
  assert.ok(directEngine.includes(directToken), `Direct encoder profile missing ${name}`);
  assert.ok(swiftEngine.includes(swiftToken), `Swift encoder profile differs for ${name}`);
}

// The Swift bundle must contain every CLI backend used by Direct. Missing tools
// used to silently select a different ImageIO fallback and produce different files.
assert.match(swiftBuild, /ENCODER_TOOLS=\(pngquant oxipng cjpeg cwebp avifenc gifsicle\)/);
assert.ok(swiftRunner.includes('case "avifenc": return ["--jobs", "\\(threadLimit)"]'));
assert.ok(swiftRunner.includes('case "oxipng": return ["--threads", "\\(threadLimit)"]'));
assert.match(buildAll, /bash "\$PROJECT_DIR\/scripts\/build_swift\.sh" \|\| fail "Swift 版构建失败"/);

console.log('Compression parity contract checks passed');
