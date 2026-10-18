#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")"

echo "Рисуем иконку..."
cat > /tmp/gen_icon.swift <<'SWIFT'
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 1. Фон (Градиент)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let gradient = NSGradient(colors: [
    NSColor(red: 0.05, green: 0.1, blue: 0.25, alpha: 1.0),
    NSColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1.0)
])
gradient?.draw(in: rect, angle: 90)

// 2. Штурвал
NSColor.white.withAlphaComponent(0.9).setStroke()

let center = NSPoint(x: size/2, y: size/2)
let radius = size * 0.35

// Внешнее кольцо
let outerCircle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius*2, height: radius*2))
outerCircle.lineWidth = 40
outerCircle.stroke()

// Внутреннее кольцо
let innerRadius = radius * 0.7
let innerCircle = NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius*2, height: innerRadius*2))
innerCircle.lineWidth = 20
innerCircle.stroke()

// Спицы (8 штук)
for i in 0..<8 {
    let angle = CGFloat(i) * (CGFloat.pi / 4)
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x + cos(angle) * (innerRadius - 20), y: center.y + sin(angle) * (innerRadius - 20)))
    path.line(to: NSPoint(x: center.x + cos(angle) * (radius + 20), y: center.y + sin(angle) * (radius + 20)))
    path.lineWidth = 30
    path.stroke()
}

// Звезда ИИ в центре
let starPath = NSBezierPath()
let starRadius = innerRadius * 0.5
for i in 0..<4 {
    let angle = CGFloat(i) * (CGFloat.pi / 2) + CGFloat.pi / 4
    let outerPoint = NSPoint(x: center.x + cos(angle) * starRadius, y: center.y + sin(angle) * starRadius)
    let innerAngle = angle + CGFloat.pi / 4
    let innerPoint = NSPoint(x: center.x + cos(innerAngle) * (starRadius * 0.3), y: center.y + sin(innerAngle) * (starRadius * 0.3))
    
    if i == 0 { starPath.move(to: outerPoint) }
    else { starPath.line(to: outerPoint) }
    starPath.line(to: innerPoint)
}
starPath.close()
NSColor(red: 0.0, green: 0.8, blue: 1.0, alpha: 1.0).setFill()
starPath.fill()

image.unlockFocus()

if let tiff = image.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: "/tmp/icon_final.png"))
}
SWIFT

swift /tmp/gen_icon.swift
rm /tmp/gen_icon.swift

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

rm /tmp/icon_final.png
echo "Готово! Иконка сгенерирована и нарезана."
