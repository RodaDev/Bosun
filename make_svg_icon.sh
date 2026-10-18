#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

echo "Создаем векторную иконку..."
cat > /tmp/icon.svg <<'SVG'
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#0D1A40"/>
      <stop offset="100%" stop-color="#194D99"/>
    </linearGradient>
    <linearGradient id="starGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#00E5FF"/>
      <stop offset="100%" stop-color="#007BFF"/>
    </linearGradient>
  </defs>

  <rect width="1024" height="1024" fill="url(#bg)"/>
  <g transform="translate(512, 512)">
    <circle cx="0" cy="0" r="350" fill="none" stroke="white" stroke-opacity="0.9" stroke-width="40"/>
    <circle cx="0" cy="0" r="240" fill="none" stroke="white" stroke-opacity="0.9" stroke-width="20"/>
    <g stroke="white" stroke-opacity="0.9" stroke-width="30" stroke-linecap="round">
      <line x1="0" y1="-220" x2="0" y2="-370"/>
      <line x1="0" y1="220" x2="0" y2="370"/>
      <line x1="-220" y1="0" x2="-370" y2="0"/>
      <line x1="220" y1="0" x2="370" y2="0"/>
      <line x1="-155" y1="-155" x2="-261" y2="-261"/>
      <line x1="155" y1="155" x2="261" y2="261"/>
      <line x1="-155" y1="155" x2="-261" y2="261"/>
      <line x1="155" y1="-155" x2="261" y2="-261"/>
    </g>
    <path d="M 0,-120 Q 0,0 120,0 Q 0,0 0,120 Q 0,0 -120,0 Q 0,0 0,-120 Z" fill="url(#starGrad)"/>
  </g>
</svg>
SVG

echo "Конвертируем в PNG через qlmanage (встроенный просмотрщик macOS)..."
qlmanage -t -s 1024 -o /tmp /tmp/icon.svg > /dev/null 2>&1 || true

# qlmanage сохраняет файл с припиской .png
if [ -f "/tmp/icon.svg.png" ]; then
    mv /tmp/icon.svg.png /tmp/icon_final.png
else
    echo "Ошибка: qlmanage не смог отрисовать SVG. Попробуйте установить librsvg: brew install librsvg"
    exit 1
fi

echo "Нарезаем иконки в Assets.xcassets..."
DIR="Bosun/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$DIR"

cat > "$DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "32.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "64.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "256.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "512.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

sips -z 16 16     /tmp/icon_final.png --out "$DIR/16.png" > /dev/null
sips -z 32 32     /tmp/icon_final.png --out "$DIR/32.png" > /dev/null
sips -z 64 64     /tmp/icon_final.png --out "$DIR/64.png" > /dev/null
sips -z 128 128   /tmp/icon_final.png --out "$DIR/128.png" > /dev/null
sips -z 256 256   /tmp/icon_final.png --out "$DIR/256.png" > /dev/null
sips -z 512 512   /tmp/icon_final.png --out "$DIR/512.png" > /dev/null
sips -z 1024 1024 /tmp/icon_final.png --out "$DIR/1024.png" > /dev/null

rm /tmp/icon_final.png /tmp/icon.svg 2>/dev/null || true
echo "✅ Готово! Иконка сгенерирована и нарезана."
