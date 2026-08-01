#!/bin/bash
# Monta ClaudeBarLocal.app a partir do arquivo Swift, sem projeto Xcode.
# Precisa apenas de: xcode-select --install
set -euo pipefail

cd "$(dirname "$0")"

APP="ClaudeBarLocal.app"
BIN_DIR="$APP/Contents/MacOS"
MIN_MACOS="13.0"

command -v swiftc >/dev/null || {
  echo "swiftc nao encontrado. Rode: xcode-select --install" >&2
  exit 1
}

rm -rf "$APP"
mkdir -p "$BIN_DIR" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeBarLocal</string>
  <key>CFBundleDisplayName</key><string>Claude Bar Local</string>
  <key>CFBundleIdentifier</key><string>local.claudebar</string>
  <key>CFBundleExecutable</key><string>ClaudeBarLocal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <!-- LSUIElement: sem icone no Dock, so na menu bar -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

ARCH="$(uname -m)"   # arm64 ou x86_64

echo "Compilando (${ARCH}, macOS ${MIN_MACOS}+)..."
# -parse-as-library: sem isso, um .swift unico compila em modo script e o @main
# e rejeitado ("'main' attribute cannot be used in a module that contains top-level code").
swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  -framework SwiftUI -framework AppKit \
  -o "$BIN_DIR/ClaudeBarLocal" \
  ClaudeBarLocal.swift

# Atributos estendidos fazem o codesign recusar o bundle com
# "resource fork, Finder information, or similar detritus not allowed".
#
# Esta pasta esta dentro do Desktop sincronizado por iCloud, e o file provider
# reinsere com.apple.FinderInfo na raiz do bundle em segundos -- entao nao basta
# limpar uma vez: limpa a raiz imediatamente antes de cada tentativa.
xattr -cr "$APP" 2>/dev/null || true

signed=0
for _ in 1 2 3; do
  xattr -c "$APP" 2>/dev/null || true
  # Assinatura ad-hoc: suficiente para rodar local, sem conta de developer.
  # (O app nao le Keychain, entao rebuild nao dispara nenhum prompt.)
  if codesign --force --sign - "$APP" 2>/dev/null; then
    signed=1
    break
  fi
done

if [ "$signed" != "1" ]; then
  echo "codesign falhou (xattrs do iCloud). Assinando via staging fora da pasta sincronizada..." >&2
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/" \
    && xattr -cr "$STAGE/$APP" \
    && codesign --force --sign - "$STAGE/$APP" \
    && rm -rf "$APP" \
    && cp -R "$STAGE/$APP" "$APP"
  rm -rf "$STAGE"
fi

codesign -dv "$APP" 2>&1 | grep -E 'Identifier|Signature' || true

echo ""
echo "Pronto: $(pwd)/$APP"
echo "Testar:   open $APP"
echo "Instalar: cp -R $APP /Applications/"
